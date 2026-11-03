#!/bin/bash
set -eux

mkdir -p /opt/lab15

cat > /opt/lab15/index.html <<'HTML'
AWS VPC Troubleshooting Lab 15

Server: Availability Zone B
Service: HTTP
Port: 8080
Status: Running
HTML

cat > /etc/systemd/system/lab15-http.service <<'UNIT'
[Unit]
Description=Lab 15 Cross-AZ HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab15
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab15-http.service
