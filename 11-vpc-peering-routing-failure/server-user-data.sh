#!/bin/bash
set -eux

mkdir -p /opt/lab11

cat > /opt/lab11/index.html <<'HTML'
VPC Peering Lab 11
Server: VPC B
Status: HTTP server reachable
Connection: Private VPC Peering
HTML

cat > /etc/systemd/system/lab11-http.service <<'UNIT'
[Unit]
Description=Lab 11 HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab11
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab11-http.service
