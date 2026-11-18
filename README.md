# Netplan Primary IP Switcher

Safely switches the primary outbound IPv4 address on Ubuntu servers using Netplan policy routing, validation, backups, and automatic rollback. It can also remove the additional address and return Netplan to the original single IPv4.

## Interactive run

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/netplan-primary-ip/main/install.sh | sudo bash
```

The script displays two actions:

1. Install or replace the new primary IPv4. Only the new address is requested.
2. Roll back to the original single IPv4. No IP address is requested.

## Non-interactive run

Install or replace the new primary IPv4:

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/netplan-primary-ip/main/install.sh | sudo bash -s -- 1 NEW_IP
```

Roll back to the original single IPv4:

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/netplan-primary-ip/main/install.sh | sudo bash -s -- 2
```

## Behavior

The script automatically reads the original IPv4, MAC address, prefix, gateway, and interface from the current Netplan configuration. On a repeated installation, it identifies the address already connected to routing table `100 custom` and replaces it instead of adding a third IPv4. The original IPv4 is never requested or replaced.

The new address is pinned as the preferred source (`from:` without a prefix, i.e. networkd `PreferredSource=`) of the main default route, so the outbound IPv4 does not depend on the order of addresses in the kernel. This keeps repeated replacements working without rolling back first.

Before applying a change, the script backs up Netplan and `rt_tables`. It schedules an independent 180-second rollback, validates the generated configuration, applies it, verifies local addresses on the target interface, the default route source, policy routing and the public IPv4 through `ifconfig.me`, and only then cancels the rollback timer. A commit marker guarantees that the rollback timer cannot revert a configuration that was already confirmed; if the rollback fired first, the script reports a failure instead of claiming success.

If the target file is `50-cloud-init.yaml`, the script warns that cloud-init may regenerate it on reboot and, in interactive mode, offers to create `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` (default: no).

The supported configuration is Ubuntu with Netplan, one static original IPv4, and one IPv4 default gateway on the target Ethernet interface. Ambiguous configurations are rejected before any network files are changed.
