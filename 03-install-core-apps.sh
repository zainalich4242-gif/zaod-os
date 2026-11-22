#!/usr/bin/env bash
set -Eeuo pipefail

# ZAOD OS Part 3: install and configure only the minimal core applications.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${ROOTFS:-${SCRIPT_DIR}/chroot}"

 die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup_mounts() {
    local mountpoint

    for mountpoint in /dev/pts /sys /proc /dev; do
        if mountpoint -q "${ROOTFS}${mountpoint}"; then
            umount -R "${ROOTFS}${mountpoint}" || true
        fi
    done
}

[[ "${EUID}" -eq 0 ]] || die "Run as root, for example: sudo ./03-install-core-apps.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Parts 1 and 2 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mkdir -p "${ROOTFS}/dev/pts"
mount -t devpts devpts "${ROOTFS}/dev/pts" 2>/dev/null || true

printf '%s\n' "Installing ZAOD core applications..."
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    chromium \
    thunar \
    thunar-archive-plugin \
    tumbler \
    ffmpegthumbnailer \
    mpv \
    ristretto \
    xfce4-terminal \
    guvcview \
    mousepad \
    xfce4-settings \
    fonts-noto-core

# Chromium: retain hardware compatibility while reducing renderer and cache pressure.
CHROMIUM_DESKTOP="${ROOTFS}/usr/share/applications/chromium.desktop"
if [[ -f "${CHROMIUM_DESKTOP}" ]]; then
    sed -i 's/^Name=.*/Name=ZAOD Browser/' "${CHROMIUM_DESKTOP}"
    sed -i 's|^Exec=/usr/bin/chromium .*|Exec=/usr/bin/chromium --process-per-site --disable-gpu-shader-disk-cache --disk-cache-size=33554432 --enable-features=UseSkiaRenderer %U|' "${CHROMIUM_DESKTOP}"
fi

# Terminal: compact dark-blue palette suitable for the ZAOD XFCE desktop.
mkdir -p "${ROOTFS}/etc/xdg/xfce4/terminal"
cat > "${ROOTFS}/etc/xdg/xfce4/terminal/terminalrc" <<'EOF'
[Configuration]
FontName=Monospace 10
ColorForeground=#d7e6f3
ColorBackground=#07111f
ColorCursor=#72dfff
ColorCursorForeground=#07111f
ColorBold=#f1f7fb
ColorSelection=#1a5f8e
ColorSelectionBackground=#72dfff
TabActivityColor=#1688df
ColorPalette=#07111f;#ef6a73;#73c991;#e6bd73;#1688df;#b58bd0;#62c8dc;#d7e6f3;#36506a;#ff7a82;#86d8a6;#f3cf8a;#4ca8ef;#cca2df;#7bd7e8;#f1f7fb
MiscShowRelaunchDialog=FALSE
EOF

# Unified Settings entry name and a single settings launcher in the menu.
SETTINGS_DESKTOP="${ROOTFS}/usr/share/applications/xfce-settings-manager.desktop"
if [[ -f "${SETTINGS_DESKTOP}" ]]; then
    sed -i 's/^Name=.*/Name=ZAOD Settings/' "${SETTINGS_DESKTOP}"
fi

# Thunar opens videos and audio through mpv, and images through Ristretto.
mkdir -p "${ROOTFS}/etc/xdg/Thunar"
cat > "${ROOTFS}/etc/xdg/Thunar/uca.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<actions>
  <action>
    <icon>video-x-generic</icon>
    <name>Play in ZAOD Media</name>
    <unique-id>zaod-open-media</unique-id>
    <command>mpv --force-window=yes --window-scale=0.9 %F</command>
    <description>Play video or audio with lightweight mpv</description>
    <patterns>*</patterns>
    <startup-notify>true</startup-notify>
    <directories/>
    <audio-files/>
    <video-files/>
  </action>
  <action>
    <icon>image-x-generic</icon>
    <name>Open in ZAOD Viewer</name>
    <unique-id>zaod-open-image</unique-id>
    <command>ristretto %F</command>
    <description>Open image in Ristretto</description>
    <patterns>*</patterns>
    <startup-notify>true</startup-notify>
    <image-files/>
  </action>
