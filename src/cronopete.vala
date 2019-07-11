/*
 * Copyright 2011-2018 (C) Raster Software Vigo (Sergio Costas)
 *
 * This file is part of Cronopete
 *
 * Cronopete is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cronopete is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. */

using GLib;
using Posix;
using Gee;
using Gtk;
using Gdk;
using Cairo;
using Gsl;
using Posix;
using AppIndicator;
using Notify;

// project version=4.9.0

namespace cronopete {
	cronopete_class callback_object;

	enum BackupStatus { STOPPED, ALLFINE, WARNING, ERROR }

	public class cronopete_class : GLib.Object {
		public int first_delay = 0;

		private backup_base backend;
		private backup_base[] backend_list;
		private int current_backend;
		private GLib.Settings cronopete_settings;
		private c_main_menu main_menu;
		private BackupStatus current_status;
		private bool aborted;

		private Indicator appindicator;
		private Gtk.Menu menuSystem;
		private Gtk.MenuItem menuDate;
		private Gtk.MenuItem menuBUnow;
		private Gtk.MenuItem menuSBUnow;
		private Gtk.MenuItem menuUnmount;
		private Gtk.SeparatorMenuItem unmountSeparatorBar;
		private Gtk.MenuItem menuEnter;
		private Notify.Notification notification;

		private int iconpos;
		private uint animation_timer;

		private restore_iface restore_window;
		private bool restore_window_visible;

		public signal void changed_backend(backup_base backend);

		public cronopete_class() {
			this.aborted = false;
			this.notification = null;
			this.restore_window_visible = false;
			this.iconpos         = 0;
			this.animation_timer = 0;
			this.current_status  = BackupStatus.STOPPED;

			this.cronopete_settings = new GLib.Settings("org.rastersoft.cronopete");
			this.backend_list       = {};
			// currently there is only the RSYNC backend
			this.backend_list   += new backup_extdisk();
			this.backend_list   += new backup_folder();
			this.current_backend = this.cronopete_settings.get_int("current-backend");
			if (this.current_backend >= this.backend_list.length) {
				this.current_backend = 0;
			}
			// Window that manages the configuration and the log
			this.main_menu = new c_main_menu(this, this.backend_list);

			this.backend = null;
			this.updated_backend();

			// Create the app indicator
			this.appindicator = new Indicator("Cronopete", "cronopete_arrow_1_green", IndicatorCategory.APPLICATION_STATUS);

			this.cronopete_settings.changed.connect(this.changed_config);

			// check if this is the first time we launch cronopete
			this.check_welcome();
			// update the menu
			this.menuSystem = null;
			this.menuSystem_popup();
			// set indicator visibility
			this.changed_config("visible");
			this.repaint_tray_icon();
			// wait 10 minutes before checking if a backup is needed, to allow the desktop to be fully loaded
			this.first_delay = 10;
			// Check every minute if we have to do a backup
			GLib.Timeout.add(60000, this.check_backup);
		}

		public void unmount_disk() {
			if (this.backend != null) {
				this.backend.umount_destination();
			}
		}

		public void updated_backend() {
			if (this.backend != null) {
				// Unconnect all the signals from the old backend
				this.backend.send_warning.disconnect(this.received_warning);
				this.backend.send_error.disconnect(this.received_error);
				this.backend.is_available_changed.disconnect(this.backend_availability_changed);
				this.backend.current_status_changed.disconnect(this.backend_status_changed);
				this.backend.in_use(false);
			}
			this.backend = this.backend_list[this.current_backend];
			// Connect all the signals
			this.backend.send_warning.connect(this.received_warning);
			this.backend.send_error.connect(this.received_error);
			this.backend.is_available_changed.connect(this.backend_availability_changed);
			this.backend.current_status_changed.connect(this.backend_status_changed);
			this.backend.in_use(true);
			this.changed_backend(this.backend);
		}

		private bool can_do_backup() {
			if (this.backend.current_status != backup_current_status.IDLE) {
				return false;
			}
			if (this.backend.storage_is_available() == false) {
				return false;
			}
			if (this.cronopete_settings.get_boolean("enabled") == false) {
				return false;
			}
			return true;
		}

