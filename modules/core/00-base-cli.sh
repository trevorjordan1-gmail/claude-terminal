# shellcheck shell=bash
# ct-desc: Base CLI tools (git, gh, tmux, curl, jq, unzip, lynx, xvfb, openssh-server, doctl)
# Sourced by bootstrap.sh inside a subshell; ends via ok/skip/fail.

PKGS=(git gh tmux curl wget jq unzip lynx xvfb openssh-server ca-certificates gnupg)

missing=()
for p in "${PKGS[@]}"; do
    pkg_installed "$p" || missing+=("$p")
done

if [ ${#missing[@]} -gt 0 ]; then
    apt_install "${missing[@]}" || fail "apt install failed for: ${missing[*]}"
fi

# doctl — not in Ubuntu's apt; PLATFORM-BUILD step 1 is doctl-driven and the box shipped
# restic/jq/gh but not this (field-hit). Pinned release tarball, sha-verified, arch-aware;
# no snapd dependency. Bump DOCTL_VER deliberately (pinned = someone schedules the bump).
DOCTL_VER="1.168.0"
if ! have doctl; then
    case "$(dpkg --print-architecture)" in
        amd64) arch=amd64 ;; arm64) arch=arm64 ;;
        *) warn "doctl: unsupported arch $(dpkg --print-architecture) — install by hand"; arch="" ;;
    esac
    if [ -n "$arch" ]; then
        tgz="doctl-${DOCTL_VER}-linux-${arch}.tar.gz"
        base="https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VER}"
        if curl -fsSL -o "$CT_TMP/$tgz" "$base/$tgz" \
           && curl -fsSL -o "$CT_TMP/doctl.sha256" "$base/doctl-${DOCTL_VER}-checksums.sha256" \
           && (cd "$CT_TMP" && grep " $tgz\$" doctl.sha256 | sha256sum -c --quiet -) \
           && sudo tar -xzf "$CT_TMP/$tgz" -C /usr/local/bin doctl; then
            missing+=("doctl@$DOCTL_VER")
        else
            warn "doctl: download/verify failed — PLATFORM-BUILD step 1 needs it (install by hand)"
        fi
    fi
fi

[ ${#missing[@]} -gt 0 ] || ok "all present"
ok "installed: ${missing[*]}"
