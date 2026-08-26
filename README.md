# OsMutation

Reinstall an OpenVZ 7+ or LXC container to Debian, Ubuntu, CentOS, Alpine Linux, or Arch Linux.

## Features

- Supports OpenVZ 7+ and LXC containers only.
- Runs from Debian, Ubuntu, CentOS, Alpine Linux, and Arch Linux.
- Reinstalls to Debian, Ubuntu, CentOS, Alpine Linux, or Arch Linux when an official template exists for the host architecture.
- Downloads every root filesystem directly from the official Linux Containers image server.
- Maps the host architecture exactly: amd64, arm64, i386, armhf, or riscv64. Incompatible templates are not shown.
- Preserves the root password, root SSH keys, hostname, and the primary static IPv4 configuration.
- Includes a Tight mode for containers with very little free disk space.

## Usage

Standard mode:

```bash
wget -qO OsMutation.sh https://raw.githubusercontent.com/senseiod/OsMutation/main/OsMutation.sh
chmod u+x OsMutation.sh
./OsMutation.sh
```

Or with curl:

```bash
curl -fsSLo OsMutation.sh https://raw.githubusercontent.com/senseiod/OsMutation/main/OsMutation.sh
chmod u+x OsMutation.sh
./OsMutation.sh
```

Tight mode for a small disk (experimental):

```bash
wget -qO OsMutationTight.sh https://raw.githubusercontent.com/senseiod/OsMutation/main/OsMutationTight.sh
chmod u+x OsMutationTight.sh
./OsMutationTight.sh
```

Tight mode downloads the latest stable Alpine template for the current architecture from the official image server and uses it as a temporary transit root. It then runs the same target selection and post-install logic as standard mode.

## Template source

Both OpenVZ and LXC use the official index:

```text
https://images.linuxcontainers.org/meta/1.0/index-system
```

Only the `default` variants of Debian, Ubuntu, CentOS, Alpine Linux, and Arch Linux are listed. Edge builds and templates for other architectures are excluded. Root filesystems are downloaded as the official `rootfs.tar.xz` artifact; the repository does not mirror or cache templates.

## Network configuration

- Debian, Ubuntu, and Arch Linux use `systemd-networkd`.
- Alpine Linux uses `ifupdown-ng`.
- Current official CentOS Stream root filesystems do not ship `systemd-networkd`, so CentOS uses an automatically generated NetworkManager keyfile as a compatibility fallback.
- Ubuntu netplan files are removed and cloud-init network management is disabled so they do not overwrite the migrated static configuration.
- `/etc/resolv.conf` is written directly with Google IPv4 and IPv6 DNS servers; `systemd-resolved` is not enabled.

The script migrates the first global IPv4 address and the default route. `GatewayOnLink=yes` is emitted for systemd-networkd to support many VPS gateways outside the assigned subnet. Unusual point-to-point routes, IPv4 configurations without a discoverable interface, and provider-specific networking may still require manual adjustment.

## Important notices

- A fresh system is installed and all old data is wiped. Back up important data first.
- OpenVZ 6 and older are not supported.
- Full virtual machines and other virtualization types are not supported.
- Run the script as root from an interactive terminal.
- Availability depends on what the official image server publishes for the current CPU architecture. For example, Arch Linux is not published for every architecture.
- Tight mode is experimental. Use standard mode when enough disk space is available.

## How it works

OpenVZ and LXC share the host kernel while keeping the container userspace in its own root filesystem. OsMutation downloads a new userspace, migrates the minimum boot-critical configuration, replaces the old root files, installs and enables SSH and networking, and then offers to reboot the container.

## Thanks

- Inspired by trimsj/reinstall.sh (https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d).

## To do

- Add a non-interactive argument mode.
- Add IPv6 address and route migration.
