import requests
import json
import sys
from datetime import datetime, timedelta

SERVICE_KEY = "4c686412dc79365266261a85c66f7c1ce97ecee4ded35b0335dedc2264e42c8d"
BASE_URL = "https://apis.data.go.kr/1613000/PublicTransportationPassengerCount/getDailyPublicTransportationPassengerCount"

# 오늘 기준 20일 전부터 50일 전까지 데이터가 있는 날짜 자동 탐색
today = datetime.today()
data = None

for i in range(20, 51):
    date_str = (today - timedelta(days=i)).strftime("%Y%m%d")
    params = {
        "serviceKey": SERVICE_KEY,
        "pageNo": 1,
        "numOfRows": 1000,
        "opr_ymd": date_str,
        "ctpv_cd": "29",
        "dataType": "JSON"
    }
    try:
        response = requests.get(BASE_URL, params=params, timeout=10)
        candidate = response.json()
        # 데이터가 실제로 있는지 확인
        items = candidate.get("Response", {}).get("body", {}).get("items", {}).get("item", None)
        if items:
            data = candidate
            break
    except Exception:
        continue

if data is None:
    print(json.dumps({"error": "데이터를 찾을 수 없습니다."}), file=sys.stderr)
    sys.exit(1)

print(json.dumps(data, ensure_ascii=False))
