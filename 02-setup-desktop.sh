#!/usr/bin/env bash
set -Eeuo pipefail

# Install a lean XFCE desktop and ZAOD OS defaults into the Part 1 rootfs.
# Fluent assets are fetched from their upstream GitHub repositories.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${ROOTFS:-${SCRIPT_DIR}/chroot}"
THEME_WORK=""

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local mountpoint

    if [[ -n "${THEME_WORK}" ]] && [[ -d "${THEME_WORK}" ]]; then
        rm -rf -- "${THEME_WORK}"
    fi

    for mountpoint in /sys /proc /dev; do
        if mountpoint -q "${ROOTFS}${mountpoint}"; then
            umount -R "${ROOTFS}${mountpoint}" || true
        fi
    done
}

[[ "${EUID}" -eq 0 ]] || die "Run as root, for example: sudo ./02-setup-desktop.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."
command -v curl >/dev/null || die "curl is required on the host to fetch the theme assets."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Part 1 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys"
trap cleanup EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"

printf '%s\n' "Installing the minimal XFCE desktop stack..."
printf 'lightdm shared/default-x-display-manager select lightdm\n' |
    chroot "${ROOTFS}" debconf-set-selections
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xorg \
    lightdm \
    lightdm-gtk-greeter \
    xfce4 \
    xfce4-panel \
    xfce4-whiskermenu-plugin \
    xfce4-pulseaudio-plugin \
    xfce4-power-manager \
    xfce4-battery-plugin \
    thunar \
    xfce4-terminal \
    network-manager \
    network-manager-gnome \
    pipewire-audio \
    pulseaudio-utils \
    wireplumber \
    brightnessctl \
    picom \
    bluez \
    blueman \
    sassc \
    sudo \
    dbus-x11

printf '%s\n' "Installing the ZAOD app grid and quick settings..."
install -m 0755 "${SCRIPT_DIR}/assets/zaod-launcher.py" "${ROOTFS}/usr/local/bin/zaod-launcher"
install -m 0755 "${SCRIPT_DIR}/assets/zaod-control-center.py" "${ROOTFS}/usr/local/bin/zaod-control-center"
mkdir -p "${ROOTFS}/usr/share/applications"
cat > "${ROOTFS}/usr/share/applications/zaod-launcher.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD Apps
Comment=Browse and launch installed applications
Exec=/usr/local/bin/zaod-launcher
Icon=view-app-grid
Terminal=false
NoDisplay=true
EOF
cat > "${ROOTFS}/usr/share/applications/zaod-control-center.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD Quick Settings
Comment=Network, Bluetooth, sound, brightness, and power
Exec=/usr/local/bin/zaod-control-center
Icon=preferences-system
Terminal=false
NoDisplay=true
EOF

THEME_WORK="$(mktemp -d "${ROOTFS}/tmp/zaod-desktop.XXXXXX")"
mkdir -p "${THEME_WORK}/gtk" "${THEME_WORK}/icons"
printf '%s\n' "Fetching Fluent GTK and icon themes..."
curl --fail --location --retry 3 \
    https://codeload.github.com/vinceliuice/Fluent-gtk-theme/tar.gz/7a49a464b0188c340101c52965c18190b1c694cf \
    -o "${THEME_WORK}/fluent-gtk.tar.gz"
curl --fail --location --retry 3 \
    https://codeload.github.com/vinceliuice/Fluent-icon-theme/tar.gz/c8a244f571ef8fb47812bdc9dbce76546cedce69 \
    -o "${THEME_WORK}/fluent-icons.tar.gz"
tar -xzf "${THEME_WORK}/fluent-gtk.tar.gz" --strip-components=1 -C "${THEME_WORK}/gtk"
tar -xzf "${THEME_WORK}/fluent-icons.tar.gz" --strip-components=1 -C "${THEME_WORK}/icons"
[[ -f "${THEME_WORK}/gtk/install.sh" ]] || die "Fluent GTK theme archive did not contain install.sh."
[[ -f "${THEME_WORK}/icons/install.sh" ]] || die "Fluent icon archive did not contain install.sh."

theme_work_in_root="${THEME_WORK#"${ROOTFS}"}"
chroot "${ROOTFS}" /bin/bash "${theme_work_in_root}/gtk/install.sh" \
    --dest /usr/share/themes --theme default --color dark --size standard --icon debian --tweaks solid
