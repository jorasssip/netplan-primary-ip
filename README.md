# Netplan Primary IP Switcher

Safely switches the primary outbound IPv4 address on Ubuntu servers using Netplan policy routing, validation, backups, and automatic rollback.

## Run

Interactive:

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/netplan-primary-ip/main/netplan-switch-primary-ip.sh | sudo bash
```

With IP arguments:

```bash
curl -fsSL https://raw.githubusercontent.com/jorasssip/netplan-primary-ip/main/netplan-switch-primary-ip.sh | sudo bash -s -- OLD_IP NEW_IP
```

The script automatically reads the MAC address, prefix, gateway, and interface from the current Netplan configuration. It keeps the old IP assigned, makes the new IP primary, configures routing table `100 custom`, verifies the external IP through `ifconfig.me`, and rolls back automatically if validation fails.
