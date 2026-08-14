#!/bin/sh

write_native_source() {
	cat >"$UNIT_SOURCE" <<'EOF'
[Unit]
Description=One Node sing-box runtime
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/one-node
EnvironmentFile=/opt/one-node/.env
ExecStart=/opt/one-node/one-node start
Restart=always
RestartSec=5s
UMask=0077
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
EOF
}

install_native_runtime() {
	install -m 0644 "$UNIT_SOURCE" "$UNIT_FILE"
	systemctl daemon-reload
	systemctl enable --now one-node.service
	systemctl is-active --quiet one-node.service ||
		die "one-node.service did not become active"
}