		/**
		 * Every 10 minutes will check if there is need to do a new backup
		 * Since deleting old backups can take a lot of time, it can delay
		 * the next backup
		 */
		private bool check_backup() {
			if (this.first_delay > 0) {
				this.first_delay--;
				return true;
			}
			if (this.can_do_backup()) {
				var last_backup = this.backend.get_last_backup();
				var now         = time_t();
				var period      = this.cronopete_settings.get_uint("backup-period");
				if ((last_backup + period) <= now) {
					// a backup is pending
					this.backup_now();
				}
			}
			return true;
		}

		public void backup_now() {
			if (this.can_do_backup()) {
				this.aborted = false;
				this.main_menu.erase_text_log();
				bool skip_hiden = this.cronopete_settings.get_boolean("skip-hiden-at-home");
				string[] folder_list = this.cronopete_settings.get_strv("backup-folders");
				if (folder_list.length == 0) {
					folder_list  = {};
					folder_list += GLib.Environment.get_home_dir();
					skip_hiden = true;
				}
				var to_exclude = this.cronopete_settings.get_value("exclude-folders").dup_strv();

				// Exclude some local folders that don't contain user data, but temporary files, pipes for DBus...
				string[] dont_backup_folders = {".gvfs", ".dbus", ".var/app/*/cache"};
				dont_backup_folders += GLib.Environment.get_user_cache_dir();
				dont_backup_folders += GLib.Environment.get_tmp_dir();
				Posix.Glob myglob = Posix.Glob();
				foreach (var base_folder in dont_backup_folders) {
					string folder;
					if (!base_folder.has_prefix("/")) {
						folder = GLib.Path.build_filename(GLib.Environment.get_home_dir(), base_folder);
					} else {
						folder = base_folder;
					}
					myglob.glob(folder);
					foreach(var f in myglob.pathv) {
						if (!f.has_suffix("/")) {
							f += "/";
						}
						var found = false;
						foreach(var exclude_folder in to_exclude) {
							if (!exclude_folder.has_suffix("/")) {
								exclude_folder += "/";
							}
							if (exclude_folder == f) {
								found = true;
								break;
							}
						}
						if (!found) {
							to_exclude += f;
						}
					}
				}
				this.backend.do_backup.begin(folder_list,
				                             to_exclude,
				                             skip_hiden);
			}
		}

		/**
		 * Manages every change in the configuration
		 */
		private void changed_config(string key) {
			if (key == "visible") {
				if (this.cronopete_settings.get_boolean("visible")) {
					this.appindicator.set_status(IndicatorStatus.ACTIVE);
				} else {
					this.appindicator.set_status(IndicatorStatus.PASSIVE);
				}
				return;
			}
			if (key == "enabled") {
				this.repaint_tray_icon();
				this.menuSystem_popup();
				return;
			}
			if (key == "current-backend") {
				this.current_backend = this.cronopete_settings.get_int("current-backend");
				if (this.current_backend >= this.backend_list.length) {
					this.current_backend = 0;
				}
				this.updated_backend();
				this.repaint_tray_icon();
				this.menuSystem_popup();
				return;
			}
		}

