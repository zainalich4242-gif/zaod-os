#!/usr/bin/env bash
set -Eeuo pipefail

# ZAOD OS Part 6: native USB ISO writer and deep USB repair utility.

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

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./06-setup-usb-tool.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Parts 1-5 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mount -t devpts devpts "${ROOTFS}/dev/pts" 2>/dev/null || true

printf '%s\n' "Installing ZAOD USB Tool dependencies..."
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3-gi \
    gir1.2-gtk-3.0 \
    parted \
    dosfstools \
    ntfs-3g \
    exfatprogs \
    util-linux \
    coreutils \
    policykit-1

mkdir -p "${ROOTFS}/usr/local/bin" "${ROOTFS}/usr/share/applications" "${ROOTFS}/usr/share/polkit-1/actions"

cat > "${ROOTFS}/usr/local/bin/zaod-usb-tool" <<'PYEOF'
#!/usr/bin/python3
import gi
import json
import os
import re
import shutil
import subprocess
import sys
import threading

gi.require_version('Gtk', '3.0')
from gi.repository import GLib, Gtk


class UsbSafetyError(Exception):
    pass


def run(args, capture=True):
    result = subprocess.run(args, capture_output=capture, text=True)
    if result.returncode != 0:
        raise UsbSafetyError((result.stderr or result.stdout or 'Command failed').strip())
    return result


def detect_usb_drives():
    result = run(['lsblk', '-J', '-d', '-b', '-o', 'NAME,MODEL,SIZE,RM,TRAN'])
    data = json.loads(result.stdout)
    drives = []
    for item in data.get('blockdevices', []):
        name = item.get('name', '')
        removable = item.get('rm') is True or item.get('rm') == 1 or str(item.get('rm')).lower() == 'true'
        transport = str(item.get('tran') or '').lower()
        if not re.fullmatch(r'sd[a-z]+', name):
            continue
        if removable and transport == 'usb':
            model = (item.get('model') or 'Unknown USB Drive').strip()
            size = int(item.get('size') or 0)
            drives.append({'name': name, 'path': '/dev/' + name, 'model': model,
                           'size': size, 'label': f'{model} - {human_size(size)} ({"/dev/" + name})'})
    return sorted(drives, key=lambda drive: drive['path'])


def human_size(size):
    value = float(size)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if value < 1000 or unit == 'TB':
            return f'{value:.1f} {unit}' if unit != 'B' else f'{int(value)} {unit}'
        value /= 1000


def validate_usb_drive(path):
    if not re.fullmatch(r'/dev/sd[a-z]+', path):
        raise UsbSafetyError('Safety lock: only /dev/sdX USB devices are accepted.')
    for drive in detect_usb_drives():
        if drive['path'] == path:
            return drive
    raise UsbSafetyError('Safety lock: the selected device is not a removable USB drive.')


def mounted_children(path):
    result = run(['lsblk', '-ln', '-o', 'NAME,MOUNTPOINT', path])
    children = []
    for line in result.stdout.strip().splitlines():
        parts = line.split()
        if not parts:
            continue
        children.append('/dev/' + parts[0])
    return children


def confirmation(parent, title, drive, extra=''):
    dialog = Gtk.MessageDialog(
        parent=parent, flags=Gtk.DialogFlags.MODAL,
        type=Gtk.MessageType.WARNING,
        buttons=Gtk.ButtonsType.OK_CANCEL,
        text=title,
    )
    dialog.format_secondary_text(
        f'Model: {drive["model"]}\nSize: {human_size(drive["size"])}\nDevice: {drive["path"]}\n\n'
        f'{extra}\n\nThis is destructive and cannot be undone.'
    )
    response = dialog.run()
    dialog.destroy()
    return response == Gtk.ResponseType.OK


