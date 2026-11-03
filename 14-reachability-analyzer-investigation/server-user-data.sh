#!/bin/bash
set -eux

mkdir -p /opt/lab14

cat > /opt/lab14/index.html <<'HTML'
AWS VPC Troubleshooting Lab 14

Service: Python HTTP Server
Port: 8080
Status: Application running
HTML

cat > /etc/systemd/system/lab14-http.service <<'UNIT'
[Unit]
Description=Lab 14 HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab14
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab14-http.service
