#!/bin/sh

uninstall_native() {
	command -v systemctl >/dev/null 2>&1 ||
		die "systemd is required to uninstall the native runtime"
	systemctl disable --now one-node.service >/dev/null 2>&1 || true
	rm -f -- "$UNIT_FILE"
	systemctl daemon-reload
}
