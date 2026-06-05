#!/bin/bash

# ========================
# 설정
# ========================
OUTPUT="/shared/index.html"

# ========================
# Python으로 API 호출
# ========================
RESPONSE=$(python3 /usr/local/bin/fetch_data.py 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
    echo "⚠️ API 호출 실패 또는 빈 응답: $(date)"
    # index.html이 아직 없을 때만 기본 페이지 생성
    if [ ! -f "$OUTPUT" ]; then
        cat > $OUTPUT << 'ERRHTML'
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="60">
  <title>투박 - 로딩 중</title>
  <style>
    body { font-family: sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #f0f2f5; color: #333; }
    .box { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); text-align: center; }
    h2 { color: #1a73e8; }
    p { color: #666; }
  </style>
</head>
<body>
  <div class="box">
    <h2>🚌 투박 - 데이터 준비 중</h2>
    <p>API 데이터를 불러오는 중입니다. 잠시 후 자동으로 새로고침됩니다.</p>
    <p style="font-size:12px;color:#999;">1분마다 자동 갱신</p>
  </div>
</body>
</html>
ERRHTML
    fi
    exit 0
fi

# ========================
# 데이터 파싱 (jq)
# ========================

# 역별 혼잡도 랭킹 TOP 10 (미상 데이터 제외)
RANKING=$(echo $RESPONSE | jq -r '
  .Response.body.items.item
  | map(select(.sttn_id != "~"))
  | group_by(.sttn_id)
  | map({
      sttn_id: .[0].sttn_id,
      sgg_nm: .[0].sgg_nm,
      emd_nm: .[0].emd_nm,
      total: map(.utztn_nope) | add
    })
  | sort_by(-.total)
  | .[:10]
  | .[]
  | "\(.sgg_nm // "미상") \(.emd_nm // "미상") \(.sttn_id) \(.total)"
')

# 이용자 유형별 합계
USER_TYPE=$(echo $RESPONSE | jq -r '
  .Response.body.items.item
  | group_by(.users_type_nm)
  | map({
      type: .[0].users_type_nm,
      total: map(.utztn_nope) | add
    })
  | .[]
  | "\(.type) \(.total)"
')

# 버스 vs 지하철
BUS=$(echo $RESPONSE | jq '[.Response.body.items.item[] | select(.trfc_mns_se_cd == "B") | .utztn_nope] | add // 0')
SUBWAY=$(echo $RESPONSE | jq '[.Response.body.items.item[] | select(.trfc_mns_se_cd == "T") | .utztn_nope] | add // 0')
GRAND_TOTAL=$(echo $RESPONSE | jq '[.Response.body.items.item[] | select(.sttn_id != "~") | .utztn_nope] | add // 0')

# 요일 및 지역명
DOW_NM=$(echo $RESPONSE | jq -r '.Response.body.items.item[0].dow_nm // "알 수 없음"')
CTPV_NM=$(echo $RESPONSE | jq -r '.Response.body.items.item[0].ctpv_nm // "알 수 없음"')

# ========================
# HTML 생성
# ========================
cat > $OUTPUT << HTML
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <title>투박 - 대중교통 이용 현황</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-datalabels"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', sans-serif; background: #f0f2f5; color: #333; }
    header { background: #1a73e8; color: white; padding: 20px 40px; }
    header h1 { font-size: 24px; }
    .search-bar { background: white; padding: 14px 40px; border-bottom: 1px solid #e0e0e0; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .search-bar label { font-size: 14px; color: #555; font-weight: 500; }
    .search-bar select, .search-bar input { padding: 7px 12px; border: 1px solid #dadce0; border-radius: 6px; font-size: 14px; outline: none; }
    .search-bar select:focus, .search-bar input:focus { border-color: #1a73e8; }
    .search-bar button { padding: 7px 20px; background: #1a73e8; color: white; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; }
    .search-bar button:hover { background: #1557b0; }
    .search-status { font-size: 13px; color: #888; }
    .container { max-width: 1200px; margin: 30px auto; padding: 0 20px; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    .card { background: white; border-radius: 12px; padding: 24px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
    .card h2 { font-size: 16px; color: #1a73e8; margin-bottom: 16px; border-bottom: 2px solid #e8f0fe; padding-bottom: 8px; display: flex; justify-content: space-between; align-items: center; }
    .view-toggle { display: flex; gap: 6px; flex-shrink: 0; }
    .toggle-btn { padding: 3px 9px; border: 1px solid #dadce0; border-radius: 6px; font-size: 11px; cursor: pointer; background: white; color: #666; transition: background 0.2s, color 0.2s; }
    .toggle-btn.active { background: #1a73e8; color: white; border-color: #1a73e8; }
    .ranking-list-wrap { }
    .card-ranking { grid-row: span 2; }
    .total-summary { margin-top: 14px; padding: 10px 14px; background: #e8f0fe; border-radius: 8px; text-align: center; font-size: 13px; font-weight: 600; color: #1a73e8; }
    .ut-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .ut-table th, .ut-table td { padding: 8px 10px; text-align: left; border-bottom: 1px solid #f0f0f0; }
    .ut-table th { color: #888; font-weight: 500; background: #fafafa; }
    .ut-table td:first-child { color: #aaa; width: 40px; }
    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
    .fade { animation: fadeIn 0.25s ease; }
    .ranking-item { display: flex; align-items: center; padding: 8px 0; border-bottom: 1px solid #f5f5f5; border-radius: 6px; transition: background 0.15s; cursor: default; }
    .ranking-item.clickable { cursor: pointer; }
    .ranking-item.clickable:hover { background: #f0f4ff; }
    .rank-num { width: 28px; height: 28px; border-radius: 50%; background: #1a73e8; color: white; display: flex; align-items: center; justify-content: center; font-size: 12px; font-weight: bold; margin-right: 12px; flex-shrink: 0; }
    .rank-num.gold { background: #f4b400; }
    .rank-num.silver { background: #9aa0a6; }
    .rank-num.bronze { background: #c8622a; }
    .rank-info { flex: 1; }
    .rank-name { font-size: 14px; font-weight: 500; }
    .rank-sub { font-size: 11px; color: #888; }
    .rank-count { font-size: 14px; font-weight: bold; color: #1a73e8; }
    .chart-wrap { position: relative; height: 250px; }
    .update-time { text-align: center; color: #888; font-size: 12px; margin-top: 20px; }
    .station-modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.45); z-index: 1000; align-items: center; justify-content: center; }
    .station-modal-overlay.open { display: flex; }
    .station-modal-box { background: white; border-radius: 14px; padding: 28px; width: 620px; max-width: 92vw; max-height: 80vh; overflow-y: auto; box-shadow: 0 8px 32px rgba(0,0,0,0.18); }
    .station-modal-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
    .station-modal-title { font-size: 17px; color: #1a73e8; font-weight: 600; }
    .station-modal-close { background: none; border: none; font-size: 22px; cursor: pointer; color: #888; line-height: 1; }
    .station-modal-controls { display: flex; gap: 10px; align-items: center; margin-bottom: 16px; }
    .station-modal-controls label { font-size: 14px; color: #555; font-weight: 500; }
    .station-modal-controls select { padding: 6px 10px; border: 1px solid #dadce0; border-radius: 6px; font-size: 14px; }
    .station-chart-wrap { position: relative; height: 260px; }
    .tab-nav { background: white; border-bottom: 2px solid #e0e0e0; display: flex; padding: 0 40px; }
    .tab-btn { padding: 14px 24px; font-size: 14px; font-weight: 600; color: #888; border: none; background: none; cursor: pointer; border-bottom: 3px solid transparent; margin-bottom: -2px; transition: color 0.2s, border-color 0.2s; }
    .tab-btn.active { color: #1a73e8; border-bottom-color: #1a73e8; }
    .tab-btn:hover { color: #1a73e8; }
    .tab-content { display: none; }
    .tab-content.active { display: block; }
    .quarterly-bar { background: white; padding: 14px 40px; border-bottom: 1px solid #e0e0e0; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .quarterly-bar label { font-size: 14px; color: #555; font-weight: 500; }
    .quarterly-bar select, .quarterly-bar input { padding: 7px 12px; border: 1px solid #dadce0; border-radius: 6px; font-size: 14px; outline: none; }
    .quarterly-bar select:focus, .quarterly-bar input:focus { border-color: #1a73e8; }
    .quarterly-bar button { padding: 7px 20px; background: #1a73e8; color: white; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; }
    .quarterly-bar button:hover { background: #1557b0; }
    .quarterly-bar .search-status { font-size: 13px; color: #888; }
    .quarterly-container { max-width: 1400px; margin: 30px auto; padding: 0 20px; }
    .quarterly-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; overflow-x: auto; }
    .q-card { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); min-width: 240px; }
    .q-card h3 { font-size: 15px; color: #1a73e8; margin-bottom: 12px; border-bottom: 2px solid #e8f0fe; padding-bottom: 8px; text-align: center; }
    .q-table { width: 100%; border-collapse: collapse; font-size: 12px; }
    .q-table th { background: #f8f9fa; color: #666; font-weight: 600; padding: 7px 6px; text-align: center; border-bottom: 1px solid #e0e0e0; }
    .q-table td { padding: 7px 6px; border-bottom: 1px solid #f5f5f5; vertical-align: middle; }
    .q-table td:first-child { text-align: center; font-weight: bold; width: 28px; }
    .q-table td:nth-child(2) { color: #333; }
    .q-table td:last-child { text-align: right; color: #1a73e8; font-weight: 600; white-space: nowrap; }
    .q-rank-1 { color: #f4b400 !important; }
    .q-rank-2 { color: #9aa0a6 !important; }
    .q-rank-3 { color: #c8622a !important; }
    .q-empty { text-align: center; color: #aaa; font-size: 13px; padding: 30px 0; }
    .map-container { background: white; border-radius: 12px; padding: 24px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
    .map-header { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
    .map-header h2 { font-size: 16px; color: #1a73e8; }
    .map-header select, .map-header input { padding: 7px 12px; border: 1px solid #dadce0; border-radius: 6px; font-size: 14px; outline: none; }
    .map-btn { padding: 7px 20px; background: #1a73e8; color: white; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; }
    .map-btn:hover { background: #1557b0; }
    .map-status { font-size: 13px; color: #888; }
    .map-legend { display: flex; gap: 16px; margin-bottom: 12px; font-size: 13px; flex-wrap: wrap; }
    .legend-item { display: flex; align-items: center; gap: 6px; }
    .legend-dot { width: 14px; height: 14px; border-radius: 50%; }
    .map-wrap { display: flex; gap: 20px; align-items: flex-start; flex-wrap: wrap; }
    .map-svg-wrap { flex: 1; min-width: 280px; max-width: 480px; }
    .region-path { cursor: pointer; stroke: white; stroke-width: 1.5; transition: opacity 0.2s; }
    .region-path:hover { opacity: 0.75; }
    .region-path.level-high    { fill: #ea4335; }
    .region-path.level-medium  { fill: #fbbc04; }
    .region-path.level-low     { fill: #34a853; }
    .region-path.level-unknown { fill: #e0e0e0; }
    .map-detail { width: 280px; background: #f8f9fa; border-radius: 10px; padding: 16px; }
    .map-detail h3 { font-size: 15px; color: #1a73e8; margin-bottom: 10px; }
    .map-detail-list { font-size: 13px; }
    .map-detail-item { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #eee; }
    .map-detail-item:last-child { border-bottom: none; }
    .congestion-badge { padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: bold; color: white; }
    .badge-high   { background: #ea4335; }
    .badge-medium { background: #fbbc04; color: #333; }
    .badge-low    { background: #34a853; }
    .badge-unknown{ background: #9e9e9e; }
  </style>
</head>
<body>
  <header>
    <h1>🚌 투박 - 대중교통 이용 현황 대시보드</h1>
  </header>

  <nav class="tab-nav">
    <button class="tab-btn active" onclick="switchTab('tab-main', this)">📊 기존 조회</button>
    <button class="tab-btn" onclick="switchTab('tab-map', this)">🗺️ 혼잡도 지도</button>
    <button class="tab-btn" onclick="switchTab('tab-quarterly', this)">📅 분기별 비교</button>
  </nav>

  <div id="tab-main" class="tab-content active">
  <div class="search-bar">
    <label>지역</label>
    <select id="ctpv">
      <option value="">📍 내 현재 위치로 검색</option>
      <option value="29">광주광역시</option>
      <option value="26">부산광역시</option>
      <option value="27">대구광역시</option>
      <option value="30">대전광역시</option>
      <option value="31">울산광역시</option>
      <option value="36">세종특별자치시</option>
      <option value="51">강원특별자치도</option>
      <option value="43">충청북도</option>
      <option value="44">충청남도</option>
      <option value="52">전북특별자치도</option>
      <option value="46">전라남도</option>
      <option value="47">경상북도</option>
      <option value="48">경상남도</option>
      <option value="50">제주특별자치도</option>
    </select>
    <label>조회단위</label>
    <select id="unit" onchange="updateDatePlaceholder()">
      <option value="today">오늘 예측 (최근 30일 평균)</option>
      <option value="daily">일별</option>
      <option value="monthly">월별</option>
      <option value="yearly">년별</option>
    </select>
    <label id="dateLabel">날짜</label>
    <input type="text" id="dateInput" placeholder="YYYYMMDD" maxlength="8" style="display:none;">
    <button onclick="fetchData()">조회</button>
    <span class="search-status" id="searchStatus"></span>
  </div>

  <div class="container">
    <div class="grid">

      <!-- 역별 혼잡도 랭킹 -->
      <div class="card card-ranking">
        <h2>
          <span>🏆 정류장별 혼잡도 랭킹 TOP 10</span>
          <small id="ranking-hint" style="font-size:11px; color:#888; font-weight:400; margin-left:8px;"></small>
          <div class="view-toggle" id="ranking-toggle">
            <button class="toggle-btn active" onclick="switchRanking('list', this)">📋 표로 보기</button>
            <button class="toggle-btn" onclick="switchRanking('chart', this)">📊 그래프로 보기</button>
          </div>
        </h2>
        <div class="ranking-list-wrap" id="ranking-list-wrap">
        <div id="ranking-list">
HTML

# 랭킹 HTML 생성
RANK=1
while IFS= read -r line; do
  SGG=$(echo $line | awk '{print $1}')
  EMD=$(echo $line | awk '{print $2}')
  STTN=$(echo $line | awk '{print $3}')
  TOTAL=$(echo $line | awk '{print $4}')

  if [ $RANK -eq 1 ]; then CLASS="gold"
  elif [ $RANK -eq 2 ]; then CLASS="silver"
  elif [ $RANK -eq 3 ]; then CLASS="bronze"
  else CLASS=""
  fi

  cat >> $OUTPUT << HTML
          <div class="ranking-item">
            <div class="rank-num ${CLASS}">${RANK}</div>
            <div class="rank-info">
              <div class="rank-name">${SGG} ${EMD}</div>
              <div class="rank-sub">정류장 ID: ${STTN}</div>
            </div>
            <div class="rank-count">${TOTAL}명</div>
          </div>
HTML
  RANK=$((RANK + 1))
done <<< "$RANKING"

cat >> $OUTPUT << HTML
        </div>
        </div>
        <div id="ranking-chart-wrap" style="display:none;" class="chart-wrap">
          <canvas id="rankingChart"></canvas>
        </div>
        <div class="total-summary" id="total-summary">📊 ${CTPV_NM} 20250801 총 이용인원: ${GRAND_TOTAL}명</div>
      </div>

      <!-- 이용자 유형별 비율 -->
      <div class="card">
        <h2>
          <span>👥 이용자 유형별 비율</span>
          <div class="view-toggle" id="usertype-toggle">
            <button class="toggle-btn active" onclick="switchUserType('chart', this)">📊 그래프로 보기</button>
            <button class="toggle-btn" onclick="switchUserType('table', this)">📋 표로 보기</button>
          </div>
        </h2>
        <div id="usertype-chart-wrap" class="chart-wrap">
          <canvas id="userTypeChart"></canvas>
        </div>
        <div id="usertype-table-wrap" style="display:none; height:250px; overflow-y:auto;">
          <table class="ut-table" id="usertype-table"></table>
        </div>
      </div>

      <!-- 버스 vs 지하철 -->
      <div class="card">
        <h2>🚇 버스 vs 지하철 이용 비교</h2>
        <div class="chart-wrap">
          <canvas id="transportChart"></canvas>
        </div>
      </div>

    </div>
    <p class="update-time">마지막 업데이트: $(date '+%Y-%m-%d %H:%M:%S')</p>
  </div>
  </div><!-- /tab-main -->

  <div id="tab-map" class="tab-content">
    <div class="container">
      <div class="map-container">
        <div class="map-header">
          <h2>🗺️ 지역별 대중교통 혼잡도 지도</h2>
          <select id="mapUnit" onchange="onMapUnitChange()">
            <option value="today">오늘 예측 (최근 30일 평균)</option>
            <option value="daily">일별</option>
          </select>
          <input type="text" id="mapDate" placeholder="YYYYMMDD" maxlength="8" style="display:none;">
          <button class="map-btn" onclick="fetchMapData()">🗺️ 지도 조회 (약 30~60초)</button>
          <span class="map-status" id="mapStatus"></span>
        </div>
        <div class="map-legend">
          <span class="legend-item"><span class="legend-dot" style="background:#ea4335"></span> 혼잡 (상위 34%)</span>
          <span class="legend-item"><span class="legend-dot" style="background:#fbbc04"></span> 보통 (중위 33%)</span>
          <span class="legend-item"><span class="legend-dot" style="background:#34a853"></span> 여유 (하위 33%)</span>
          <span class="legend-item"><span class="legend-dot" style="background:#e0e0e0"></span> 데이터 없음</span>
        </div>
        <div class="map-wrap">
          <div class="map-svg-wrap">
            <div style="display:inline-block;width:100%;max-width:450px;">
              <svg viewBox="0 0 225 225" xmlns="http://www.w3.org/2000/svg" id="koreaMap" style="width:100%;height:auto;">
                <path id="map-47" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.9;" d="M 164,67 L 162,67 L 157,73 L 154,72 L 147,73 L 146,75 L 140,75 L 137,78 L 135,84 L 124,84 L 118,91 L 118,104 L 123,108 L 122,115 L 119,117 L 119,121 L 127,124 L 130,128 L 129,131 L 139,131 L 146,133 L 153,132 L 159,127 L 169,128 L 171,125 L 172,117 L 168,118 L 166,116 L 167,112 L 165,106 L 167,101 L 166,91 L 168,88 L 168,84 L 166,81 L 166,73 Z" onclick="onRegionClick('47','경북')"/>
                <text x="144" y="104" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">경북</text>
                <path id="map-51" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.9;" d="M 88,21 L 87,25 L 89,28 L 92,29 L 93,27 L 96,27 L 108,37 L 108,40 L 106,42 L 106,48 L 115,52 L 115,60 L 113,63 L 114,68 L 118,64 L 120,64 L 121,66 L 128,65 L 133,69 L 145,72 L 147,70 L 157,69 L 161,64 L 160,59 L 156,55 L 153,48 L 139,30 L 131,12 L 128,12 L 117,22 L 109,23 L 95,19 Z" onclick="onRegionClick('51','강원')"/>
                <text x="127" y="45" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">강원</text>
                <path id="map-48" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.9;" d="M 109,149 L 116,160 L 121,159 L 122,162 L 133,161 L 135,164 L 137,154 L 140,154 L 142,152 L 149,155 L 152,148 L 156,145 L 162,149 L 162,146 L 166,142 L 165,140 L 169,136 L 169,131 L 159,130 L 153,135 L 133,135 L 126,132 L 127,128 L 125,126 L 115,124 L 111,127 L 109,133 L 111,140 Z" onclick="onRegionClick('48','경남')"/>
                <text x="132" y="144" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">경남</text>
                <path id="map-41" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.9;" d="M 86,29 L 86,32 L 82,37 L 77,40 L 74,40 L 78,42 L 78,48 L 80,51 L 78,52 L 74,48 L 73,51 L 79,55 L 78,62 L 83,65 L 81,68 L 84,70 L 83,73 L 85,74 L 85,76 L 89,78 L 97,78 L 102,72 L 106,73 L 107,70 L 111,67 L 112,53 L 107,52 L 103,48 L 105,37 L 95,30 L 90,32 Z" onclick="onRegionClick('41','경기')"/>
                <text x="92" y="55" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">경기</text>
                <path id="map-46" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.9;" d="M 105,147 L 90,148 L 88,144 L 81,142 L 80,145 L 75,149 L 70,148 L 67,150 L 70,157 L 67,172 L 72,172 L 76,176 L 73,178 L 73,181 L 71,182 L 73,184 L 72,187 L 74,187 L 80,175 L 82,176 L 82,182 L 84,182 L 87,176 L 95,168 L 99,169 L 106,166 L 106,163 L 108,161 L 111,162 L 113,160 Z" onclick="onRegionClick('46','전남')"/>
                <text x="86" y="162" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">전남</text>
                <path id="map-52" class="region-path level-low" style="fill:#34a853;fill-opacity:0.9;" d="M 76,120 L 75,124 L 80,126 L 81,129 L 74,131 L 70,134 L 72,135 L 75,133 L 78,135 L 77,139 L 71,140 L 72,146 L 75,146 L 81,139 L 84,139 L 86,141 L 89,140 L 91,142 L 91,145 L 107,145 L 107,129 L 111,124 L 116,121 L 116,117 L 111,117 L 107,115 L 103,119 L 100,117 L 99,114 L 92,116 L 86,113 Z" onclick="onRegionClick('52','전북')"/>
                <text x="92" y="130" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">전북</text>
                <path id="map-44" class="region-path level-low" style="fill:#34a853;fill-opacity:0.9;" d="M 68,78 L 69,82 L 62,88 L 64,91 L 68,89 L 72,92 L 70,97 L 74,99 L 73,110 L 76,116 L 79,116 L 85,111 L 90,111 L 92,113 L 100,111 L 97,107 L 99,98 L 96,92 L 98,85 L 95,80 L 87,81 L 83,83 L 83,86 L 81,87 L 79,80 L 74,81 L 72,78 Z" onclick="onRegionClick('44','충남')"/>
                <text x="82" y="97" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">충남</text>
                <path id="map-43" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.9;" d="M 128,68 L 123,70 L 120,68 L 118,68 L 115,71 L 112,70 L 106,77 L 102,76 L 99,80 L 99,82 L 103,86 L 101,89 L 99,89 L 99,92 L 101,94 L 101,97 L 104,97 L 108,100 L 106,106 L 111,114 L 119,114 L 120,108 L 118,108 L 115,105 L 116,95 L 114,93 L 116,89 L 121,85 L 123,81 L 133,81 L 138,74 L 131,71 Z" onclick="onRegionClick('43','충북')"/>
                <text x="114" y="87" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">충북</text>
                <path id="map-50" class="region-path level-low" style="fill:#34a853;fill-opacity:0.9;" d="M 96,203 L 93,200 L 79,201 L 77,204 L 71,207 L 72,213 L 78,212 L 80,210 L 85,212 L 93,208 L 96,205 Z" onclick="onRegionClick('50','제주')"/>
                <text x="83" y="207" font-size="7" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="paint-order:stroke;stroke:#0006;stroke-width:0.6;font-family:'Noto Sans KR',sans-serif;">제주</text>
                <path id="map-11" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 90,52 L 100,52 L 100,58 L 90,58 Z" onclick="onRegionClick('11','서울')"/>
                <text x="95" y="56.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">서울</text>
                <path id="map-28" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 73,59 L 83,59 L 83,65 L 73,65 Z" onclick="onRegionClick('28','인천')"/>
                <text x="78" y="63.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">인천</text>
                <path id="map-36" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 108,90 L 118,90 L 118,96 L 108,96 Z" onclick="onRegionClick('36','세종')"/>
                <text x="113" y="94.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">세종</text>
                <path id="map-30" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 108,100 L 118,100 L 118,106 L 108,106 Z" onclick="onRegionClick('30','대전')"/>
                <text x="113" y="104.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">대전</text>
                <path id="map-29" class="region-path level-medium" style="fill:#fbbc04;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 73,147 L 83,147 L 83,153 L 73,153 Z" onclick="onRegionClick('29','광주')"/>
                <text x="78" y="151.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">광주</text>
                <path id="map-27" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 128,115 L 138,115 L 138,121 L 128,121 Z" onclick="onRegionClick('27','대구')"/>
                <text x="133" y="119.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">대구</text>
                <path id="map-31" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 153,125 L 163,125 L 163,131 L 153,131 Z" onclick="onRegionClick('31','울산')"/>
                <text x="158" y="129.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">울산</text>
                <path id="map-26" class="region-path level-high" style="fill:#ea4335;fill-opacity:0.95;stroke:white;stroke-width:0.4" d="M 150,145 L 160,145 L 160,151 L 150,151 Z" onclick="onRegionClick('26','부산')"/>
                <text x="155" y="149.5" font-size="3.2" text-anchor="middle" fill="white" pointer-events="none" font-weight="800" style="font-family:'Noto Sans KR',sans-serif;">부산</text>
              </svg>
            </div>
          </div>
          <div class="map-detail" id="mapDetail">
            <h3>📍 지역을 클릭하세요</h3>
            <div class="map-detail-list" id="mapDetailList">
              <p style="color:#aaa; font-size:13px;">지도 조회 후 지역을 클릭하면<br>상세 정보가 표시됩니다.</p>
            </div>
          </div>
        </div>
        <div id="mapRankWrap" style="display:none; margin-top:20px;">
          <h3 style="font-size:15px; color:#1a73e8; margin-bottom:10px;">📊 전체 지역 혼잡도 순위</h3>
          <div id="mapRankList" style="display:grid; grid-template-columns: repeat(auto-fill, minmax(200px,1fr)); gap:8px;"></div>
        </div>
      </div>
    </div>
  </div>

  <div id="tab-quarterly" class="tab-content">
    <div class="quarterly-bar">
      <label>지역</label>
      <select id="q-ctpv">
        <option value="29">광주광역시</option>
        <option value="26">부산광역시</option>
        <option value="27">대구광역시</option>
        <option value="30">대전광역시</option>
        <option value="31">울산광역시</option>
        <option value="36">세종특별자치시</option>
        <option value="51">강원특별자치도</option>
        <option value="43">충청북도</option>
        <option value="44">충청남도</option>
        <option value="52">전북특별자치도</option>
        <option value="46">전라남도</option>
        <option value="47">경상북도</option>
        <option value="48">경상남도</option>
        <option value="50">제주특별자치도</option>
      </select>
      <label>연도</label>
      <input type="number" id="q-year" value="2025" min="2024" max="2026" style="width:90px;">
      <button onclick="fetchQuarterly()">📅 조회하기</button>
      <span class="search-status" id="q-status"></span>
    </div>
    <div class="quarterly-container">
      <div class="quarterly-grid">
        <div class="q-card">
          <h3>🌱 1분기 (1~3월)</h3>
          <div id="q1-body"><p class="q-empty">조회 버튼을 눌러주세요</p></div>
        </div>
        <div class="q-card">
          <h3>☀️ 2분기 (4~6월)</h3>
          <div id="q2-body"><p class="q-empty">조회 버튼을 눌러주세요</p></div>
        </div>
        <div class="q-card">
          <h3>🍂 3분기 (7~9월)</h3>
          <div id="q3-body"><p class="q-empty">조회 버튼을 눌러주세요</p></div>
        </div>
        <div class="q-card">
          <h3>❄️ 4분기 (10~12월)</h3>
          <div id="q4-body"><p class="q-empty">조회 버튼을 눌러주세요</p></div>
        </div>
      </div>
    </div>
  </div>

  <!-- 정류장 시계열 모달 -->
  <div id="station-modal" class="station-modal-overlay">
    <div class="station-modal-box">
      <div class="station-modal-header">
        <span class="station-modal-title" id="modal-title"></span>
        <button class="station-modal-close" onclick="closeStationModal()">✕</button>
      </div>
      <div class="station-modal-controls">
        <label>연도</label>
        <select id="modal-year" onchange="fetchStation()">
          <option value="2024">2024년</option>
          <option value="2025" selected>2025년</option>
          <option value="2026">2026년</option>
        </select>
        <span id="modal-status" style="font-size:13px; color:#888;"></span>
      </div>
      <div class="station-chart-wrap">
        <canvas id="stationChart"></canvas>
      </div>
    </div>
  </div>

  <script>
    var USER_TYPE_COLORS = {
      '일반인': '#1a73e8', '청소년': '#34a853', '어린이': '#fbbc04',
      '경로': '#ea4335', '장애인': '#ff6d00', '국가유공자': '#9c27b0'
    };
    var USER_TYPE_ORDER = ['일반인', '청소년', '어린이', '경로', '장애인', '국가유공자'];

    function getUserTypeColors(labels) {
      return labels.map(function(l) { return USER_TYPE_COLORS[l] || '#9e9e9e'; });
    }
    function sortUserTypeData(labels, data) {
      var map = {};
      labels.forEach(function(l, i) { map[l] = data[i]; });
      var sorted = USER_TYPE_ORDER.filter(function(l) { return map[l] !== undefined; });
      return { labels: sorted, data: sorted.map(function(l) { return map[l]; }) };
    }

    var utRaw = sortUserTypeData(
      [$(echo "$USER_TYPE" | awk '{print "\"" $1 "\""}' | paste -sd ',')],
      [$(echo "$USER_TYPE" | awk '{print $2}' | paste -sd ',')]
    );
    var currentUserTypeData = utRaw.labels.map(function(l, i) { return { type: l, total: utRaw.data[i] }; });

    var rkRawLabels = [$(echo "$RANKING" | awk '{print "\"" $1 " " $2 "\""}' | paste -sd ',')];
    var rkRawData   = [$(echo "$RANKING" | awk '{print $4}' | paste -sd ',')];

    let rankingChart = new Chart(document.getElementById('rankingChart'), {
      type: 'bar',
      data: {
        labels: rkRawLabels,
        datasets: [{ data: rkRawData, backgroundColor: '#1a73e8' }]
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          datalabels: {
            anchor: 'end', align: 'end',
            formatter: function(v) { return v.toLocaleString() + '명'; },
            font: { size: 11 }
          }
        },
        scales: { x: { ticks: { display: false }, grid: { display: false } } }
      }
    });

    let userTypeChart = new Chart(document.getElementById('userTypeChart'), {
      type: 'bar',
      data: {
        labels: utRaw.labels,
        datasets: [{ data: utRaw.data, backgroundColor: getUserTypeColors(utRaw.labels) }]
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          datalabels: {
            anchor: 'end', align: 'end',
            formatter: function(v) { return v.toLocaleString() + '명'; },
            font: { size: 11 }
          }
        }
      }
    });

    let transportChart = new Chart(document.getElementById('transportChart'), {
      type: 'bar',
      data: {
        labels: ['버스', '지하철'],
        datasets: [{
          label: '이용인원수',
          data: [${BUS}, ${SUBWAY}],
          backgroundColor: ['#1a73e8', '#34a853']
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, datalabels: { display: false } }
      }
    });

    function switchRanking(mode, btnEl) {
      document.querySelectorAll('#ranking-toggle .toggle-btn').forEach(function(b) { b.classList.remove('active'); });
      btnEl.classList.add('active');
      var listWrap  = document.getElementById('ranking-list-wrap');
      var chartWrap = document.getElementById('ranking-chart-wrap');
      if (mode === 'list') {
        chartWrap.style.display = 'none';
        listWrap.style.display  = '';
        listWrap.classList.remove('fade'); void listWrap.offsetWidth; listWrap.classList.add('fade');
      } else {
        listWrap.style.display  = 'none';
        chartWrap.style.display = '';
        chartWrap.classList.remove('fade'); void chartWrap.offsetWidth; chartWrap.classList.add('fade');
        rankingChart.resize();
      }
    }

    function switchUserType(mode, btnEl) {
      document.querySelectorAll('#usertype-toggle .toggle-btn').forEach(function(b) { b.classList.remove('active'); });
      btnEl.classList.add('active');
      var chartWrap = document.getElementById('usertype-chart-wrap');
      var tableWrap = document.getElementById('usertype-table-wrap');
      if (mode === 'chart') {
        tableWrap.style.display = 'none';
        chartWrap.style.display = '';
        chartWrap.classList.remove('fade'); void chartWrap.offsetWidth; chartWrap.classList.add('fade');
      } else {
        chartWrap.style.display = 'none';
        tableWrap.style.display = '';
        tableWrap.classList.remove('fade'); void tableWrap.offsetWidth; tableWrap.classList.add('fade');
        renderUserTypeTable();
      }
    }

    function renderUserTypeTable() {
      var total  = currentUserTypeData.reduce(function(s, d) { return s + d.total; }, 0);
      var sorted = currentUserTypeData.slice().sort(function(a, b) { return b.total - a.total; });
      var html = '<thead><tr><th>순위</th><th>이용자 유형</th><th>인원수</th><th>비율</th></tr></thead><tbody>';
      sorted.forEach(function(d, i) {
        var pct = total > 0 ? Math.round(d.total / total * 100) : 0;
        html += '<tr><td>' + (i + 1) + '</td><td>' + d.type + '</td><td>' + d.total.toLocaleString() + '명</td><td>' + pct + '%</td></tr>';
      });
      html += '</tbody>';
      document.getElementById('usertype-table').innerHTML = html;
    }

    function escapeHtml(value) {
      return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    function updateDatePlaceholder() {
      var unit  = document.getElementById('unit').value;
      var input = document.getElementById('dateInput');
      var label = document.getElementById('dateLabel');
      if (unit === 'today') {
        input.style.display = 'none';
        label.style.display = 'none';
        input.value = '';
        return;
      }
      input.style.display = '';
      label.style.display = '';
      if (unit === 'daily')        { input.placeholder = 'YYYYMMDD'; input.maxLength = 8; }
      else if (unit === 'monthly') { input.placeholder = 'YYYYMM';   input.maxLength = 6; }
      else                         { input.placeholder = 'YYYY';      input.maxLength = 4; }
      input.value = '';
    }
    updateDatePlaceholder();

    var lastSearch = null;

    function renderRanking(items, unit) {
      var list = document.getElementById('ranking-list');
      list.innerHTML = '';
      var newRkLabels = [];
      var newRkData = [];
      var isMonthly = (unit === 'monthly');

      (items || []).forEach(function(item, i) {
        var cls = i === 0 ? 'gold' : i === 1 ? 'silver' : i === 2 ? 'bronze' : '';
        var name = item.name || '미상';
        var sttnId = item.sttn_id || '';
        var total = Number(item.total || 0);
        var clickAttr = isMonthly
          ? ' class="ranking-item clickable" data-sttn-id="' + escapeHtml(sttnId) + '" data-name="' + escapeHtml(name) + '" onclick="openStationModal(this)"'
          : ' class="ranking-item"';

        list.innerHTML +=
          '<div' + clickAttr + '>' +
            '<div class="rank-num ' + cls + '">' + (i + 1) + '</div>' +
            '<div class="rank-info">' +
              '<div class="rank-name">' + escapeHtml(name) + '</div>' +
              '<div class="rank-sub">정류장 ID: ' + escapeHtml(sttnId) + '</div>' +
            '</div>' +
            '<div class="rank-count">' + total.toLocaleString() + '명</div>' +
          '</div>';
        newRkLabels.push(name);
        newRkData.push(total);
      });

      rankingChart.data.labels = newRkLabels;
      rankingChart.data.datasets[0].data = newRkData;
      rankingChart.update();
      document.getElementById('ranking-hint').textContent = isMonthly ? '📈 정류장 클릭 시 월별 추이 확인 가능' : '';
    }

    function applyRegionFromMeta(ctpv, meta) {
      if (!meta || !meta.ctpv_nm) return ctpv;
      var selectBox = document.getElementById('ctpv');
      for (var i = 0; i < selectBox.options.length; i++) {
        if (selectBox.options[i].text.replace(/^📍\s*/, '') === meta.ctpv_nm) {
          selectBox.selectedIndex = i;
          return selectBox.options[i].value;
        }
      }
      return ctpv;
    }

    function buildQueryUrl(ctpv, unit, date, lat, lon) {
      var url = '/api/query?unit=' + encodeURIComponent(unit);
      if (unit !== 'today') url += '&date=' + encodeURIComponent(date || '');
      if (ctpv) url += '&ctpv_cd=' + encodeURIComponent(ctpv);
      if (lat && lon) url += '&lat=' + encodeURIComponent(lat) + '&lon=' + encodeURIComponent(lon);
      return url;
    }

    function fetchData(params) {
      var ctpv, unit, date, lat, lon;
      var status = document.getElementById('searchStatus');

      if (params) {
        ctpv = params.ctpv || '';
        unit = params.unit || 'today';
        date = params.date || '';
        lat = params.lat || '';
        lon = params.lon || '';
      } else {
        ctpv = document.getElementById('ctpv').value;
        unit = document.getElementById('unit').value;
        date = document.getElementById('dateInput').value.trim();
        lat = '';
        lon = '';
        if (unit !== 'today' && !date) { status.textContent = '날짜를 입력해주세요.'; return; }

        if (ctpv === '') {
          if (navigator.geolocation) {
            status.textContent = '위치 파악 및 데이터 로딩 중...';
            navigator.geolocation.getCurrentPosition(function(position) {
              fetchData({ unit: unit, date: date, lat: position.coords.latitude, lon: position.coords.longitude });
            }, function() {
              alert('위치 접근이 거부되었습니다. 광주광역시로 조회합니다.');
              fetchData({ ctpv: '29', unit: unit, date: date });
            });
            return;
          }
          alert('위치 기능을 지원하지 않습니다. 광주광역시로 조회합니다.');
          ctpv = '29';
        }
      }

      status.textContent = unit === 'today' ? '최근 30일 데이터 수집 중... (약 10~20초 소요)' : '조회 중...';

      fetch(buildQueryUrl(ctpv, unit, date, lat, lon))
        .then(function(r) { return r.json(); })
        .then(function(data) {
          if (data.error) { status.textContent = '오류: ' + data.error; return; }

          var meta = data.meta || {};
          ctpv = applyRegionFromMeta(ctpv, meta);
          lastSearch = { ctpv: ctpv, unit: unit, date: date };

          renderRanking(data.ranking || [], unit);

          var userType = data.userType || [];
          var utSorted = sortUserTypeData(
            userType.map(function(u) { return u.type; }),
            userType.map(function(u) { return Number(u.total || 0); })
          );
          currentUserTypeData = utSorted.labels.map(function(l, i) { return { type: l, total: utSorted.data[i] }; });
          userTypeChart.data.labels = utSorted.labels;
          userTypeChart.data.datasets[0].data = utSorted.data;
          userTypeChart.data.datasets[0].backgroundColor = getUserTypeColors(utSorted.labels);
          userTypeChart.update();

          transportChart.data.datasets[0].data = [Number(data.bus || 0), Number(data.subway || 0)];
          transportChart.update();

          var displayDate = unit === 'today' ? (meta.note || '오늘 예측') : date;
          var regionName = meta.ctpv_nm || '알 수 없음';
          document.getElementById('total-summary').textContent =
            '📊 ' + regionName + ' ' + displayDate + ' 총 이용인원: ' + Number(data.total || 0).toLocaleString() + '명';

          var unitLabel = unit === 'today' ? '오늘 예측' : unit === 'daily' ? '일별' : unit === 'monthly' ? '월별' : '년별';
          status.textContent = regionName + ' | ' + displayDate + ' (' + unitLabel + ') 조회 완료';
        })
        .catch(function(e) { status.textContent = '요청 실패: ' + e.message; });
    }

    setInterval(function() {
      if (lastSearch) fetchData(lastSearch);
    }, 60000);

    function initAutoLoad() {
      var unitEl = document.getElementById('unit');
      unitEl.value = 'today';
      updateDatePlaceholder();
      document.getElementById('ctpv').value = '';
      fetchData();
    }

    var _stationModal = { sttn_id: null, name: null, ctpv_cd: null, chart: null };

    function openStationModal(el) {
      _stationModal.sttn_id  = el.getAttribute('data-sttn-id');
      _stationModal.name     = el.getAttribute('data-name');
      _stationModal.ctpv_cd  = document.getElementById('ctpv').value || (lastSearch && lastSearch.ctpv) || '29';
      document.getElementById('modal-title').textContent = '📈 ' + _stationModal.name + ' 월별 추이';
      document.getElementById('station-modal').classList.add('open');
      fetchStation();
    }

    function closeStationModal() {
      document.getElementById('station-modal').classList.remove('open');
    }

    document.getElementById('station-modal').addEventListener('click', function(e) {
      if (e.target === this) closeStationModal();
    });

    function fetchStation() {
      var year   = document.getElementById('modal-year').value;
      var status = document.getElementById('modal-status');
      status.textContent = '조회 중...';
      console.log('[station] 요청:', { sttn_id: _stationModal.sttn_id, name: _stationModal.name, ctpv_cd: _stationModal.ctpv_cd, year: year });

      fetch('/api/station?ctpv_cd=' + _stationModal.ctpv_cd + '&sttn_id=' + encodeURIComponent(_stationModal.sttn_id) + '&name=' + encodeURIComponent(_stationModal.name) + '&year=' + year)
        .then(function(r) { return r.json(); })
        .then(function(data) {
          console.log('[station] 응답:', data);
          if (data.error) { status.textContent = '오류: ' + data.error; return; }
          if (!data.found) {
            status.textContent = year + '년 해당 정류장의 데이터가 없습니다';
            return;
          }
          var labels = data.months.map(function(m) { return m.month + '월'; });
          var values = data.months.map(function(m) { return m.total; });
          if (_stationModal.chart) {
            _stationModal.chart.data.labels           = labels;
            _stationModal.chart.data.datasets[0].data = values;
            _stationModal.chart.update();
          } else {
            _stationModal.chart = new Chart(document.getElementById('stationChart'), {
              type: 'bar',
              data: { labels: labels, datasets: [{ data: values, backgroundColor: '#1a73e8' }] },
              options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                  legend: { display: false },
                  datalabels: {
                    anchor: 'end', align: 'end',
                    formatter: function(v) { return v > 0 ? v.toLocaleString() : ''; },
                    font: { size: 10 }
                  }
                },
                scales: { y: { ticks: { callback: function(v) { return v.toLocaleString(); } } } }
              }
            });
          }
          status.textContent = year + '년 조회 완료' + (data.source === 'daily_sample' ? ' (매월 1일 기준)' : '');
        })
        .catch(function(e) { status.textContent = '요청 실패: ' + e.message; });
    }

    function switchTab(tabId, btnEl) {
      document.querySelectorAll('.tab-content').forEach(function(el) { el.classList.remove('active'); });
      document.querySelectorAll('.tab-btn').forEach(function(el) { el.classList.remove('active'); });
      document.getElementById(tabId).classList.add('active');
      btnEl.classList.add('active');
    }

    function onMapUnitChange() {
      var unit = document.getElementById('mapUnit').value;
      var dateInput = document.getElementById('mapDate');
      dateInput.style.display = unit === 'today' ? 'none' : '';
      if (unit === 'today') dateInput.value = '';
    }

    var mapRegionData = {};

    function fetchMapData() {
      var unit   = document.getElementById('mapUnit').value;
      var date   = document.getElementById('mapDate').value.trim();
      var status = document.getElementById('mapStatus');

      if (unit !== 'today' && !date) { status.textContent = '날짜를 입력해주세요.'; return; }

      status.textContent = '지역 데이터 수집 중... (약 30~60초 소요)';

      var url = '/api/map?unit=' + encodeURIComponent(unit);
      if (unit !== 'today') url += '&date=' + encodeURIComponent(date);

      fetch(url)
        .then(function(r) { return r.json(); })
        .then(function(data) {
          if (data.error) { status.textContent = '오류: ' + data.error; return; }

          mapRegionData = {};
          (data.regions || []).forEach(function(r) { mapRegionData[r.ctpv_cd] = r; });

          (data.regions || []).forEach(function(r) {
            var el = document.getElementById('map-' + r.ctpv_cd);
            if (!el || r.level === 'unknown') return;
            el.className.baseVal = 'region-path level-' + r.level;
          });

          var sorted = (data.regions || []).slice().sort(function(a, b) { return Number(b.total || 0) - Number(a.total || 0); });
          var rankHtml = '';
          sorted.forEach(function(r, i) {
            var badgeCls = 'badge-' + r.level;
            var levelTxt = r.level === 'high' ? '혼잡' : r.level === 'medium' ? '보통' : r.level === 'low' ? '여유' : '없음';
            rankHtml += '<div style="background:white;border-radius:8px;padding:10px 14px;box-shadow:0 1px 4px rgba(0,0,0,0.08);display:flex;justify-content:space-between;align-items:center;">' +
              '<span style="font-size:13px;"><b>' + (i + 1) + '.</b> ' + escapeHtml(r.ctpv_nm || '') + '</span>' +
              '<span><span class="congestion-badge ' + badgeCls + '">' + levelTxt + '</span> <span style="font-size:12px;color:#888;">' + Number(r.total || 0).toLocaleString() + '명</span></span>' +
              '</div>';
          });
          document.getElementById('mapRankList').innerHTML = rankHtml;
          document.getElementById('mapRankWrap').style.display = '';

          var noteDate = unit === 'today' ? '오늘 예측' : date;
          status.textContent = noteDate + ' 조회 완료 ✅';
        })
        .catch(function(e) { status.textContent = '요청 실패: ' + e.message; });
    }

    function onRegionClick(cd, name) {
      var r = mapRegionData[cd];
      var detail = document.getElementById('mapDetailList');
      if (!r) {
        document.getElementById('mapDetail').querySelector('h3').textContent = '📍 ' + name;
        detail.innerHTML = '<p style="color:#aaa;font-size:13px;">먼저 지도 조회를 해주세요.</p>';
        return;
      }
      var levelTxt  = r.level === 'high' ? '혼잡' : r.level === 'medium' ? '보통' : r.level === 'low' ? '여유' : '데이터 없음';
      var badgeCls  = 'badge-' + r.level;
      document.getElementById('mapDetail').querySelector('h3').textContent = '📍 ' + name;
      detail.innerHTML =
        '<div class="map-detail-item"><span>혼잡도</span><span class="congestion-badge ' + badgeCls + '">' + levelTxt + '</span></div>' +
        '<div class="map-detail-item"><span>총 이용인원</span><span style="font-weight:bold;">' + Number(r.total || 0).toLocaleString() + '명</span></div>' +
        '<div style="margin-top:12px;">' +
          '<button style="width:100%;padding:8px;background:#1a73e8;color:white;border:none;border-radius:6px;cursor:pointer;font-size:13px;" ' +
          'onclick="switchTab(\'tab-main\', document.querySelectorAll(\'.tab-btn\')[0]); document.getElementById(\'ctpv\').value=\'' + cd + '\'; fetchData();">' +
          '🔍 이 지역 상세 조회</button>' +
        '</div>';
    }

    function renderQuarterTable(items) {
      if (!items || items.length === 0) {
        return '<p class="q-empty">데이터가 없습니다<br><small>(해당 기간 미제공)</small></p>';
      }
      var html = '<table class="q-table"><thead><tr><th>순위</th><th>정류장</th><th>이용인원</th></tr></thead><tbody>';
      items.forEach(function(item, i) {
        var rank = i + 1;
        var rankClass = rank === 1 ? 'q-rank-1' : rank === 2 ? 'q-rank-2' : rank === 3 ? 'q-rank-3' : '';
        html += '<tr>' +
          '<td class="' + rankClass + '">' + rank + '</td>' +
          '<td>' + item.name + '</td>' +
          '<td>' + item.total.toLocaleString() + '명</td>' +
          '</tr>';
      });
      html += '</tbody></table>';
      return html;
    }

    function fetchQuarterly() {
      var ctpv = document.getElementById('q-ctpv').value;
      var year = document.getElementById('q-year').value;
      var status = document.getElementById('q-status');

      if (!year || year.length !== 4) { status.textContent = '연도 4자리를 입력해주세요.'; return; }

      status.textContent = '조회 중... (최대 30초 소요)';
      ['q1','q2','q3','q4'].forEach(function(q) {
        document.getElementById(q + '-body').innerHTML = '<p class="q-empty">불러오는 중...</p>';
      });

      fetch('/api/quarterly?ctpv_cd=' + ctpv + '&year=' + year)
        .then(function(r) { return r.json(); })
        .then(function(data) {
          if (data.error) { status.textContent = '오류: ' + data.error; return; }
          document.getElementById('q1-body').innerHTML = renderQuarterTable(data.q1);
          document.getElementById('q2-body').innerHTML = renderQuarterTable(data.q2);
          document.getElementById('q3-body').innerHTML = renderQuarterTable(data.q3);
          document.getElementById('q4-body').innerHTML = renderQuarterTable(data.q4);
          var regionName = (data.meta && data.meta.ctpv_nm) ? data.meta.ctpv_nm : document.getElementById('q-ctpv').selectedOptions[0].text;
          status.textContent = regionName + ' ' + year + '년 분기별 조회 완료';
        })
        .catch(function(e) { status.textContent = '요청 실패: ' + e.message; });
    }

    window.addEventListener('load', initAutoLoad);
  </script>
</body>
</html>
HTML

echo "✅ index.html 업데이트 완료: $(date)"