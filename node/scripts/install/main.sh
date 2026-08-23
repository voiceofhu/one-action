#!/bin/sh

if ! command -v initialize_install_config >/dev/null 2>&1; then
	printf '%s\n' \
		"[one-node] error: installer main module must be loaded through install.sh" >&2
	exit 1
fi

main() {
	umask 077
	initialize_install_config
	parse_install_arguments "$@"
	validate_install_host
	validate_install_config
	probe_control_endpoint
	validate_install_target
	if [ "$INSTALL_OPERATION" = "reconfigure" ]; then
		if [ "$INSTALL_MODE" = "native" ]; then
			initialize_install_workspace
			prepare_native_binary
			write_native_source
			reconfigure_native_installation
		else
			reconfigure_existing_installation
		fi
		return
	fi
	initialize_install_workspace

	if [ "$INSTALL_MODE" = "native" ]; then
		prepare_native_binary
		write_native_source
	else
		prepare_docker_image
		write_docker_source
	fi
	if [ "$INSTALL_OPERATION" = "replace" ]; then
		replace_existing_installation
	fi
	prepare_install_directories
	write_common_sources
	install_common_files
	if [ "$INSTALL_MODE" = "native" ]; then
		install_native_runtime
	else
		install_docker_runtime
	fi
	wait_for_ready_heartbeat

	INSTALL_COMMITTED="true"
	log "${INSTALL_MODE} sing-box installation is ready at config revision ${ONE_NODE_EXPECTED_CONFIG_REVISION} and bindings revision ${ONE_NODE_EXPECTED_BINDINGS_REVISION}"
}
