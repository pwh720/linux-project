# 투박 - 대중교통 이용 현황 대시보드

공공 데이터 포털의 대중교통 이용인원 API를 활용해 지역별 혼잡도를 시각화하는 웹 대시보드입니다.  
Docker Compose 명령어 하나로 실행되며, 1분마다 데이터를 자동으로 갱신합니다.

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| 기본 조회 | 지역·단위(일/월/연) 선택 → 정류장 랭킹 TOP10, 이용자 유형 비율, 버스 vs 지하철 비교 |
| 오늘 예측 | 최근 30일 일평균을 병렬 API 호출로 계산해 오늘 예상 수치 제공 |
| 혼잡도 지도 | 전국 14개 시·도를 SVG 지도로 시각화, 3단계(혼잡/보통/여유) 색상 표시 |
| 분기별 비교 | 선택 연도의 1~4분기 정류장 TOP10을 한 화면에 나란히 비교 |
| 정류장 추이 | 월별 조회 시 정류장 클릭 → 해당 정류장의 연간 월별 이용 추이 모달 팝업 |
| 자동 갱신 | 1분마다 HTML 재생성, 브라우저도 60초마다 마지막 검색 자동 재조회 |

---

## 기술 스택

| 영역 | 사용 기술 |
|------|----------|
| 인프라 | Docker, Docker Compose, nginx |
| 백엔드 | Python 3.11, Flask, flask-cors, requests |
| 데이터 수집 | bash, Python, jq, cron |
| 프론트엔드 | HTML / CSS / JavaScript, Chart.js |
| 데이터 출처 | 국토교통부 대중교통 이용객 수 정보 서비스 (data.go.kr) |

---

## 아키텍처

```
twopark_project/
│
├── docker-compose.yml          ← 3개 서비스 정의
│
├── collector/                  ← 데이터 수집 및 HTML 생성 컨테이너
│   ├── Dockerfile
│   ├── entrypoint.sh           ← 컨테이너 시작 시 실행 (최초 1회 + cron 등록)
│   ├── update.sh               ← API 호출 → jq 파싱 → index.html 생성
│   └── fetch_data.py           ← 공공 API 호출 스크립트
│
├── flask-api/                  ← REST API 서버 컨테이너
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py                  ← /api/* 엔드포인트 구현
│
└── nginx/
    └── nginx.conf              ← 정적 파일 서빙 + /api/ 리버스 프록시
```

### 데이터 흐름

```
[공공 API] → collector(fetch_data.py) → update.sh → index.html
                                                        ↓
                                               shared-html 볼륨
                                                        ↓
[브라우저] ← nginx(:80) ← /        → shared-html/index.html
                        ↑ /api/   → flask-api(:5000) → [공공 API]
```

- **collector**: 1분마다 공공 API를 호출해 정적 `index.html`을 생성하고 shared 볼륨에 저장
- **flask-api**: 브라우저의 동적 조회 요청(`/api/*`)을 받아 공공 API로 중계
- **nginx**: 정적 HTML 서빙 + `/api/` 요청을 flask-api로 프록시

---

## 시작하기

### 사전 요구사항

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) 설치

### 실행

```cmd
docker-compose up --build
```

브라우저에서 `http://localhost` 접속

### 종료

```cmd
docker-compose down
```

### 공공 API 키 설정

`flask-api/app.py` 13번째 줄의 기본 키를 본인의 키로 교체하거나, 환경변수로 주입합니다.

```python
SERVICE_KEY = os.getenv("SERVICE_KEY", "YOUR_API_KEY_HERE")
```

