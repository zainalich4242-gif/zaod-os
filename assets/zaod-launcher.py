#!/usr/bin/python3
import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gio, GLib, Gtk

CSS = b"""
window { background: rgba(244,247,251,.98); color: #17283b; }
.header { font-size: 22px; font-weight: 700; }
.subtitle { color: #64758a; font-size: 12px; }
searchentry { min-height: 38px; border-radius: 20px; padding: 0 14px; background: #e7edf4; color: #17283b; border: 1px solid #d5dfe9; }
flowboxchild { padding: 6px; }
.app-tile { min-width: 104px; min-height: 104px; border-radius: 10px; background: transparent; color: #26384b; border: 1px solid transparent; }
.app-tile:hover { background: #e8f2fd; border-color: #c9e2fa; }
.app-name { font-size: 12px; }
.category { border-radius: 16px; padding: 6px 12px; background: #e9eef4; color: #35485c; border: 0; }
.category:checked { background: #d7eaff; color: #07599b; }
"""


class AppLauncher(Gtk.Window):
    def __init__(self):
        super().__init__(title='ZAOD Apps', type=Gtk.WindowType.TOPLEVEL)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_default_size(760, 620)
        self.set_resizable(False)
        self.apps = self.read_apps()
        self.category = 'All apps'

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        outer.set_border_width(22)
        outer.get_style_context().add_class('launcher')

        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title = Gtk.Label(label='Your apps', xalign=0)
        title.get_style_context().add_class('header')
        subtitle = Gtk.Label(label='ZAOD OS application library', xalign=0)
        subtitle.get_style_context().add_class('subtitle')
        title_box.pack_start(title, False, False, 0)
        title_box.pack_start(subtitle, False, False, 0)
        top.pack_start(title_box, True, True, 0)
        self.search = Gtk.SearchEntry(placeholder_text='Search apps')
        self.search.set_size_request(300, -1)
        self.search.connect('search-changed', self.render_apps)
        top.pack_end(self.search, False, False, 0)
        outer.pack_start(top, False, False, 0)

        categories = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.category_buttons = []
        for category in ('All apps', 'Internet', 'Accessories', 'Multimedia', 'System'):
            button = Gtk.ToggleButton(label=category)
            button.get_style_context().add_class('category')
            button.connect('toggled', self.select_category, category)
            categories.pack_start(button, False, False, 0)
            self.category_buttons.append(button)
        self.category_buttons[0].set_active(True)
        outer.pack_start(categories, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.flow = Gtk.FlowBox()
        self.flow.set_selection_mode(Gtk.SelectionMode.NONE)
        self.flow.set_homogeneous(True)
        self.flow.set_min_children_per_line(5)
        self.flow.set_max_children_per_line(5)
        self.flow.set_row_spacing(8)
        self.flow.set_column_spacing(8)
        scroll.add(self.flow)
        outer.pack_start(scroll, True, True, 0)

        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.count = Gtk.Label(xalign=0)
        self.count.get_style_context().add_class('subtitle')
        close_button = Gtk.Button(label='Close')
        close_button.connect('clicked', lambda *_: self.destroy())
        footer.pack_start(self.count, True, True, 0)
        footer.pack_end(close_button, False, False, 0)
        outer.pack_start(footer, False, False, 0)

        self.add(outer)
        self.connect('key-press-event', self.on_key)
        self.render_apps()
        self.show_all()
        self.search.grab_focus()

    @staticmethod
    def read_apps():
        apps = []
        for app in Gio.AppInfo.get_all():
            try:
                if not app.should_show():
                    continue
                if not app.get_id() or app.get_id().startswith('zaod-zos-'):
                    continue
                categories = []
                if hasattr(app, 'get_categories'):
                    categories = (app.get_categories() or '').split(';')
                apps.append((app, categories))
            except Exception:
                continue
        return sorted(apps, key=lambda item: (item[0].get_name() or '').casefold())

    def select_category(self, button, category):
        if not button.get_active():
            return
        self.category = category
        for other in self.category_buttons:
            if other is not button:
                other.set_active(False)
        if hasattr(self, 'flow'):
            self.render_apps()

    def category_matches(self, categories):
        if self.category == 'All apps':
            return True
        mapping = {
            'Internet': ('Network', 'WebBrowser', 'Email'),
            'Accessories': ('Utility', 'TextEditor', 'FileManager'),
            'Multimedia': ('AudioVideo', 'Graphics', 'Video', 'Audio'),
            'System': ('Settings', 'System', 'X-XFCE', 'PackageManager'),
        }
        return any(token in categories for token in mapping.get(self.category, ()))

    def render_apps(self, *_):
        for child in self.flow.get_children():
            self.flow.remove(child)
        query = self.search.get_text().strip().casefold()
        shown = 0
        for app, categories in self.apps:
            name = app.get_name() or 'Application'
            if query and query not in name.casefold():
                continue
            if not self.category_matches(categories):
                continue
            tile = Gtk.Button()
            tile.set_relief(Gtk.ReliefStyle.NONE)
            tile.get_style_context().add_class('app-tile')
            content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
            content.set_halign(Gtk.Align.CENTER)
            app_icon = app.get_icon()
            if app_icon is None:
                image = Gtk.Image.new_from_icon_name('application-x-executable', Gtk.IconSize.DIALOG)
            else:
                image = Gtk.Image.new_from_gicon(app_icon, Gtk.IconSize.DIALOG)
            image.set_pixel_size(48)
            label = Gtk.Label(label=name, wrap=True, max_width_chars=16)
            label.set_ellipsize(3)
            label.get_style_context().add_class('app-name')
            content.pack_start(image, True, True, 2)
            content.pack_start(label, False, False, 2)
            tile.add(content)
            tile.set_tooltip_text(name)
            tile.connect('clicked', self.launch_app, app)
            self.flow.add(tile)
            shown += 1
        self.count.set_text(f'{shown} applications')
        self.flow.show_all()

    def launch_app(self, _button, app):
        try:
            app.launch([], None)
            self.destroy()
        except GLib.Error as error:
            dialog = Gtk.MessageDialog(parent=self, flags=0, type=Gtk.MessageType.ERROR,
                                       buttons=Gtk.ButtonsType.CLOSE,
                                       text='Could not open application')
            dialog.format_secondary_text(str(error))
            dialog.run()
            dialog.destroy()

    def on_key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        return False


from gi.repository import Gdk

window = AppLauncher()
window.connect('destroy', Gtk.main_quit)
Gtk.main()
