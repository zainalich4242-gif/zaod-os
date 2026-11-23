#!/usr/bin/env bash
set -Eeuo pipefail

# ZAOD OS Part 7: audit, desktop polish, and first-boot onboarding wizard.

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

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./07-audit-polish-onboarding.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Parts 1-6 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

# Users must be able to traverse the operating-system root to launch desktop apps.
chmod 0755 "${ROOTFS}"

# Codespaces ACLs may drop the execute bit for other users from public paths.
for public_tree in usr/local etc/xdg etc/lightdm etc/skel opt/zaod-apps opt/zaod-store opt/zaod-optional usr/share/applications usr/share/backgrounds; do
    if [[ -d "${ROOTFS}/${public_tree}" ]]; then
        find "${ROOTFS}/${public_tree}" -type d -exec chmod 0755 {} +
    fi
done

mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mount -t devpts devpts "${ROOTFS}/dev/pts" 2>/dev/null || true

printf '%s\n' "Installing audit and onboarding dependencies..."
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    desktop-file-utils \
    python3-gi \
    gir1.2-gtk-3.0 \
    policykit-1 \
    util-linux

printf '%s\n' "Auditing ownership and permissions..."
mkdir -p \
    "${ROOTFS}/opt/zaod-apps" \
    "${ROOTFS}/opt/zaod-store" \
    "${ROOTFS}/opt/zaod-optional" \
    "${ROOTFS}/var/lib/zaod"
chmod 0755 "${ROOTFS}/opt/zaod-apps" "${ROOTFS}/opt/zaod-store" "${ROOTFS}/opt/zaod-optional"
chmod 0775 "${ROOTFS}/opt/zaod-apps" "${ROOTFS}/var/lib/zaod"
if chroot "${ROOTFS}" getent passwd zaod >/dev/null 2>&1; then
    chroot "${ROOTFS}" chown -R zaod:zaod /var/lib/zaod /opt/zaod-apps
fi
chmod 0644 "${ROOTFS}/var/lib/zaod/installed.json" 2>/dev/null || true

# Keep newly provisioned users able to install packages; CLI tools remain root-safe.
if [[ -d "${ROOTFS}/etc/sudoers.d" ]]; then
    cat > "${ROOTFS}/etc/sudoers.d/zaod-package-manager" <<'EOF'
Cmnd_Alias ZAOD_PACKAGE_CMDS = /usr/local/bin/zos-install, /usr/local/bin/zos-remove
ALL ALL=(root) NOPASSWD: ZAOD_PACKAGE_CMDS
EOF
    chmod 0440 "${ROOTFS}/etc/sudoers.d/zaod-package-manager"
fi

printf '%s\n' "Fixing display, audio, network, and compositor defaults..."
systemctl --root="${ROOTFS}" enable lightdm.service NetworkManager.service bluetooth.service 2>/dev/null || true
systemctl --root="${ROOTFS}" enable pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
systemctl --root="${ROOTFS}" set-default graphical.target 2>/dev/null || true

mkdir -p "${ROOTFS}/etc/lightdm/lightdm.conf.d"
cat > "${ROOTFS}/etc/lightdm/lightdm.conf.d/50-zaod-autologin.conf" <<'EOF'
[Seat:*]
autologin-user=zaod
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF

mkdir -p "${ROOTFS}/usr/share/backgrounds"
if [[ ! -f "${ROOTFS}/usr/share/backgrounds/zaod-wallpaper.svg" ]]; then
    cat > "${ROOTFS}/usr/share/backgrounds/zaod-wallpaper.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="#07111f"/><stop offset=".55" stop-color="#0a1c35"/><stop offset="1" stop-color="#1688df"/></linearGradient></defs><rect width="1920" height="1080" fill="url(#g)"/><path d="M0 900 C500 650 900 950 1920 420V1080H0Z" fill="#72dfff" opacity=".10"/></svg>
EOF
fi
cat > "${ROOTFS}/etc/lightdm/lightdm-gtk-greeter.conf" <<'EOF'
[greeter]
background=/usr/share/backgrounds/zaod-wallpaper.svg
theme-name=Fluent-Dark
icon-theme-name=Fluent
font-name=Noto Sans 10
EOF

mkdir -p "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
cat > "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml.tmp" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Fluent-Dark"/>
    <property name="button_layout" type="string" value="O|HMC"/>
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF
mv "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml.tmp" \
   "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"

