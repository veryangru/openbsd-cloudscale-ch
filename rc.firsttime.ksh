#
# OpenBSD cloud-init replacement for cloudscale.ch
#
# A lightweight shell script replacement for cloud-init, specifically designed
# for OpenBSD on cloudscale.ch. Although cloud-init supports OpenBSD, this
# script was created to avoid its many dependencies.
#
# Replaces /etc/rc.firsttime and runs on first boot
# Configures: hostname, network, DNS, SSH keys
#
# Not affiliated with cloudscale.ch.
#
# Copyright (c) 2026 Angelo Gruendler <angelo@cuandu.ch>
# ISC License - see LICENSE file for details
#

MOUNT_POINT="/mnt"
CONFIG_DRIVE="/dev/cd0c"
METADATA_DIR="${MOUNT_POINT}/openstack/latest"

# Global: network interface name and data
IFACE=""
NETWORK_DATA=""

log() {
	logger -t cloud-init "$1"
	echo "cloud-init: $1"
}

# Mount config drive
mount_config_drive() {
	if ! mount | grep -q "${CONFIG_DRIVE}"; then
		log "Mounting config drive ${CONFIG_DRIVE}"
		mount -t cd9660 "${CONFIG_DRIVE}" "${MOUNT_POINT}" || {
			log "Failed to mount config drive"
			return 1
		}
	fi
}

# Unmount config drive
umount_config_drive() {
	if mount | grep -q "${CONFIG_DRIVE}"; then
		umount "${MOUNT_POINT}" || true
	fi
}

