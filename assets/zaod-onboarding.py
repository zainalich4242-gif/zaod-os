#!/usr/bin/python3
import gi
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

gi.require_version('Gtk', '3.0')
from gi.repository import GLib, Gtk

COMPLETE = Path('/var/lib/zaod/.onboarding_complete')
USERNAME_RE = re.compile(r'^[a-z][a-z0-9-]{0,31}$')
CSS = b"""
window { background: #eaf0f6; color: #17283b; }
.card { background: rgba(255,255,255,.97); border: 1px solid #d5e0eb; border-radius: 14px; padding: 38px; }
.brand { background: #1688df; color: white; border-radius: 12px; font-size: 30px; font-weight: 800; }
.title { font-size: 27px; font-weight: 750; color: #14283d; }
.subtitle { color: #60738a; font-size: 14px; }
entry { min-height: 38px; border-radius: 7px; border: 1px solid #cbd8e5; background: #f7f9fc; color: #17283b; padding: 8px; }
button.primary { min-height: 42px; border-radius: 7px; background: #1688df; color: white; border: 1px solid #1688df; font-weight: 700; padding: 0 18px; }
button.secondary { border-radius: 7px; background: #f4f7fa; color: #30455b; border: 1px solid #d1dce7; min-height: 38px; padding: 0 14px; }
progressbar trough { background: #e2eaf2; border-radius: 8px; min-height: 8px; }
progressbar progress { background: #1688df; border-radius: 8px; min-height: 8px; }
"""


def suggest_username(full_name):
    words = re.sub(r'[^a-zA-Z0-9]+', ' ', full_name).strip().lower().split()
    if not words:
        return ''
    name = words[0] if len(words) == 1 else words[0] + '-' + words[-1]
    return re.sub(r'[^a-z0-9-]', '', name)[:32]


