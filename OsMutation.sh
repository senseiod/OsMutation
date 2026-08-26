#!/bin/bash
# Reinstall an OpenVZ/LXC container to Debian, Ubuntu, CentOS, Alpine, or Arch Linux.
# Author: Lloyd@nodeseek.com
# WARNING: A fresh system will be installed and all old data will be wiped.
# License: GPLv3; partly based on https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d

set -o errexit
set -o pipefail

IMAGE_SERVER="https://images.linuxcontainers.org"
IMAGE_INDEX="${IMAGE_SERVER}/meta/1.0/index-system"

die() {
    echo "Error: $*" >&2
    exit 1
}

retry_command() {
    local attempt=1
    local max_attempts=3
    until "$@"; do
        [ "$attempt" -lt "$max_attempts" ] || return 1
        attempt=$((attempt + 1))
        echo "Command failed; retrying ($attempt/$max_attempts)..." >&2
        sleep 2
    done
}

print_help() {
    echo -ne "\e[1;32m"
    cat <<-'EOF'

		 ██████╗ ███████╗███╗   ███╗██╗   ██╗████████╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
		██╔═══██╗██╔════╝████╗ ████║██║   ██║╚══██╔══╝██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
		██║   ██║███████╗██╔████╔██║██║   ██║   ██║   ███████║   ██║   ██║██║   ██║██╔██╗ ██║
		██║   ██║╚════██║██║╚██╔╝██║██║   ██║   ██║   ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
		╚██████╔╝███████║██║ ╚═╝ ██║╚██████╔╝   ██║   ██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
		 ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

		Reinstall an OpenVZ/LXC VPS to Debian/Ubuntu/CentOS/Alpine/Arch Linux.
		[warning] A fresh system will be installed and all old data will be wiped!
		Author: Lloyd@nodeseek.com
EOF
    echo -ne "\e[m"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this script must be run as root"
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
            retry_command pacman -Sy --noconfirm --disable-download-timeout
            retry_command pacman -S --noconfirm --needed --disable-download-timeout "$@"
            ;;
    esac
}

install_requirement() {
    detect_package_manager

    case "$pkg_manager" in
        apt)
            install curl sed gawk wget gzip xz-utils tar virt-what iproute2
            ;;
        dnf|yum)
            install curl sed gawk wget gzip xz tar virt-what iproute
            ;;
        apk)
            install curl sed gawk wget gzip xz tar virt-what iproute2
            ;;
        pacman)
            install curl sed gawk wget gzip xz tar virt-what iproute2
            ;;
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

read_virt_tech() {
    if [ -n "${OSM_CTTYPE:-}" ]; then
        cttype="$OSM_CTTYPE"
    else
        detected_virt="$(virt-what 2>/dev/null || true)"
        cttype="$(printf '%s\n' "$detected_virt" | awk '$0 == "lxc" || $0 == "openvz" { print; exit }')"

        if [ -z "$cttype" ] && [ -n "$detected_virt" ]; then
            die "this virtualization type is not supported; only OpenVZ/LXC containers are supported"
        fi

        while [ "$cttype" != "lxc" ] && [ "$cttype" != "openvz" ]; do
            echo -ne "\e[1;33mplease input container type (lxc/openvz):\e[m"
            read -r cttype </dev/tty
        done
    fi

    case "$cttype" in
        lxc|openvz) echo -e "\e[1;33mYour container type: $cttype\e[m" ;;
        *) die "invalid container type: $cttype" ;;
    esac
}

read_template() {
    normalize_arch
    echo -e "\e[1;32mfetching official template index for $image_arch...\e[m"

    template_records="$(
        curl -fsSL --retry 3 "$IMAGE_INDEX" |
            awk -F ';' -v arch="$image_arch" '
                $3 == arch &&
                $4 == "default" &&
                $2 != "edge" &&
                ($1 == "debian" || $1 == "ubuntu" || $1 == "centos" || $1 == "alpine" || $1 == "archlinux") {
                    print $1 ";" $2 ";" $3 ";" $NF
                }
            '
    )"
    [ -n "$template_records" ] || die "no supported official template is available for $image_arch"

    printf '%s\n' "$template_records" |
        awk -F ';' '{ printf "%4d  %-12s %-16s %s\n", NR, $1, $2, $3 }'

    template_count="$(printf '%s\n' "$template_records" | awk 'END { print NR }')"
    os_index=""
    while :; do
        echo -ne "\e[1;33mplease select os (input number):\e[m"
        read -r os_index </dev/tty
        case "$os_index" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$os_index" -ge 1 ] && [ "$os_index" -le "$template_count" ] && break
    done

    selected_record="$(printf '%s\n' "$template_records" | sed -n "${os_index}p")"
    IFS=';' read -r os_selected os_release os_arch image_path <<EOF
