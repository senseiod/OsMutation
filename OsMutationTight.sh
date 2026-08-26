#!/bin/bash
# Tight-mode OpenVZ/LXC reinstall using an official Alpine transit root.
# WARNING: A fresh system will be installed and all old data will be wiped.

set -o errexit
set -o pipefail

IMAGE_SERVER="https://images.linuxcontainers.org"
IMAGE_INDEX="${IMAGE_SERVER}/meta/1.0/index-system"
TRANSIT_ROOT="/x"
transit_mounted=""

die() {
    echo "Error: $*" >&2
    exit 1
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    elif command -v apk >/dev/null 2>&1; then
        pkg_manager="apk"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    else
        die "unsupported source operating system"
    fi
}

install() {
    detect_package_manager
    case "$pkg_manager" in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf)
            dnf -y makecache
            dnf install -y "$@"
            ;;
        yum)
            yum -y makecache
            yum install -y "$@"
            ;;
        apk)
            apk update
            apk add --no-cache "$@"
            ;;
        pacman)
            pacman -Sy --noconfirm
            pacman -S --noconfirm --needed "$@"
            ;;
    esac
}

install_requirement() {
    detect_package_manager
    case "$pkg_manager" in
        apt) install curl sed gawk wget gzip xz-utils tar virt-what iproute2 ;;
        dnf|yum) install curl sed gawk wget gzip xz tar virt-what iproute ;;
        apk) install curl sed gawk wget gzip xz tar virt-what iproute2 ;;
        pacman) install curl sed gawk wget gzip xz tar virt-what iproute2 ;;
    esac
}

normalize_arch() {
    case "$(uname -m)" in
        x86_64|amd64) image_arch="amd64" ;;
        aarch64|arm64) image_arch="arm64" ;;
        i386|i686|x86) image_arch="i386" ;;
        armv7l|armv7|armhf) image_arch="armhf" ;;
        riscv64) image_arch="riscv64" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

detect_container_type() {
    detected="$(virt-what 2>/dev/null || true)"
    cttype="$(printf '%s\n' "$detected" | awk '$0 == "lxc" || $0 == "openvz" { print; exit }')"
    if [ -z "$cttype" ] && [ -n "$detected" ]; then
        die "this virtualization type is not supported; only OpenVZ/LXC containers are supported"
    fi
    while [ "$cttype" != "lxc" ] && [ "$cttype" != "openvz" ]; do
        echo -ne "\e[1;33mplease input container type (lxc/openvz):\e[m"
        read -r cttype </dev/tty
    done
}

select_transit_template() {
    normalize_arch
    transit_record="$(
        curl -fsSL --retry 3 "$IMAGE_INDEX" |
            awk -F ';' -v arch="$image_arch" '
                function version_score(version, parts, count) {
                    count = split(version, parts, ".")
                    return (parts[1] + 0) * 1000000 + (parts[2] + 0) * 1000 + (parts[3] + 0)
                }
                $1 == "alpine" && $2 != "edge" && $3 == arch && $4 == "default" {
                    score = version_score($2)
                    if (score > best_score) {
                        best_score = score
                        best_record = $1 ";" $2 ";" $3 ";" $NF
                    }
                }
                END { print best_record }
            '
    )"
    [ -n "$transit_record" ] || die "no official Alpine transit template is available for $image_arch"
    IFS=';' read -r transit_distro transit_release transit_arch transit_path <<EOF
$transit_record
EOF
    transit_url="${IMAGE_SERVER}${transit_path}rootfs.tar.xz"
    echo "Using official Alpine $transit_release ($transit_arch) transit root."
}

copy_main_script() {
    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    current_script="$script_dir/$(basename -- "${BASH_SOURCE[0]}")"
    source_script="$script_dir/OsMutation.sh"

    if [ -f "$source_script" ] && [ ! "$source_script" -ef "$current_script" ]; then
        cp "$source_script" "$TRANSIT_ROOT/OsMutation.sh"
    else
        curl -fsSL --retry 3 \
            https://raw.githubusercontent.com/LloydAsp/OsMutation/main/OsMutation.sh \
            -o "$TRANSIT_ROOT/OsMutation.sh"
    fi
    chmod 700 "$TRANSIT_ROOT/OsMutation.sh"
}

