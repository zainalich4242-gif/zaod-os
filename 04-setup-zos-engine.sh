#!/usr/bin/env bash
set -Eeuo pipefail

# ZAOD OS Part 4: native .zos package engine, MIME handler, protocol handler,
# and the optional ZAOD Studio builder package.

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

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./04-setup-zos-engine.sh"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Run this on an amd64/x86_64 host."

ROOTFS="$(realpath -m -- "${ROOTFS}")"
[[ -f "${ROOTFS}/etc/debian_version" ]] || die "No Debian root filesystem found at ${ROOTFS}; run Parts 1-3 first."
grep -q '^12\.' "${ROOTFS}/etc/debian_version" || die "${ROOTFS} is not Debian 12 (Bookworm)."

mkdir -p "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts"
trap cleanup_mounts EXIT
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mount -t devpts devpts "${ROOTFS}/dev/pts" 2>/dev/null || true

printf '%s\n' "Installing .zos engine dependencies..."
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "${ROOTFS}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 \
    python3-gi \
    gir1.2-gtk-3.0 \
    zenity \
    curl \
    ca-certificates \
    file

mkdir -p \
    "${ROOTFS}/usr/local/bin" \
    "${ROOTFS}/var/lib/zaod" \
    "${ROOTFS}/opt/zaod-apps" \
    "${ROOTFS}/opt/zaod-optional" \
    "${ROOTFS}/usr/share/mime/packages" \
    "${ROOTFS}/usr/share/applications" \
    "${ROOTFS}/usr/share/icons/hicolor/256x256/apps"

cat > "${ROOTFS}/var/lib/zaod/installed.json" <<'EOF'
{
  "format": "ZAOD installed application registry",
  "version": 1,
  "applications": {}
}
EOF

cat > "${ROOTFS}/usr/local/bin/zos-install" <<'PYEOF'
#!/usr/bin/python3
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REGISTRY = Path('/var/lib/zaod/installed.json')
APPROOT = Path('/opt/zaod-apps')
REQUIRED = ('id', 'name', 'version', 'category', 'exec', 'icon', 'description')
CATEGORIES = {'Gaming': 'Game', 'Development': 'Development', 'Content': 'Graphics'}


def fail(message):
    print(f"zos-install: {message}", file=sys.stderr)
    sys.exit(1)


def confirm_install(package):
    if 'ZAOD_ZOS_AUTOINSTALL' in os.environ:
        return True
    try:
        result = subprocess.run([
            'zenity', '--question', '--title=ZAOD Package Installer',
            '--width=420', '--text=Install this .zos package?\n\n' + str(package)
        ])
        return result.returncode == 0
    except FileNotFoundError:
        return False


def safe_archive_members(archive):
    for member in archive.getmembers():
        path = Path(member.name)
        if path.is_absolute() or '..' in path.parts:
            fail('archive contains an unsafe path')
        if member.issym() or member.islnk() or member.isdev():
            fail('archive contains an unsafe file type')


