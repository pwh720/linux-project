#!/bin/bash

# 초기 HTML 생성 (컨테이너 시작 시 1회 즉시 실행)
/usr/local/bin/update.sh

# cron 등록 (1분마다 실행)
echo "*/1 * * * * root /usr/local/bin/update.sh >> /var/log/cron.log 2>&1" > /etc/cron.d/twopark-cron

# cron 파일 권한 설정
chmod 0644 /etc/cron.d/twopark-cron

# cron 적용
crontab /etc/cron.d/twopark-cron

# 로그 파일 생성
touch /var/log/cron.log

# cron 포그라운드 실행 (컨테이너 유지)
cron -f