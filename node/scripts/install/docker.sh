#!/bin/sh

ensure_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		if command -v apt-get >/dev/null 2>&1; then
			log "installing Debian/Ubuntu Docker Engine and Compose"
			apt-get update
			env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
			if ! env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2; then
				env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
			fi
		else
			die "Docker Engine and Docker Compose v2 must be installed before Docker mode on this Linux distribution"
		fi
	fi
	if command -v systemctl >/dev/null 2>&1; then
		systemctl enable --now docker.service
	elif command -v rc-service >/dev/null 2>&1; then
		rc-update add docker default >/dev/null 2>&1 || true
		rc-service docker start >/dev/null 2>&1 || true
	fi
	docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
	docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required"
}

prepare_docker_image() {
	ensure_docker
	docker pull "$ONE_NODE_DOCKER_IMAGE"
	ONE_NODE_DOCKER_IMAGE=$(docker image inspect --format '{{index .RepoDigests 0}}' "$ONE_NODE_DOCKER_IMAGE") ||
		die "unable to resolve the downloaded Docker image digest"
	manifest_validate_image "$ONE_NODE_DOCKER_IMAGE" ||
		die "downloaded Docker image is not the digest-pinned One Node product image"
	product_version=$(docker run --rm --entrypoint /usr/local/bin/one-node \
		"$ONE_NODE_DOCKER_IMAGE" version --product-name) ||
		die "immutable One Node image cannot report its One Node product version"
	set_product_version "$product_version" "Docker image"
}

docker_bootstrap_env_file() {
	printf '%s\n' "${ONE_NODE_STATE_DIR}/bootstrap.env"
}

# Compose requires every env_file to exist; installs that predate the separate
# bootstrap file get an empty one before the new compose file is used.
ensure_docker_bootstrap_env() {
	bootstrap_env=$(docker_bootstrap_env_file)
	[ ! -L "$bootstrap_env" ] || die "bootstrap environment file must not be a symlink"
	if [ -e "$bootstrap_env" ]; then
		[ -f "$bootstrap_env" ] || die "bootstrap environment file must be a regular file"
		return 0
	fi
	: >"$bootstrap_env"
	chmod 0600 "$bootstrap_env"
}

write_docker_source() {
	bootstrap_env=$(docker_bootstrap_env_file)
	cat >"$COMPOSE_SOURCE" <<EOF
services:
  one-node:
    image: "${ONE_NODE_DOCKER_IMAGE}"
    container_name: "${CONTAINER_NAME}"
    network_mode: host
    restart: unless-stopped
    read_only: true
    security_opt:
      - "no-new-privileges:true"
    # Root in the container, but with only the network capabilities. A
    # non-root user would lose them: Docker sets no ambient capabilities and
    # no-new-privileges ignores file capabilities.
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_BIND_SERVICE
      - NET_RAW
    env_file:
      - "${ENV_FILE}"
      - "${bootstrap_env}"
    # Only runtime state is writable; ${INSTALL_DIR} holds scripts the host
    # runs as root and must stay outside the container.
    volumes:
      - "${ONE_NODE_STATE_DIR}:${ONE_NODE_STATE_DIR}"
      - "/etc/ssl/certs:/etc/ssl/certs:ro"
    tmpfs:
      - /tmp:mode=1777
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "5"
    command:
      - start
EOF
	chmod 0600 "$COMPOSE_SOURCE"
}

install_docker_runtime() {
	ensure_docker_bootstrap_env
	# Without CAP_DAC_OVERRIDE container root reaches only root-owned state,
	# e.g. after a native install left it to the one-node service account.
	chown -hR 0:0 "$ONE_NODE_STATE_DIR"
	install -m 0600 "$COMPOSE_SOURCE" "$COMPOSE_FILE"
	docker compose -f "$COMPOSE_FILE" up -d
	docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -qx true ||
		die "One Node container did not become active"
}