def load_registry():
    try:
        return json.loads(REGISTRY.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return {'format': 'ZAOD installed application registry', 'version': 1, 'applications': {}}


def save_registry(registry):
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    temp = REGISTRY.with_suffix('.json.tmp')
    temp.write_text(json.dumps(registry, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, REGISTRY)


def validate_manifest(root):
    manifest_path = root / 'manifest.json'
    if not manifest_path.is_file():
        fail('manifest.json is missing')
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError as exc:
        fail(f'manifest.json is invalid: {exc}')
    missing = [key for key in REQUIRED if key not in manifest]
    if missing:
        fail('manifest.json missing fields: ' + ', '.join(missing))
    app_id = manifest['id']
    if not app_id or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in app_id):
        fail('manifest id must contain only lowercase letters, digits, and hyphen')
    if manifest['category'] not in CATEGORIES:
        fail("category must be Gaming, Development, or Content")
    if not (root / 'app').is_dir():
        fail('app/ directory is missing')
    exec_name = Path(manifest['exec']).name
    exec_path = root / 'app' / exec_name
    if not exec_path.is_file():
        fail('manifest executable is missing from app/')
    icon_name = manifest['icon']
    icon_path = root / icon_name
    if not icon_path.is_file():
        fail('manifest icon is missing')
    return manifest


def main():
    if len(sys.argv) != 2:
        print('Usage: zos-install <file.zos>', file=sys.stderr)
        sys.exit(2)
    package = Path(sys.argv[1]).resolve()
    if not package.is_file():
        fail('package file not found')
    if not confirm_install(package):
        print('Installation cancelled.')
        return

    APPROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zos-install-') as temp_dir:
        root = Path(temp_dir)
        try:
            with tarfile.open(package, 'r:*') as archive:
                safe_archive_members(archive)
                archive.extractall(root)
        except (tarfile.TarError, OSError) as exc:
            fail(f'cannot read package: {exc}')
        manifest = validate_manifest(root)
        app_id = manifest['id']
        destination = (APPROOT / app_id).resolve()
        if APPROOT not in destination.parents:
            fail('invalid app id')
        if destination.exists():
            shutil.rmtree(destination)

        shutil.copytree(root, destination, symlinks=False)
        exec_name = Path(manifest['exec']).name
        exec_path = destination / 'app' / exec_name
        exec_path.chmod(exec_path.stat().st_mode | 0o111)

        icon_name = Path(manifest['icon']).name
        icon_source = destination / icon_name
        icon_target = Path('/usr/share/icons/hicolor/256x256/apps') / f'zaod-{app_id}.png'
        shutil.copyfile(icon_source, icon_target)

        desktop = Path('/usr/share/applications') / f'zaod-{app_id}.desktop'
        desktop.write_text(
            '[Desktop Entry]\n'
            'Type=Application\n'
            f'Name={manifest["name"]}\n'
            f'Comment={manifest["description"]}\n'
            f'Exec={exec_path}\n'
            f'Icon=zaod-{app_id}\n'
            f'Categories={CATEGORIES[manifest["category"]]}\n'
            'Terminal=false\n',
            encoding='utf-8'
        )

        registry = load_registry()
        registry.setdefault('applications', {})[app_id] = {
            'name': manifest['name'],
            'version': str(manifest['version']),
            'category': manifest['category'],
            'install_path': str(destination),
            'desktop': str(desktop),
        }
        save_registry(registry)

    print(f'Installed {manifest["name"]} ({app_id})')


if __name__ == '__main__':
    main()
PYEOF
chmod 0755 "${ROOTFS}/usr/local/bin/zos-install"

cat > "${ROOTFS}/usr/local/bin/zos-pack" <<'PYEOF'
#!/usr/bin/python3
import json
import sys
import tarfile
from pathlib import Path

REQUIRED = ('id', 'name', 'version', 'category', 'exec', 'icon', 'description')
CATEGORIES = {'Gaming', 'Development', 'Content'}


def fail(message):
    print(f"zos-pack: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        print('Usage: zos-pack <project-folder> <output.zos>', file=sys.stderr)
        sys.exit(2)
    project = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    manifest_path = project / 'manifest.json'
    if not manifest_path.is_file():
        fail('manifest.json is missing')
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError as exc:
        fail(f'manifest.json is invalid: {exc}')
    missing = [key for key in REQUIRED if key not in manifest]
    if missing:
        fail('manifest.json missing fields: ' + ', '.join(missing))
    app_id = manifest['id']
    if not app_id or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in app_id):
        fail('manifest id must contain only lowercase letters, digits, and hyphen')
    if manifest['category'] not in CATEGORIES:
        fail('category must be Gaming, Development, or Content')
    if not (project / 'app').is_dir():
        fail('app/ directory is missing')
    executable = project / 'app' / Path(manifest['exec']).name
    if not executable.is_file():
        fail('manifest executable is missing from app/')
    icon = project / Path(manifest['icon']).name
    if not icon.is_file():
        fail('manifest icon is missing')
    if not output.name.endswith('.zos'):
        fail('output filename must end in .zos')
    output.parent.mkdir(parents=True, exist_ok=True)

    with tarfile.open(output, 'w:gz', compresslevel=6) as archive:
        for path in sorted(project.rglob('*')):
            if path.is_file() and '__pycache__' not in path.parts:
                archive.add(path, arcname=str(path.relative_to(project)))
    print(f'Created {output}')


if __name__ == '__main__':
    main()
PYEOF
chmod 0755 "${ROOTFS}/usr/local/bin/zos-pack"

cat > "${ROOTFS}/usr/local/bin/zos-remove" <<'PYEOF'
#!/usr/bin/python3
import json
import shutil
import sys
from pathlib import Path

REGISTRY = Path('/var/lib/zaod/installed.json')
APPROOT = Path('/opt/zaod-apps')


def main():
    if len(sys.argv) != 2:
        print('Usage: zos-remove <app-id>', file=sys.stderr)
        sys.exit(2)
    app_id = sys.argv[1]
    if not app_id or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in app_id):
        print('zos-remove: invalid app id', file=sys.stderr)
        sys.exit(2)

    destination = (APPROOT / app_id).resolve()
    if APPROOT not in destination.parents:
        print('zos-remove: invalid app id', file=sys.stderr)
        sys.exit(2)
    if destination.exists():
        shutil.rmtree(destination)

    desktop = Path('/usr/share/applications') / f'zaod-{app_id}.desktop'
    desktop.unlink(missing_ok=True)
    icon = Path('/usr/share/icons/hicolor/256x256/apps') / f'zaod-{app_id}.png'
    icon.unlink(missing_ok=True)

    try:
        registry = json.loads(REGISTRY.read_text(encoding='utf-8'))
    except FileNotFoundError:
        registry = {'format': 'ZAOD installed application registry', 'version': 1, 'applications': {}}
    registry.setdefault('applications', {}).pop(app_id, None)
    temp = REGISTRY.with_suffix('.json.tmp')
    temp.write_text(json.dumps(registry, indent=2) + '\n', encoding='utf-8')
    temp.replace(REGISTRY)
    print(f'Removed {app_id}')


