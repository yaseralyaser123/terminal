// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/***
    BEGIN LICENSE

    Copyright (C) 2011-2014 Pantheon Terminal Developers
    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU Lesser General Public License version 3, as published
    by the Free Software Foundation.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranties of
    MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
    PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with this program.  If not, see <http://www.gnu.org/licenses/>

    END LICENSE
 ***/

namespace PantheonTerminal {

    public class PantheonTerminalWindow : Gtk.Window {

        public PantheonTerminalApp app {
            get {
                return application as PantheonTerminalApp;
            }
        }

        public Granite.Widgets.DynamicNotebook notebook;
        Pango.FontDescription term_font;
        private Gtk.Clipboard clipboard;
        private PantheonTerminal.Widgets.SearchToolbar search_toolbar;
        private Gtk.Revealer search_revealer;
        public Gtk.ToggleButton search_button;

        public GLib.List <TerminalWidget> terminals = new GLib.List <TerminalWidget> ();

        private HashTable<string, TerminalWidget> restorable_terminals;

        public TerminalWidget current_terminal = null;
        private bool is_fullscreen = false;
        private string[] saved_tabs;

        const string BG_STYLE_CSS = """
            .terminal-window.background {
                background-color: transparent;
            }
        """;

        const string ui_string = """
            <ui>
            <popup name="MenuItemTool">
                <menuitem name="New window" action="New window"/>
                <menuitem name="New tab" action="New tab"/>
                <menuitem name="CloseTab" action="CloseTab"/>
                <menuitem name="Copy" action="Copy"/>
                <menuitem name="Paste" action="Paste"/>
                <menuitem name="Select All" action="Select All"/>
                <menuitem name="Search" action="Search"/>
                <menuitem name="About" action="About"/>

                <menuitem name="NextTab" action="NextTab"/>
                <menuitem name="PreviousTab" action="PreviousTab"/>

                <menuitem name="ZoomIn" action="ZoomIn"/>
                <menuitem name="ZoomOut" action="ZoomOut"/>

                <menuitem name="Fullscreen" action="Fullscreen"/>
            </popup>

            <popup name="AppMenu">
                <menuitem name="Copy" action="Copy"/>
                <menuitem name="Paste" action="Paste"/>
                <menuitem name="Select All" action="Select All"/>
                <menuitem name="Search" action="Search"/>
                <menuitem name="Open in Files" action="Open in Files"/>
            </popup>
            </ui>
        """;

        public Gtk.ActionGroup main_actions;
        public Gtk.UIManager ui;

        public bool unsafe_ignored;

        public PantheonTerminalWindow (PantheonTerminalApp app, bool should_recreate_tabs=true) {
            init (app, should_recreate_tabs);
        }

        public PantheonTerminalWindow.with_coords (PantheonTerminalApp app, int x, int y,
                                                   bool should_recreate_tabs = true) {
            move (x, y);
            init (app, should_recreate_tabs, false);
        }

        public PantheonTerminalWindow.with_working_directory (PantheonTerminalApp app, string location,
                                                              bool should_recreate_tabs = true) {
            init (app, should_recreate_tabs);
            new_tab (location);
        }

        public void add_tab_with_command (string command) {
            new_tab ("", command);
        }

        public void add_tab_with_working_directory (string location) {
            new_tab (location);
        }

        private void init (PantheonTerminalApp app, bool recreate_tabs = true, bool restore_pos = true) {
            icon_name = "utilities-terminal";
            set_application (app);

            Gtk.Settings.get_default ().gtk_application_prefer_dark_theme = true;

            set_visual (Gdk.Screen.get_default ().get_rgba_visual ());

            title = _("Terminal");
            restore_saved_state (restore_pos);
            if (recreate_tabs) {
                open_tabs ();
            }

            /* Actions and UIManager */
            main_actions = new Gtk.ActionGroup ("MainActionGroup");
            main_actions.set_translation_domain ("pantheon-terminal");
            main_actions.add_actions (main_entries, this);

            clipboard = Gtk.Clipboard.get (Gdk.Atom.intern ("CLIPBOARD", false));
            update_context_menu ();
            clipboard.owner_change.connect (update_context_menu);

            ui = new Gtk.UIManager ();

            try {
                ui.add_ui_from_string (ui_string, -1);
            } catch (Error e) {
                error ("Couldn't load the UI: %s", e.message);
            }

            Gtk.AccelGroup accel_group = ui.get_accel_group ();
            add_accel_group (accel_group);

            ui.insert_action_group (main_actions, 0);
            ui.ensure_update ();

            setup_ui ();
            show_all ();

            this.search_revealer.set_reveal_child (false);
            term_font = Pango.FontDescription.from_string (get_term_font ());

            set_size_request (app.minimum_width, app.minimum_height);

            search_button.toggled.connect (on_toggle_search);
            configure_event.connect (on_window_state_change);
            destroy.connect (on_destroy);

            restorable_terminals = new HashTable<string, TerminalWidget> (str_hash, str_equal);
        }