</actions>
EOF

# System-wide MIME defaults keep the media apps behind Thunar's unified experience.
mkdir -p "${ROOTFS}/etc/xdg"
cat > "${ROOTFS}/etc/xdg/mimeapps.list" <<'EOF'
[Default Applications]
video/mp4=mpv.desktop
video/mpeg=mpv.desktop
video/quicktime=mpv.desktop
video/webm=mpv.desktop
video/x-matroska=mpv.desktop
video/x-msvideo=mpv.desktop
audio/flac=mpv.desktop
audio/mpeg=mpv.desktop
audio/ogg=mpv.desktop
audio/wav=mpv.desktop
audio/x-vorbis+ogg=mpv.desktop
image/bmp=ristretto.desktop
image/gif=ristretto.desktop
image/jpeg=ristretto.desktop
image/png=ristretto.desktop
image/svg+xml=ristretto.desktop
image/tiff=ristretto.desktop
image/webp=ristretto.desktop

[Added Associations]
video/mp4=mpv.desktop
video/mpeg=mpv.desktop
video/quicktime=mpv.desktop
video/webm=mpv.desktop
video/x-matroska=mpv.desktop
video/x-msvideo=mpv.desktop
audio/flac=mpv.desktop
audio/mpeg=mpv.desktop
audio/ogg=mpv.desktop
audio/wav=mpv.desktop
audio/x-vorbis+ogg=mpv.desktop
image/bmp=ristretto.desktop
image/gif=ristretto.desktop
image/jpeg=ristretto.desktop
image/png=ristretto.desktop
image/svg+xml=ristretto.desktop
image/tiff=ristretto.desktop
image/webp=ristretto.desktop
EOF

# Hide redundant standalone applications while preserving the six core launchers.
mkdir -p "${ROOTFS}/usr/share/applications"
for desktop in "${ROOTFS}"/usr/share/applications/*.desktop; do
    [[ -f "${desktop}" ]] || continue
    base="$(basename -- "${desktop}")"
    case "${base}" in
        chromium.desktop|thunar.desktop|xfce4-terminal.desktop|guvcview.desktop|mousepad.desktop|org.xfce.mousepad.desktop|xfce-settings-manager.desktop)
            sed -i '/^NoDisplay=/d' "${desktop}" 2>/dev/null || true
            sed -i '/^Hidden=/d' "${desktop}" 2>/dev/null || true
            ;;
        *)
            if grep -q '^\[Desktop Entry\]' "${desktop}"; then
                sed -i '/^NoDisplay=/d; /^Hidden=/d' "${desktop}"
                sed -i '/^\[Desktop Entry\]/a NoDisplay=true' "${desktop}"
            fi
            ;;
    esac
done

# Explicit overrides for built-in media entries in case package metadata changes.
for media_desktop in mpv.desktop ristretto.desktop org.xfce.ristretto.desktop cheese.desktop; do
    target="${ROOTFS}/usr/share/applications/${media_desktop}"
    if [[ -f "${target}" ]]; then
        sed -i '/^NoDisplay=/d; /^Hidden=/d' "${target}"
        sed -i '/^\[Desktop Entry\]/a NoDisplay=true' "${target}"
    fi
done

# Core launcher branding and reliable display names.
for pair in \
    "thunar.desktop|ZAOD Files" \
    "xfce4-terminal.desktop|ZAOD Terminal" \
    "guvcview.desktop|ZAOD Camera" \
    "mousepad.desktop|ZAOD Notes" \
    "org.xfce.mousepad.desktop|ZAOD Notes" \
    "xfce-settings-manager.desktop|ZAOD Settings"
do
    desktop="${pair%%|*}"
    name="${pair#*|}"
    target="${ROOTFS}/usr/share/applications/${desktop}"
    if [[ -f "${target}" ]]; then
        sed -i "s/^Name=.*/Name=${name}/" "${target}"
    fi
done

printf '%s\n' "Cleaning apt caches and temporary files..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"* "${ROOTFS}/tmp/"*

cleanup_mounts
trap - EXIT

printf '\nPart 3 complete. Core applications configured in %s\n' "${ROOTFS}"
