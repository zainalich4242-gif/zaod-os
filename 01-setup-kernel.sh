#!/usr/bin/env bash
set -Eeuo pipefail

# Build a minimal Debian Bookworm root filesystem with the Debian kernel,
# initramfs tooling, and firmware required for common x86_64 hardware.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ARCH="amd64"
readonly RELEASE="bookworm"
readonly MIRROR="https://deb.debian.org/debian"
ROOTFS="${ROOTFS:-${SCRIPT_DIR}/chroot}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup_mounts() {
    local mountpoint

    for mountpoint in "/sys" "/proc" "/dev"; do
        if mountpoint -q "${ROOTFS}${mountpoint}"; then
            umount -R "${ROOTFS}${mountpoint}" || true
        fi
    done
}

[[ "$(dpkg --print-architecture)" == "${ARCH}" ]] || die "Run this script on an amd64/x86_64 host."
[[ "${EUID}" -eq 0 ]] || die "Run as root, for example: sudo ./01-setup-kernel.sh"

ROOTFS="$(realpath -m -- "${ROOTFS}")"
TARGET_ROOTFS="${ROOTFS}"
BUILD_ROOT="${ROOTFS}"
STAGED_BUILD=false

# Codespaces mounts /workspaces with nodev, which debootstrap rejects even for
# root. Stage the bootstrap on /tmp, then copy the finished filesystem into the
# requested workspace directory.
if findmnt -no OPTIONS --target "${ROOTFS}" | tr ',' '\n' | grep -qx 'nodev'; then
    BUILD_ROOT="$(mktemp -d /tmp/zaod-rootfs.XXXXXX)"
    STAGED_BUILD=true
    printf 'Staging Debian bootstrap on executable /tmp filesystem: %s\n' "${BUILD_ROOT}"
fi

printf '%s\n' "Installing host build dependencies..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub-pc-bin \
    grub-efi-amd64-bin

if [[ -e "${ROOTFS}" ]] && [[ -n "$(find "${ROOTFS}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    [[ -f "${ROOTFS}/etc/debian_version" ]] || die "${ROOTFS} is non-empty and is not a Debian root filesystem."
    grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not a Debian 12 (Bookworm) root filesystem."
    printf 'Using existing Bookworm root filesystem at %s\n' "${ROOTFS}"
    BUILD_ROOT="${ROOTFS}"
else
    printf 'Bootstrapping Debian %s into %s...\n' "${RELEASE}" "${BUILD_ROOT}"
    mkdir -p "${BUILD_ROOT}"
    debootstrap \
        --arch="${ARCH}" \
        --variant=minbase \
        --components=main,contrib,non-free,non-free-firmware \
        "${RELEASE}" "${BUILD_ROOT}" "${MIRROR}"
fi

    # The staged root starts life as a mode-0700 mktemp directory. A Linux rootfs
    # must be traversable by unprivileged desktop users after it is copied to disk.
    chmod 0755 "${BUILD_ROOT}"

# Ensure non-free-firmware is enabled for Bookworm firmware packages.
cat > "${BUILD_ROOT}/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
EOF

ROOTFS="${BUILD_ROOT}"
mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"

printf '%s\n' "Installing kernel, initramfs tooling, systemd, live boot, and firmware..."
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    initramfs-tools \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    firmware-linux-free \
    firmware-iwlwifi \
    firmware-realtek \
    firmware-amd-graphics \
    intel-microcode \
    amd64-microcode

# Confirm the package post-install hooks produced a kernel and initramfs.
shopt -s nullglob
kernel_images=("${ROOTFS}"/boot/vmlinuz-*)
initramfs_images=("${ROOTFS}"/boot/initrd.img-*)
[[ "${#kernel_images[@]}" -gt 0 ]] || die "No kernel image was generated in ${ROOTFS}/boot."
[[ "${#initramfs_images[@]}" -gt 0 ]] || die "No initramfs was generated in ${ROOTFS}/boot."

for kernel_image in "${kernel_images[@]}"; do
    kernel_version="${kernel_image##*/vmlinuz-}"
    [[ -s "${ROOTFS}/boot/initrd.img-${kernel_version}" ]] || die "Missing initramfs for kernel ${kernel_version}."
done

printf '%s\n' "Cleaning package caches..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

cleanup_mounts
trap - EXIT

if [[ "${STAGED_BUILD}" == true ]]; then
    printf 'Copying completed root filesystem to %s...\n' "${TARGET_ROOTFS}"
    mkdir -p "${TARGET_ROOTFS}"
    cp -a "${BUILD_ROOT}/." "${TARGET_ROOTFS}/"
    rm -rf -- "${BUILD_ROOT}"
    ROOTFS="${TARGET_ROOTFS}"
fi

printf '\nPart 1 complete. Kernel and initramfs files:\n'
ls -lh "${ROOTFS}"/boot/vmlinuz-* "${ROOTFS}"/boot/initrd.img-*