$selected_record
EOF
    download_link="${IMAGE_SERVER}${image_path}rootfs.tar.xz"
    echo -e "\e[1;33mSelected: $os_selected $os_release ($os_arch)\e[m"
}

detect_os_family() {
    os_root="${1:-/}"
    os_root="${os_root%/}"
    [ -n "$os_root" ] || os_root="/"

    if [ -e "$os_root/etc/os-release" ]; then
        release_file="$os_root/etc/os-release"
    elif [ -e "$os_root/usr/lib/os-release" ]; then
        release_file="$os_root/usr/lib/os-release"
    else
        return 1
    fi

    os_id="$(awk -F '=' '$1 == "ID" {
        value=substr($0, index($0, "=") + 1)
        gsub(/^"|"$/, "", value)
        print value
        exit
    }' "$release_file")"
    os_id_like="$(awk -F '=' '$1 == "ID_LIKE" {
        value=substr($0, index($0, "=") + 1)
        gsub(/^"|"$/, "", value)
        print value
        exit
    }' "$release_file")"

    case "$os_id" in
        arch|archlinux|archarm) printf '%s\n' "arch" ;;
        ubuntu) printf '%s\n' "ubuntu" ;;
        debian) printf '%s\n' "debian" ;;
        centos) printf '%s\n' "centos" ;;
        alpine) printf '%s\n' "alpine" ;;
        *)
            case " $os_id_like " in
                *" arch "*) printf '%s\n' "arch" ;;
                *" debian "*) printf '%s\n' "ubuntu" ;;
                *" rhel "*|*" fedora "*) printf '%s\n' "centos" ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

collect_network_configuration() {
    default_route="$(ip -4 route show default | sed -n '1p')"
    dev="$(printf '%s\n' "$default_route" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev" && i < NF) {
                print $(i + 1)
                exit
            }
        }
    }')"

    if [ -z "$dev" ]; then
        dev="$(ip -o -4 addr show scope global | awk 'NR == 1 { print $2 }')"
    fi
    [ -n "$dev" ] || die "could not determine the IPv4 network interface"

    ipaddr_with_mask="$(ip -o -4 addr show dev "$dev" scope global | awk 'NR == 1 { print $4 }')"
    [ -n "$ipaddr_with_mask" ] || die "could not determine the IPv4 address for $dev"

    gateway="$(printf '%s\n' "$default_route" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "via" && i < NF) {
                print $(i + 1)
                exit
            }
        }
    }')"
    saved_hostname=""
    if command -v hostname >/dev/null 2>&1; then
        saved_hostname="$(hostname 2>/dev/null || true)"
    fi
    if [ -z "$saved_hostname" ] && [ -f /etc/hostname ]; then
        saved_hostname="$(sed -n '1p' /etc/hostname 2>/dev/null || true)"
    fi
    if [ -z "$saved_hostname" ]; then
        saved_hostname="$(uname -n 2>/dev/null || true)"
    fi
    [ -n "$saved_hostname" ] || saved_hostname="localhost"
}

write_resolv_conf() {
    dest_root="$1"
    rm -f "$dest_root/etc/resolv.conf"
    cat >"$dest_root/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
EOF
}

write_alpine_network() {
    dest_root="$1"
    mkdir -p "$dest_root/etc/network"
    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo
        echo "auto $dev"
        echo "iface $dev inet static"
        echo "    address $ipaddr_with_mask"
        if [ -n "$gateway" ]; then
            echo "    gateway $gateway"
        fi
    } >"$dest_root/etc/network/interfaces"
}

