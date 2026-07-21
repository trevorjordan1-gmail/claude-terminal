# shellcheck shell=bash
# ct-desc: Docker CE from docker.com (engine, buildx, compose) + user in docker group

ensure_docker_group() {
    if ! id -nG | grep -qw docker; then
        sudo usermod -aG docker "$USER" || fail "usermod -aG docker failed"
        next_step "Log out and back in so docker-group membership applies (or run: newgrp docker)."
    fi
}

if pkg_installed docker-ce; then
    ensure_docker_group
    ok "already installed ($(docker --version 2>/dev/null))"
fi

# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${VERSION_CODENAME:-noble}"

sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
        || fail "could not fetch docker gpg key"
    sudo chmod a+r /etc/apt/keyrings/docker.asc
fi

if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    rm -f "$CT_TMP/apt-updated"   # new repo → force apt-get update
fi

apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    || fail "docker packages failed to install"

sudo systemctl enable --now docker || fail "could not enable docker service"
ensure_docker_group

ok "$(docker --version 2>/dev/null)"
