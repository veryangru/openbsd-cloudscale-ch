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

1. An `openbsd` user configured (the script installs SSH keys to `/home/openbsd/.ssh/authorized_keys`)
2. Network configured for DHCP initially (to obtain IPv4 before script runs)
3. This script appended to `/etc/rc.firsttime`

## Building a template

You can use OpenBSD's integrated virtualization to build a template. See https://www.openbsd.org/faq/faq16.html for details on vmm/vmd.

1. Create a VM with the desired disk size (qcow2 format recommended)
2. Attach the OpenBSD install CD and boot the VM
3. Install OpenBSD as usual (network not required, sets are on the CD). Create an `openbsd` user when prompted
4. When prompted to reboot, switch to the shell instead
5. Append this script to `/mnt/etc/rc.firsttime`
6. Create `/mnt/etc/hostname.vio0` with `inet autoconf` and `chmod 0640`
7. Halt the VM with `halt -p`
8. Import the qcow2 image into cloudscale.ch

For more info about cloudscale custom images see: https://www.cloudscale.ch/en/api/v1#custom-images

## What it configures

The following values are examples.

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