		/* Paints the animated icon in the panel */
		public bool repaint_tray_icon() {
			backup_current_status backup_status = this.backend.current_status;

			if (backup_status != backup_current_status.IDLE) {
				this.iconpos++;
			}
			if (this.iconpos > 3) {
				this.iconpos = 0;
			}

			string icon_color  = "";
			string description = "";
			if (this.backend.storage_is_available() == false) {
				// There's no disk connected
				icon_color = "red";
				// TRANSLATORS Specify that the disk configured for backups is not available
				description = _("Disk not available");
			} else {
				if (this.cronopete_settings.get_boolean("enabled")) {
					switch (this.current_status) {
					case BackupStatus.STOPPED:
						// Idle
						icon_color = "white";
						// TRANSLATORS The program state, used in a tooltip, when it is waiting to do the next backup
						description = _("Idle");
						break;

					case BackupStatus.ALLFINE:
					{
						switch (backup_status) {
						case backup_current_status.RUNNING:
						case backup_current_status.SYNCING:
							// doing backup, everything is fine
							icon_color  = "green";
							description = _("Doing backup");
							break;

						case backup_current_status.CLEANING:
							icon_color  = "cyan";
							description = _("Cleaning old backups");
							break;
						}
					}
					break;

					case BackupStatus.WARNING:
						icon_color = "yellow";
						// TRANSLATORS The program state, used in a tooltip, when it is doing a backup and there is, at least, a warning message
						description = _("Doing backup, have a warning");
						break;

					case BackupStatus.ERROR:
						icon_color = "red";
						// TRANSLATORS The program state, used in a tooltip, when it is doing a backup and there is, at least, an error message
						description = _("Doing backup, have an error");
						break;
					}
				} else {
					// the backup is disabled
					icon_color = "orange";
					// TRANSLATORS The program state, used in a tooltip, when the backups are disabled and won't be done
					description = _("Backup is disabled");
				}
			}
			string icon_name = "cronopete-arrow-%d-%s".printf(this.iconpos + 1, icon_color);

			this.appindicator.set_icon_full(icon_name, description);
			if (backup_status == backup_current_status.IDLE) {
				this.animation_timer = 0;
				if ((this.current_status == BackupStatus.WARNING) || (this.current_status == BackupStatus.ERROR)) {
					if (this.notification != null) {
						try {
							this.notification.close();
						} catch (GLib.Error e) {
						}
						this.notification = null;
					}
					if (!this.aborted) {
						this.notification = new Notify.Notification(_("Backup incorrect"), _("There was a problem when doing the last backup. Please, check the log."), "dialog-error");
						notification.add_action("action-name", _("View log"), (notification, action) => {
							this.show_log();
						});
						this.notification.set_timeout(Notify.EXPIRES_NEVER);
						this.notification.set_urgency(Notify.Urgency.CRITICAL);
						try {
							notification.show();
						} catch (GLib.Error e) {
							print("Can't open a notification\n");
						}
					}
				}
				return false;
			} else {
				return true;
			}
		}

		private void backend_availability_changed(bool is_availabe) {
			// update the menu
			this.menuSystem_popup();
			// and the tray icon color
			this.repaint_tray_icon();
		}

		public void backend_status_changed(backup_current_status status) {
			// update the menu
			this.menuSystem_popup();
			if (status != backup_current_status.IDLE) {
				if (this.animation_timer == 0) {
					this.current_status  = BackupStatus.ALLFINE;
					this.animation_timer = GLib.Timeout.add(250, this.repaint_tray_icon);
				}
			} else {
				if (this.current_status == BackupStatus.ALLFINE) {
					this.current_status = BackupStatus.STOPPED;
				}
			}
		}

		private void received_warning(string msg, bool show_alert) {
			if ((this.current_status != BackupStatus.STOPPED) && show_alert) {
				this.current_status = BackupStatus.WARNING;
			}
		}

		private void received_error(string msg) {
			if (this.current_status != BackupStatus.STOPPED) {
				this.current_status = BackupStatus.ERROR;
			}
		}

		public void check_welcome() {
			if (this.cronopete_settings.get_boolean("show-welcome") == false) {
				return;
			}

			var w = new Builder();
			try {
				w.add_from_file(GLib.Path.build_filename(Constants.PKGDATADIR, "welcome.ui"));
			} catch (GLib.Error e) {
				print("Error trying to show the WELCOME window.\n");
				return;
			}
			var welcome_w = (Dialog) w.get_object("dialog1");
			welcome_w.show();
			var retval = welcome_w.run();
			welcome_w.hide();
			welcome_w.destroy();
			switch (retval) {
			case 1:
				// ask me later
				break;

			case 2:
				// configure now
				this.cronopete_settings.set_boolean("show-welcome", false);
				this.show_configuration();
				break;

			case 3:
				// don't ask again
				this.cronopete_settings.set_boolean("show-welcome", false);
				break;
			}
		}

		public void show_configuration() {
			this.main_menu.show_main(false);
		}