write_systemd_network() {
    dest_root="$1"
    mkdir -p "$dest_root/etc/systemd/network"
    {
        echo "[Match]"
        echo "Name=$dev"
        echo
        echo "[Network]"
        echo "Address=$ipaddr_with_mask"
        echo "DNS=8.8.8.8"
        echo "DNS=2001:4860:4860::8888"
        if [ -n "$gateway" ]; then
            echo
            echo "[Route]"
            echo "Gateway=$gateway"
            echo "GatewayOnLink=yes"
        fi
    } >"$dest_root/etc/systemd/network/10-osmutation.network"
}

write_networkmanager_fallback() {
    dest_root="$1"
    mkdir -p "$dest_root/etc/NetworkManager/system-connections"
    {
        echo "[connection]"
        echo "id=osmutation"
        echo "type=ethernet"
        echo "interface-name=$dev"
        echo "autoconnect=true"
        echo
        echo "[ipv4]"
        echo "method=manual"
        echo "address1=$ipaddr_with_mask"
        if [ -n "$gateway" ]; then
            echo "gateway=$gateway"
        fi
        echo "dns=8.8.8.8;"
        echo "may-fail=false"
        echo
        echo "[ipv6]"
        echo "method=ignore"
    } >"$dest_root/etc/NetworkManager/system-connections/osmutation.nmconnection"
    chmod 600 "$dest_root/etc/NetworkManager/system-connections/osmutation.nmconnection"
}

capture_configuration() {
    dest_root="$1"
    source_root="${2:-/}"
    dest_root="${dest_root%/}"
    source_root="${source_root%/}"
    [ -n "$dest_root" ] || dest_root="/"
    [ -n "$source_root" ] || source_root="/"

    collect_network_configuration
    [ -f "$source_root/etc/shadow" ] || die "source root password database is missing"
    root_shadow="$(grep '^root:' "$source_root/etc/shadow" | head -n 1)"
    [ -n "$root_shadow" ] || die "source root password entry is missing"

    mkdir -p "$dest_root/etc"
    printf '%s\n' "$root_shadow" >"$dest_root/.osmutation-root-shadow"
    printf '%s\n' "$dev" >"$dest_root/.osmutation-dev"
    printf '%s\n' "$ipaddr_with_mask" >"$dest_root/.osmutation-address"
    printf '%s\n' "$gateway" >"$dest_root/.osmutation-gateway"
    printf '%s\n' "$saved_hostname" >"$dest_root/.osmutation-hostname"
    chmod 600 "$dest_root/.osmutation-root-shadow"

    if [ -d "$source_root/root/.ssh" ]; then
        rm -rf "$dest_root/.osmutation-ssh"
        cp -a "$source_root/root/.ssh" "$dest_root/.osmutation-ssh"
    fi
}

restore_configuration() {
    source_root="$1"
    dest_root="$2"
    source_root="${source_root%/}"
    dest_root="${dest_root%/}"
    [ -n "$source_root" ] || source_root="/"
    [ -n "$dest_root" ] || dest_root="/"

    target_family="$(detect_os_family "$dest_root")" || die "unsupported target operating system"
    [ -f "$source_root/.osmutation-root-shadow" ] || die "saved root password entry is missing"
    [ -f "$dest_root/etc/shadow" ] || die "target root password database is missing"

    dev="$(sed -n '1p' "$source_root/.osmutation-dev")"
    ipaddr_with_mask="$(sed -n '1p' "$source_root/.osmutation-address")"
    gateway="$(sed -n '1p' "$source_root/.osmutation-gateway")"
    saved_hostname="$(sed -n '1p' "$source_root/.osmutation-hostname")"
    [ -n "$dev" ] && [ -n "$ipaddr_with_mask" ] || die "saved network configuration is incomplete"

    sed -i '/^root:/d' "$dest_root/etc/shadow"
    cat "$source_root/.osmutation-root-shadow" >>"$dest_root/etc/shadow"

    if [ -d "$source_root/.osmutation-ssh" ]; then
        rm -rf "$dest_root/root/.ssh"
        mkdir -p "$dest_root/root"
        cp -a "$source_root/.osmutation-ssh" "$dest_root/root/.ssh"
    fi

    mkdir -p "$dest_root/etc"
    printf '%s\n' "$saved_hostname" >"$dest_root/etc/hostname"
    if [ "$target_family" = "alpine" ]; then
        write_alpine_network "$dest_root"
    else
        write_systemd_network "$dest_root"
        if [ "$target_family" = "centos" ]; then
            write_networkmanager_fallback "$dest_root"
        fi
    fi
    write_resolv_conf "$dest_root"
}

