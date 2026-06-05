from flask import Flask, request, jsonify
from flask_cors import CORS
import requests as http
from datetime import datetime, timedelta
from collections import defaultdict
import concurrent.futures
import os

app = Flask(__name__)
CORS(app)

# 환경변수 SERVICE_KEY가 있으면 우선 사용하고, 없으면 기존 파일의 키를 사용합니다.
SERVICE_KEY = "4c686412dc79365266261a85c66f7c1ce97ecee4ded35b0335dedc2264e42c8d"
BASE = "https://apis.data.go.kr/1613000/PublicTransportationPassengerCount"

ENDPOINTS = {
    "daily":   ("getDailyPublicTransportationPassengerCount",   "opr_ymd"),
    "monthly": ("getMonthlyPublicTransportationPassengerCount", "opr_ym"),
    "yearly":  ("getAnnualPublicTransportationPassengerCount",  "opr_yr"),
}

REGIONS = {
    "26": "부산광역시", "27": "대구광역시", "29": "광주광역시",
    "30": "대전광역시", "31": "울산광역시", "36": "세종특별자치시",
    "43": "충청북도",   "44": "충청남도",   "46": "전라남도",
    "47": "경상북도",   "48": "경상남도",   "50": "제주특별자치도",
    "51": "강원특별자치도", "52": "전북특별자치도",
}

QUARTERS = {
    "q1": [1, 2, 3],
    "q2": [4, 5, 6],
    "q3": [7, 8, 9],
    "q4": [10, 11, 12],
}

REGION_CENTERS = {
    "26": (35.1796, 129.0756), "27": (35.8714, 128.6014),
    "29": (35.1595, 126.8526), "30": (36.3504, 127.3845),
    "31": (35.5384, 129.3114), "36": (36.4800, 127.2890),
    "43": (36.6357, 127.4913), "44": (36.6588, 126.6728),
    "46": (34.8161, 126.4629), "47": (36.5760, 128.5056),
    "48": (35.2383, 128.6924), "50": (33.4996, 126.5312),
    "51": (37.8854, 127.7298), "52": (35.8203, 127.1088),
}


def safe_int(value, default=0):
    try:
        if value in (None, ""):
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def station_name(item):
    sttn_nm = item.get("sttn_nm")
    if sttn_nm:
        return sttn_nm
    return f"{item.get('sgg_nm') or '미상'} {item.get('emd_nm') or '미상'}".strip()


def nearest_region(lat, lon):
    try:
        lat = float(lat)
        lon = float(lon)
    except (TypeError, ValueError):
        return "29"

    def distance_sq(center):
        return (center[0] - lat) ** 2 + (center[1] - lon) ** 2

    return min(REGION_CENTERS, key=lambda cd: distance_sq(REGION_CENTERS[cd]))


def fetch_daily_items(date_str, ctpv_cd):
    """특정 날짜의 daily 데이터를 가져와 items 리스트 반환. 실패 시 빈 리스트."""
    endpoint, date_param = ENDPOINTS["daily"]
    url = f"{BASE}/{endpoint}"
    try:
        resp = http.get(url, params={
            "serviceKey": SERVICE_KEY,
            "pageNo": 1,
            "numOfRows": 1000,
            date_param: date_str,
            "ctpv_cd": ctpv_cd,
            "dataType": "JSON",
        }, timeout=30)
        resp.raise_for_status()
        raw = resp.json()
        items = raw["Response"]["body"]["items"]["item"]
        if isinstance(items, dict):
            items = [items]
        # 미상 데이터 필터링
        return [i for i in items if i.get("sttn_id") != "~"]
    except Exception:
        return []


def aggregate_items(items):
    """items 리스트로부터 ranking, userType, bus, subway, total 집계."""
    sttn_map = {}
    for item in items:
        sid = item.get("sttn_id", "unknown")
        if sid not in sttn_map:
            sttn_map[sid] = {
                "sttn_id": sid,
                "name": station_name(item),
                "total": 0,
            }
        sttn_map[sid]["total"] += safe_int(item.get("utztn_nope"))

    ranking = sorted(sttn_map.values(), key=lambda x: -x["total"])[:10]

    user_map = {}
    for item in items:
        t = item.get("users_type_nm", "기타")
        user_map[t] = user_map.get(t, 0) + safe_int(item.get("utztn_nope"))
    user_type = [{"type": k, "total": v} for k, v in user_map.items()]

    bus    = sum(safe_int(i.get("utztn_nope")) for i in items if i.get("trfc_mns_se_cd") == "B")
    subway = sum(safe_int(i.get("utztn_nope")) for i in items if i.get("trfc_mns_se_cd") == "T")
    total  = sum(safe_int(i.get("utztn_nope")) for i in items)

    return ranking, user_type, bus, subway, total


