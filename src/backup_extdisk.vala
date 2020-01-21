/*
 * Copyright 2011-2018 (C) Raster Software Vigo (Sergio Costas)
 *
 * This file is part of Cronopete
 *
 * Cronopete is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3,
 * as published by the Free Software Foundation.
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
	public class backup_extdisk : backup_rsync {
		// the disk monitor object to manage the disks
		private udisk2_cronopete udisk2;

		private bool do_umount;

		public backup_extdisk() {
			this.icon_name   = "drive-harddisk";
			this.settings_id = "backup-uid";
			this.do_umount   = false;
			this.udisk2      = new udisk2_cronopete();
			this.udisk2.InterfacesAdded.connect_after(this.refresh_connect);
			this.udisk2.InterfacesRemoved.connect_after(this.refresh_connect);
			this.refresh_connect();
		}

		public override string get_descriptor() {
			// TRANSLATORS This is the name for the backend that allows to store the backups in an external disk
			return (_("Store backups in an external hard disk"));
		}

		public override void in_use(bool backend_enabled) {
			this.backend_enabled = backend_enabled;
			this.refresh_connect();
		}

		public override string ? can_umount_destination() {
			return _("Unmount backup disk");
		}

		public override void umount_destination() {
			Gee.Map<ObjectPath, Drive_if>      drives      = new Gee.HashMap<ObjectPath, Drive_if>();
			Gee.Map<ObjectPath, Block_if>      blocks      = new Gee.HashMap<ObjectPath, Block_if>();
			Gee.Map<ObjectPath, Filesystem_if> filesystems = new Gee.HashMap<ObjectPath, Filesystem_if>();

			try {
				this.udisk2.get_drives(out drives, out blocks, out filesystems);
			} catch (GLib.IOError e) {
				return;
			} catch (GLib.DBusError e) {
				return;
			}

			var drive_uuid = cronopete_settings.get_string("backup-uid");
			this.base_drive_path = null;
			foreach (var partition_id in blocks.keys) {
				var block = blocks.get(partition_id);
				var fs    = filesystems.get(partition_id);
				if ((drive_uuid != "") && (drive_uuid == block.IdUUID)) {
					var mnt = fs.MountPoints.dup_bytestring_array();
					if (mnt.length != 0) {
						this.do_umount = true;
						var opts = new GLib.HashTable<string, Variant>(str_hash, str_equal);
						fs.Unmount.begin(opts, (obj, res) => {
							bool had_error = false;
							try {
							    fs.Unmount.end(res);
							} catch (GLib.IOError e) {
							    had_error = true;
							} catch (GLib.DBusError e) {
							    had_error = true;
							}
							if (had_error) {
							    show_error_window(_("Can't unmount the backup disk. Another process is using it."), null);
							}
						});
					}
					return;
				}
			}
		}

		public override bool configure_backup_device(Gtk.Window main_window) {
			var choose_window = new c_choose_disk(main_window);
			var disk_uuid     = choose_window.run(this.cronopete_settings);
			if (disk_uuid != null) {
				this.folder_path = null;
				this.cronopete_settings.set_string("backup-uid", disk_uuid);
				this.refresh_connect();
			}
			return false;
		}

		private void refresh_connect() {
			Gee.Map<ObjectPath, Drive_if>      drives      = new Gee.HashMap<ObjectPath, Drive_if>();
			Gee.Map<ObjectPath, Block_if>      blocks      = new Gee.HashMap<ObjectPath, Block_if>();
			Gee.Map<ObjectPath, Filesystem_if> filesystems = new Gee.HashMap<ObjectPath, Filesystem_if>();

			bool get_drives_error = false;
			try {
				this.udisk2.get_drives(out drives, out blocks, out filesystems);
			} catch (GLib.IOError e) {
				get_drives_error = true;
			} catch (GLib.DBusError e) {
				get_drives_error = true;
			}

			if (get_drives_error == false) {
				var drive_uuid = cronopete_settings.get_string("backup-uid");
				this.base_drive_path = null;
				foreach (var partition_id in blocks.keys) {
					var block = blocks.get(partition_id);
					var fs    = filesystems.get(partition_id);
					if ((drive_uuid != "") && (drive_uuid == block.IdUUID)) {
						var mnt = fs.MountPoints.dup_bytestring_array();
						if (mnt.length == 0) {
							this.last_backup_time = 0;
							// the drive is not mounted!!!!!!
							if (this.folder_path != null) {
								this.folder_path = null;
								this.is_available_changed(false);
							}
							if (this.backend_enabled && cronopete_settings.get_boolean("enabled") && (this.do_umount == false)) {
								// if backups are enabled and the user didn't force an umount, remount it
								var opts = new GLib.HashTable<string, Variant>(str_hash, str_equal);
								fs.Mount.begin(opts, (obj, res) => {
									string mount_point;
									try {
									    fs.Mount.end(res, out mount_point);
									} catch (GLib.DBusError e) {
									} catch (GLib.IOError e) {
									}
								});
							}
						} else {
							if (this.folder_path == null) {
								this.do_umount        = false;
								this.last_backup_time = 0;
								this.folder_path      = Path.build_filename(mnt[0], "cronopete", Environment.get_user_name());
								this.base_drive_path  = Path.build_filename(mnt[0], "cronopete");
								// only each user can read and write in their backup folder
								Posix.chmod(this.folder_path, 0x01C0);
								// everybody can read and write in the CRONOPETE folder
								Posix.chmod(this.base_drive_path, 0x01FF);
								this.is_available_changed(true);
							}
						}
						return;
					}
				}
			}
			// the backup disk isn't connected
			this.last_backup_time = 0;
			this.do_umount        = false;
			if (this.folder_path != null) {
				this.folder_path = null;
				this.is_available_changed(false);
			}
		}
	}
}