# Load network data and determine interface name
load_network_data() {
	if [ ! -f "${METADATA_DIR}/network_data.json" ]; then
		log "No network_data.json found"
		return 1
	fi

	NETWORK_DATA=$(cat "${METADATA_DIR}/network_data.json")

	# Find the network interface by MAC address
	local mac
	mac=$(echo "$NETWORK_DATA" | sed 's/.*"ethernet_mac_address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

	# Find interface with matching MAC (on OpenBSD/virtio it's usually vio0)
	IFACE="vio0"
	if [ -n "$mac" ]; then
		local found_iface
		found_iface=$(ifconfig | awk -v mac="$mac" '
			/^[a-z]/ { iface=$1; gsub(/:$/, "", iface) }
			/lladdr/ { if (tolower($2) == tolower(mac)) print iface }
		')
		if [ -n "$found_iface" ]; then
			IFACE="$found_iface"
		fi
	fi

	log "Using interface: ${IFACE}"
}

# Configure hostname from user_data (fqdn)
configure_hostname() {
	local fqdn=""

	if [ -f "${METADATA_DIR}/user_data" ]; then
		fqdn=$(awk '/^fqdn:/ { print $2 }' "${METADATA_DIR}/user_data")
	fi

	if [ -n "$fqdn" ]; then
		log "Setting hostname to: ${fqdn}"
		echo "${fqdn}" > /etc/myname
		hostname "$fqdn"
	fi
}

# Configure network interface
configure_network() {
	# Get IPv4 address and netmask from running interface (already configured via DHCP)
	local ipv4_addr ipv4_netmask hostname_cfg
	ipv4_addr=$(ifconfig "$IFACE" | awk '/inet / { print $2 }')
	ipv4_netmask=$(ifconfig "$IFACE" | awk '/inet / { print $4 }')

	if [ -n "$ipv4_addr" ] && [ -n "$ipv4_netmask" ]; then
		log "IPv4: ${ipv4_addr} netmask ${ipv4_netmask}"
		hostname_cfg="inet ${ipv4_addr} ${ipv4_netmask}"
	fi

	# IPv6 static configuration from metadata
	local ipv6_addr
	ipv6_addr=$(echo "$NETWORK_DATA" | awk -F'"' '{
		for(i=1; i<=NF; i++) {
			if($i == "type" && $(i+2) ~ /ipv6/) {
				for(j=i; j<=NF; j++) {
					if($j == "ip_address") { print $(j+2); exit }
				}
			}
		}
	}')

	if [ -n "$ipv6_addr" ]; then
		log "IPv6: ${ipv6_addr}/64"
		hostname_cfg="${hostname_cfg}
inet6 ${ipv6_addr}/64"
	fi

	log "Writing /etc/hostname.${IFACE}"
	echo "$hostname_cfg" > "/etc/hostname.${IFACE}"
}

# Configure gateway in /etc/mygate
configure_gateway() {
	local mygate_cfg=""

	# Get IPv4 gateway from routing table
	local ipv4_gw
	ipv4_gw=$(netstat -rn | awk '/^default/ && $NF == "'"$IFACE"'" && $2 ~ /^[0-9]/ { print $2 }')
	if [ -n "$ipv4_gw" ]; then
		mygate_cfg="$ipv4_gw"
	fi

	# Get IPv6 gateway from metadata
	local ipv6_gw
	ipv6_gw=$(echo "$NETWORK_DATA" | awk -F'"' '{
		in_ipv6=0
		for(i=1; i<=NF; i++) {
			if($i == "type" && $(i+2) ~ /ipv6/) { in_ipv6=1 }
			if(in_ipv6 && $i == "gateway") { print $(i+2); exit }
		}
	}')

	if [ -n "$ipv6_gw" ]; then
		# Link-local addresses need interface specification
		if echo "$ipv6_gw" | grep -q "^fe80:"; then
			ipv6_gw="${ipv6_gw}%${IFACE}"
		fi
		if [ -n "$mygate_cfg" ]; then
			mygate_cfg="${mygate_cfg}
${ipv6_gw}"
		else
			mygate_cfg="$ipv6_gw"
		fi
	fi

	if [ -n "$mygate_cfg" ]; then
		log "Writing /etc/mygate"
		echo "$mygate_cfg" > /etc/mygate
	fi
}

# Configure DNS from network_data.json
configure_dns() {
	local dns_servers
	dns_servers=$(echo "$NETWORK_DATA" | awk -F'"' '{
		in_services=0
		for(i=1; i<=NF; i++) {
			if($i == "services") { in_services=1 }
			if(in_services) {
				if($i == "type" && $(i+2) == "dns") {
					for(j=i; j<=NF && j<i+10; j++) {
						if($j == "address") { print $(j+2); break }
					}
				}
			}
		}
	}' | sort -u)

	if [ -n "$dns_servers" ]; then
		log "Configuring DNS servers"
		{
			# Add search domain from hostname if FQDN
			local hostname domain
			hostname=$(cat /etc/myname 2>/dev/null)
			domain=$(echo "$hostname" | awk -F'.' '{if(NF>1){$1="";gsub(/^ /,"");gsub(/ /,".");print}}')
			if [ -n "$domain" ]; then
				echo "search ${domain}"
			fi
			# Add nameservers
			echo "$dns_servers" | while read -r ns; do
				[ -n "$ns" ] && echo "nameserver ${ns}"
			done
			echo "lookup file bind"
		} > /etc/resolv.conf
	fi
}

# Configure SSH authorized keys from user_data
configure_ssh_keys() {
	if [ ! -f "${METADATA_DIR}/user_data" ]; then
		log "No user_data found"
		return 0
	fi

	local user_data
	user_data=$(cat "${METADATA_DIR}/user_data")

	# Check if this is cloud-config format
	if ! echo "$user_data" | head -1 | grep -q "^#cloud-config"; then
		log "user_data is not cloud-config format, skipping SSH key setup"
		return 0
	fi

	# Extract SSH keys (lines starting with "- ssh-" after ssh_authorized_keys:)
	local ssh_keys
	ssh_keys=$(echo "$user_data" | awk '
		/^ssh_authorized_keys:/ { in_keys=1; next }
		in_keys && /^[a-z]/ { exit }
		in_keys && /^- / {
			sub(/^- /, "")
			print
		}
	')

	if [ -n "$ssh_keys" ]; then
		log "Installing SSH authorized keys for openbsd user"
		echo "$ssh_keys" >> /home/openbsd/.ssh/authorized_keys
	fi

	# Configure doas for openbsd user
	log "Configuring doas"
	echo "permit nopass openbsd as root" > /etc/doas.conf
	chmod 600 /etc/doas.conf
}

# Main execution
main() {
	log "Starting cloud-init configuration"

	# Output SSH host keys for cloudscale.ch console parsing
	echo "-----BEGIN SSH HOST KEY KEYS-----"
	cat /etc/ssh/ssh_host_*_key.pub
	echo "-----END SSH HOST KEY KEYS-----"

	if ! mount_config_drive; then
		log "Config drive not available, exiting"
		exit 1
	fi

	# Load network data and find interface
	if ! load_network_data; then
		log "Failed to load network data"
		exit 1
	fi

	# Run configuration steps
	configure_hostname
	configure_network
	configure_gateway
	configure_dns
	configure_ssh_keys

	# Cleanup
	umount_config_drive

	log "Cloud-init configuration complete"

	# Disable resolvd as we manage /etc/resolv.conf directly
	log "Disabling resolvd"
	rcctl stop resolvd
	rcctl disable resolvd
	echo

	# Restart networking
	log "Restarting network"
	sh /etc/netstart

	# Restart services that depend on hostname
	log "Restarting services for hostname change"
	rcctl restart smtpd
	rcctl restart syslogd
	echo
}

main "$@"