class ZaodUsbTool(Gtk.Window):
    def __init__(self):
        super().__init__(title='ZAOD USB Tool')
        self.set_default_size(760, 540)
        self.set_border_width(0)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.modify_bg(Gtk.StateType.NORMAL, self.gdk_color('#08111e'))
        header = Gtk.Label(label='ZAOD USB Tool')
        header.set_xalign(0)
        header.modify_fg(Gtk.StateType.NORMAL, self.gdk_color('#edf4fb'))
        header.get_style_context().add_class('header')
        header.set_margin_top(18)
        header.set_margin_bottom(12)
        header.set_margin_left(20)
        header.set_margin_right(20)

        notebook = Gtk.Notebook()
        notebook.set_margin_left(20)
        notebook.set_margin_right(20)
        notebook.set_margin_bottom(20)

        notebook.append_page(self.writer_page(), Gtk.Label(label='Bootable USB Writer'))
        notebook.append_page(self.formatter_page(), Gtk.Label(label='Deep Repair & Format'))
        root.pack_start(header, False, False, 0)
        root.pack_start(notebook, True, True, 0)
        self.add(root)

        css = Gtk.CssProvider()
        css.load_from_data(b"""
        window, notebook, box, grid { background: #08111e; color: #edf4fb; }
        .header { font-size: 20px; font-weight: bold; }
        button, combobox, entry { border-radius: 6px; }
        button { background: #1688df; color: #ffffff; border: 1px solid #319bf0; padding: 8px 12px; }
        entry, combobox { background: #10243a; color: #edf4fb; border: 1px solid #294864; padding: 6px; }
        progressbar trough { background: #10243a; border: 1px solid #294864; min-height: 14px; }
        progressbar progress { background: #1688df; min-height: 14px; }
        notebook tab { background: #10243a; color: #b7c7d7; padding: 8px 14px; }
        notebook tab:checked { background: #1688df; color: #ffffff; }
        """)
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    @staticmethod
    def gdk_color(value):
        color = __import__('gi').repository.Gdk.RGBA()
        color.parse(value)
        return color

    def writer_page(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.set_border_width(16)

        iso_row = Gtk.Box(spacing=8)
        iso_row.pack_start(Gtk.Label(label='ISO image', xalign=0), False, False, 0)
        self.iso_button = Gtk.FileChooserButton(title='Select an ISO image')
        iso_filter = Gtk.FileFilter()
        iso_filter.set_name('Disc images (*.iso)')
        iso_filter.add_mime_type('application/x-iso9660-image')
        iso_filter.add_pattern('*.iso')
        self.iso_button.add_filter(iso_filter)
        iso_row.pack_end(self.iso_button, True, True, 0)

        drive_row = Gtk.Box(spacing=8)
        drive_row.pack_start(Gtk.Label(label='Target USB', xalign=0), False, False, 0)
        self.writer_drive = Gtk.ComboBoxText()
        drive_row.pack_start(self.writer_drive, True, True, 0)
        refresh = Gtk.Button(label='Refresh Drives')
        refresh.connect('clicked', lambda button: self.refresh_writer_drives())
        drive_row.pack_start(refresh, False, False, 0)

        self.writer_progress = Gtk.ProgressBar()
        self.writer_status = Gtk.Label(label='Select an ISO and USB drive.')
        self.writer_status.set_xalign(0)
        self.writer_button = Gtk.Button(label='Write Bootable USB')
        self.writer_button.connect('clicked', self.start_writer)

        page.pack_start(iso_row, False, False, 0)
        page.pack_start(drive_row, False, False, 0)
        page.pack_start(self.writer_status, False, False, 0)
        page.pack_start(self.writer_progress, False, False, 0)
        page.pack_start(self.writer_button, False, False, 0)
        self.refresh_writer_drives()
        return page

    def formatter_page(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.set_border_width(16)

        grid = Gtk.Grid(column_spacing=10, row_spacing=10)
        grid.attach(Gtk.Label(label='Target USB', xalign=0), 0, 0, 1, 1)
        self.format_drive = Gtk.ComboBoxText()
        grid.attach(self.format_drive, 1, 0, 1, 1)
        refresh = Gtk.Button(label='Refresh Drives')
        refresh.connect('clicked', lambda button: self.refresh_format_drives())
        grid.attach(refresh, 2, 0, 1, 1)

        grid.attach(Gtk.Label(label='Volume label', xalign=0), 0, 1, 1, 1)
        self.volume_label = Gtk.Entry()
        self.volume_label.set_text('ZAOD_USB')
        grid.attach(self.volume_label, 1, 1, 2, 1)

        grid.attach(Gtk.Label(label='Partition scheme', xalign=0), 0, 2, 1, 1)
        self.scheme = Gtk.ComboBoxText()
        self.scheme.append_text('MBR / msdos')
        self.scheme.append_text('GPT')
        self.scheme.set_active(0)
        grid.attach(self.scheme, 1, 2, 2, 1)

        grid.attach(Gtk.Label(label='Filesystem', xalign=0), 0, 3, 1, 1)
        self.filesystem = Gtk.ComboBoxText()
        self.filesystem.append_text('FAT32')
        self.filesystem.append_text('exFAT')
        self.filesystem.append_text('NTFS')
        self.filesystem.set_active(0)
        grid.attach(self.filesystem, 1, 3, 2, 1)

        self.format_status = Gtk.Label(label='Select a removable USB drive.')
        self.format_status.set_xalign(0)
        self.format_progress = Gtk.ProgressBar()
        self.format_button = Gtk.Button(label='Deep Repair & Format')
        self.format_button.connect('clicked', self.start_formatter)

        page.pack_start(grid, False, False, 0)
        page.pack_start(self.format_status, False, False, 0)
        page.pack_start(self.format_progress, False, False, 0)
        page.pack_start(self.format_button, False, False, 0)
        self.refresh_format_drives()
        return page

    def refresh_writer_drives(self):
        self.writer_drive.remove_all()
        try:
            for drive in detect_usb_drives():
                self.writer_drive.append(drive['path'], drive['label'])
        except Exception as exc:
            self.writer_status.set_text(str(exc))

    def refresh_format_drives(self):
        self.format_drive.remove_all()
        try:
            for drive in detect_usb_drives():
                self.format_drive.append(drive['path'], drive['label'])
        except Exception as exc:
            self.format_status.set_text(str(exc))

    def selected_drive(self, combo):
        path = combo.get_active_id()
        if not path:
            raise UsbSafetyError('Select a USB drive first.')
        return validate_usb_drive(path)

    def start_writer(self, button):
        try:
            iso = self.iso_button.get_filename()
            if not iso or not os.path.isfile(iso):
                raise UsbSafetyError('Select a valid ISO file first.')
            if not iso.lower().endswith('.iso'):
                raise UsbSafetyError('Selected file is not an ISO image.')
            drive = self.selected_drive(self.writer_drive)
            if not confirmation(self, 'Write this ISO to the USB drive?', drive,
                                f'ISO: {iso}\nAll data on the drive will be destroyed.'):
                return
        except Exception as exc:
            self.error(str(exc))
            return

        button.set_sensitive(False)
        self.writer_progress.set_fraction(0)
        threading.Thread(target=self.write_iso_thread, args=(iso, drive), daemon=True).start()

    def write_iso_thread(self, iso, drive):
        try:
            iso_size = os.path.getsize(iso)
            command = ['dd', f'if={iso}', f'of={drive["path"]}', 'bs=4M', 'status=progress', 'oflag=sync']
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                       text=True, bufsize=1)
            written = 0
            for line in process.stderr:
                match = re.search(r'(\d+) bytes.*copied.*([\d.]+ (?:MB|GB|kB)/s)', line)
                if match:
                    written = int(match.group(1))
                    speed = match.group(2)
                    fraction = min(written / iso_size, 1.0)
                    GLib.idle_add(self.writer_progress.set_fraction, fraction)
                    GLib.idle_add(self.writer_status.set_text,
                                  f'{human_size(written)} / {human_size(iso_size)} - {speed}')
                else:
                    values = re.findall(r'(\d+) bytes', line)
                    if values:
                        written = int(values[-1])
                        GLib.idle_add(self.writer_progress.set_fraction,
                                      min(written / iso_size, 1.0))
                        GLib.idle_add(self.writer_status.set_text,
                                      f'{human_size(written)} / {human_size(iso_size)}')
            code = process.wait()
            if code != 0:
                raise UsbSafetyError(f'dd exited with status {code}')
            GLib.idle_add(self.writer_progress.set_fraction, 1.0)
            GLib.idle_add(self.complete, 'Bootable USB created.', 'The ISO was written successfully.')
        except Exception as exc:
            GLib.idle_add(self.error, str(exc))
        finally:
            GLib.idle_add(self.writer_button.set_sensitive, True)

    def start_formatter(self, button):
        try:
            drive = self.selected_drive(self.format_drive)
            label = re.sub(r'[^A-Za-z0-9_.-]', '_', self.volume_label.get_text().strip())[:32]
            if not label:
                raise UsbSafetyError('Enter a valid volume label.')
            scheme_text = self.scheme.get_active_text()
            filesystem = self.filesystem.get_active_text()
            if not confirmation(self, 'Deep repair and format this USB drive?', drive,
                                f'New label: {label}\nPartition scheme: {scheme_text}\nFilesystem: {filesystem}'):
                return
        except Exception as exc:
            self.error(str(exc))
            return

        button.set_sensitive(False)
        self.format_progress.set_fraction(0)
        threading.Thread(target=self.format_thread,
                         args=(drive, label, scheme_text, filesystem), daemon=True).start()

    def format_thread(self, drive, label, scheme_text, filesystem):
        partition = drive['path'] + '1'
        try:
            validate_usb_drive(drive['path'])

            GLib.idle_add(self.format_status.set_text, 'Stage 1/4 - Force unmounting partitions')
            GLib.idle_add(self.format_progress.set_fraction, 0.10)
            for child in mounted_children(drive['path']):
                subprocess.run(['umount', '-f', child], capture_output=True)

            GLib.idle_add(self.format_status.set_text, 'Stage 2/4 - Wiping signatures')
            GLib.idle_add(self.format_progress.set_fraction, 0.30)
            run(['wipefs', '--all', '--force', drive['path']])

            GLib.idle_add(self.format_status.set_text, 'Stage 3/4 - Zeroing drive boundaries')
            GLib.idle_add(self.format_progress.set_fraction, 0.45)
            run(['dd', 'if=/dev/zero', f'of={drive["path"]}', 'bs=1M', 'count=10', 'oflag=direct', 'status=none'])
            size = drive['size']
            last_offset = max(size - (10 * 1024 * 1024), 0)
            run(['dd', 'if=/dev/zero', f'of={drive["path"]}', 'bs=1M', f'seek={last_offset // (1024 * 1024)}',
                 'count=10', 'oflag=direct', 'status=none'])

            GLib.idle_add(self.format_status.set_text, 'Stage 4/4 - Creating partition and filesystem')
            GLib.idle_add(self.format_progress.set_fraction, 0.70)
            scheme = 'gpt' if scheme_text == 'GPT' else 'msdos'
            run(['wipefs', '--all', '--force', drive['path']], capture=True)
            run(['parted', '-s', drive['path'], 'mklabel', scheme])
            run(['parted', '-s', drive['path'], 'mkpart', 'primary', '1MiB', '100%'])
            run(['partprobe', drive['path']])

            if filesystem == 'FAT32':
                run(['mkfs.vfat', '-F', '32', '-n', label, partition])
            elif filesystem == 'exFAT':
                run(['mkfs.exfat', '-n', label, partition])
            else:
                run(['mkfs.ntfs', '-f', '-L', label, partition])

            GLib.idle_add(self.format_progress.set_fraction, 1.0)
            GLib.idle_add(self.format_status.set_text, 'Repair complete')
            GLib.idle_add(self.complete, 'USB repair complete.',
                          f'{filesystem} volume "{label}" was created on {drive["path"]}.')
        except Exception as exc:
            GLib.idle_add(self.error, str(exc))
        finally:
            GLib.idle_add(self.format_button.set_sensitive, True)

    def complete(self, heading, text):
        dialog = Gtk.MessageDialog(parent=self, flags=Gtk.DialogFlags.MODAL,
                                   type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK, text=heading)
        dialog.format_secondary_text(text)
        dialog.run()
        dialog.destroy()

    def error(self, text):
        dialog = Gtk.MessageDialog(parent=self, flags=Gtk.DialogFlags.MODAL,
                                   type=Gtk.MessageType.ERROR,
                                   buttons=Gtk.ButtonsType.OK, text='ZAOD USB Tool Error')
        dialog.format_secondary_text(str(text))
        dialog.run()
        dialog.destroy()


def main():
    if '--help' in sys.argv:
        print('ZAOD USB Tool')
        print('Use --detect-usb to perform a non-destructive USB-only device test.')
        return
    if '--detect-usb' in sys.argv:
        drives = detect_usb_drives()
        for drive in drives:
            print(f'{drive["path"]}\t{drive["model"]}\t{human_size(drive["size"])}')
        return
    window = ZaodUsbTool()
    window.connect('destroy', Gtk.main_quit)
    window.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
PYEOF
chmod 0755 "${ROOTFS}/usr/local/bin/zaod-usb-tool"

cat > "${ROOTFS}/usr/share/polkit-1/actions/com.zaod.usbtool.policy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>ZAOD OS</vendor>
  <vendor_url>https://github.com/zaod-os/zaod-os</vendor_url>
  <action id="com.zaod.usbtool.write">
    <description>Write or repair a removable USB drive</description>
    <message>Authentication is required to write or format a removable USB drive.</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
  </action>
</policyconfig>
EOF

cat > "${ROOTFS}/usr/share/applications/zaod-usb-tool.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD USB Tool
Comment=Write bootable images and repair USB drives
Exec=pkexec /usr/local/bin/zaod-usb-tool
Icon=media-removable
Terminal=false
Categories=System;Utility;
StartupNotify=true
EOF

printf '%s\n' "Running non-destructive tool verification..."
chroot "${ROOTFS}" python3 -m py_compile /usr/local/bin/zaod-usb-tool
chroot "${ROOTFS}" /usr/local/bin/zaod-usb-tool --help
printf '%s\n' "Detected removable USB devices (no destructive action):"
chroot "${ROOTFS}" /usr/local/bin/zaod-usb-tool --detect-usb

printf '%s\n' "Cleaning apt caches and temporary files..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"* "${ROOTFS}/tmp/"*

cleanup_mounts
trap - EXIT

printf '\nPart 6 complete. ZAOD USB Tool installed at /usr/local/bin/zaod-usb-tool\n'