chroot "${ROOTFS}" /bin/bash "${theme_work_in_root}/icons/install.sh" \
    --dest /usr/share/icons standard

printf '%s\n' "Creating the ZAOD live user and system identity..."
if ! chroot "${ROOTFS}" id -u zaod >/dev/null 2>&1; then
    chroot "${ROOTFS}" useradd --create-home --shell /bin/bash --groups sudo zaod
else
    chroot "${ROOTFS}" usermod --append --groups sudo zaod
fi
printf 'zaod:zaod\n' | chroot "${ROOTFS}" chpasswd
printf 'zaod ALL=(ALL) NOPASSWD:ALL\n' > "${ROOTFS}/etc/sudoers.d/zaod"
chmod 0440 "${ROOTFS}/etc/sudoers.d/zaod"
chroot "${ROOTFS}" visudo --check --file=/etc/sudoers.d/zaod

printf '%s\n' 'zaod-os' > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/usr/lib/os-release" <<'EOF'
NAME="ZAOD OS"
PRETTY_NAME="ZAOD OS"
ID=zaod
ID_LIKE=debian
VERSION="1.0 (Bookworm)"
VERSION_ID="1.0"
VERSION_CODENAME=bookworm
DEBIAN_CODENAME=bookworm
EOF
ln -sfn ../usr/lib/os-release "${ROOTFS}/etc/os-release"

mkdir -p "${ROOTFS}/etc/lightdm/lightdm.conf.d"
cat > "${ROOTFS}/etc/lightdm/lightdm.conf.d/50-zaod-autologin.conf" <<'EOF'
[Seat:*]
autologin-user=zaod
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF
cat > "${ROOTFS}/etc/lightdm/lightdm-gtk-greeter.conf" <<'EOF'
[greeter]
background=/usr/share/backgrounds/zaod-landscape.jpg
theme-name=Fluent-Dark
icon-theme-name=Fluent
font-name=Sans 10
EOF

mkdir -p "${ROOTFS}/usr/share/backgrounds"
curl --fail --location --retry 3 \
  'https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=2560&q=85' \
  -o "${ROOTFS}/usr/share/backgrounds/zaod-landscape.jpg"
cat > "${ROOTFS}/usr/share/backgrounds/zaod-wallpaper.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs>
    <linearGradient id="base" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#07111f"/>
      <stop offset="0.52" stop-color="#0a1c35"/>
      <stop offset="1" stop-color="#07101d"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.72" cy="0.42" r="0.62">
      <stop offset="0" stop-color="#1688df" stop-opacity="0.56"/>
      <stop offset="0.48" stop-color="#115ca8" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#07111f" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="ribbon" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#5edaff" stop-opacity="0.05"/>
      <stop offset="0.48" stop-color="#258ef0" stop-opacity="0.42"/>
      <stop offset="1" stop-color="#9beaff" stop-opacity="0.08"/>
    </linearGradient>
    <filter id="soft" x="-20%" y="-30%" width="140%" height="160%">
      <feGaussianBlur stdDeviation="34"/>
    </filter>
  </defs>
  <rect width="3840" height="2160" fill="url(#base)"/>
  <rect width="3840" height="2160" fill="url(#glow)"/>
  <path d="M1560 2160 C1770 1700 1850 1450 2230 1190 C2600 935 3000 1000 3840 450 L3840 1140 C3150 1590 2830 1450 2480 1690 C2220 1870 2100 2040 2040 2160Z" fill="#0878c9" opacity="0.16" filter="url(#soft)"/>
  <path d="M1710 2160 C1910 1740 1980 1500 2340 1270 C2700 1040 3100 1090 3840 640 L3840 885 C3160 1280 2820 1230 2470 1450 C2210 1610 2110 1880 2040 2160Z" fill="url(#ribbon)"/>
  <path d="M1880 2160 C2070 1770 2150 1580 2460 1390 C2760 1210 3120 1220 3840 810" fill="none" stroke="#72dfff" stroke-opacity="0.24" stroke-width="5"/>
  <path d="M0 1660 C760 1390 1180 1450 1710 1700 C2090 1880 2400 1890 2760 1740" fill="none" stroke="#4cb7ed" stroke-opacity="0.10" stroke-width="3"/>
</svg>
EOF

