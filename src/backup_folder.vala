/*
 * Copyright 2018 (C) Raster Software Vigo (Sergio Costas)
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

namespace cronopete {
	public class backup_folder : backup_rsync {
		public backup_folder() {
			this.icon_name   = "folder";
			this.settings_id = "folder-backup";
			GLib.Timeout.add(3000, this.check_folder_exists);
			this.check_folder_exists();
		}

		public override string get_descriptor() {
			// TRANSLATORS This is the name for the backend that allows to store the backups in a folder, instead of choosing a disk.
			return (_("Store backups in a folder"));
		}

		public override void in_use(bool backend_enabled) {
			this.backend_enabled = backend_enabled;
		}

		public override string ? can_umount_destination() {
			return null;
		}

		public override void umount_destination() {
		}

		public override bool configure_backup_device(Gtk.Window main_window) {
			var is_enabled = this.cronopete_settings.get_boolean("enable-folder-backend");
			var builder    = new Gtk.Builder();
			try {
				if (is_enabled) {
					builder.add_from_file(Path.build_filename(Constants.PKGDATADIR, "folder_selector.ui"));
				} else {
					builder.add_from_file(Path.build_filename(Constants.PKGDATADIR, "warning_folder_backend.ui"));
					var w = (Gtk.Dialog)builder.get_object("warning_dialog");
					w.transient_for = main_window;
					w.show_all();
					w.run();
					w.hide();
					w.destroy();
					return false;
				}
			} catch (GLib.Error e) {
				print("Failed to create the window for choosing the folder\n");
				return false;
			}

			var w = (Gtk.FileChooserDialog)builder.get_object("folder_selector");
			// TRANSLATORS This is the text for a Cancel button, that cancels the current action of choosing a folder where to do the backups
			var b1 = new Gtk.Button.with_label(_("Cancel"));
			// TRANSLATORS This is the text for an Add button, that adds a selected folder as the destination where to do the backups when using the "backup to folder" backend
			var b2 = new Gtk.Button.with_label(_("Add"));
			w.add_action_widget(b1, Gtk.ResponseType.CANCEL);
			w.add_action_widget(b2, Gtk.ResponseType.OK);
			w.create_folders  = true;
			w.select_multiple = false;
			w.local_only      = false;
			w.action          = Gtk.FileChooserAction.SELECT_FOLDER;
			var current = this.cronopete_settings.get_string("folder-backup");
			if ((current != null) && (current != "")) {
				w.set_current_folder(current);
			}

			w.transient_for = main_window;
			w.show_all();
			var r = w.run();
			if (r == Gtk.ResponseType.OK) {
				current = w.get_current_folder();
				if ((current != null) && (current != "")) {
					this.cronopete_settings.set_string("folder-backup", current);
					this.check_folder_exists();
				}
			}
			w.hide();
			w.destroy();

			return false;
		}

		private bool check_folder_exists() {
			var is_enabled = this.cronopete_settings.get_boolean("enable-folder-backend");
			var folder     = this.cronopete_settings.get_string("folder-backup");

			if ((folder == null) || (folder == "") || (is_enabled == false)) {
				if (this.folder_path != null) {
					this.folder_path = null;
					this.is_available_changed(false);
				}
				return true;
			}
			var ffile = File.new_for_path(folder);
			if (ffile.query_exists() == false) {
				if (this.folder_path != null) {
					this.folder_path = null;
					this.is_available_changed(false);
				}
				return true;
			}
			this.folder_path = Path.build_filename(folder, "cronopete");
			this.is_available_changed(true);
			return true;
		}
	}

	public class folder_element : backup_element {
		/**
		 * Extending the "backup_element" class, to simplify managing the backups
		 * by keeping the folder where it is stored.
		 */

		private FileInfo file_info;
		public string path;
		public string full_path;

		public folder_element(time_t t, string path, FileInfo f) {
			this.set_common_data(t);
			this.file_info = f;
			this.path      = f.get_name();
			this.full_path = Path.build_filename(path, this.path);
		}
	}
}