> API 키 발급: [공공 데이터 포털](https://www.data.go.kr/data/15142080/openapi.do) 에서 활용 신청

---

## API 엔드포인트

모든 요청은 nginx를 통해 `http://localhost/api/` 로 접근합니다.

### `GET /api/query` — 지역별 이용현황 조회

| 파라미터 | 필수 | 설명 | 예시 |
|----------|------|------|------|
| `ctpv_cd` | 필수 | 시·도 코드 | `29` |
| `unit` | 필수 | 조회 단위 (`daily` / `monthly` / `yearly` / `today`) | `daily` |
| `date` | 조건부 | unit이 today가 아닐 때 필수 | `20250801` |

```
/api/query?ctpv_cd=29&unit=daily&date=20250801
/api/query?ctpv_cd=29&unit=today
```

**응답**
```json
{
  "ranking":  [{ "sttn_id": "...", "name": "...", "total": 12345 }],
  "userType": [{ "type": "일반인", "total": 9000 }],
  "bus":    5000,
  "subway": 7000,
  "total":  12000,
  "meta":   { "ctpv_nm": "광주광역시", "date": "20250801", "unit": "daily" }
}
```

---

### `GET /api/map` — 전국 혼잡도 조회

| 파라미터 | 필수 | 설명 |
|----------|------|------|
| `unit` | 선택 | `today`(기본값) 또는 `daily` |
| `date` | 조건부 | unit=daily일 때 필수 (`YYYYMMDD`) |

```
/api/map?unit=today
/api/map?unit=daily&date=20250801
```

**응답**
```json
{
  "regions": [
    { "ctpv_cd": "29", "ctpv_nm": "광주광역시", "total": 50000, "level": "high" }
  ],
  "meta": { "thresholds": { "low": 30000, "high": 60000 } }
}
```

---

### `GET /api/quarterly` — 분기별 정류장 랭킹

| 파라미터 | 필수 | 설명 |
|----------|------|------|
| `ctpv_cd` | 필수 | 시·도 코드 |
| `year` | 필수 | 연도 4자리 |

```
/api/quarterly?ctpv_cd=29&year=2025
```

**응답**
```json
{
  "q1": [{ "sttn_id": "...", "name": "...", "total": 99999 }],
  "q2": [...],
  "q3": [...],
  "q4": [...],
  "meta": { "ctpv_nm": "광주광역시", "year": "2025" }
}
```

---

### `GET /api/station` — 정류장 월별 추이

| 파라미터 | 필수 | 설명 |
|----------|------|------|
| `ctpv_cd` | 필수 | 시·도 코드 |
| `sttn_id` | 조건부 | 정류장 ID (sttn_id 또는 name 중 하나 필수) |
| `name` | 조건부 | 정류장 이름 |
| `year` | 필수 | 연도 4자리 |

```
/api/station?ctpv_cd=29&sttn_id=ABC123&year=2025
```

**응답**
```json
{
  "found": true,
  "source": "monthly",
  "months": [{ "month": 1, "total": 8000 }, { "month": 2, "total": 7500 }],
  "meta": { "ctpv_nm": "광주광역시", "year": "2025" }
}
```

---

## 지원 지역 (시·도 코드) - 존재하지 않는 지역 데이터 다수

| 코드 | 지역 | 코드 | 지역 |
|------|------|------|------|
| 26 | 부산광역시 | 43 | 충청북도 |
| 27 | 대구광역시 | 44 | 충청남도 |
| 29 | 광주광역시 | 46 | 전라남도 |
| 30 | 대전광역시 | 47 | 경상북도 |
| 31 | 울산광역시 | 48 | 경상남도 |
| 36 | 세종특별자치시 | 50 | 제주특별자치도 |
| 51 | 강원특별자치도 | 52 | 전북특별자치도 |

---

## 팀원 참여 항목

**박우혁**
- 오늘 혼잡도 예측 (데이터의 정보가 오늘 날짜의 정보가 존재하지 않아, 근 한달 간의 정보의 통계를 구하여 오늘 혼잡도를 예측)
- 혼잡도 지도 (지도 이미지 상으로 혼잡도의 상, 중, 하를 색상으로 구분하여 한눈에 볼 수 있게 표시, 각 지역을 눌러 지역의 상세 정보 확인 가능)
- 코드 병합 및 조장 역할

**연일**
- 정류장별 혼잡도 랭킹 TOP 10
- 이용자 유형별 비율
- 버스 vs 지하철 이용 비교
- 검색바 (지역 / 조회단위 / 날짜)

**이상윤**
- 분기별 비교 탭: 기존 조회 탭 옆에 분기별 비교 탭이 추가됨.
- 정류장 클릭 시 월별 추이 확인: 월별 단위로 조회한 결과에서 TOP 10 정류장 행을 클릭하면 해당 정류장의 12개월 이용인원 추이를 막대 차트로 보여주는 모달이 열림.

**박상호**
- 현재 위치(GPS) 자동 추적
- 오늘 날짜 기반 자동 조회 구현