		public void show_log() {
			this.main_menu.show_main(true);
		}

		/**
		 * Updates the menu in the AppIndicator
		 */
		private void menuSystem_popup() {
			Gtk.MenuItem menuMain;

			if (this.menuSystem == null) {
				// if there is no menu, create it
				this.menuSystem = new Gtk.Menu();
				this.menuDate   = new Gtk.MenuItem();

				menuDate.sensitive = false;
				menuSystem.append(menuDate);

				// TRANSLATORS Menu entry to start a new backup manually
				this.menuBUnow = new Gtk.MenuItem.with_label(_("Back Up Now"));
				menuBUnow.activate.connect(this.backup_now);
				this.menuSystem.append(menuBUnow);
				// TRANSLATORS Menu entry to abort the current backup manually
				this.menuSBUnow = new Gtk.MenuItem.with_label(_("Stop Backing Up"));
				menuSBUnow.activate.connect(this.stop_backup);
				this.menuSystem.append(menuSBUnow);

				// TRANSLATORS Menu entry to open the interface for restoring files from a backup
				this.menuEnter = new Gtk.MenuItem.with_label(_("Restore files"));
				this.menuEnter.activate.connect(this.restore_files);
				menuSystem.append(this.menuEnter);

				this.unmountSeparatorBar = new Gtk.SeparatorMenuItem();
				menuSystem.append(this.unmountSeparatorBar);

				this.menuUnmount = new Gtk.MenuItem.with_label("");
				this.menuUnmount.activate.connect(this.unmount_disk);
				menuSystem.append(this.menuUnmount);

				var menuBar = new Gtk.SeparatorMenuItem();
				menuSystem.append(menuBar);

				// TRANSLATORS Menu entry to open the configuration window
				menuMain = new Gtk.MenuItem.with_label(_("Configure the backups"));
				menuMain.activate.connect(this.show_configuration);
				menuSystem.append(menuMain);

				menuSystem.show_all();
				this.appindicator.set_menu(this.menuSystem);
			}

			// TRANSLATORS Show the date of the last backup
			this.menuDate.set_label(_("Latest backup: %s").printf(cronopete.date_to_string(this.backend.get_last_backup())));

			if (this.backend.storage_is_available()) {
				int64 a, b;
				var   list = this.backend.get_backup_list(out a, out b);
				if ((list == null) || (list.size <= 0)) {
					menuEnter.sensitive = false;
				} else {
					menuEnter.sensitive = true;
				}
			} else {
				menuEnter.sensitive = false;
			}
			if (this.backend.current_status == backup_current_status.IDLE) {
				menuBUnow.show();
				menuSBUnow.hide();
			} else {
				menuSBUnow.show();
				menuBUnow.hide();
			}
			if (this.backend.storage_is_available() && this.cronopete_settings.get_boolean("enabled")) {
				menuBUnow.sensitive  = true;
				menuSBUnow.sensitive = true;
			} else {
				menuBUnow.sensitive  = false;
				menuSBUnow.sensitive = false;
			}
			var can_unmount = this.backend.can_umount_destination();
			if (can_unmount != null) {
				this.menuUnmount.show();
				this.unmountSeparatorBar.show();
				this.menuUnmount.set_label(can_unmount);
				if (this.backend.storage_is_available() && (this.backend.current_status == backup_current_status.IDLE)) {
					this.menuUnmount.sensitive = true;
				} else {
					this.menuUnmount.sensitive = false;
				}
			} else {
				this.menuUnmount.hide();
				this.unmountSeparatorBar.hide();
			}
		}

		public void stop_backup() {
			if (this.backend.current_status != backup_current_status.IDLE) {
				this.backend.abort_backup();
				this.aborted = true;
			}
		}

		public void restore_files() {
			this.restore_files_from_folder(null);
		}

		public bool try_unmount() {
			if (this.backend != null) {
				var can_unmount = this.backend.can_umount_destination();
				if (can_unmount != null) {
					if (this.backend.storage_is_available() && (this.backend.current_status == backup_current_status.IDLE)) {
						this.unmount_disk();
						return true;
					}
				}
			}
			return false;
		}