remove_configuration_snapshot() {
    snapshot_root="$1"
    rm -f \
        "$snapshot_root/.osmutation-root-shadow" \
        "$snapshot_root/.osmutation-dev" \
        "$snapshot_root/.osmutation-address" \
        "$snapshot_root/.osmutation-gateway" \
        "$snapshot_root/.osmutation-hostname"
    rm -rf "$snapshot_root/.osmutation-ssh"
}

migrate_configuration() {
    dest_root="$1"
    source_root="${2:-/}"
    capture_configuration "$dest_root" "$source_root"
    restore_configuration "$dest_root" "$dest_root"
    remove_configuration_snapshot "$dest_root"
}

download_rootfs() {
    dest_root="$1"
    mkdir -p "$dest_root"
    curl -fsSL --retry 3 "$download_link" |
        tar -xJ --numeric-owner --delay-directory-restore -C "$dest_root"
}

ensure_target_bash() {
    target_root="$1"
    target_family="$(detect_os_family "$target_root")" || die "unsupported target operating system"
    if [ "$target_family" = "alpine" ]; then
        chroot "$target_root" /bin/sh -c 'apk update && apk add --no-cache bash'
    fi
    [ -x "$target_root/bin/bash" ] || die "the target template does not provide bash"
}

current_script_path() {
    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s/%s\n' "$script_dir" "$(basename -- "${BASH_SOURCE[0]}")"
}