@app.route("/api/query")
def query():
    ctpv_cd = request.args.get("ctpv_cd")
    unit    = request.args.get("unit", "daily")
    date    = request.args.get("date", "")
    lat     = request.args.get("lat")
    lon     = request.args.get("lon")

    if not ctpv_cd and lat and lon:
        ctpv_cd = nearest_region(lat, lon)
    if not ctpv_cd:
        ctpv_cd = "29"

    # ── today 모드: 오늘 기준 -30일 ~ -1일 daily 평균 ──────────────────────
    if unit == "today":
        today = datetime.today()
        date_range = [
            (today - timedelta(days=i)).strftime("%Y%m%d")
            for i in range(20, 51)   # -20일 ~ -50일 (데이터 지연 고려)
        ]

        # 병렬로 30일치 API 호출
        all_days_items = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            future_to_date = {
                executor.submit(fetch_daily_items, d, ctpv_cd): d
                for d in date_range
            }
            for future in concurrent.futures.as_completed(future_to_date):
                d = future_to_date[future]
                all_days_items[d] = future.result()

        # 데이터가 하나라도 있는 날짜만 카운트
        valid_days = [d for d, items in all_days_items.items() if items]
        if not valid_days:
            return jsonify({"error": "최근 30일간 데이터를 가져올 수 없습니다."}), 502

        day_count = len(valid_days)

        # 정류장별 합산 후 평균
        sttn_total = defaultdict(lambda: {"name": "", "total": 0})
        user_total = defaultdict(int)
        bus_total = subway_total = grand_total = 0

        for d in valid_days:
            items = all_days_items[d]
            for item in items:
                sid = item.get("sttn_id", "unknown")
                nope = safe_int(item.get("utztn_nope"))
                sttn_total[sid]["name"] = station_name(item)
                sttn_total[sid]["total"] += nope

                t = item.get("users_type_nm", "기타")
                user_total[t] += nope

            bus_total    += sum(safe_int(i.get("utztn_nope")) for i in items if i.get("trfc_mns_se_cd") == "B")
            subway_total += sum(safe_int(i.get("utztn_nope")) for i in items if i.get("trfc_mns_se_cd") == "T")
            grand_total  += sum(safe_int(i.get("utztn_nope")) for i in items)

        # 평균 적용
        ranking = sorted(
            [{"sttn_id": sid, "name": v["name"], "total": round(v["total"] / day_count)}
             for sid, v in sttn_total.items()],
            key=lambda x: -x["total"]
        )[:10]

        user_type = [
            {"type": k, "total": round(v / day_count)}
            for k, v in user_total.items()
        ]

        return jsonify({
            "ranking":  ranking,
            "userType": user_type,
            "bus":      round(bus_total    / day_count),
            "subway":   round(subway_total / day_count),
            "total":    round(grand_total  / day_count),
            "meta": {
                "ctpv_nm":   REGIONS.get(ctpv_cd, "알 수 없음"),
                "date":      today.strftime("%Y%m%d"),
                "unit":      "today",
                "note":      f"최근 {day_count}일 일평균 ({date_range[-1]} ~ {date_range[0]})",
            },
        })

    # ── 기존 daily / monthly / yearly 모드 ─────────────────────────────────
    if unit not in ENDPOINTS:
        return jsonify({"error": "unit은 daily/monthly/yearly/today 중 하나여야 합니다."}), 400
    if not date:
        return jsonify({"error": "date 파라미터가 필요합니다."}), 400

    endpoint, date_param = ENDPOINTS[unit]
    url = f"{BASE}/{endpoint}"

    try:
        resp = http.get(url, params={
            "serviceKey": SERVICE_KEY,
            "pageNo": 1,
            "numOfRows": 1000,
            date_param: date,
            "ctpv_cd": ctpv_cd,
            "dataType": "JSON",
        }, timeout=30)
        resp.raise_for_status()
        raw = resp.json()
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    try:
        # 일별/월별: {"Response": {"body": ...}}, 연도별: {"header": ..., "body": ...}
        body = raw.get("Response", raw).get("body", {})
        items = body["items"]["item"]
        if isinstance(items, dict):
            items = [items]
    except (KeyError, TypeError):
        return jsonify({"error": "API 응답에서 데이터를 찾을 수 없습니다."}), 502

    # 미상 데이터 필터링
    items = [i for i in items if i.get("sttn_id") != "~"]

    ranking, user_type, bus, subway, total = aggregate_items(items)

    meta_item = items[0] if items else {}
    return jsonify({
        "ranking":  ranking,
        "userType": user_type,
        "bus":      bus,
        "subway":   subway,
        "total":    total,
        "meta": {
            "ctpv_nm": meta_item.get("ctpv_nm") or REGIONS.get(ctpv_cd, "알 수 없음"),
            "date":    date,
            "unit":    unit,
        },
    })


