# OpenBSD Cloud-Init for cloudscale.ch

A lightweight shell script replacement for cloud-init, specifically designed for OpenBSD on cloudscale.ch. Although cloud-init supports OpenBSD, this script was created to avoid its many dependencies.

This project is not affiliated with cloudscale.ch.

## Overview

This script runs on first boot via `/etc/rc.firsttime` and configures:

- Hostname (FQDN)
- Network interface (IPv4 + IPv6)
- Default gateway
- DNS resolvers
- SSH authorized keys
- doas access

## Template requirements

The OpenBSD template image must have:

1. An `openbsd` user with `/home/openbsd/.ssh/authorized_keys` present
2. Network configured for DHCP initially (to obtain IPv4 before script runs)
3. This script installed as `/etc/rc.firsttime`

## Installation

Append the script to the existing `/etc/rc.firsttime` (which contains fw_update and syspatch checks):

```sh
cat rc.firsttime.cloud >> /etc/rc.firsttime
```

The script runs once on first boot and is automatically deleted by OpenBSD.

## What it configures

### /etc/myname
```
server.example.com
```

### /etc/hostname.vio0
```
inet 203.0.113.8 0xffffff00
inet6 2001:db8:1000:1164::8/64
```

### /etc/mygate
```
203.0.113.1
fe80::1%vio0
```

### /etc/resolv.conf
```
search example.com
nameserver 198.51.100.101
nameserver 198.51.100.102
nameserver 2001:db8:f::101
nameserver 2001:db8:f::102
lookup file bind
```

### /etc/doas.conf
```
permit nopass openbsd as root
```

## Services

The script also:

- Stops and disables `resolvd` (we manage `/etc/resolv.conf` directly)
- Restarts networking via `sh /etc/netstart`
- Restarts `smtpd` and `syslogd` (depend on hostname)

## cloudscale.ch-specific design decisions

This script is opinionated for cloudscale.ch's environment:

| Feature | Implementation | Reason |
|---------|---------------|--------|
| IPv4 address | Read from running interface | cloudscale.ch metadata only provides `ipv4_dhcp` type without static details; DHCP runs before rc.firsttime |
| IPv4 gateway | Read from routing table | Not available in metadata |
| IPv6 address | Read from metadata | Provided as static in `network_data.json` |
| IPv6 prefix | Hardcoded `/64` | Observed in testing |
| IPv6 gateway | Read from metadata | Provided in routes, formatted as `fe80::1%iface` |
| SSH user | `openbsd` | Matches cloud-init conventions; OpenBSD disables root SSH |

## Metadata sources

The script reads from the config drive mounted at `/dev/cd0c`:

- `openstack/latest/network_data.json` - MAC address, IPv6 config, DNS servers
- `openstack/latest/user_data` - FQDN and SSH keys (cloud-config YAML format)

## Limitations

- Single network interface only
- No support for multiple IPv4/IPv6 addresses
- No support for static IPv4 from metadata (cloudscale.ch doesn't provide it)
- No support for custom users (hardcoded to `openbsd`)

## Tested

2026-01-17 with OpenBSD 7.8 on cloudscale.ch

## License

ISC License. See [LICENSE](LICENSE) for details.
