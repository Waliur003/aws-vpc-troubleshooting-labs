#!/bin/bash
set -euxo pipefail

mkdir -p /opt/vpc-lab04

cat > /opt/vpc-lab04/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>VPC Lab 04</title></head>
<body>
<h1>VPC LAB 04 - HTTP SERVER WORKING</h1>
<p>Security group troubleshooting test.</p>
</body>
</html>
HTML

cat > /etc/systemd/system/vpc-lab04-web.service <<'UNIT'
[Unit]
Description=VPC Lab 04 HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/opt/vpc-lab04
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

chmod 755 /opt/vpc-lab04
chmod 644 /opt/vpc-lab04/index.html
chmod 644 /etc/systemd/system/vpc-lab04-web.service

systemctl daemon-reload
systemctl enable --now vpc-lab04-web.service