def fetch_region_total(ctpv_cd, date_str):
    """특정 지역·날짜의 총 이용인원 반환. 실패 시 None."""
    endpoint, date_param = ENDPOINTS["daily"]
    url = f"{BASE}/{endpoint}"
    try:
        resp = http.get(url, params={
            "serviceKey": SERVICE_KEY,
            "pageNo": 1,
            "numOfRows": 1000,
            date_param: date_str,
            "ctpv_cd": ctpv_cd,
            "dataType": "JSON",
        }, timeout=30)
        resp.raise_for_status()
        raw = resp.json()
        items = raw["Response"]["body"]["items"]["item"]
        if isinstance(items, dict):
            items = [items]
        items = [i for i in items if i.get("sttn_id") != "~"]
        total = sum(safe_int(i.get("utztn_nope")) for i in items)
        return total if items else None
    except Exception:
        return None


@app.route("/api/map")
def map_data():
    """14개 전 지역 혼잡도 반환. unit=today 시 최근 30일 평균 사용."""
    unit = request.args.get("unit", "today")
    date = request.args.get("date", "")

    if unit == "today":
        today = datetime.today()
        date_list = [
            (today - timedelta(days=i)).strftime("%Y%m%d")
            for i in range(20, 51)
        ]
    else:
        if not date:
            return jsonify({"error": "date 파라미터가 필요합니다."}), 400
        # 입력 날짜 포함 최근 5일 범위로 탐색 (데이터 없는 날 보완)
        try:
            base = datetime.strptime(date, "%Y%m%d")
            date_list = [
                (base - timedelta(days=i)).strftime("%Y%m%d")
                for i in range(0, 6)
            ]
        except Exception:
            date_list = [date]

    all_codes = list(REGIONS.keys())
    tasks = [(cd, d) for cd in all_codes for d in date_list]
    results = {}

    # 1차 호출
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
        future_map = {
            executor.submit(fetch_region_total, cd, d): (cd, d)
            for cd, d in tasks
        }
        for future in concurrent.futures.as_completed(future_map):
            cd, d = future_map[future]
            val = future.result()
            if val is not None:
                results.setdefault(cd, []).append(val)

    # 2차 재시도: 데이터가 없는 지역만 재호출
    failed_tasks = [(cd, d) for cd, d in tasks if cd not in results]
    if failed_tasks:
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
            future_map2 = {
                executor.submit(fetch_region_total, cd, d): (cd, d)
                for cd, d in failed_tasks
            }
            for future in concurrent.futures.as_completed(future_map2):
                cd, d = future_map2[future]
                val = future.result()
                if val is not None:
                    results.setdefault(cd, []).append(val)

    region_totals = {}
    for cd in all_codes:
        vals = results.get(cd, [])
        region_totals[cd] = round(sum(vals) / len(vals)) if vals else 0

    valid_vals = [v for v in region_totals.values() if v > 0]
    if valid_vals:
        sorted_vals = sorted(valid_vals)
        n = len(sorted_vals)
        low_threshold  = sorted_vals[int(n * 0.33)]
        high_threshold = sorted_vals[int(n * 0.66)]
    else:
        low_threshold = high_threshold = 0

    def get_level(total):
        if total == 0:              return "unknown"
        if total >= high_threshold: return "high"
        if total >= low_threshold:  return "medium"
        return "low"

    regions_out = []
    for cd in all_codes:
        total = region_totals[cd]
        regions_out.append({
            "ctpv_cd": cd,
            "ctpv_nm": REGIONS[cd],
            "total":   total,
            "level":   get_level(total),
        })

    return jsonify({
        "regions": regions_out,
        "meta": {
            "unit": unit,
            "date": date if unit != "today" else datetime.today().strftime("%Y%m%d"),
            "thresholds": {"low": low_threshold, "high": high_threshold},
        }
    })


def fetch_items(unit, ctpv_cd, date_value, timeout=30):
    """daily/monthly/yearly API에서 item 리스트를 가져옵니다."""
    endpoint, date_param = ENDPOINTS[unit]
    url = f"{BASE}/{endpoint}"
    resp = http.get(url, params={
        "serviceKey": SERVICE_KEY,
        "pageNo": 1,
        "numOfRows": 1000,
        date_param: date_value,
        "ctpv_cd": ctpv_cd,
        "dataType": "JSON",
    }, timeout=timeout)
    resp.raise_for_status()
    raw = resp.json()
    items = raw.get("Response", {}).get("body", {}).get("items", {}).get("item", [])
    if isinstance(items, dict):
        items = [items]
    if not isinstance(items, list):
        return []
    return [i for i in items if i.get("sttn_id") != "~"]


