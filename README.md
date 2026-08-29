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

Before applying a change, the script backs up Netplan and `rt_tables`. It schedules an independent 90-second rollback, validates the generated configuration, applies it, verifies local routes and the public IPv4 through `ifconfig.me`, and only then cancels the rollback timer.

The supported configuration is Ubuntu with Netplan, one static original IPv4, and one IPv4 default gateway on the target Ethernet interface. Ambiguous configurations are rejected before any network files are changed.