list_oldroot_data_mounts() {
    oldroot="$1"
    while IFS= read -r mount_path; do
        [ -n "$mount_path" ] || continue
        relative_path="${mount_path#"$oldroot"/}"
        case "$relative_path" in
            dev|dev/*|proc|proc/*|run|run/*|sys|sys/*|x|x/*|oldroot|oldroot/*)
                continue
                ;;
        esac
        printf '%s\n' "$mount_path"
    done < <(awk -v prefix="$oldroot/" 'index($5, prefix) == 1 { print $5 }' /proc/self/mountinfo | sort -r)
}

detach_oldroot_mounts() {
    oldroot="$1"
    mount --make-rslave "$oldroot" 2>/dev/null || true

    while IFS= read -r mount_path; do
        [ -n "$mount_path" ] || continue
        umount -R "$mount_path" 2>/dev/null || umount -l "$mount_path" 2>/dev/null || true
    done < <(list_oldroot_data_mounts "$oldroot")

    remaining_mounts="$(list_oldroot_data_mounts "$oldroot")"
    if [ -n "$remaining_mounts" ]; then
        echo "Unable to detach old-root mounts:" >&2
        printf '%s\n' "$remaining_mounts" >&2
        return 1
    fi
}

mount_transit() {
    mkdir -p "$TRANSIT_ROOT/oldroot" "$TRANSIT_ROOT/dev" "$TRANSIT_ROOT/proc" "$TRANSIT_ROOT/sys" "$TRANSIT_ROOT/run"
    mount --bind / "$TRANSIT_ROOT/oldroot"
    transit_mounted="yes"
    detach_oldroot_mounts "$TRANSIT_ROOT/oldroot" || die "old-root submounts are still busy; no old system files were removed"
    mount --rbind /dev "$TRANSIT_ROOT/dev"
    mount --make-rslave "$TRANSIT_ROOT/dev"
    mount -t proc proc "$TRANSIT_ROOT/proc"
    mount --rbind /sys "$TRANSIT_ROOT/sys"
    mount --make-rslave "$TRANSIT_ROOT/sys"
    mount --rbind /run "$TRANSIT_ROOT/run" 2>/dev/null || true
    mount --make-rslave "$TRANSIT_ROOT/run" 2>/dev/null || true
}

unmount_transit() {
    [ -n "$transit_mounted" ] || return 0
    for mount_path in "$TRANSIT_ROOT/run" "$TRANSIT_ROOT/sys" "$TRANSIT_ROOT/proc" "$TRANSIT_ROOT/dev" "$TRANSIT_ROOT/oldroot"; do
        umount -R "$mount_path" 2>/dev/null || umount -l "$mount_path" 2>/dev/null || true
    done
    transit_mounted=""
}

cleanup_on_error() {
    status=$?
    if [ "$status" -ne 0 ]; then
        unmount_transit
    fi
    return "$status"
}

prepare_transit_root() {
    if awk -v root="$TRANSIT_ROOT" '$5 == root || index($5, root "/") == 1 { found=1 } END { exit !found }' /proc/self/mountinfo; then
        die "$TRANSIT_ROOT already contains active mounts"
    fi

    rm -rf "$TRANSIT_ROOT"
    mkdir -p "$TRANSIT_ROOT"
    curl -fsSL --retry 3 "$transit_url" |
        tar -xJ --numeric-owner --delay-directory-restore -C "$TRANSIT_ROOT"
    copy_main_script

    OSM_PREPARE_TRANSIT=1 OSM_CTTYPE="$cttype" OSM_DEST_ROOT="$TRANSIT_ROOT" \
        /bin/bash "$TRANSIT_ROOT/OsMutation.sh"

    mount_transit
    chroot "$TRANSIT_ROOT" /bin/sh -c \
        'apk update && apk add --no-cache bash coreutils curl gawk sed tar xz iproute2'
}

main() {
    [ "$(id -u)" -eq 0 ] || die "this script must be run as root"
    trap cleanup_on_error EXIT
    echo -e "\e[1;32minstalling requirements...\e[m"
    install_requirement
    detect_container_type
    select_transit_template
    prepare_transit_root
    echo -e "\e[1;32mstarting reinstall inside the Alpine transit root...\e[m"
    chroot "$TRANSIT_ROOT" /usr/bin/env \
        OSM_TIGHT_STAGE=1 OSM_NO_REBOOT_PROMPT=1 OSM_CTTYPE="$cttype" \
        /bin/bash /OsMutation.sh
    unmount_transit
    rm -rf "$TRANSIT_ROOT"

    reboot_ans=""
    while [ "$reboot_ans" != "yes" ] && [ "$reboot_ans" != "no" ]; do
        echo -ne "\e[1;33mreboot now? (yes/no):\e[m"
        read -r reboot_ans </dev/tty
    done
    if [ "$reboot_ans" = "yes" ]; then
        reboot -f
    fi
}

main
