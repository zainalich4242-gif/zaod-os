#!/usr/bin/python3
import subprocess
import gi

gi.require_version('Gdk', '3.0')
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, GLib, Gtk

CSS = b"""
window { background: rgba(242,246,251,.98); color: #17283b; }
.title { font-size: 19px; font-weight: 700; }
.muted { color: #63758a; font-size: 12px; }
.card { background: #e8eef5; border: 1px solid #d5e0eb; border-radius: 12px; padding: 14px; }
button { min-height: 36px; border-radius: 8px; border: 1px solid #cfdae6; background: #f9fbfd; color: #21364b; padding: 4px 10px; }
button:hover { background: #e1effc; border-color: #b6d6f1; }
switch:checked { background: #1688df; }
scale trough { background: #d5e0eb; border-radius: 8px; min-height: 7px; }
scale highlight { background: #1688df; border-radius: 8px; }
scale slider { background: #ffffff; border: 1px solid #b6c8d9; min-width: 18px; min-height: 18px; }
"""


def command(args, timeout=4):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=timeout)


class ControlCenter(Gtk.Window):
    def __init__(self):
        super().__init__(title='Quick settings')
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_default_size(360, 510)
        self.set_resizable(False)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.set_border_width(18)
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        title = Gtk.Label(label='Quick settings', xalign=0)
        title.get_style_context().add_class('title')
        header.pack_start(title, True, True, 0)
        self.date = Gtk.Label(label='', xalign=1)
        self.date.get_style_context().add_class('muted')
        header.pack_end(self.date, False, False, 0)
        root.pack_start(header, False, False, 0)

        toggles = Gtk.Grid(column_spacing=10, row_spacing=10)
        toggles.attach(self.toggle_card('Wi-Fi', self.wifi_state(), self.toggle_wifi), 0, 0, 1, 1)
        toggles.attach(self.toggle_card('Bluetooth', self.bluetooth_state(), self.toggle_bluetooth), 1, 0, 1, 1)
        root.pack_start(toggles, False, False, 0)

        root.pack_start(self.slider_card('Volume', 0, 100, self.volume_value(), self.set_volume),
                        False, False, 0)
        root.pack_start(self.slider_card('Brightness', 0, 100, self.brightness_value(), self.set_brightness),
                        False, False, 0)

        settings = Gtk.Grid(column_spacing=8, row_spacing=8)
        for idx, (label, cmd) in enumerate((
            ('Network', ['nm-connection-editor']),
            ('Display', ['xfce4-display-settings']),
            ('Sound', ['xfce4-settings-manager']),
            ('Appearance', ['xfce4-appearance-settings']),
        )):
            button = Gtk.Button(label=label)
            button.connect('clicked', self.run_command, cmd)
            settings.attach(button, idx % 2, idx // 2, 1, 1)
        root.pack_start(settings, False, False, 0)

        bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        power = Gtk.Button(label='Power')
        power.connect('clicked', self.run_command, ['xfce4-session-logout'])
        close = Gtk.Button(label='Close')
        close.connect('clicked', lambda *_: self.destroy())
        bottom.pack_start(power, True, True, 0)
        bottom.pack_start(close, True, True, 0)
        root.pack_end(bottom, False, False, 0)
        self.add(root)
        GLib.timeout_add_seconds(30, self.update_date)
        self.update_date()
        self.connect('key-press-event', self.on_key)
        self.show_all()

    def update_date(self):
        result = command(['date', '+%a, %b %-d | %-I:%M %p'])
        self.date.set_text(result.stdout.strip() if result.returncode == 0 else '')
        return True

    @staticmethod
    def toggle_card(label, active, callback):
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        text = Gtk.Label(label=label, xalign=0)
        switch = Gtk.Switch()
        switch.set_active(active)
        switch.connect('state-set', callback)
        box.pack_start(text, True, True, 0)
        box.pack_end(switch, False, False, 0)
        frame = Gtk.Frame()
        frame.get_style_context().add_class('card')
        frame.add(box)
        frame.set_size_request(150, 66)
        return frame

    @staticmethod
    def slider_card(label, minimum, maximum, value, callback):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        row.pack_start(Gtk.Label(label=label, xalign=0), True, True, 0)
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, minimum, maximum, 1)
        scale.set_draw_value(True)
        scale.set_value(value)
        scale.connect('value-changed', callback)
        box.pack_start(row, False, False, 0)
        box.pack_start(scale, False, False, 0)
        frame = Gtk.Frame()
        frame.get_style_context().add_class('card')
        frame.add(box)
        return frame

    @staticmethod
    def wifi_state():
        result = command(['nmcli', '-t', '-f', 'WIFI', 'radio'])
        return result.stdout.strip().lower() == 'enabled'

    @staticmethod
    def bluetooth_state():
        result = command(['bluetoothctl', 'show'])
        return 'Powered: yes' in result.stdout

    @staticmethod
    def volume_value():
        result = command(['pactl', 'get-sink-volume', '@DEFAULT_SINK@'])
        for part in result.stdout.split():
            if part.endswith('%'):
                try:
                    return float(part.rstrip('%'))
                except ValueError:
                    pass
        return 50

    @staticmethod
    def brightness_value():
        result = command(['brightnessctl', 'g'])
        maximum = command(['brightnessctl', 'm'])
        try:
            current_value = float(result.stdout.strip())
            max_value = float(maximum.stdout.strip())
            return 50 if not max_value else min(100, 100 * current_value / max_value)
        except (ValueError, ZeroDivisionError, OSError):
            return 50

    def toggle_wifi(self, switch, state):
        command(['nmcli', 'radio', 'wifi', 'on' if state else 'off'])
        return False

    def toggle_bluetooth(self, switch, state):
        command(['bluetoothctl', 'power', 'on' if state else 'off'])
        return False

    def set_volume(self, scale):
        value = int(scale.get_value())
        command(['pactl', 'set-sink-volume', '@DEFAULT_SINK@', f'{value}%'])

    def set_brightness(self, scale):
        value = int(scale.get_value())
        subprocess.Popen(['pkexec', 'brightnessctl', 'set', f'{value}%'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run_command(self, _button, args):
        try:
            subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError as error:
            dialog = Gtk.MessageDialog(parent=self, flags=0, type=Gtk.MessageType.ERROR,
                                       buttons=Gtk.ButtonsType.CLOSE, text='Could not open setting')
            dialog.format_secondary_text(str(error))
            dialog.run()
            dialog.destroy()

    def on_key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        return False


window = ControlCenter()
window.connect('destroy', Gtk.main_quit)
Gtk.main()
