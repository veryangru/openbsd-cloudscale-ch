#!/bin/ksh
#
# repack-iso.ksh - Repack OpenBSD install ISO with autoinstall and site set
#
# Creates a modified install ISO that:
# - Boots directly into autoinstall (auto_install.conf in bsd.rd)
# - Includes site set with rc.firsttime
#
# Must be run on OpenBSD (uses vnconfig, mount, rdsetroot via doas)
#

set -e

usage() {
	echo "usage: ${0##*/} [-r release]" >&2
	echo "  -r release   OpenBSD release (default: 7.8)" >&2
	exit 1
}

RELEASE="7.8"
while getopts "hr:" opt; do
	case $opt in
	h)	usage ;;
	r)	RELEASE="$OPTARG" ;;
	*)	usage ;;
	esac
done

ARCH="amd64"
if [[ -f /etc/installurl ]]; then
	MIRROR=$(cat /etc/installurl)
else
	MIRROR="https://ftp2.eu.openbsd.org/pub/OpenBSD"
fi
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SHORT_RELEASE=$(echo "$RELEASE" | tr -d '.')

# Input files (in script directory)
SOURCE_ISO="${SCRIPT_DIR}/install${SHORT_RELEASE}.iso"
AUTO_INSTALL_CONF="${SCRIPT_DIR}/auto_install.conf"
RC_FIRSTTIME="${SCRIPT_DIR}/rc.firsttime.ksh"

# Output
OUTPUT_ISO="${SCRIPT_DIR}/install${SHORT_RELEASE}-autoinstall.iso"

# Working directories
WORK_DIR=$(mktemp -d)
ISO_DIR="${WORK_DIR}/iso"
SITE_DIR="${WORK_DIR}/site"
RAMDISK="${WORK_DIR}/ramdisk.fs"

