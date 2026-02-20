# OpenBSD Cloud-Init for cloudscale.ch

A lightweight shell script replacement for cloud-init, specifically designed for OpenBSD on cloudscale.ch. Although cloud-init supports OpenBSD, this script was created to avoid its many dependencies.

This project is not affiliated with cloudscale.ch.

## Overview

The provided `rc.firsttime` script runs on first boot and configures:

- Hostname (FQDN)
- Network interface (IPv4 + IPv6)
- Default gateway
- DNS resolvers
- SSH authorized keys
- doas access

## Template requirements

The OpenBSD template image must have an `openbsd` user configured (the script installs SSH keys to `/home/openbsd/.ssh/authorized_keys`). The autoinstall process handles this via `auto_install.conf`. If you build the template on your own, make sure to create the openbsd user when asked by the installer.

Additional requirements (DHCP network config, rc.firsttime) are installed automatically via `site78.tgz`.

## Building a template

There are two approaches to building a template:

1. **Automated** (requires OpenBSD) - Use the included `repack-iso.ksh` script to create an autoinstall ISO that handles everything unattended
2. **Manual** (any platform) - Boot the standard OpenBSD installer in any VM and configure the template by hand

### Manual installation

If you don't have access to an OpenBSD machine to run the build scripts, you can create a template manually using any virtualization platform (QEMU, VirtualBox, VMware, etc.):

1. Boot the official OpenBSD install ISO
2. Run through the installer, creating an `openbsd` user when prompted
3. When the installer finishes and asks what to do next, choose shell
4. Ensure `/mnt/etc/hostname.vio0` contains `inet autoconf` (DHCP is required for initial boot)
5. Copy `rc.firsttime.ksh` to `/mnt/etc/rc.firsttime`
6. Shut down and convert/export the disk image to qcow2 format
7. Upload to cloudscale.ch as a custom image

### Automated build

This section describes the automated approach using vmd. See https://www.openbsd.org/faq/faq16.html for details on vmm/vmd.

### Prerequisites

An OpenBSD machine is required to build the template. `vnd0`/`vnd1` are used by the script, make sure these are free. Enable vmd:

```
doas rcctl enable vmd
doas rcctl start vmd
```

### Create the autoinstall ISO

Run the repack script. It will download and verify the OpenBSD ISO if not already present. The script uses `doas` and can be run as a normal user. If you don't have `persist` or `nopass` configured, you may be asked for your password multiple times.

```
./repack-iso.ksh
```

This creates `install78-autoinstall.iso` with:
- `auto_install.conf` embedded in bsd.rd for unattended installation
- `site78.tgz` custom site set

### site78.tgz layout

The site set is extracted after all other sets and contains:

```
etc/
    hostname.vio0    # inet autoconf (DHCP for initial IPv4)
    installurl       # fast mirror (picked after manual speed tests)
    rc.firsttime     # cloud-init replacement script
```

### Create the template image

Create a qcow2 disk image:

```
vmctl create -s 25G openbsd78.qcow2
```

Start the VM with the autoinstall ISO:

```
doas vmctl start -m 4G -r install78-autoinstall.iso -d openbsd78.qcow2 openbsd-template
```

Connect to the console to watch progress:

```
doas vmctl console openbsd-template
```

The installer runs automatically and reboots when complete. When the boot loader appears, press any key other than enter to prevent boot, then exit the console with `~.` and stop the VM:

```
doas vmctl stop openbsd-template
```

### Upload to cloudscale.ch

Import the qcow2 image into cloudscale.ch. See: https://www.cloudscale.ch/en/api/v1#custom-images

## What `rc.firsttime` configures

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

Note: The OpenBSD installer appends `fw_update` and `syspatch` to `/etc/rc.firsttime`, so these run automatically after our script completes.

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

2026-01-25 with OpenBSD 7.8 on cloudscale.ch

## License

ISC License. See [LICENSE](LICENSE) for details.