if __name__ == '__main__':
    main()
PYEOF
chmod 0755 "${ROOTFS}/usr/local/bin/zos-remove"

cat > "${ROOTFS}/usr/share/mime/packages/zaod-zos.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-zos-package">
    <comment>ZAOD application package</comment>
    <glob pattern="*.zos"/>
  </mime-type>
</mime-info>
EOF

cat > "${ROOTFS}/usr/local/bin/zos-open" <<'SH'
#!/bin/bash
set -e
package="${1:-}"
[[ -n "${package}" ]] || exit 1
if zenity --question --title="ZAOD Package Installer" --width=420 \
    --text="Install this ZAOD application?\n\n${package}"; then
    /usr/local/bin/zos-install "${package}"
fi
SH
chmod 0755 "${ROOTFS}/usr/local/bin/zos-open"

cat > "${ROOTFS}/usr/share/applications/zaod-zos-handler.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD Package Installer
Exec=/usr/local/bin/zos-open %f
MimeType=application/x-zos-package;
Terminal=false
NoDisplay=true
EOF

mkdir -p "${ROOTFS}/usr/share/desktop-directories"
cat > "${ROOTFS}/usr/share/desktop-directories/ZAOD-Gaming.directory" <<'EOF'
[Desktop Entry]
Type=Directory
Name=ZAOD Games
Icon=applications-games
EOF
cat > "${ROOTFS}/usr/share/desktop-directories/ZAOD-Development.directory" <<'EOF'
[Desktop Entry]
Type=Directory
Name=ZAOD Development
Icon=applications-development
EOF
cat > "${ROOTFS}/usr/share/desktop-directories/ZAOD-Content.directory" <<'EOF'
[Desktop Entry]
Type=Directory
Name=ZAOD Content
Icon=applications-graphics
EOF

cat > "${ROOTFS}/usr/local/bin/zaod-zos-protocol" <<'PYEOF'
#!/usr/bin/python3
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request