list_root_data_mounts() {
    while IFS= read -r mount_path; do
        [ -n "$mount_path" ] || continue
        case "$mount_path" in
            /|/dev|/dev/*|/proc|/proc/*|/run|/run/*|/sys|/sys/*|/x|/x/*|/oldroot|/oldroot/*)
                continue
                ;;
        esac
        printf '%s\n' "$mount_path"
    done < <(awk '$5 ~ /^\// { print $5 }' /proc/self/mountinfo | sort -r)
}

detach_root_data_mounts() {
    mount --make-rslave / 2>/dev/null || true

    while IFS= read -r mount_path; do
        [ -n "$mount_path" ] || continue
        umount -R "$mount_path" 2>/dev/null || umount -l "$mount_path" 2>/dev/null || true
    done < <(list_root_data_mounts)

    remaining_mounts="$(list_root_data_mounts)"
    if [ -n "$remaining_mounts" ]; then
        echo "Unable to detach root data mounts:" >&2
        printf '%s\n' "$remaining_mounts" >&2
        return 1
    fi
}

replace_os() {
    new_root="$1"
    cd /
    cp "$(current_script_path)" "$new_root/OsMutation.sh"
    if ! detach_root_data_mounts; then
        die "root data mounts are still busy; no old system files were removed"
    fi
    mkdir -p "$new_root/oldroot"
    mount --bind / "$new_root/oldroot"

    chroot "$new_root" /bin/bash -c '
        set -o errexit

        remove_paths=()
        for path in /oldroot/* /oldroot/.[!.]* /oldroot/..?*; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            name=${path##*/}
            case "$name" in
                dev|proc|run|sys|x|oldroot) continue ;;
            esac
            remove_paths+=("$path")
        done
        if [ ${#remove_paths[@]} -gt 0 ]; then
            rm -rf -- "${remove_paths[@]}"
        fi

        move_paths=()
        for path in /* /.[!.]* /..?*; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            name=${path##*/}
            case "$name" in
                dev|proc|run|sys|x|oldroot) continue ;;
            esac
            move_paths+=("$path")
        done
        if [ ${#move_paths[@]} -gt 0 ]; then
            mv -f -- "${move_paths[@]}" /oldroot/
        fi
    '

    umount "$new_root/oldroot"
    exec env OSM_POSTINSTALL=1 OSM_CTTYPE="$cttype" OSM_CLEANUP_SCRIPT=/OsMutation.sh \
        /bin/bash /OsMutation.sh
}

offline_systemctl() {
    systemctl --root=/ "$@"
}

configure_root_ssh() {
    sshd_config="/etc/ssh/sshd_config"
    [ -f "$sshd_config" ] || die "OpenSSH server configuration is missing"

    if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+' "$sshd_config"; then
        sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin yes/' "$sshd_config"
    else
        printf '\nPermitRootLogin yes\n' >>"$sshd_config"
    fi
}

initialize_arch_keyring() {
    local keyring
    local keyrings=()

    pacman-key --init
    for keyring in archlinux archlinuxarm; do
        if [ -f "/usr/share/pacman/keyrings/$keyring.gpg" ]; then
            keyrings+=("$keyring")
        fi
    done
    [ "${#keyrings[@]}" -gt 0 ] || die "no Arch Linux pacman keyring is available"
    pacman-key --populate "${keyrings[@]}"
}

initialize_systemd_identity() {
    if [ ! -s /etc/machine-id ]; then
        command -v systemd-machine-id-setup >/dev/null 2>&1 ||
            die "systemd-machine-id-setup is not available in the target system"
        systemd-machine-id-setup
    fi
}

configure_systemd_network() {
    target_family="$1"

    if [ ! -x /usr/lib/systemd/systemd-networkd ] && [ ! -x /lib/systemd/systemd-networkd ]; then
        if [ "$target_family" = "centos" ]; then
            install NetworkManager
            offline_systemctl unmask NetworkManager.service NetworkManager-wait-online.service || true
            offline_systemctl enable NetworkManager.service
            offline_systemctl disable systemd-networkd.service systemd-networkd-wait-online.service || true
            offline_systemctl mask systemd-resolved.service || true
            return
        fi
        install systemd
    fi

    if [ ! -x /usr/lib/systemd/systemd-networkd ] && [ ! -x /lib/systemd/systemd-networkd ]; then
        die "systemd-networkd is not available in the target system"
    fi

    offline_systemctl unmask systemd-networkd.service systemd-networkd-wait-online.service || true
    offline_systemctl enable systemd-networkd.service
    offline_systemctl disable NetworkManager.service NetworkManager-wait-online.service networking.service || true
    offline_systemctl mask NetworkManager.service NetworkManager-wait-online.service networking.service systemd-resolved.service || true
}

cleanup_installation_files() {
    if [ -n "${OSM_TIGHT_TARGET:-}" ]; then
        :
    elif [ -n "${OSM_TIGHT_STAGE:-}" ]; then
        for mount_path in /x/oldroot /x/run /x/sys /x/proc /x/dev; do
            umount -l "$mount_path" 2>/dev/null || true
        done

        if ! awk '$5 == "/x" || index($5, "/x/") == 1 { found=1 } END { exit !found }' /proc/self/mountinfo; then
            rm -rf /x
        else
            echo "Warning: /x still contains active mounts and was not removed." >&2
        fi
    else
        rm -rf /x
    fi

    if [ -n "${OSM_CLEANUP_SCRIPT:-}" ]; then
        rm -f "$OSM_CLEANUP_SCRIPT"
    fi
}

post_install() {
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    require_root
    cttype="${OSM_CTTYPE:-${cttype:-}}"
    case "$cttype" in
        lxc|openvz) ;;
        *) die "container type was not preserved during installation" ;;
    esac

    target_family="$(detect_os_family /)" || die "unsupported installed operating system"
    if [ "$target_family" != "alpine" ]; then
        initialize_systemd_identity
    fi
    case "$target_family" in
        alpine)
            install openssh bash ifupdown-ng
            rc-update add sshd default
            rc-update add mdev sysinit
            rc-update add devfs sysinit
            rc-update add networking default
            if [ "$cttype" = "lxc" ] && [ -f /etc/init.d/networking ]; then
                sed -i 's/--auto/-a/' /etc/init.d/networking
            fi
            ;;
        arch)
            initialize_arch_keyring
            install openssh
            offline_systemctl enable sshd.service
            configure_systemd_network "$target_family"
            ;;
        ubuntu)
            install openssh-server
            mkdir -p /etc/netplan /etc/cloud/cloud.cfg.d
            rm -f /etc/netplan/*
            printf '%s\n' 'network: {config: disabled}' >/etc/cloud/cloud.cfg.d/99-osmutation-disable-network.cfg
            offline_systemctl enable ssh.service
            configure_systemd_network "$target_family"
            ;;
        debian)
            install openssh-server
            offline_systemctl enable ssh.service
            configure_systemd_network "$target_family"
            ;;
        centos)
            if ! install openssh-server; then
                install openssh
            fi
            offline_systemctl enable sshd.service
            configure_systemd_network "$target_family"
            ;;
    esac

    configure_root_ssh
    sync
    cleanup_installation_files

    if [ -z "${OSM_NO_REBOOT_PROMPT:-}" ]; then
        reboot_ans=""
        while [ "$reboot_ans" != "yes" ] && [ "$reboot_ans" != "no" ]; do
            echo -ne "\e[1;33mreboot now? (yes/no):\e[m"
            read -r reboot_ans </dev/tty
        done

        if [ "$reboot_ans" = "yes" ]; then
            reboot -f
        fi
    fi
}

clear_tight_old_root() {
    remove_paths=()
    for path in /oldroot/* /oldroot/.[!.]* /oldroot/..?*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        name="${path##*/}"
        case "$name" in
            dev|proc|run|sys|x|oldroot) continue ;;
        esac
        remove_paths+=("$path")
    done
    if [ "${#remove_paths[@]}" -gt 0 ]; then
        rm -rf -- "${remove_paths[@]}"
    fi
}

