#!/bin/bash
set -eu

cat > /usr/local/bin/lab13-traffic.sh <<'SCRIPT'
#!/bin/bash

for i in $(seq 1 360); do
  curl -4 -sS \
    --noproxy '*' \
    --connect-timeout 3 \
    --max-time 8 \
    https://example.com \
    -o /dev/null || true

  sleep 10
done
SCRIPT

chmod +x /usr/local/bin/lab13-traffic.sh

systemd-run \
  --unit=lab13-traffic \
  --collect \
  /usr/local/bin/lab13-traffic.sh
