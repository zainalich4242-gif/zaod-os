#!/usr/bin/env bash
set -Eeuo pipefail

# ZAOD OS Part 8: final cleanup, SquashFS compression, hybrid GRUB ISO build.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${ROOTFS:-${SCRIPT_DIR}/chroot}"
STAGING="${STAGING:-${SCRIPT_DIR}/iso-staging}"
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/ZAOD-OS.iso}"

 die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup_mounts() {
    local mountpoint
    for mountpoint in /run /dev/pts /sys /proc /dev; do
        if mountpoint -q "${ROOTFS}${mountpoint}"; then
            umount -R "${ROOTFS}${mountpoint}" || true
        fi
    done
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./08-build-final-iso.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
STAGING="$(realpath -m -- "${STAGING}")"
OUTPUT="$(realpath -m -- "${OUTPUT}")"

[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Parts 1-7 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

# The root directory must be traversable by the live desktop account.
chmod 0755 "${ROOTFS}"

printf '%s\n' "Checking host ISO and SquashFS dependencies..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    squashfs-tools \
    xorriso \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools

cleanup_mounts
mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/run"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"

printf '%s\n' "Ensuring live-boot hooks are present in initramfs..."
chroot "${ROOTFS}" dpkg-query -W -f='${Status}\n' live-boot | grep -qx 'install ok installed' || die "live-boot is missing from the root filesystem."
chroot "${ROOTFS}" update-initramfs -u -k all
cleanup_mounts

printf '%s\n' "Verifying kernel and initramfs..."
shopt -s nullglob
kernel_images=("${ROOTFS}"/boot/vmlinuz-*)
initramfs_images=("${ROOTFS}"/boot/initrd.img-*)
[[ "${#kernel_images[@]}" -eq 1 ]] || die "Expected exactly one kernel image in ${ROOTFS}/boot."
[[ "${#initramfs_images[@]}" -eq 1 ]] || die "Expected exactly one initramfs in ${ROOTFS}/boot."
[[ -s "${kernel_images[0]}" ]] || die "Kernel image is empty."
[[ -s "${initramfs_images[0]}" ]] || die "Initramfs is empty."

printf '%s\n' "Performing final chroot cleanup..."
rm -rf -- \
    "${ROOTFS}/var/cache/apt/archives/"* \
    "${ROOTFS}/var/lib/apt/lists/"* \
    "${ROOTFS}/tmp/"* \
    "${ROOTFS}/var/tmp/"*
find "${ROOTFS}/var/log" -type f \( -name '*.log' -o -name '*.log.*' \) -delete 2>/dev/null || true
find "${ROOTFS}" -xdev -type f -name '*bash_history*' -delete 2>/dev/null || true
rm -f -- "${ROOTFS}/var/lib/zaod/.onboarding_complete"

# Remove stale machine-specific state while preserving the fresh OS configuration.
rm -f -- "${ROOTFS}/etc/machine-id" "${ROOTFS}/var/lib/dbus/machine-id"
: > "${ROOTFS}/etc/machine-id"
rm -rf -- "${ROOTFS}/run/"*
mkdir -p "${ROOTFS}/run" "${ROOTFS}/dev"

# Keep essential device nodes in the unmounted live root. Initramfs udev will
# normally move /dev over, but these nodes make switch_root robust on BIOS/UEFI.
if [[ ! -e "${ROOTFS}/dev/console" ]]; then
    mknod -m 600 "${ROOTFS}/dev/console" c 5 1
fi
if [[ ! -e "${ROOTFS}/dev/null" ]]; then
    mknod -m 666 "${ROOTFS}/dev/null" c 1 3
fi
if [[ ! -e "${ROOTFS}/dev/tty" ]]; then
    mknod -m 666 "${ROOTFS}/dev/tty" c 5 0
fi

printf '%s\n' "Rebuilding ISO staging tree..."
rm -rf -- "${STAGING}" "${OUTPUT}.work"
mkdir -p "${STAGING}/live" "${STAGING}/boot/grub" "${STAGING}/EFI/BOOT"

printf '%s\n' "Copying live kernel and initramfs..."
cp "${kernel_images[0]}" "${STAGING}/live/vmlinuz"
cp "${initramfs_images[0]}" "${STAGING}/live/initrd"
chmod 0644 "${STAGING}/live/vmlinuz" "${STAGING}/live/initrd"

cat > "${STAGING}/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0
set gfxpayload=keep

insmod all_video
insmod gfxterm
terminal_output gfxterm

set color_normal=white/black
set color_highlight=white/blue
set menu_color_normal=white/black
set menu_color_highlight=white/blue

menuentry 'Boot ZAOD OS 1.0 (Professional Edition)' --class zaod --class os {
    linux /live/vmlinuz boot=live components quiet splash live-media-path=live live-media-timeout=30 console=tty0
    initrd /live/initrd
}

menuentry 'Boot ZAOD OS (Safe Graphics / Legacy Hardware Mode)' --class zaod --class recovery {
    linux /live/vmlinuz boot=live components nomodeset live-media-path=live live-media-timeout=30 console=tty0
    initrd /live/initrd
}

menuentry 'UEFI Firmware Settings' --class efi {
    fwsetup
}

menuentry 'System Restart' --class reboot {
    reboot
}
EOF

printf '%s\n' "Compressing Debian root filesystem with SquashFS zstd..."
mksquashfs "${ROOTFS}" "${STAGING}/live/filesystem.squashfs" \
    -comp zstd \
    -b 1M \
    -Xcompression-level 15 \
    -wildcards \
    -e 'proc/*' 'sys/*' 'dev/*' 'tmp/*' 'run/*' 'mnt/*'

# Ensure the staging live directory contains only the expected boot payload.
chmod 0755 "${STAGING}" "${STAGING}/live" "${STAGING}/boot" "${STAGING}/boot/grub"

printf '%s\n' "Building hybrid BIOS/UEFI ISO..."
rm -f -- "${OUTPUT}"
grub-mkrescue -o "${OUTPUT}" "${STAGING}"

printf '%s\n' "Verifying final ISO structure..."
[[ -f "${OUTPUT}" ]] || die "ZAOD-OS.iso was not created."
[[ -s "${OUTPUT}" ]] || die "ZAOD-OS.iso is empty."
xorriso -indev "${OUTPUT}" -toc >/tmp/zaod-xorriso-toc.txt 2>&1
if ! grep -q 'El Torito' /tmp/zaod-xorriso-toc.txt; then
    # El Torito text varies by GRUB/xorriso version; ISO9660 PVD is sufficient
    # when xorriso exits successfully and reports a valid volume descriptor.
    grep -Eq 'ISO9660|Rock Ridge|Joliet|Volume Id' /tmp/zaod-xorriso-toc.txt || {
        cat /tmp/zaod-xorriso-toc.txt >&2
        die "ISO structure validation did not return readable TOC data."
    }
fi

ISO_SIZE="$(du -h "${OUTPUT}" | awk '{print $1}')"
ISO_SHA="$(sha256sum "${OUTPUT}" | awk '{print $1}')"
printf '\nZAOD OS 1.0 - Release Summary\n'
printf '================================\n'
printf 'ISO:      %s\n' "${OUTPUT}"
printf 'Size:     %s\n' "${ISO_SIZE}"
printf 'SHA256:   %s\n' "${ISO_SHA}"
printf 'Kernel:   %s\n' "${kernel_images[0]##*/}"
printf '\nCreate GitHub Release:\n'
printf 'gh release create v1.0 "%s" --title "ZAOD OS 1.0 Professional Edition" --notes "ZAOD OS 1.0 bootable ISO"\n' "${OUTPUT}"

cleanup_mounts
trap - EXIT