def main():
    if len(sys.argv) != 2:
        sys.exit(2)
    parsed = urllib.parse.urlparse(sys.argv[1])
    if parsed.scheme != 'zos' or parsed.netloc != 'install':
        sys.exit(2)
    query = urllib.parse.parse_qs(parsed.query)
    url = query.get('url', [None])[0]
    if not url:
        sys.exit(2)
    filename = os.path.basename(urllib.parse.urlparse(url).path) or 'download.zos'
    if not filename.endswith('.zos'):
        filename += '.zos'
    target = os.path.join('/tmp', filename)
    try:
        urllib.request.urlretrieve(url, target)
    except Exception as exc:
        subprocess.run(['zenity', '--error', '--title=ZAOD App Store', '--text=' + str(exc)])
        sys.exit(1)
    os.environ['ZAOD_ZOS_AUTOINSTALL'] = '1'
    subprocess.run(['/usr/local/bin/zos-install', target])


if __name__ == '__main__':
    main()
PYEOF
chmod 0755 "${ROOTFS}/usr/local/bin/zaod-zos-protocol"

cat > "${ROOTFS}/usr/share/applications/zaod-zos-protocol.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZAOD App Store Protocol
Exec=/usr/local/bin/zaod-zos-protocol %u
Terminal=false
MimeType=x-scheme-handler/zos;
NoDisplay=true
EOF

# Studio is an installable optional package, not pre-installed in the main menu.
STUDIO="${ROOTFS}/tmp/zaod-studio-project"
mkdir -p "${STUDIO}/app" "${STUDIO}/templates"
cat > "${STUDIO}/manifest.json" <<'EOF'
{
  "id": "zaod-studio",
  "name": "ZAOD Studio",
  "version": "1.0",
  "category": "Development",
  "exec": "zaod-studio.py",
  "icon": "icon.png",
  "description": "Create, edit, and build .zos application packages"
}
EOF

cat > "${STUDIO}/icon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="40" fill="#10243f"/><path d="M55 72h146v112H55z" fill="#1688df"/><path d="M78 94h100v68H78z" fill="#07111f"/><path d="m108 112 24 16-24 16z" fill="#72dfff"/><path d="M55 72h146v20H55z" fill="#2b79bd"/></svg>
EOF

# Convert the SVG to PNG with ImageMagick if available on the host; otherwise
# write a valid one-pixel PNG so Studio remains installable in minimal systems.
if command -v convert >/dev/null 2>&1; then
    convert -background none -density 192 "${STUDIO}/icon.svg" -resize 256x256 "${STUDIO}/icon.png"
else
    printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' | base64 -d > "${STUDIO}/icon.png"
fi

cat > "${STUDIO}/app/zaod-studio.py" <<'PYEOF'
#!/usr/bin/python3
import json
import os
import subprocess
import sys
import tarfile
import tempfile

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk


class Studio(Gtk.Window):
    def __init__(self):
        super().__init__(title='ZAOD Studio')
        self.set_default_size(760, 500)
        self.project = os.path.expanduser('~/ZAODStudio/new-app')

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_border_width(12)
        toolbar = Gtk.Box(spacing=8)
        for label, callback in (
            ('Web App', self.template_web),
            ('Python GUI', self.template_python),
            ('Game/Binary', self.template_binary),
            ('Build .zos', self.build_package),
        ):
            button = Gtk.Button(label=label)
            button.connect('clicked', callback)
            toolbar.pack_start(button, True, True, 0)
        box.pack_start(toolbar, False, False, 0)

        self.editor = Gtk.TextView()
        self.editor.set_monospace(True)
        self.editor.get_buffer().set_text('// Choose a template, edit this source, then click Build .zos')
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.editor)
        box.pack_start(scroll, True, True, 0)
        self.add(box)

    def create_project(self):
        os.makedirs(os.path.join(self.project, 'app'), exist_ok=True)

    def template_web(self, button):
        self.create_project()
        source = '<html><body style="font-family:sans-serif"><h1>ZAOD Web App</h1></body></html>'
        with open(os.path.join(self.project, 'app', 'index.html'), 'w', encoding='utf-8') as file:
            file.write(source)
        with open(os.path.join(self.project, 'app', 'run.sh'), 'w', encoding='utf-8') as file:
            file.write('#!/bin/sh\nxdg-open "$(dirname "$0")/index.html"\n')
        os.chmod(os.path.join(self.project, 'app', 'run.sh'), 0o755)
        self.write_manifest('Web App', 'run.sh')
        self.editor.get_buffer().set_text(source)

    def template_python(self, button):
        self.create_project()
        source = 'import gi\ngi.require_version("Gtk", "3.0")\nfrom gi.repository import Gtk\nwin=Gtk.Window(title="ZAOD Python App")\nwin.connect("destroy", Gtk.main_quit)\nwin.add(Gtk.Label(label="Hello from ZAOD"))\nwin.show_all()\nGtk.main()\n'
        path = os.path.join(self.project, 'app', 'main.py')
        with open(path, 'w', encoding='utf-8') as file:
            file.write(source)
        os.chmod(path, 0o755)
        self.write_manifest('Python App', 'main.py')
        self.editor.get_buffer().set_text(source)

    def template_binary(self, button):
        self.create_project()
        path = os.path.join(self.project, 'app', 'run.sh')
        with open(path, 'w', encoding='utf-8') as file:
            file.write('#!/bin/sh\nx-terminal-emulator\n')
        os.chmod(path, 0o755)
        self.write_manifest('Game/Binary Wrapper', 'run.sh')
        self.editor.get_buffer().set_text('# Game or binary wrapper\nPlace your executable in app/ and update the manifest exec field.')

    def write_manifest(self, name, executable):
        manifest = {
            'id': 'zaod-example', 'name': name, 'version': '1.0',
            'category': 'Development', 'exec': executable,
            'icon': 'icon.png', 'description': name,
        }
        with open(os.path.join(self.project, 'manifest.json'), 'w', encoding='utf-8') as file:
            json.dump(manifest, file, indent=2)
        icon = os.path.join(self.project, 'icon.png')
        if not os.path.exists(icon):
            open(icon, 'wb').write(b'')

    def build_package(self, button):
        if not os.path.isfile(os.path.join(self.project, 'manifest.json')):
            self.message('Choose a template before building.')
            return
        output = os.path.expanduser('~/ZAODStudio/zaod-example.zos')
        os.makedirs(os.path.dirname(output), exist_ok=True)
        result = subprocess.run(['/usr/local/bin/zos-pack', self.project, output], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.message(result.stdout + result.stderr)

    def message(self, text):
        dialog = Gtk.MessageDialog(parent=self, flags=0, type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK, text=text)
        dialog.run()
        dialog.destroy()


window = Studio()
window.connect('destroy', Gtk.main_quit)
window.show_all()
Gtk.main()
PYEOF
chmod 0755 "${STUDIO}/app/zaod-studio.py"

mkdir -p "${ROOTFS}/tmp"
THEME_ICON_PNG="${STUDIO}/icon.png"
STUDIO_PROJECT_IN_ROOT="${STUDIO#"${ROOTFS}"}"
chroot "${ROOTFS}" /bin/bash -lc "cd '${STUDIO_PROJECT_IN_ROOT}' && /usr/local/bin/zos-pack '${STUDIO_PROJECT_IN_ROOT}' /opt/zaod-optional/zaod-studio.zos" 2>/dev/null || true

cat > "${ROOTFS}/usr/local/bin/install-zaod-studio" <<'SH'
#!/bin/bash
set -e
ZAOD_ZOS_AUTOINSTALL=1 /usr/local/bin/zos-install /opt/zaod-optional/zaod-studio.zos
SH
chmod 0755 "${ROOTFS}/usr/local/bin/install-zaod-studio"

printf '%s\n' "Refreshing MIME database..."
chroot "${ROOTFS}" /usr/bin/update-mime-database /usr/share/mime
chroot "${ROOTFS}" /usr/bin/update-desktop-database /usr/share/applications

printf '%s\n' "Cleaning apt caches and temporary files..."
chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"* "${ROOTFS}/tmp/zaod-studio-project" "${ROOTFS}/tmp/"*

cleanup_mounts
trap - EXIT

printf '\nPart 4 complete. .zos engine installed at /usr/local/bin and Studio package at /opt/zaod-optional/zaod-studio.zos\n'