class Onboarding(Gtk.Window):
    def __init__(self):
        super().__init__(title='Welcome to ZAOD OS')
        self.set_decorated(False)
        self.set_default_size(850, 620)
        self.fullscreen()
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE,
                               transition_duration=180)
        self.add(self.stack)
        self.build_welcome()
        self.build_account()
        self.build_progress()
        self.build_ready()

    def card(self, height=430):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        card.set_valign(Gtk.Align.CENTER)
        card.set_halign(Gtk.Align.CENTER)
        card.set_size_request(640, height)
        card.set_border_width(38)
        card.get_style_context().add_class('card')
        return card

    def heading(self, text):
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class('title')
        return label

    def action_row(self, actions):
        row = Gtk.Box(spacing=10)
        row.set_halign(Gtk.Align.END)
        for label, style, callback in actions:
            button = Gtk.Button(label=label)
            button.get_style_context().add_class(style)
            button.connect('clicked', callback)
            row.pack_start(button, False, False, 0)
        return row

    def build_welcome(self):
        card = self.card(470)
        brand = Gtk.Label(label='Z')
        brand.set_size_request(62, 62)
        brand.get_style_context().add_class('brand')
        card.pack_start(brand, False, False, 8)
        card.pack_start(self.heading('Welcome to ZAOD OS'), False, False, 4)
        sub = Gtk.Label(label='A fast, modern desktop. Let us set up your private account.', xalign=0)
        sub.get_style_context().add_class('subtitle')
        card.pack_start(sub, False, False, 0)
        live_note = Gtk.Label(
            label='Live USB note: accounts and files reset after reboot unless the USB has a persistence partition.',
            xalign=0, wrap=True
        )
        live_note.get_style_context().add_class('subtitle')
        card.pack_start(live_note, False, False, 8)
        card.pack_end(self.action_row([('Get Started', 'primary', self.go_account)]), False, False, 0)
        self.stack.add_named(card, 'welcome')

    def build_account(self):
        card = self.card(510)
        card.pack_start(self.heading('Create your account'), False, False, 2)
        subtitle = Gtk.Label(label='Your home folder is private to your account.', xalign=0)
        subtitle.get_style_context().add_class('subtitle')
        card.pack_start(subtitle, False, False, 0)
        grid = Gtk.Grid(column_spacing=16, row_spacing=12)
        fields = (
            ('Full name', 'Zaid Khan', False),
            ('Username', 'zaid-khan', False),
            ('Password', '', True),
            ('Confirm password', '', True),
        )
        self.full_name = Gtk.Entry()
        self.username = Gtk.Entry()
        self.password = Gtk.Entry()
        self.confirm = Gtk.Entry()
        self.password.set_visibility(False)
        self.confirm.set_visibility(False)
        self.full_name.set_placeholder_text(fields[0][1])
        self.username.set_placeholder_text(fields[1][1])
        entries = (self.full_name, self.username, self.password, self.confirm)
        for index, ((label, _placeholder, _secret), entry) in enumerate(zip(fields, entries)):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, index, 1, 1)
            entry.set_hexpand(True)
            grid.attach(entry, 1, index, 1, 1)
        card.pack_start(grid, False, False, 8)
        self.show_password = Gtk.CheckButton(label='Show passwords')
        self.show_password.connect('toggled', self.toggle_password)
        card.pack_start(self.show_password, False, False, 0)
        self.validation = Gtk.Label(label='Enter your name to suggest a username.', xalign=0)
        self.validation.get_style_context().add_class('subtitle')
        card.pack_start(self.validation, False, False, 0)
        self.full_name.connect('changed', self.update_suggestion)
        for entry in (self.username, self.password, self.confirm):
            entry.connect('changed', self.validate_account)
        card.pack_end(self.action_row([('Back', 'secondary', self.go_welcome),
                                       ('Create account', 'primary', self.go_progress)]), False, False, 0)
        self.stack.add_named(card, 'account')

    def build_progress(self):
        card = self.card(360)
        card.pack_start(self.heading('Preparing your desktop'), False, False, 16)
        self.progress_label = Gtk.Label(label='Creating your account...', xalign=0)
        self.progress_label.get_style_context().add_class('subtitle')
        card.pack_start(self.progress_label, False, False, 0)
        self.progress = Gtk.ProgressBar()
        card.pack_start(self.progress, False, False, 8)
        self.stack.add_named(card, 'progress')

    def build_ready(self):
        card = self.card(390)
        card.pack_start(self.heading("You're all set"), False, False, 10)
        message = Gtk.Label(label='Sign in with your new username and password to open your desktop.',
                            xalign=0, wrap=True)
        message.get_style_context().add_class('subtitle')
        card.pack_start(message, False, False, 4)
        developer = Gtk.Button(label='I am a developer: install ZAOD Studio')
        developer.get_style_context().add_class('secondary')
        developer.connect('clicked', self.install_studio)
        card.pack_start(developer, False, False, 8)
        card.pack_end(self.action_row([('Go to sign in', 'primary', self.launch_desktop)]), False, False, 0)
        self.stack.add_named(card, 'ready')

    def go_welcome(self, _button):
        self.stack.set_visible_child_name('welcome')

    def go_account(self, _button):
        self.stack.set_visible_child_name('account')

    def update_suggestion(self, _entry):
        if not self.username.get_text() or getattr(self, '_auto_username', False):
            self._auto_username = True
            self.username.set_text(suggest_username(self.full_name.get_text()))
            self._auto_username = False
        self.validate_account()

    def toggle_password(self, check):
        visible = check.get_active()
        self.password.set_visibility(visible)
        self.confirm.set_visibility(visible)

    def validate_account(self, *_args):
        full_name = self.full_name.get_text().strip()
        username = self.username.get_text().strip()
        password = self.password.get_text()
        confirm = self.confirm.get_text()
        if len(full_name) < 2:
            message = 'Enter your full name.'
        elif not USERNAME_RE.fullmatch(username):
            message = 'Username must start with a lowercase letter; use lowercase letters, digits, or hyphen.'
        elif subprocess.run(['getent', 'passwd', username], capture_output=True).returncode == 0:
            message = 'That username already exists.'
        elif len(password) < 8:
            message = 'Use a password with at least eight characters.'
        elif password != confirm:
            message = 'Passwords do not match.'
        else:
            message = 'Account details look good.'
        self.validation.set_text(message)
        return message == 'Account details look good.'

    def go_progress(self, _button):
        if not self.validate_account():
            return
        self.stack.set_visible_child_name('progress')
        values = {
            'username': self.username.get_text().strip(),
            'full_name': self.full_name.get_text().strip(),
            'password': self.password.get_text(),
        }
        threading.Thread(target=self.provision_user, args=(values,), daemon=True).start()

    def provision_user(self, values):
        request_path = None
        try:
            fd, request_path = tempfile.mkstemp(prefix='zaod-account-', dir='/tmp')
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                json.dump(values, stream)
            result = subprocess.run(
                ['pkexec', '/usr/local/libexec/zaod-provision-user', request_path],
                capture_output=True, text=True
            )
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or 'Account creation was cancelled or failed.')
            GLib.idle_add(self.progress.set_fraction, 1.0)
            GLib.idle_add(self.stack.set_visible_child_name, 'ready')
        except Exception as error:
            GLib.idle_add(self.show_error, str(error))
        finally:
            if request_path and os.path.exists(request_path):
                os.unlink(request_path)
            GLib.idle_add(self.password.set_text, '')
            GLib.idle_add(self.confirm.set_text, '')

    def install_studio(self, _button):
        dialog = Gtk.MessageDialog(parent=self, flags=Gtk.DialogFlags.MODAL,
                                   type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.YES_NO,
                                   text='Install ZAOD Studio?')
        dialog.format_secondary_text('ZAOD Studio is optional and intended for app developers.')
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.YES:
            subprocess.Popen(['pkexec', '/usr/local/bin/zos-install',
                              '/opt/zaod-optional/zaod-studio.zos'])

    def launch_desktop(self, _button):
        subprocess.Popen(['/usr/bin/xfce4-session-logout', '--logout', '--fast'])
        Gtk.main_quit()

    def show_error(self, message):
        dialog = Gtk.MessageDialog(parent=self, flags=Gtk.DialogFlags.MODAL,
                                   type=Gtk.MessageType.ERROR,
                                   buttons=Gtk.ButtonsType.CLOSE,
                                   text='Could not finish account setup')
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()


def main():
    if '--dry-run' in sys.argv:
        print('ZAOD onboarding dry-run: account fields, private request flow, and sign-in handoff are ready')
        return
    if COMPLETE.exists():
        return
    window = Onboarding()
    window.connect('destroy', Gtk.main_quit)
    window.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