def fetch_monthly_ranking(ctpv_cd, ym):
    """월별 API 1회 호출 후 정류장별 합산 dict 반환."""
    try:
        items = fetch_items("monthly", ctpv_cd, ym, timeout=10)
    except Exception:
        return {}

    result = {}
    for item in items:
        sid = item.get("sttn_id") or station_name(item)
        if sid not in result:
            result[sid] = {
                "sttn_id": sid,
                "name": station_name(item),
                "total": 0,
            }
        result[sid]["total"] += safe_int(item.get("utztn_nope"))
    return result


@app.route("/api/quarterly")
def quarterly():
    ctpv_cd = request.args.get("ctpv_cd", "29")
    year = request.args.get("year", "")

    if not year or len(year) != 4:
        return jsonify({"error": "연도 4자리를 입력하세요"}), 400

    ym_list = [f"{year}{month:02d}" for month in range(1, 13)]
    monthly_results = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        future_map = {
            executor.submit(fetch_monthly_ranking, ctpv_cd, ym): ym
            for ym in ym_list
        }
        for future in concurrent.futures.as_completed(future_map):
            monthly_results[future_map[future]] = future.result()

    final_data = {}
    for quarter, months in QUARTERS.items():
        merged = {}
        for month in months:
            ym = f"{year}{month:02d}"
            for sid, info in monthly_results.get(ym, {}).items():
                if sid not in merged:
                    merged[sid] = {
                        "sttn_id": info.get("sttn_id", sid),
                        "name": info.get("name", "미상"),
                        "total": 0,
                    }
                merged[sid]["total"] += safe_int(info.get("total"))

        final_data[quarter] = sorted(
            merged.values(),
            key=lambda item: item["total"],
            reverse=True,
        )[:10]

    final_data["meta"] = {
        "ctpv_cd": ctpv_cd,
        "ctpv_nm": REGIONS.get(ctpv_cd, "알 수 없음"),
        "year": year,
    }
    return jsonify(final_data)


def find_station_total(items, sttn_id, name):
    """정류장 ID를 우선 매칭하고, 없으면 이름으로 보조 매칭합니다."""
    wanted_name = (name or "").strip()
    total = 0
    found = False

    for item in items:
        item_name = station_name(item)
        if item.get("sttn_id") == sttn_id or (wanted_name and item_name == wanted_name):
            total += safe_int(item.get("utztn_nope"))
            found = True

    if found:
        return total
    return None


@app.route("/api/station")
def station():
    ctpv_cd = request.args.get("ctpv_cd", "29")
    sttn_id = request.args.get("sttn_id", "")
    name = request.args.get("name", "")
    year = request.args.get("year", "")

    if not year or len(year) != 4:
        return jsonify({"error": "연도 4자리를 입력하세요"}), 400
    if not sttn_id and not name:
        return jsonify({"error": "sttn_id 또는 name 파라미터가 필요합니다."}), 400

    months = []
    monthly_found = False

    def fetch_station_month(month):
        ym = f"{year}{month:02d}"
        try:
            items = fetch_items("monthly", ctpv_cd, ym, timeout=10)
            total = find_station_total(items, sttn_id, name)
            return month, total
        except Exception:
            return month, None

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        future_map = {
            executor.submit(fetch_station_month, month): month
            for month in range(1, 13)
        }
        monthly_values = {}
        for future in concurrent.futures.as_completed(future_map):
            month, total = future.result()
            monthly_values[month] = total
            if total is not None:
                monthly_found = True

    if monthly_found:
        for month in range(1, 13):
            months.append({"month": month, "total": monthly_values.get(month) or 0})
        return jsonify({
            "found": True,
            "source": "monthly",
            "months": months,
            "meta": {
                "ctpv_cd": ctpv_cd,
                "ctpv_nm": REGIONS.get(ctpv_cd, "알 수 없음"),
                "sttn_id": sttn_id,
                "name": name,
                "year": year,
            },
        })

    def fetch_station_daily_sample(month):
        date_value = f"{year}{month:02d}01"
        items = fetch_daily_items(date_value, ctpv_cd)
        return month, find_station_total(items, sttn_id, name)

    daily_found = False
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        future_map = {
            executor.submit(fetch_station_daily_sample, month): month
            for month in range(1, 13)
        }
        daily_values = {}
        for future in concurrent.futures.as_completed(future_map):
            month, total = future.result()
            daily_values[month] = total
            if total is not None:
                daily_found = True

    for month in range(1, 13):
        months.append({"month": month, "total": daily_values.get(month) or 0})

    return jsonify({
        "found": daily_found,
        "source": "daily_sample",
        "months": months,
        "meta": {
            "ctpv_cd": ctpv_cd,
            "ctpv_nm": REGIONS.get(ctpv_cd, "알 수 없음"),
            "sttn_id": sttn_id,
            "name": name,
            "year": year,
        },
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