readonly XDG_CHANNELS="${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "${XDG_CHANNELS}"
cat > "${XDG_CHANNELS}/xfce4-desktop.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/backgrounds/zaod-landscape.jpg"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
cat > "${XDG_CHANNELS}/xsettings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Fluent-Dark"/>
    <property name="IconThemeName" type="string" value="Fluent"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Sans 10"/>
    <property name="DecorationLayout" type="string" value="menu:minimize,maximize,close"/>
  </property>
</channel>
EOF
cat > "${XDG_CHANNELS}/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Fluent-Dark"/>
    <property name="button_layout" type="string" value="O|HMC"/>
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF
cat > "${XDG_CHANNELS}/xfce4-panel.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="length-adjust" type="bool" value="false"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="mode" type="uint" value="0"/>
      <property name="size" type="uint" value="46"/>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-color" type="array">
        <value type="uint" value="242"/>
        <value type="uint" value="246"/>
        <value type="uint" value="251"/>
        <value type="uint" value="226"/>
      </property>
      <property name="plugin-ids" type="array">
          <value type="int" value="1"/><value type="int" value="2"/>
          <value type="int" value="3"/><value type="int" value="4"/>
          <value type="int" value="5"/><value type="int" value="6"/>
          <value type="int" value="7"/><value type="int" value="8"/>
          <value type="int" value="9"/><value type="int" value="10"/>
          <value type="int" value="11"/><value type="int" value="12"/>
          <value type="int" value="13"/><value type="int" value="14"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="zaod-launcher.desktop"/></property>
    </property>
    <property name="plugin-2" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-3" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="thunar.desktop"/></property>
    </property>
    <property name="plugin-4" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="chromium.desktop"/></property>
    </property>
    <property name="plugin-5" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="zaod-store.desktop"/></property>
    </property>
    <property name="plugin-6" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="zaod-usb-tool.desktop"/></property>
    </property>
    <property name="plugin-7" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="xfce4-terminal.desktop"/></property>
    </property>
    <property name="plugin-8" type="string" value="tasklist">
      <property name="expand" type="bool" value="false"/>
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-labels" type="bool" value="false"/>
      <property name="grouping" type="uint" value="1"/>
    </property>
    <property name="plugin-9" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-10" type="string" value="launcher">
      <property name="items" type="array"><value type="string" value="zaod-control-center.desktop"/></property>
    </property>
    <property name="plugin-11" type="string" value="systray">
      <property name="size-max" type="uint" value="24"/>
    </property>
    <property name="plugin-12" type="string" value="pulseaudio"/>
    <property name="plugin-13" type="string" value="battery"/>
    <property name="plugin-14" type="string" value="clock">
      <property name="digital-format" type="string" value="%H:%M"/>
      <property name="tooltip-format" type="string" value="%A, %d %B %Y"/>
    </property>
  </property>
</channel>
EOF

mkdir -p "${ROOTFS}/etc/xdg/picom" "${ROOTFS}/etc/xdg/autostart"
cat > "${ROOTFS}/etc/xdg/picom/picom.conf" <<'EOF'
backend = "xrender";
vsync = true;
shadow = true;
shadow-radius = 8;
shadow-opacity = 0.28;
shadow-offset-x = -6;
shadow-offset-y = -6;
fading = true;
fade-in-step = 0.04;
fade-out-step = 0.04;
inactive-opacity = 1.0;
active-opacity = 1.0;
shadow-exclude = [ "class_g = 'Xfce4-panel'" ];
EOF
cat > "${ROOTFS}/etc/xdg/autostart/zaod-picom.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD Compositor
Comment=Window shadows and subtle transitions
Exec=picom --config /etc/xdg/picom/picom.conf
OnlyShowIn=XFCE;
Terminal=false
EOF

printf '%s\n' "Enabling the display manager and hardware services..."
systemctl --root="${ROOTFS}" enable lightdm.service NetworkManager.service bluetooth.service
systemctl --root="${ROOTFS}" set-default graphical.target

printf '%s\n' "Cleaning apt caches..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

cleanup
trap - EXIT

printf '\nPart 2 complete. Desktop defaults installed under:\n'
printf '  %s\n' \
    "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml" \
    "${ROOTFS}/etc/lightdm" \
    "${ROOTFS}/usr/share/themes/Fluent-Dark" \
    "${ROOTFS}/usr/share/icons/Fluent"