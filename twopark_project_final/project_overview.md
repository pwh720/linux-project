# 투박(TWOPARK) 프로젝트 구조 설명

공공데이터포털의 대중교통 이용인원 API를 받아와 시각화하는 대시보드입니다.  
Docker 컨테이너 3개(collector, flask-api, nginx) + 공유 볼륨으로 구성됩니다.

---

## 전체 아키텍처

```
사용자 브라우저
      ↕ (HTTP :80)
  [nginx] ─────────── /api/* 요청 → [flask-api :5000]
      |                                    ↕
 [shared-html 볼륨]              공공데이터포털 API
      ↑
 [collector] (1분마다 HTML 재생성)
```

---

## 컴포넌트별 역할

### 1. `collector/` — 정적 HTML 생성기

컨테이너가 시작될 때 초기 HTML을 즉시 생성하고, 이후 1분마다 최신 데이터로 덮어씁니다.

| 파일 | 역할 |
|---|---|
| `dockerfile` | 컨테이너 빌드 정의 (아래 별도 설명) |
| `fetch_data.py` | 공공데이터포털 API를 Python으로 호출해 JSON 반환 |
| `update.sh` | fetch_data.py 실행 → jq로 파싱 → `index.html` 생성 |
| `entrypoint.sh` | 컨테이너 시작 시 update.sh 1회 즉시 실행 후, cron으로 1분마다 재실행 등록 |

#### `collector/dockerfile`

```dockerfile
FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    curl \
    cron \
    jq \
    python3 \
    python3-pip \
    && pip3 install requests --break-system-packages \
    && apt-get clean

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY update.sh     /usr/local/bin/update.sh
COPY fetch_data.py /usr/local/bin/fetch_data.py

RUN chmod +x /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/update.sh

VOLUME /shared

ENTRYPOINT ["entrypoint.sh"]
```

| 항목 | 설명 |
|---|---|
| `FROM ubuntu:latest` | 베이스 이미지로 Ubuntu 사용. cron, jq 등 리눅스 도구를 그대로 쓰기 위해 선택 |
| `apt-get install` | cron(스케줄러), jq(JSON 파서), python3 + pip(API 호출용) 설치 |
| `pip3 install requests` | fetch_data.py에서 공공API 호출에 사용하는 라이브러리 |
| `COPY ... /usr/local/bin/` | 스크립트 3개를 컨테이너 내부의 실행 경로에 복사 |
| `chmod +x` | entrypoint.sh, update.sh에 실행 권한 부여 |
| `VOLUME /shared` | nginx와 공유하는 볼륨 마운트 포인트 선언 (index.html이 여기에 생성됨) |
| `ENTRYPOINT ["entrypoint.sh"]` | 컨테이너 시작 시 entrypoint.sh를 진입점으로 실행 |

---

### 2. `flask-api/` — 동적 API 서버

사용자가 지역/기간/날짜를 바꿔 조회할 때 호출되는 백엔드 API 서버입니다.  
공공데이터 API를 직접 호출한 뒤 가공해서 JSON으로 반환합니다.

**엔드포인트 목록:**

| 엔드포인트 | 파라미터 | 설명 |
|---|---|---|
| `GET /api/query` | `ctpv_cd`, `unit`, `date` | 지역·단위·날짜 기반 조회. unit = daily/monthly/yearly |
| `GET /api/station` | `ctpv_cd`, `sttn_id`, `name`, `year` | 특정 정류장의 연간 월별 추이 조회 |
| `GET /api/quarterly` | `ctpv_cd`, `year` | 지역·연도 기반 분기별(Q1~Q4) TOP 10 조회 |
| `GET /api/debug/monthly` | `ctpv_cd`, `ym` | 월별 API 원본 응답 확인용 *(임시, 배포 전 삭제 예정)* |
| `GET /api/debug/yearly` | `ctpv_cd`, `year` | 년별 API 원본 응답 확인용 *(임시, 배포 전 삭제 예정)* |

**`/api/query` 응답 데이터 3가지:**
- 정류장별 혼잡도 **TOP 10 랭킹**
- **이용자 유형별** 합계 (일반인 / 청소년 / 경로 / 장애인 등)
- **버스 vs 지하철** 이용량 비교

**내부 유틸 함수:**

| 함수 | 설명 |
|---|---|
| `_fetch_monthly(ctpv_cd, ym)` | 월별 API 1회 호출 → 정류장별 합산 dict 반환. `/api/quarterly`와 `/api/station`이 공통으로 사용 |
| `_fetch_daily(ctpv_cd, date_str)` | 일별 API 1회 호출 → 정류장별 합산 dict 반환. `/api/station` 폴백용 |

> **참고 — 일별/월별 API의 sttn_id 불일치:**  
> 일별 API와 월별 API는 서로 다른 sttn_id 체계를 사용합니다. 월별 API는 일부 기간(2025년 이후)에서 정류장 이름(sgg_nm, emd_nm)도 null로 반환합니다.  
> `/api/station`은 이를 처리하기 위해 **월별 API 우선 조회 → 실패 시 일별 API 폴백(매월 1일 기준)** 방식으로 동작합니다.

