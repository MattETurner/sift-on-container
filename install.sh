#!/usr/bin/env bash
# SIFT Workstation ARM64 container installer.
#
# This script is part of the container build, not a post-build bolt-on. It:
#   * bootstraps Ubuntu 22.04 ARM64 prerequisites,
#   * installs Cast,
#   * patches SIFT SaltStack states for ARM64 where needed,
#   * tolerates known ARM64 Cast misses during container builds, and
#   * installs Ubuntu ARM64 equivalents for tools that the GIFT PPA names miss.
#
# Environment:
#   SIFT_ASSUME_YES=1     do not prompt on non-22.04 Ubuntu
#   SIFT_ALLOW_PARTIAL=1  continue after Cast returns non-zero
#   SIFT_CONTAINER_BUILD=1 annotate output as a container build

set -euo pipefail

CAST_VERSION="${CAST_VERSION:-1.0.8}"
CAST_DEB="cast-v${CAST_VERSION}-linux-arm64.deb"
CAST_URL="https://github.com/ekristen/cast/releases/download/v${CAST_VERSION}/${CAST_DEB}"
SIFT_CACHE_BASE="/var/cache/cast/teamdfir_sift-saltstack"
SIFT_USER="${SIFT_USER:-sift}"
SIFT_ALLOW_PARTIAL="${SIFT_ALLOW_PARTIAL:-0}"

if [[ -f /.dockerenv || -f /run/.containerenv || "${SIFT_CONTAINER_BUILD:-0}" == "1" ]]; then
    IN_CONTAINER=1
else
    IN_CONTAINER=0
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. In the container image it is executed during build."
    fi
}