cleanup() {
	echo "Cleaning up..."
	doas umount "${WORK_DIR}/mnt" 2>/dev/null || true
	doas umount "${ISO_DIR}" 2>/dev/null || true
	doas vnconfig -u vnd0 2>/dev/null || true
	doas vnconfig -u vnd1 2>/dev/null || true
	rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

die() {
	echo "Error: $1" >&2
	exit 1
}

# Download and verify install ISO if not present
download_iso() {
	local iso_name="install${SHORT_RELEASE}.iso"
	local iso_url="${MIRROR}/${RELEASE}/${ARCH}/${iso_name}"
	local sig_url="${MIRROR}/${RELEASE}/${ARCH}/SHA256.sig"
	local signify_key="/etc/signify/openbsd-${SHORT_RELEASE}-base.pub"

	if [[ -f "${SOURCE_ISO}" ]]; then
		echo "Source ISO already exists: ${SOURCE_ISO}"
		return 0
	fi

	echo "Downloading ${iso_name}..."
	ftp -o "${SOURCE_ISO}" "${iso_url}" || die "Failed to download ISO"

	echo "Downloading SHA256.sig..."
	ftp -o "${SCRIPT_DIR}/SHA256.sig" "${sig_url}" || die "Failed to download SHA256.sig"

	echo "Verifying signature..."
	cd "${SCRIPT_DIR}"
	signify -Cp "${signify_key}" -x SHA256.sig "${iso_name}" || die "Signature verification failed"
	rm -f "${SCRIPT_DIR}/SHA256.sig"

	echo "ISO verified successfully"
}

# Check prerequisites
check_prereqs() {
	[[ -f "${AUTO_INSTALL_CONF}" ]] || die "auto_install.conf not found"
	[[ -f "${RC_FIRSTTIME}" ]] || die "rc.firsttime.ksh not found"
	which rdsetroot >/dev/null || die "rdsetroot not found"
	which mkhybrid >/dev/null || die "mkhybrid not found"
}

# Build site tgz
build_site_tgz() {
	echo "Building site${SHORT_RELEASE}.tgz..."
	mkdir -p "${SITE_DIR}/etc"
	cp "${RC_FIRSTTIME}" "${SITE_DIR}/etc/rc.firsttime"
	chmod 755 "${SITE_DIR}/etc/rc.firsttime"
	echo "inet autoconf" > "${SITE_DIR}/etc/hostname.vio0"
	chmod 640 "${SITE_DIR}/etc/hostname.vio0"
	# Mirror picked after manual speed tests from cloudscale.ch
	echo "https://ftp2.eu.openbsd.org/pub/OpenBSD" > "${SITE_DIR}/etc/installurl"
	chmod 644 "${SITE_DIR}/etc/installurl"
	tar -C "${SITE_DIR}" -czf "${WORK_DIR}/site${SHORT_RELEASE}.tgz" etc
}

# Extract and mount source ISO
mount_source_iso() {
	echo "Mounting source ISO..."
	doas vnconfig vnd0 "${SOURCE_ISO}"
	mkdir -p "${ISO_DIR}"
	doas mount -t cd9660 /dev/vnd0c "${ISO_DIR}"
}

# Copy ISO contents to working directory
copy_iso_contents() {
	echo "Copying ISO contents..."
	mkdir -p "${WORK_DIR}/newiso"
	cp -rp "${ISO_DIR}"/* "${WORK_DIR}/newiso/"
	# Make files writable
	chmod -R u+w "${WORK_DIR}/newiso"
}

# Modify bsd.rd to include auto_install.conf
patch_bsd_rd() {
	local bsd_rd="${WORK_DIR}/newiso/${RELEASE}/${ARCH}/bsd.rd"
	local is_gzip=false

	echo "Patching bsd.rd..."

	# Check if gzip compressed
	if file -b "${bsd_rd}" | grep -q gzip; then
		echo "  Decompressing bsd.rd..."
		is_gzip=true
		mv "${bsd_rd}" "${bsd_rd}.gz"
		gunzip "${bsd_rd}.gz"
	fi

	# Extract ramdisk
	echo "  Extracting ramdisk..."
	rdsetroot -x "${bsd_rd}" "${RAMDISK}"

	# Mount ramdisk and add auto_install.conf
	echo "  Adding auto_install.conf..."
	doas vnconfig vnd1 "${RAMDISK}"
	mkdir -p "${WORK_DIR}/mnt"
	doas mount /dev/vnd1a "${WORK_DIR}/mnt"
	doas cp "${AUTO_INSTALL_CONF}" "${WORK_DIR}/mnt/auto_install.conf"
	doas umount "${WORK_DIR}/mnt"
	doas vnconfig -u vnd1

	# Reinsert ramdisk
	echo "  Reinserting ramdisk..."
	rdsetroot "${bsd_rd}" "${RAMDISK}"

	# Recompress if needed
	if ${is_gzip}; then
		echo "  Recompressing bsd.rd..."
		gzip -9n "${bsd_rd}"
		mv "${bsd_rd}.gz" "${bsd_rd}"
	fi
}

# Add site tgz to ISO
add_site_tgz() {
	echo "Adding site${SHORT_RELEASE}.tgz to ISO..."
	cp "${WORK_DIR}/site${SHORT_RELEASE}.tgz" "${WORK_DIR}/newiso/${RELEASE}/${ARCH}/"
}

# Create new ISO
create_iso() {
	local sets_dir="${RELEASE}/${ARCH}"
	local efi_opts=""

	echo "Creating new ISO..."

	# Check for EFI boot support
	if [[ -f "${WORK_DIR}/newiso/${sets_dir}/eficdboot" ]]; then
		efi_opts="-e ${sets_dir}/eficdboot"
	fi

	mkhybrid -a -R -T -L -l -d -D -N \
		-o "${OUTPUT_ISO}" \
		-A "OpenBSD ${RELEASE} ${ARCH} autoinstall" \
		-P "OpenBSD" \
		-p "repack-iso.ksh" \
		-b "${sets_dir}/cdbr" \
		-c "${sets_dir}/boot.catalog" \
		${efi_opts} \
		"${WORK_DIR}/newiso"

	echo "Created: ${OUTPUT_ISO}"
}

# Main
main() {
	echo "OpenBSD Install ISO Repacker"
	echo "============================"
	echo

	check_prereqs
	download_iso
	build_site_tgz
	mount_source_iso
	copy_iso_contents
	patch_bsd_rd
	add_site_tgz
	create_iso

	echo
	echo "Done! ISO ready: ${OUTPUT_ISO}"
}

main "$@"
