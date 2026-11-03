#!/bin/bash
set -eu

cat > /usr/local/bin/lab09-check.sh <<'SCRIPT'
#!/bin/bash
LOG="/var/tmp/vpc-lab09-probe.log"
REGION="us-east-1"

for i in $(seq 1 120); do
  echo "Time: $(date -u +%FT%TZ)" >> "$LOG"

  for SERVICE in ssm ssmmessages; do
    HOST="${SERVICE}.${REGION}.amazonaws.com"

    CODE=$(curl -4 -k -s \
      --noproxy '*' \
      --connect-timeout 3 --max-time 5 \
      -o /dev/null \
      -w '%{http_code}' \
      "https://${HOST}/" || true)

    if [ "$CODE" != "000" ] && [ -n "$CODE" ]; then
      echo "${SERVICE}=TCP_TLS_OK HTTP_${CODE}" >> "$LOG"
    else
      echo "${SERVICE}=CONNECT_FAILED" >> "$LOG"
    fi
  done

  echo "---" >> "$LOG"
  sleep 10
done
SCRIPT

chmod +x /usr/local/bin/lab09-check.sh
systemd-run --unit=lab09-probe --collect /usr/local/bin/lab09-check.sh