check_platform() {
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
        error "This implementation targets Ubuntu ARM64 for Apple Silicon containers. Detected: $arch"
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        error "This script requires Ubuntu. Detected: $ID"
    fi
    if [[ "$VERSION_ID" != "22.04" ]]; then
        warn "This script is tested on Ubuntu 22.04. Detected: $VERSION_ID"
        if [[ "${SIFT_ASSUME_YES:-0}" != "1" ]]; then
            read -r -p "Continue anyway? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
        fi
    fi

    info "Starting SIFT ARM64 installation on Ubuntu $VERSION_ID ($arch)"
    if [[ "$IN_CONTAINER" == "1" ]]; then
        info "Container build mode enabled"
    fi
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

bootstrap_apt() {
    info "Bootstrapping package repositories and prerequisites..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt_install \
        apt-utils \
        ca-certificates \
        curl \
        git \
        gnupg \
        lsb-release \
        python3 \
        python3-pip \
        software-properties-common \
        sudo \
        tar \
        tzdata \
        unzip \
        wget

    add-apt-repository -y universe >/dev/null 2>&1 || warn "Could not enable universe via add-apt-repository"
    add-apt-repository -y multiverse >/dev/null 2>&1 || warn "Could not enable multiverse via add-apt-repository"
    apt-get update
}

ensure_sift_user() {
    if ! id -u "$SIFT_USER" >/dev/null 2>&1; then
        info "Creating ${SIFT_USER} user required by SIFT states..."
        useradd -m -s /bin/bash "$SIFT_USER"
    fi

    if ! grep -q "^${SIFT_USER} " /etc/sudoers 2>/dev/null; then
        echo "${SIFT_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    fi
}

install_cast() {
    if command -v cast >/dev/null 2>&1; then
        success "cast already installed ($(cast --version 2>/dev/null || echo unknown))"
        return
    fi

    info "Downloading Cast v${CAST_VERSION} for ARM64..."
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "${tmp_dir}/${CAST_DEB}" "${CAST_URL}"
    else
        wget -q --show-progress -O "${tmp_dir}/${CAST_DEB}" "${CAST_URL}"
    fi

    info "Installing Cast..."
    dpkg -i "${tmp_dir}/${CAST_DEB}"
    rm -rf "$tmp_dir"
    success "Cast installed: $(cast --version)"
}

latest_sift_source() {
    local latest=""
    if [[ -d "$SIFT_CACHE_BASE" ]]; then
        latest=$(ls -1t "$SIFT_CACHE_BASE" 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$latest" && -d "${SIFT_CACHE_BASE}/${latest}/source" ]]; then
        printf '%s\n' "${SIFT_CACHE_BASE}/${latest}/source"
    fi
}

patch_sift_states() {
    local sift_src="$1"
    local changed=1

    info "Applying ARM64 patches to SaltStack states in: $sift_src"

    local universe_sls="${sift_src}/sift/repos/ubuntu-universe.sls"
    if [[ -f "$universe_sls" ]]; then
        if ! grep -q "ubuntu-ports" "$universe_sls"; then
            info "Patching ubuntu-universe.sls for ARM64 ports repository..."
            cat > "$universe_sls" << 'UNIVERSE_EOF'
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
sift-ubuntu-ports-repo-universe:
  file.append:
    - name: /etc/apt/sources.list.d/ubuntu.sources
    - text: |

        Types: deb
        URIs: http://ports.ubuntu.com/ubuntu-ports/
        Suites: jammy jammy-updates jammy-security jammy-backports
        Components: main universe restricted multiverse
        Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
        Architectures: arm64
    - unless: grep -q "ubuntu-ports" /etc/apt/sources.list.d/ubuntu.sources
{% else %}
sift-universe-repo:
  file.replace:
    - name: /etc/apt/sources.list.d/ubuntu.sources
    - pattern: '^(Components: )(?!.*\buniverse\b)(.*)$'
    - repl: '\1\2 universe'
    - flags:
        - MULTILINE
{%- endif %}
UNIVERSE_EOF
            changed=0
        else
            info "ubuntu-universe.sls already patched"
        fi
    else
        warn "ubuntu-universe.sls not found at expected path: $universe_sls"
    fi

    local docker_sls="${sift_src}/sift/repos/docker.sls"
    if [[ -f "$docker_sls" ]]; then
        if ! grep -q "Architectures: arm64" "$docker_sls"; then
            info "Patching docker.sls for ARM64 architecture..."
            cat > "$docker_sls" << 'DOCKER_EOF'
include:
  - sift.packages.software-properties-common

sift-docker-key:
  file.managed:
    - name: /usr/share/keyrings/DOCKER-PGP-KEY.asc
    - source: https://download.docker.com/linux/ubuntu/gpg
    - skip_verify: True
    - makedirs: True

sift-remove-docker-ppa:
  pkgrepo.absent:
    - ppa: docker/stable
    - require:
      - sls: sift.packages.software-properties-common

sift-remove-docker-list:
  file.absent:
    - name: /etc/apt/sources.list.d/docker.list
    - require:
      - pkgrepo: sift-remove-docker-ppa

sift-remove-docker-sources:
  file.absent:
    - name: /etc/apt/sources.list.d/docker.sources
    - require:
      - pkgrepo: sift-remove-docker-ppa

sift-docker-repo:
  file.managed:
    - name: /etc/apt/sources.list.d/docker.sources
    - contents: |
        Types: deb
        URIs: https://download.docker.com/linux/ubuntu
        Suites: {{ grains['lsb_distrib_codename'] }}
        Components: stable
        Signed-By: /usr/share/keyrings/DOCKER-PGP-KEY.asc
        Architectures: arm64
    - require:
      - file: sift-docker-key
      - pkgrepo: sift-remove-docker-ppa
      - file: sift-remove-docker-list
      - file: sift-remove-docker-sources
DOCKER_EOF
            changed=0
        else
            info "docker.sls already patched"
        fi
    else
        warn "docker.sls not found at expected path: $docker_sls"
    fi

    local radare2_sls="${sift_src}/sift/packages/radare2.sls"
    if [[ -f "$radare2_sls" ]]; then
        if ! grep -q "aarch64" "$radare2_sls"; then
            info "Patching radare2.sls for ARM64 binary..."
            local r2_version
            r2_version=$(sed -n 's/.*set version = "\([^"]*\)".*/\1/p' "$radare2_sls" | head -1)
            if [[ -z "$r2_version" ]]; then
                r2_version="5.9.6"
            fi
            cat > "$radare2_sls" << RADARE2_EOF
{# renovate: datasource=github-release-attachments depName=radareorg/radare2 #}
{%- set version = "${r2_version}" -%}
{%- set base_url = "https://github.com/radareorg/radare2/releases/download/" -%}
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
{%- set filename = "radare2_" ~ version ~ "_arm64.deb" -%}
{%- else -%}
{%- set filename = "radare2_" ~ version ~ "_amd64.deb" -%}
{%- endif -%}

sift-package-radare2-download:
  file.managed:
    - name: /var/cache/sift/archives/{{ filename }}
    - source: "{{ base_url }}{{ version }}/{{ filename }}"
    - skip_verify: True
    - makedirs: True

sift-radare2:
  pkg.installed:
    - sources:
      - radare2: /var/cache/sift/archives/{{ filename }}
    - watch:
      - file: sift-package-radare2-download
RADARE2_EOF
            changed=0
        else
            info "radare2.sls already has ARM64 support"
        fi
    else
        warn "radare2.sls not found at expected path: $radare2_sls"
    fi

    return "$changed"
}

preload_and_patch_states() {
    local source_dir
    source_dir=$(latest_sift_source || true)
    if [[ -n "$source_dir" ]]; then
        patch_sift_states "$source_dir" || true
        return
    fi

    info "Attempting to pre-load SIFT states into Cast cache..."
    cast install teamdfir/sift-saltstack --dry-run >/tmp/cast-dry-run.log 2>&1 || true

    source_dir=$(latest_sift_source || true)
    if [[ -n "$source_dir" ]]; then
        patch_sift_states "$source_dir" || true
    else
        warn "Could not pre-load states; they will be patched after Cast's first fetch if needed."
    fi
}

run_cast_install() {
    info "Running SIFT installer via Cast..."
    warn "Known ARM64 misses are handled after Cast by installing Ubuntu ARM64 equivalents where available."

    local cast_rc=0
    set +e
    cast install teamdfir/sift-saltstack
    cast_rc=$?
    set -e

    local source_dir=""
    source_dir=$(latest_sift_source || true)
    local patched_after_first_run=1
    if [[ -n "$source_dir" ]]; then
        set +e
        patch_sift_states "$source_dir"
        patched_after_first_run=$?
        set -e
    fi

    if [[ "$cast_rc" -ne 0 || "$patched_after_first_run" -eq 0 ]]; then
        info "Re-running Cast once after ARM64 state patching..."
        set +e
        cast install teamdfir/sift-saltstack
        cast_rc=$?
        set -e
    fi

    if [[ "$cast_rc" -ne 0 ]]; then
        if [[ "$SIFT_ALLOW_PARTIAL" == "1" ]]; then
            warn "Cast exited with ${cast_rc}; continuing because SIFT_ALLOW_PARTIAL=1."
        else
            error "Cast exited with ${cast_rc}. Set SIFT_ALLOW_PARTIAL=1 for container builds with known ARM64 misses."
        fi
    fi
}

install_arm64_recovery_packages() {
    local packages=(
        afflib-tools
        aircrack-ng
        autopsy
        ewf-tools
        libbde-utils
        libesedb-utils
        libevt-utils
        libevtx-utils
        libfsapfs-utils
        libfvde-utils
        libmsiecf-utils
        libolecf-utils
        libregf-utils
        libvmdk-utils
        libvshadow-utils
        plaso
        python3-dfvfs
        python3-plaso
        python3-tsk
        sleuthkit
        unrar
        xmount
    )

    info "Installing ARM64 recovery packages available from Ubuntu Jammy..."
    apt-get update

    local pkg
    local failed=()
    for pkg in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            info "${pkg} already installed"
            continue
        fi

        if ! apt-cache show "$pkg" >/dev/null 2>&1; then
            warn "${pkg} is not available in the configured repositories"
            failed+=("$pkg")
            continue
        fi

        if apt_install "$pkg"; then
            success "Installed ${pkg}"
        else
            warn "Failed to install ${pkg}"
            failed+=("$pkg")
        fi
    done

    if [[ "${#failed[@]}" -gt 0 ]]; then
        warn "Some recovery packages did not install: ${failed[*]}"
    fi
}

print_summary() {
    echo ""
    success "SIFT container installation flow complete."
    echo ""
    info "Recovered ARM64 tools include Ubuntu-native libyal utilities, plaso/python3-dfvfs, sleuthkit/autopsy, afflib-tools, xmount, ewf-tools, and unrar when repositories provide them."
    warn "Still unavailable or intentionally skipped on Ubuntu 22.04 ARM64: aeskeyfind, bulk-extractor, liblightgrep, rar, cmospwd, and amd64-only PowerShell."
    echo ""
    info "Verify key tools in the container:"
    echo "  command -v log2timeline.py || command -v psort.py"
    echo "  command -v ewfinfo && command -v regfinfo && command -v vshadowinfo"
    echo "  command -v fls && command -v xmount && command -v radare2"
    echo "  exiftool -ver"
}

main() {
    require_root
    check_platform
    bootstrap_apt
    ensure_sift_user
    install_cast
    preload_and_patch_states
    run_cast_install
    install_arm64_recovery_packages
    print_summary
}

main "$@"