download_tight_rootfs() {
    curl -fsSL --retry 3 "$download_link" |
        tar -xJ --numeric-owner --delay-directory-restore \
            --exclude='dev' --exclude='dev/*' \
            --exclude='proc' --exclude='proc/*' \
            --exclude='run' --exclude='run/*' \
            --exclude='sys' --exclude='sys/*' \
            -C /oldroot
}

prepare_transit() {
    require_root
    cttype="${OSM_CTTYPE:-}"
    case "$cttype" in
        lxc|openvz) ;;
        *) die "invalid container type for Tight mode" ;;
    esac
    dest_root="${OSM_DEST_ROOT:-/x}"
    capture_configuration "$dest_root" /
    write_resolv_conf "$dest_root"
    printf '%s\n' "$cttype" >"$dest_root/.osmutation-cttype"
}

tight_stage() {
    require_root
    cttype="${OSM_CTTYPE:-}"
    case "$cttype" in
        lxc|openvz) ;;
        *) die "invalid container type for Tight mode" ;;
    esac
    [ -d /oldroot/x ] || die "Tight mode transit mount is missing"

    read_template
    clear_tight_old_root
    download_tight_rootfs
    restore_configuration / /oldroot
    ensure_target_bash /oldroot
    cp /OsMutation.sh /oldroot/OsMutation.sh
    chmod 700 /oldroot/OsMutation.sh

    exec chroot /oldroot /usr/bin/env \
        OSM_POSTINSTALL=1 OSM_TIGHT_TARGET=1 OSM_NO_REBOOT_PROMPT=1 OSM_CTTYPE="$cttype" \
        /bin/bash /OsMutation.sh
}

main() {
    require_root
    print_help
    echo -e "\e[1;32minstalling requirements...\e[m"
    install_requirement
    read_virt_tech
    read_template

    collect_network_configuration
    rm -rf /x
    mkdir -p /x

    echo -e "\e[1;32mdownloading official template...\e[m"
    download_rootfs /x
    echo -e "\e[1;32mmigrating configuration...\e[m"
    migrate_configuration /x /
    ensure_target_bash /x
    echo -e "\e[1;32mreplacing old files...\e[m"
    replace_os /x
}

if [ -n "${OSM_PREPARE_TRANSIT:-}" ]; then
    prepare_transit
elif [ -n "${OSM_TIGHT_STAGE:-}" ] && [ -z "${OSM_POSTINSTALL:-}" ]; then
    tight_stage
elif [ -n "${OSM_POSTINSTALL:-}" ]; then
    post_install 2>&1 | tee /reinstall.log
else
    main 2>&1 | tee /reinstall.log
fi