mkdir -p "${ROOTFS}/etc/xdg/picom" "${ROOTFS}/etc/xdg/autostart"
cat > "${ROOTFS}/etc/xdg/picom/picom.conf" <<'EOF'
backend = "xrender";
vsync = true;
shadow = false;
fading = true;
fade-in-step = 0.04;
fade-out-step = 0.04;
inactive-opacity = 1.0;
active-opacity = 1.0;
EOF
if [[ -f "${ROOTFS}/etc/xdg/autostart/zaod-picom.desktop" ]]; then
    sed -i '/^Exec=/c\Exec=picom --config /etc/xdg/picom/picom.conf' \
        "${ROOTFS}/etc/xdg/autostart/zaod-picom.desktop"
fi

printf '%s\n' "Installing Windows 11-style GTK defaults..."
mkdir -p "${ROOTFS}/etc/skel/.config/gtk-3.0" "${ROOTFS}/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "${ROOTFS}/etc/skel/.config/gtk-3.0/gtk.css" <<'EOF'
window, .solid-csd, .titlebar, headerbar { border-radius: 8px 8px 0 0; }
window { background: rgba(8,17,30,0.96); }
headerbar, .titlebar { min-height: 38px; background: rgba(16,36,58,0.92); box-shadow: 0 1px 0 rgba(114,223,255,0.08); }
button { border-radius: 6px; border: 1px solid rgba(255,255,255,0.10); background: rgba(255,255,255,0.07); padding: 5px 10px; }
entry, textview, notebook, combobox { border-radius: 6px; }
menu, .menu, .context-menu { border-radius: 8px; border: 1px solid rgba(255,255,255,0.10); background: rgba(16,36,58,0.96); }
tooltip { border-radius: 6px; background: rgba(16,36,58,0.98); }
scrollbar slider { border-radius: 8px; }
EOF

# Copy complete XFCE system defaults into skel for newly provisioned users.
for channel in xfce4-panel xfce4-desktop xsettings xfwm4; do
    if [[ -f "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/${channel}.xml" ]]; then
        cp "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/${channel}.xml" \
           "${ROOTFS}/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/${channel}.xml"
    fi
done
mkdir -p "${ROOTFS}/etc/skel/.config/Thunar" "${ROOTFS}/etc/skel/.config/picom"
cp "${ROOTFS}/etc/xdg/picom/picom.conf" "${ROOTFS}/etc/skel/.config/picom/picom.conf"
if [[ -f "${ROOTFS}/etc/xdg/Thunar/uca.xml" ]]; then
    cp "${ROOTFS}/etc/xdg/Thunar/uca.xml" "${ROOTFS}/etc/skel/.config/Thunar/uca.xml"
fi
mkdir -p "${ROOTFS}/etc/skel/.config/autostart"
cp "${ROOTFS}/etc/xdg/autostart/zaod-picom.desktop" "${ROOTFS}/etc/skel/.config/autostart/zaod-picom.desktop" 2>/dev/null || true

mkdir -p "${ROOTFS}/home/zaod/.config/gtk-3.0"
if [[ -d "${ROOTFS}/etc/skel/.config" ]]; then
    cp -a "${ROOTFS}/etc/skel/.config/." "${ROOTFS}/home/zaod/.config/" 2>/dev/null || true
fi
if chroot "${ROOTFS}" getent passwd zaod >/dev/null 2>&1; then
    chroot "${ROOTFS}" chown -R zaod:zaod /home/zaod
fi

printf '%s\n' "Installing ZAOD onboarding wizard..."
mkdir -p "${ROOTFS}/usr/local/bin" "${ROOTFS}/usr/local/libexec" "${ROOTFS}/etc/xdg/autostart" "${ROOTFS}/usr/share/polkit-1/actions"
install -m 0755 "${SCRIPT_DIR}/assets/zaod-provision-user.py" "${ROOTFS}/usr/local/libexec/zaod-provision-user"
cat > "${ROOTFS}/usr/local/bin/zaod-onboarding" <<'PYEOF'
#!/usr/bin/python3
import gi
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

gi.require_version('Gtk', '3.0')
from gi.repository import GLib, Gtk

COMPLETE = '/var/lib/zaod/.onboarding_complete'
USERNAME_RE = re.compile(r'^[a-z][a-z0-9-]{0,31}$')


def gdk_color(value):
    color = __import__('gi').repository.Gdk.RGBA()
    color.parse(value)
    return color


def suggest_username(full_name):
    name = re.sub(r'[^a-zA-Z0-9]+', ' ', full_name).strip().lower()
    words = name.split()
    if not words:
        return ''
    if len(words) == 1:
        return re.sub(r'[^a-z0-9-]', '', words[0])[:32]
    return re.sub(r'[^a-z0-9-]', '', (words[0] + '-' + words[-1]))[:32]