**지원 지역 (ctpv_cd):** 광주(29), 부산(26), 대구(27), 대전(30), 울산(31), 세종(36), 강원(51), 충북(43), 충남(44), 전북(52), 전남(46), 경북(47), 경남(48), 제주(50)

| 파일 | 역할 |
|---|---|
| `Dockerfile` | 컨테이너 빌드 정의 (아래 별도 설명) |
| `app.py` | Flask 앱 본체. 위 엔드포인트 처리 및 데이터 가공 |
| `requirements.txt` | 의존 패키지 목록 (flask, requests, flask-cors) |

#### `flask-api/Dockerfile`

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
CMD ["python", "app.py"]
```

| 항목 | 설명 |
|---|---|
| `FROM python:3.11-slim` | 공식 Python 3.11 경량 이미지 사용. ubuntu 대비 용량이 작고 Python에 최적화 |
| `WORKDIR /app` | 이후 명령의 작업 디렉토리를 `/app`으로 설정 |
| `COPY requirements.txt .` | 의존성 파일만 먼저 복사 (레이어 캐시 최적화 — 코드만 바뀌면 pip install을 재실행하지 않음) |
| `RUN pip install -r requirements.txt` | flask, requests, flask-cors 설치 |
| `COPY app.py .` | 앱 코드 복사 |
| `CMD ["python", "app.py"]` | 컨테이너 시작 시 Flask 서버 실행 (0.0.0.0:5000) |

---

### 3. `nginx/` — 리버스 프록시 + 정적 파일 서버

외부의 모든 HTTP 요청을 받아 적절한 곳으로 라우팅합니다.  
별도 Dockerfile 없이 `docker-compose.yml`에서 공식 `nginx:latest` 이미지를 그대로 사용합니다.

| 파일 | 역할 |
|---|---|
| `nginx.conf` | 요청 경로에 따른 라우팅 규칙 정의 |

**라우팅 규칙:**

| 경로 | 처리 방식 |
|---|---|
| `/` | `shared-html` 볼륨의 `index.html` 서빙 (collector가 생성한 정적 파일) |
| `/api/` | `flask-api:5000` 컨테이너로 프록시 |

---

### 4. 프론트엔드 화면 구조

`update.sh`가 생성하는 `index.html`은 **탭 2개**로 구성됩니다.

#### 탭 1 — 📊 기존 조회
지역 / 조회단위(일별·월별·년별) / 날짜를 입력해 실시간 조회하는 메인 화면입니다.

| 카드 | 설명 |
|---|---|
| 정류장별 혼잡도 랭킹 TOP 10 | 이용인원 상위 10개 정류장. 표/그래프 전환 가능. 월별 조회 시 행 클릭 → 월별 추이 모달 |
| 이용자 유형별 비율 | 일반인·청소년·어린이·경로·장애인·국가유공자 비율. 그래프/표 전환 가능 |
| 버스 vs 지하철 이용 비교 | trfc_mns_se_cd 기준(B=버스, T=지하철) 막대 차트 |

> **정류장 월별 추이 모달**: 월별 조회 결과에서만 정류장 행 클릭 가능. 클릭 시 해당 정류장의 1~12월 이용인원 막대 차트를 모달로 표시. 연도 변경 드롭다운 제공.

#### 탭 2 — 📅 분기별 비교
지역과 연도를 선택하면 Q1~Q4 각 분기의 이용인원 TOP 10을 4개 카드로 나란히 보여줍니다.  
백엔드 `/api/quarterly`를 호출하며, 월별 API를 12개월 병렬 호출 후 분기별로 합산합니다.

---

### 5. `docker-compose.yml` — 전체 오케스트레이션

3개의 서비스를 한 번에 정의하고, 서비스 간 의존관계 및 볼륨 공유를 설정합니다.

| 설정 | 설명 |
|---|---|
| `shared-html` 볼륨 | collector(쓰기)와 nginx(읽기)가 같은 볼륨을 공유 |
| `restart: always` | 모든 서비스가 예외 없이 자동 재시작 |
| `depends_on` | nginx가 collector, flask-api보다 나중에 시작 |
| `ports: "80:80"` | 외부 포트 80을 nginx로 노출 (flask-api는 외부 미노출) |

---

## 데이터 흐름 요약

| 상황 | 흐름 |
|---|---|
| **초기 로드** | collector가 생성한 정적 HTML을 nginx가 바로 전달 → 페이지가 빠르게 뜸 |
| **사용자 조회** | 지역/날짜 변경 시 브라우저가 `/api/query` 호출 → flask-api가 공공API 실시간 요청 → 차트 업데이트 |
| **자동 갱신** | collector가 1분마다 HTML 재생성 + 프론트엔드 JS도 60초마다 마지막 검색을 재조회 |
| **분기별 조회** | 브라우저 → `/api/quarterly` → flask-api가 월별API 12회 병렬 호출 → 분기별 합산 → 4개 카드 렌더링 |
| **정류장 월별 추이** | 월별 조회 후 정류장 클릭 → `/api/station` → 월별API 12개월 병렬 조회(1순위) → 데이터 없으면 일별API 매월1일 병렬 조회(2순위) → 막대 차트 모달 표시 |