		public void restore_files_from_folder(string ? folder) {
			if (this.restore_window_visible) {
				this.restore_window.present();
			} else {
				this.restore_window_visible = true;
				this.restore_window         = new restore_iface(this.backend);
				this.restore_window.destroy.connect(() => {
					this.restore_window_visible = false;
				});
			}
			if (folder != null) {
				this.restore_window.set_folder(folder);
			}
		}
	}

	void on_bus_aquired(DBusConnection conn) {
		try {
			conn.register_object("/com/rastersoft/cronopete", new DetectServer());
		} catch (IOError e) {
			GLib.stderr.printf("Could not register DBUS service\n");
		}
	}

	void install_script() {
		// Install Gnome Files script
		var folder = GLib.Path.build_filename(Environment.get_home_dir(), ".local", "share", "nautilus", "scripts");
		var f2     = GLib.File.new_for_path(folder);
		if (f2.query_exists() == false) {
			try {
				f2.make_directory_with_parents();
			} catch (GLib.Error e) {
			}
		}
		var file_destination = GLib.File.new_for_path(GLib.Path.build_filename(folder, "cronopete"));
		var file_origin      = GLib.File.new_for_path(GLib.Path.build_filename(Constants.PKGDATADIR, "cronopete"));
		try {
			file_origin.copy(file_destination, FileCopyFlags.OVERWRITE);
			GLib.FileUtils.chmod(GLib.Path.build_filename(folder, "cronopete"), 493);
		} catch (GLib.Error e) {
		}
	}

	int main(string[] args) {
		int fork_pid;
		int status;

		while (true) {
			// Create a child and run cronopete there
			// If the child dies, launch cronopete again, to ensure that the backup always work
			fork_pid = Posix.fork();
			if (fork_pid == 0) {
				Notify.init("Cronopete");
				Intl.bindtextdomain(Constants.GETTEXT_PACKAGE, GLib.Path.build_filename(Constants.DATADIR, "locale"));
				Intl.textdomain("cronopete");
				Intl.bind_textdomain_codeset("cronopete", "UTF-8");
				Gtk.init(ref args);
				callback_object = new cronopete_class();
				Bus.own_name(BusType.SESSION, "com.rastersoft.cronopete", BusNameOwnerFlags.NONE, on_bus_aquired, () => {}, () => {
					GLib.stderr.printf("Cronopete is already running.\n");
					Posix.exit(1);
				});
				install_script();
				Gtk.main();
				return 0;
			}
			Posix.waitpid(fork_pid, out status, 0);
			if (status == 48) {
				// This is the status for an abort
				break;
			}
			Posix.sleep(1);
		}
		return -1;
	}

	[DBus(name = "com.rastersoft.cronopete")]
	public class DetectServer : GLib.Object {
		public int do_ping(int v) throws GLib.DBusError, GLib.IOError {
			return (v + 1);
		}

		public void do_backup() throws GLib.DBusError, GLib.IOError {
			callback_object.backup_now();
		}

		public void stop_backup() throws GLib.DBusError, GLib.IOError {
			callback_object.stop_backup();
		}

		public void show_preferences() throws GLib.DBusError, GLib.IOError {
			callback_object.show_configuration();
		}

		public void restore_files() throws GLib.DBusError, GLib.IOError {
			callback_object.restore_files();
		}

		public void restore_files_from_folder(string folder) throws GLib.DBusError, GLib.IOError {
			string folder2 = folder;
			if (folder.has_prefix("file://")) {
				folder2 = folder2.substring(7);
			}
			callback_object.restore_files_from_folder(folder2);
		}

		public void unmount_backup_disk() throws GLib.DBusError, GLib.IOError {
			if (false == callback_object.try_unmount()) {
				throw new GLib.DBusError.FAILED("Can't unmount the backup disk");
			}
		}

		public void set_status(bool enable) throws GLib.DBusError, GLib.IOError {
			var cronopete_settings = new GLib.Settings("org.rastersoft.cronopete");
			cronopete_settings.set_boolean("enabled", enable);
		}
	}
}
