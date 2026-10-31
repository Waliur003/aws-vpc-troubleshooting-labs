#!/bin/bash
set -euxo pipefail

mkdir -p /opt/vpc-lab05

cat > /opt/vpc-lab05/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>VPC Lab 05</title></head>
<body>
<h1>VPC LAB 05 - NACL TROUBLESHOOTING</h1>
<p>Server is responding on TCP 8080.</p>
</body>
</html>
HTML

cat > /etc/systemd/system/vpc-lab05-web.service <<'UNIT'
[Unit]
Description=VPC Lab 05 HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/opt/vpc-lab05
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

chmod 755 /opt/vpc-lab05
chmod 644 /opt/vpc-lab05/index.html
chmod 644 /etc/systemd/system/vpc-lab05-web.service

systemctl daemon-reload
systemctl enable --now vpc-lab05-web.service