class Onboarding(Gtk.Window):
    def __init__(self):
        super().__init__(title='Welcome to ZAOD OS')
        self.set_decorated(False)
        self.set_default_size(820, 560)
        request_path = None
        self.fullscreen()

            request_fd, request_path = tempfile.mkstemp(prefix='zaod-account-', dir='/tmp')
            os.fchmod(request_fd, 0o600)
            with os.fdopen(request_fd, 'w', encoding='utf-8') as request_file:
                json.dump({'username': username, 'full_name': full_name, 'password': password}, request_file)
            result = subprocess.run(
                ['pkexec', '/usr/local/libexec/zaod-provision-user', request_path],
                capture_output=True, text=True
            )
        progressbar progress { background: #1688df; min-height: 8px; }
        """)
    def card(self):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        card.set_valign(Gtk.Align.CENTER)
        card.set_halign(Gtk.Align.CENTER)
        card.set_size_request(620, 390)
        card.get_style_context().add_class('card')
        finally:
            password = ''
            self.password.set_text('')
            self.confirm.set_text('')
            if request_path and os.path.exists(request_path):
                os.unlink(request_path)
        return card

    def build_welcome(self):
        card = self.card()
        brand = Gtk.Label(label='Z')
        brand.set_size_request(64, 64)
        brand.modify_bg(Gtk.StateType.NORMAL, gdk_color('#1688df'))
        brand.modify_fg(Gtk.StateType.NORMAL, gdk_color('#ffffff'))
        brand.get_style_context().add_class('title')
        card.pack_start(brand, False, False, 8)
        title = Gtk.Label(label='Welcome to ZAOD OS')
        title.get_style_context().add_class('title')
        card.pack_start(title, False, False, 8)
        subtitle = Gtk.Label(label='A fast, modern desktop built around you.')
        subtitle.get_style_context().add_class('subtitle')
        card.pack_start(subtitle, False, False, 8)
        card.pack_end(self.action_row([('Get Started', self.primary, self.go_account)]), False, False, 8)
        self.stack.add_named(card, 'welcome')

    def build_account(self):
        card = self.card()
        card.set_size_request(620, 440)
        title = Gtk.Label(label='Create your account')
        title.get_style_context().add_class('title')
        title.set_xalign(0)
        card.pack_start(title, False, False, 4)

        grid = Gtk.Grid(column_spacing=12, row_spacing=10)
        grid.attach(Gtk.Label(label='Full name', xalign=0), 0, 0, 1, 1)
        self.full_name = Gtk.Entry()
        self.full_name.set_placeholder_text('Zaid Khan')
        grid.attach(self.full_name, 1, 0, 1, 1)

        grid.attach(Gtk.Label(label='Username', xalign=0), 0, 1, 1, 1)
        self.username = Gtk.Entry()
        self.username.set_placeholder_text('zaid-khan')
        grid.attach(self.username, 1, 1, 1, 1)

        grid.attach(Gtk.Label(label='Password', xalign=0), 0, 2, 1, 1)
        self.password = Gtk.Entry()
        self.password.set_visibility(False)
        grid.attach(self.password, 1, 2, 1, 1)

        grid.attach(Gtk.Label(label='Confirm password', xalign=0), 0, 3, 1, 1)
        self.confirm = Gtk.Entry()
        self.confirm.set_visibility(False)
        grid.attach(self.confirm, 1, 3, 1, 1)

        grid.set_column_homogeneous(False)
        self.full_name.set_hexpand(True)
        self.username.set_hexpand(True)
        self.password.set_hexpand(True)
        self.confirm.set_hexpand(True)
        card.pack_start(grid, False, False, 8)

        self.show_password = Gtk.CheckButton(label='Show password')
        self.show_password.connect('toggled', self.toggle_password)
        card.pack_start(self.show_password, False, False, 0)
        self.validation = Gtk.Label(label='')
        self.validation.set_xalign(0)
        self.validation.modify_fg(Gtk.StateType.NORMAL, gdk_color('#72dfff'))
        card.pack_start(self.validation, False, False, 0)

        self.full_name.connect('changed', self.update_suggestion)
        self.username.connect('changed', self.validate_account)
        self.password.connect('changed', self.validate_account)
        self.confirm.connect('changed', self.validate_account)

        card.pack_end(self.action_row([('Back', self.secondary, self.go_welcome),
                                       ('Continue', self.primary, self.go_finalizing)]), False, False, 8)
        self.stack.add_named(card, 'account')

    def build_finalizing(self):
        card = self.card()
        title = Gtk.Label(label='Finalizing setup')
        title.get_style_context().add_class('title')
        card.pack_start(title, False, False, 12)
        self.final_status = Gtk.Label(label='Preparing your ZAOD account...')
        self.final_status.get_style_context().add_class('subtitle')
        card.pack_start(self.final_status, False, False, 8)
        self.final_progress = Gtk.ProgressBar()
        card.pack_start(self.final_progress, False, False, 8)
        self.stack.add_named(card, 'finalizing')

    def build_ready(self):
        card = self.card()
        title = Gtk.Label(label='All Set!')
        title.get_style_context().add_class('title')
        card.pack_start(title, False, False, 12)
        subtitle = Gtk.Label(label='Your ZAOD OS account is ready.')
        subtitle.get_style_context().add_class('subtitle')
        card.pack_start(subtitle, False, False, 8)
        developer = Gtk.Button(label='I am a developer: install ZAOD Studio')
        developer.get_style_context().add_class('secondary')
        developer.connect('clicked', self.install_studio)
        card.pack_start(developer, False, False, 8)
        card.pack_end(self.action_row([('Launch Desktop', self.primary, self.launch_desktop)]), False, False, 8)
        self.stack.add_named(card, 'ready')

    @staticmethod
    def primary(button):
        button.get_style_context().add_class('primary')

    @staticmethod
    def secondary(button):
        button.get_style_context().add_class('secondary')

    def action_row(self, actions):
        row = Gtk.Box(spacing=10)
        row.set_halign(Gtk.Align.END)
        for label, style, callback in actions:
            button = Gtk.Button(label=label)
            style(button)
            button.connect('clicked', callback)
            row.pack_start(button, False, False, 0)
        return row

    def go_welcome(self, button):
        self.stack.set_visible_child_name('welcome')

    def go_account(self, button):
        self.stack.set_visible_child_name('account')

    def update_suggestion(self, entry):
        if not self.username.get_text() or getattr(self, '_username_auto', False):
            self._username_auto = True
            self.username.set_text(suggest_username(entry.get_text()))
            self._username_auto = False
        self.validate_account(entry)

    def toggle_password(self, check):
        visible = check.get_active()
        self.password.set_visibility(visible)
        self.confirm.set_visibility(visible)

    def validate_account(self, widget=None):
        full_name = self.full_name.get_text().strip()
        username = self.username.get_text().strip()
        password = self.password.get_text()
        confirm = self.confirm.get_text()
        if len(full_name) < 2:
            self.validation.set_text('Enter your full name.')
            return False
        if not USERNAME_RE.match(username):
            self.validation.set_text('Username must start with a letter and use lowercase letters, digits, or hyphen.')
            return False
        if subprocess.run(['getent', 'passwd', username], capture_output=True).returncode == 0:
            self.validation.set_text('That username already exists.')
            return False
        if len(password) < 8:
            self.validation.set_text('Password must contain at least 8 characters.')
            return False
        if password != confirm:
            self.validation.set_text('Passwords do not match.')
            return False
        self.validation.set_text('Account details look good.')
        return True

    def go_finalizing(self, button):
        if not self.validate_account():
            return
        self.stack.set_visible_child_name('finalizing')
        GLib.timeout_add(80, self.update_progress)
        threading = __import__('threading')
        threading.Thread(target=self.provision_user, daemon=True).start()

    def update_progress(self):
        fraction = self.final_progress.get_fraction()
        if fraction < 0.9:
            self.final_progress.set_fraction(fraction + 0.08)
        return True

    def provision_user(self):
        username = self.username.get_text().strip()
        full_name = self.full_name.get_text().strip()
        password = self.password.get_text()
        try:
            GLib.idle_add(self.final_status.set_text, 'Creating your Linux account...')
            script = (
                f"useradd -m -s /bin/bash -c '{full_name.replace(chr(39), chr(92)+chr(39))}' "
                f"-G sudo,audio,video,plugdev,netdev {username} && "
                f"printf '%s:%s\\n' '{username}' '{password}' | chpasswd && "
                f"cp -a /etc/skel/. /home/{username}/ && "
                f"chown -R {username}:{username} /home/{username} && "
                f"mkdir -p /var/lib/zaod /home/{username}/.config/autostart && "
                f"touch /var/lib/zaod/.onboarding_complete"
            )
            result = subprocess.run(['pkexec', '/bin/bash', '-c', script], capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError(result.stderr or 'Account creation failed')

            lightdm = '/etc/lightdm/lightdm.conf.d/50-zaod-autologin.conf'
            script2 = (
                f"mkdir -p /etc/lightdm/lightdm.conf.d && "
                f"printf '[Seat:*]\nuser-session=xfce\ngreeter-session=lightdm-gtk-greeter\n' > {lightdm} && "
                f"touch /var/lib/zaod/.onboarding_complete"
            )
            result = subprocess.run(['pkexec', '/bin/bash', '-c', script2], capture_output=True, text=True)
            if result.returncode != 0:
                raise RuntimeError(result.stderr or 'LightDM configuration failed')

            GLib.idle_add(self.final_progress.set_fraction, 1.0)
            GLib.idle_add(self.final_status.set_text, 'Setup complete.')
            GLib.idle_add(self.stack.set_visible_child_name, 'ready')
        except Exception as exc:
            GLib.idle_add(self.show_error, str(exc))

    def show_error(self, message):
        dialog = Gtk.MessageDialog(parent=self, flags=Gtk.DialogFlags.MODAL,
                                   type=Gtk.MessageType.ERROR,
                                   buttons=Gtk.ButtonsType.OK,
                                   text='Could not complete setup')
        dialog.format_secondary_text(str(message))
        dialog.run()
        dialog.destroy()

    def launch_desktop(self, button):
        Gtk.main_quit()
        subprocess.Popen(['/usr/bin/xfce4-session-logout', '--logout', '--fast'])

    def install_studio(self, button):
        dialog = Gtk.MessageDialog(parent=self, flags=Gtk.DialogFlags.MODAL,
                                   type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.YES_NO,
                                   text='Install ZAOD Studio?')
        dialog.format_secondary_text('Studio is an optional developer tool. It adds a package builder to your Apps grid.')
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.YES:
            subprocess.Popen(['pkexec', '/usr/local/bin/zos-install',
                              '/opt/zaod-optional/zaod-studio.zos'])


if __name__ == '__main__':
    if '--dry-run' in sys.argv:
        print('ZAOD onboarding dry-run: validation and provisioning backend are ready')
        sys.exit(0)
    if Path(COMPLETE).exists():
        sys.exit(0)
    window = Onboarding()
    window.connect('destroy', Gtk.main_quit)
    window.show_all()
    Gtk.main()
PYEOF
install -m 0755 "${SCRIPT_DIR}/assets/zaod-onboarding.py" "${ROOTFS}/usr/local/bin/zaod-onboarding"
chmod 0755 "${ROOTFS}/usr/local/bin/zaod-onboarding"

cat > "${ROOTFS}/etc/xdg/autostart/zaod-onboarding.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD First-Boot Setup
Comment=Create the initial ZAOD OS account
Exec=/usr/local/bin/zaod-onboarding
OnlyShowIn=XFCE;
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

cat > "${ROOTFS}/usr/share/polkit-1/actions/com.zaod.onboarding.policy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>ZAOD OS</vendor>
  <vendor_url>https://github.com/zaod-os/zaod-os</vendor_url>
  <action id="com.zaod.onboarding.provision">
    <description>Create the ZAOD OS user account</description>
    <message>Authentication is required to create the first user account.</message>
        <annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/zaod-provision-user</annotate>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
  </action>
</policyconfig>
EOF

printf '%s\n' "Validating desktop launchers..."
chroot "${ROOTFS}" /bin/bash -lc '
    bad=0
    mkdir -p /tmp/zaod-desktop-validation
    for desktop in /usr/share/applications/*.desktop; do
        [ -f "$desktop" ] || continue
        desktop-file-validate "$desktop" >/tmp/zaod-desktop-validation/check.out 2>&1 || {
            cat /tmp/zaod-desktop-validation/check.out >&2
            bad=1
        }
    done
    exit "$bad"
'

printf '%s\n' "Running onboarding syntax and dry-run verification..."
chroot "${ROOTFS}" python3 -m py_compile /usr/local/bin/zaod-onboarding
chroot "${ROOTFS}" /usr/local/bin/zaod-onboarding --dry-run

chroot "${ROOTFS}" update-desktop-database /usr/share/applications
chroot "${ROOTFS}" update-mime-database /usr/share/mime

printf '%s\n' "Cleaning apt caches and temporary files..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"* "${ROOTFS}/tmp/"*

cleanup_mounts
trap - EXIT

printf '\nPart 7 complete. ZAOD onboarding installed and desktop environment audited.\n'