        /** Returns true if the code parameter matches the keycode of the keyval parameter for
          * any keyboard group or level (in order to allow for non-QWERTY keyboards) **/
        protected bool match_keycode (int keyval, uint code) {
            Gdk.KeymapKey [] keys;
            Gdk.Keymap keymap = Gdk.Keymap.get_default ();
            if (keymap.get_entries_for_keyval (keyval, out keys)) {
                foreach (var key in keys) {
                    if (code == key.keycode)
                        return true;
                }
            }

            return false;
        }

        private void setup_ui () {
            var provider = new Gtk.CssProvider ();
            try {
                provider.load_from_data (BG_STYLE_CSS, BG_STYLE_CSS.length);
                Gtk.StyleContext.add_provider_for_screen (Gdk.Screen.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            } catch (Error e) {
                critical (e.message);
            }

            get_style_context ().add_class ("terminal-window");

            var header = new Gtk.HeaderBar ();
            header.set_show_close_button (true);
            header.get_style_context ().add_class ("default-decoration");

            this.set_titlebar (header);

            search_button = new Gtk.ToggleButton ();
            var img = new Gtk.Image.from_icon_name ("edit-find-symbolic", Gtk.IconSize.SMALL_TOOLBAR);
            search_button.set_image (img);
            search_button.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            search_button.set_tooltip_text (_("Find…"));
            search_button.valign = Gtk.Align.CENTER;
            header.pack_end (search_button);

            var grid = new Gtk.Grid ();
            this.search_toolbar = new PantheonTerminal.Widgets.SearchToolbar (this);
            this.search_revealer = new Gtk.Revealer ();
            this.search_revealer.set_transition_type (Gtk.RevealerTransitionType.SLIDE_DOWN);
            this.search_revealer.add (this.search_toolbar);

            grid.attach (this.search_revealer, 0, 0, 1, 1);

            /* Set up the Notebook */
            notebook = new Granite.Widgets.DynamicNotebook ();

            main_actions.get_action ("Copy").set_sensitive (false);

            notebook.tab_added.connect (on_tab_added);
            notebook.tab_removed.connect (on_tab_removed);
            notebook.tab_switched.connect (on_switch_page);
            notebook.tab_moved.connect (on_tab_moved);
            notebook.tab_reordered.connect (on_tab_reordered);
            notebook.tab_restored.connect (on_tab_restored);
            notebook.tab_duplicated.connect (on_tab_duplicated);
            notebook.close_tab_requested.connect (on_close_tab_requested);
            notebook.new_tab_requested.connect (on_new_tab_requested);
            notebook.allow_new_window = true;
            notebook.allow_duplication = true;
            notebook.allow_restoring = settings.save_exited_tabs;
            notebook.max_restorable_tabs = 5;
            notebook.group_name = "pantheon-terminal";
            notebook.can_focus = false;
            notebook.tab_bar_behavior = settings.tab_bar_behavior;

            grid.attach (notebook, 0, 1, 1, 1);
            add (grid);

            key_press_event.connect ((e) => {
                switch (e.keyval) {
                    case Gdk.Key.Escape:
                        if (this.search_toolbar.search_entry.has_focus) {
                            this.search_button.active = !this.search_button.active;
                            return true;
                        }
                        break;
                    case Gdk.Key.KP_Add:
                        if ((e.state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                            action_zoom_in_font ();
                            return true;
                        }
                        break;
                    case Gdk.Key.KP_Subtract:
                        if ((e.state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                            action_zoom_out_font ();
                            return true;
                        }
                        break;
                    case Gdk.Key.Return:
                        if (this.search_toolbar.search_entry.has_focus) {
                            if ((e.state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                                this.search_toolbar.previous_search ();
                            } else {
                                this.search_toolbar.next_search ();
                            }
                            return true;
                        }
                        break;
                    case Gdk.Key.@0:
                        if ((e.state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                            action_zoom_default_font ();
                            return true;
                        }
                        break;
                    case Gdk.Key.@1: //alt+[1-8]
                    case Gdk.Key.@2:
                    case Gdk.Key.@3:
                    case Gdk.Key.@4:
                    case Gdk.Key.@5:
                    case Gdk.Key.@6:
                    case Gdk.Key.@7:
                    case Gdk.Key.@8:
                        if (((e.state & Gdk.ModifierType.MOD1_MASK) != 0) &&
                            settings.alt_changes_tab) {
                            var i = e.keyval - 49;
                            if (i > notebook.n_tabs - 1)
                                return false;
                            notebook.current = notebook.get_tab_by_index ((int) i);
                            return true;
                        }
                        break;
                    case Gdk.Key.@9:
                        if (((e.state & Gdk.ModifierType.MOD1_MASK) != 0) &&
                            settings.alt_changes_tab) {
                            notebook.current = notebook.get_tab_by_index (notebook.n_tabs - 1);
                            return true;
                        }
                        break;
                }

                /* Use hardware keycodes so the key used
                 * is unaffected by internationalized layout */
                if (((e.state & Gdk.ModifierType.CONTROL_MASK) != 0) &&
                                            settings.natural_copy_paste) {
                    uint keycode = e.hardware_keycode;
                    if (match_keycode (Gdk.Key.c, keycode)) {
                        if (current_terminal.get_has_selection ()) {
                            current_terminal.copy_clipboard ();
                            return true;
                        }
                    } else if (match_keycode (Gdk.Key.v, keycode)) {
                        if (this.search_toolbar.search_entry.has_focus) {
                            return false;
                        } else if (clipboard.wait_is_text_available ()) {
                            action_paste ();
                            return true;
                        }
                    }
                }

                return false;
            });
        }

        private void restore_saved_state (bool restore_pos = true) {
            saved_tabs = saved_state.tabs;
            default_width = PantheonTerminal.saved_state.window_width;
            default_height = PantheonTerminal.saved_state.window_height;

            if (restore_pos) {
                int x = saved_state.opening_x;
                int y = saved_state.opening_y;

                if (x != -1 && y != -1) {
                    move (x, y);
                } else {
                    x = (Gdk.Screen.width ()  - default_width)  / 2;
                    y = (Gdk.Screen.height () - default_height) / 2;
                    move (x, y);
                }
            }

            if (PantheonTerminal.saved_state.window_state == PantheonTerminalWindowState.MAXIMIZED) {
                maximize ();
            } else if (PantheonTerminal.saved_state.window_state == PantheonTerminalWindowState.FULLSCREEN) {
                fullscreen ();
            }
        }

        private void on_toggle_search () {

            var is_search = this.search_button.get_active ();

            this.search_revealer.set_reveal_child (is_search);
            if (is_search) {
                search_toolbar.grab_focus ();
            } else {
                this.search_toolbar.clear ();
                this.current_terminal.grab_focus ();
            }
        }

        private void on_tab_added (Granite.Widgets.Tab tab) {
            var t = get_term_widget (tab);
            terminals.append (t);
            t.window = this;
        }

        private void on_tab_removed (Granite.Widgets.Tab tab) {
            var t = get_term_widget (tab);
            terminals.remove (t);

            if (notebook.n_tabs == 0)
                destroy ();
        }

        private bool on_close_tab_requested (Granite.Widgets.Tab tab) {
            var t = get_term_widget (tab);

            if (t.has_foreground_process ()) {
                var d = new ForegroundProcessDialog ();
                if (d.run () == 1) {
                    d.destroy ();
                    t.kill_fg ();
                } else {
                    d.destroy ();

                    return false;
                }
            }

            if (!t.child_has_exited) {
                if (notebook.n_tabs >= 2 && settings.save_exited_tabs) {
                    make_restorable (tab);
                } else {
                    t.term_ps ();
                }
            }

            if (notebook.n_tabs - 1 == 0) {
                reset_saved_tabs ();
            }

            return true;
        }

        private void on_tab_reordered (Granite.Widgets.Tab tab, int new_pos) {
            current_terminal.grab_focus ();
        }

        private void on_tab_restored (string label, string restore_key, GLib.Icon? icon) {
            TerminalWidget term = restorable_terminals.get (restore_key);
            var tab = create_tab (label, icon, term);

            restorable_terminals.remove (restore_key);
            notebook.insert_tab (tab, -1);
            notebook.current = tab;
            term.grab_focus ();
        }

        private void on_tab_moved (Granite.Widgets.Tab tab, int x, int y) {
            Idle.add (() => {
                var new_window = app.new_window_with_coords (x, y, false);
                var t = get_term_widget (tab);
                var new_notebook = new_window.notebook;

                notebook.remove_tab (tab);
                new_notebook.insert_tab (tab, -1);
                new_window.current_terminal = t;
                return false;
            });
        }

        private void on_tab_duplicated (Granite.Widgets.Tab tab) {
            var t = get_term_widget (tab);
            new_tab (t.get_shell_location ());
        }

        private void on_new_tab_requested () {
            if (settings.follow_last_tab)
                new_tab (current_terminal.get_shell_location ());
            else
                new_tab (Environment.get_home_dir ());
        }

        private void update_context_menu () {
            clipboard.request_targets (update_context_menu_cb);
        }

        private void update_context_menu_cb (Gtk.Clipboard clipboard_,
                                             Gdk.Atom[] atoms) {
            bool can_paste = false;

            if (atoms != null && atoms.length > 0)
                can_paste = Gtk.targets_include_text (atoms) || Gtk.targets_include_uri (atoms);

            main_actions.get_action ("Paste").set_sensitive (can_paste);
        }

        uint timer_window_state_change = 0;

        private bool on_window_state_change (Gdk.EventConfigure event) {
            // triggered when the size, position or stacking of the window has changed
            // it is delayed 400ms to prevent spamming gsettings
            if (timer_window_state_change > 0)
                GLib.Source.remove (timer_window_state_change);

            timer_window_state_change = GLib.Timeout.add (400, () => {
                timer_window_state_change = 0;
                if (get_window () == null)
                    return false;

                /* Save window state */
                if ((get_window ().get_state () & Gdk.WindowState.MAXIMIZED) != 0) {
                    PantheonTerminal.saved_state.window_state = PantheonTerminalWindowState.MAXIMIZED;
                } else if ((get_window ().get_state () & Gdk.WindowState.FULLSCREEN) != 0) {
                    PantheonTerminal.saved_state.window_state = PantheonTerminalWindowState.FULLSCREEN;
                } else {
                    PantheonTerminal.saved_state.window_state = PantheonTerminalWindowState.NORMAL;
                }

                /* Save window size */
                if (PantheonTerminal.saved_state.window_state == PantheonTerminalWindowState.NORMAL) {
                    int width, height;
                    get_size (out width, out height);
                    PantheonTerminal.saved_state.window_width = width;
                    PantheonTerminal.saved_state.window_height = height;
                }

                /* Save window position */
                int root_x, root_y;
                get_position (out root_x, out root_y);
                saved_state.opening_x = root_x;
                saved_state.opening_y = root_y;
                return false;
            });
            return false;
        }

        private void reset_saved_tabs () {
            saved_state.tabs = {};
        }

        private void on_switch_page (Granite.Widgets.Tab? old,
                                     Granite.Widgets.Tab new_tab) {
            current_terminal = get_term_widget (new_tab);
            title = current_terminal.window_title ?? "";
            new_tab.icon = null;
            new_tab.page.grab_focus ();
        }

        private void open_tabs () {
            string[] tabs = {};
            if (settings.remember_tabs) {
                tabs = saved_tabs;
                if (tabs.length == 0) {
                    tabs += Environment.get_home_dir ();
                }
            } else {
                tabs += PantheonTerminalApp.working_directory ?? Environment.get_current_dir ();
            }

            int null_dirs = 0;
            for (int i = 0; i < tabs.length; i++) {
                File file = File.new_for_path (tabs[i]);

                if (file.query_exists () == false) {
                    null_dirs++;
                    tabs[i] = "";
                }

                if (null_dirs == tabs.length) {
                    tabs[0] = PantheonTerminalApp.working_directory ?? Environment.get_current_dir ();
                }
            }

            foreach (string loc in tabs) {
                if (loc == "") {
                    continue;
                } else {
                    /* Schedule tab to be added when idle (helps to avoid corruption of
                     * prompt on startup with multiple tabs) */
                    Idle.add_full (GLib.Priority.LOW, () => {
                        new_tab (loc);
                        return false;
                    });
                }
            }
        }

        private void new_tab (string directory, string? program = null) {
            /*
             * If the user choose to use a specific working directory.
             * Reassigning the directory variable a new value
             * leads to free'd memory being read.
             */
            string location;
            if (directory == "") {
                location = PantheonTerminalApp.working_directory ?? Environment.get_current_dir ();
            } else {
                location = directory;
            }

            /* Set up terminal */
            var t = new TerminalWidget (this);
            t.scrollback_lines = settings.scrollback_lines;

            /* Make the terminal occupy the whole GUI */
            t.vexpand = true;
            t.hexpand = true;


            var tab = create_tab (_("Terminal"), null, t);

            t.child_exited.connect (() => {
                if (!t.killed) {
                    if (program != null) {
                        /* If a program was running, do not close the tab so that output of program
                         * remains visible */
                        t.active_shell (location);
                        /* Allow closing tab with "exit" */
                        program = null;
                    } else {
                        t.tab.close ();
                    }
                }
            });

            t.set_font (term_font);

            int minimum_width = t.calculate_width (80) / 2;
            int minimum_height = t.calculate_height (24) / 2;
            set_size_request (minimum_width, minimum_height);
            app.minimum_width = minimum_width;
            app.minimum_height = minimum_height;

            Gdk.Geometry hints = Gdk.Geometry();
            hints.width_inc = (int) t.get_char_width ();
            hints.height_inc = (int) t.get_char_height ();
            set_geometry_hints (this, hints, Gdk.WindowHints.RESIZE_INC);

            notebook.insert_tab (tab, -1);
            notebook.current = tab;
            t.grab_focus ();

            if (program == null) {
                /* Set up the virtual terminal */
                if (location == "") {
                    t.active_shell ();
                } else {
                    t.active_shell (location);
                }
            } else {
                t.run_program (program);
            }
        }

        private Granite.Widgets.Tab create_tab (string label, GLib.Icon? icon, TerminalWidget term) {
            var sw = new Gtk.ScrolledWindow (null, term.get_vadjustment ());
            sw.add (term);
            var tab = new Granite.Widgets.Tab (label, icon, sw);
            term.tab = tab;
            tab.ellipsize_mode = Pango.EllipsizeMode.START;

            return tab;
        }

        private void make_restorable (Granite.Widgets.Tab tab) {
            var term = get_term_widget (tab);
            terminals.remove (term);
            restorable_terminals.insert (term.terminal_id, term);
            tab.restore_data = term.terminal_id;

            tab.dropped_callback = (() => {
                unowned TerminalWidget t = restorable_terminals.get (tab.restore_data);
                t.term_ps ();
                restorable_terminals.remove (tab.restore_data);
            });
        }

        public void run_program_term (string program) {
            new_tab ("", program);
        }

        static string get_term_font () {
            string font_name;

            if (settings.font == "") {
                var settings_sys = new GLib.Settings ("org.gnome.desktop.interface");
                font_name = settings_sys.get_string ("monospace-font-name");
            } else {
                font_name = settings.font;
            }

            return font_name;
        }

        protected override bool delete_event (Gdk.EventAny event) {
            action_quit ();
            string[] tabs = {};
            var tabs_to_terminate = new GLib.List <TerminalWidget> ();

            foreach (var t in terminals) {
                t = (TerminalWidget) t;
                tabs += t.get_shell_location ();
                if (t.has_foreground_process ()) {
                    var d = new ForegroundProcessDialog.before_close ();
                    if (d.run () == 1) {
                        t.kill_fg ();
                        d.destroy ();
                    } else {
                        d.destroy ();
                        return true;
                    }
                }

                tabs_to_terminate.append (t);
            }

            foreach (var t in tabs_to_terminate)
                t.term_ps ();

            saved_state.tabs = tabs;
            return false;
        }

        private void on_destroy () {
            foreach (unowned TerminalWidget t in restorable_terminals.get_values ()) {
                t.term_ps ();
            }
        }

        void on_get_text (Gtk.Clipboard board, string? intext) {
            /* if unsafe paste alert is enabled, show dialog */
            if (settings.unsafe_paste_alert && !unsafe_ignored ) {

                if (intext == null) {
                    return;
                }
                if (!intext.validate()) {
                    warning("Dropping invalid UTF-8 paste");
                    return;
                }
                var text = intext.strip();

                if ((text.index_of ("sudo") > -1) && (text.index_of ("\n") != 0)) {
                    var d = new UnsafePasteDialog (this);
                    if (d.run () == 1) {
                        d.destroy ();
                        return;
                    }
                    d.destroy ();
                }
            }
            current_terminal.paste_clipboard();
        }

        void action_quit () {

        }

        void action_copy () {
            if (current_terminal.uri != null && ! current_terminal.get_has_selection ())
                clipboard.set_text (current_terminal.uri,
                                    current_terminal.uri.length);
            else
                current_terminal.copy_clipboard ();
        }

        void action_paste () {
            clipboard.request_text (on_get_text);
        }

        void action_select_all () {
            current_terminal.select_all ();
        }

        void action_open_in_files () {
            try {
                string uri = Filename.to_uri (current_terminal.get_shell_location ());

                try {
                     Gtk.show_uri (null, uri, Gtk.get_current_event_time ());
                } catch (Error e) {
                     warning (e.message);
                }

            } catch (ConvertError e) {
                warning (e.message);
            }
        }

        void action_close_tab () {
            current_terminal.tab.close ();
            current_terminal.grab_focus ();
        }

        void action_new_window () {
            app.new_window ();
        }

        void action_new_tab () {
            if (settings.follow_last_tab)
                new_tab (current_terminal.get_shell_location ());
            else
                new_tab (Environment.get_home_dir ());
        }

        void action_about () {
            app.show_about (this);
        }

        void action_zoom_in_font () {
            current_terminal.increment_size ();
        }

        void action_zoom_out_font () {
            current_terminal.decrement_size ();
        }

        void action_zoom_default_font () {
            current_terminal.set_default_font_size ();
        }

        void action_next_tab () {
            notebook.next_page ();
        }

        void action_previous_tab () {
            notebook.previous_page ();
        }

        void action_search () {
            this.search_button.active = !this.search_button.active;
        }

        void action_fullscreen () {
            if (is_fullscreen) {
                unfullscreen ();
                is_fullscreen = false;
            } else {
                fullscreen ();
                is_fullscreen = true;
            }
        }

        private TerminalWidget get_term_widget (Granite.Widgets.Tab tab) {
            return (TerminalWidget)((Gtk.Bin)tab.page).get_child ();
        }

        static const Gtk.ActionEntry[] main_entries = {
            { "CloseTab", "gtk-close", N_("Close"),
              "<Control><Shift>w", N_("Close"),
              action_close_tab },

            { "New window", "window-new",
              N_("New Window"), "<Control><Shift>n", N_("Open a new window"),
              action_new_window },

            { "New tab", "gtk-new",
              N_("New Tab"), "<Control><Shift>t", N_("Create a new tab"),
              action_new_tab },

            { "Copy", "gtk-copy",
              N_("Copy"), "<Control><Shift>c", N_("Copy the selected text"),
              action_copy },

            { "Search", "edit-find",
              N_("Find…"), "<Control><Shift>f",
              N_("Search for a given string in the terminal"), action_search },

            { "Paste", "gtk-paste",
              N_("Paste"), "<Control><Shift>v", N_("Paste some text"),
              action_paste },

            { "Select All", "gtk-select-all",
              N_("Select All"), "<Control><Shift>a",
              N_("Select all the text in the terminal"), action_select_all },

            { "Open in Files", "gtk-directory",
              N_("Open in Files"), "<Control><Shift>e",
              N_("Open current location in Files"), action_open_in_files },

            { "About", "gtk-about", N_("About"),
              null, N_("Show about window"), action_about },

            { "NextTab", null, N_("Next Tab"),
              "<Control><Shift>Right", N_("Go to next tab"),
              action_next_tab },

            { "PreviousTab", null, N_("Previous Tab"),
              "<Control><Shift>Left", N_("Go to previous tab"),
              action_previous_tab },

            { "ZoomIn", "gtk-zoom-in", N_("Zoom in"),
              "<Control>plus", N_("Zoom in"),
              action_zoom_in_font },

            { "ZoomOut", "gtk-zoom-out",
              N_("Zoom out"), "<Control>minus", N_("Zoom out"),
              action_zoom_out_font },

            { "Fullscreen", "gtk-fullscreen",
              N_("Fullscreen"), "F11", N_("Toggle/Untoggle fullscreen"),
              action_fullscreen }
        };
    }
}
