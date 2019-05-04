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
	public abstract class backup_rsync : backup_base {
		// the full path (or null if it is not available) where the backup will be done
		protected string ? folder_path;
		// the current disk path  without the user (or null if the drive is not available or is a backup to a folder)
		protected string ? base_drive_path;
		// the last backup path if there is one, or null if there are no previous backups
		private string ? last_backup;
		// the current backup name
		private string ? current_backup;
		// contains the base regexp to identify a backup folder
		private string regex_backup = "[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]_[0-9]+";
		// contains the type of delete we are doing, to now what do call at the end
		private int deleting_mode;
		// contains the last backup time
		protected time_t last_backup_time;
		// contains the current backup time
		private time_t current_backup_time;
		// the PID for the currently running child, to abort a backup
		private Pid current_child_pid;
		// if an abort call has been issued
		private bool aborting;
		// used to calculate how many time was needed to do the backup
		private time_t start_time;

		protected bool backend_enabled;
		protected string icon_name;
		protected string settings_id;

		public backup_rsync() {
			this.backend_enabled   = false;
			this.folder_path       = null;
			this.base_drive_path   = null;
			this.current_child_pid = -1;
			this.aborting          = false;
			this.last_backup       = null;
			this.current_backup    = null;
			this.deleting_mode     = -1;
			this.last_backup_time  = 0;
		}

		public override time_t get_last_backup() {
			if (this.last_backup_time == 0) {
				time_t v1, v2;
				// get the value
				this.get_backup_list(out v1, out v2);
			}
			return this.last_backup_time;
		}

		private void get_free_space(out uint64 total_space, out uint64 free_space) {
			total_space = 0;
			free_space  = 0;
			try {
				if (this.folder_path != null) {
					var file = File.new_for_path(this.folder_path);
					var info = file.query_filesystem_info(FileAttribute.FILESYSTEM_SIZE + "," + FileAttribute.FILESYSTEM_FREE, null);
					total_space = info.get_attribute_uint64(FileAttribute.FILESYSTEM_SIZE);
					free_space  = info.get_attribute_uint64(FileAttribute.FILESYSTEM_FREE);
				}
			} catch (Error e) {
			}
		}

		public override bool get_backup_data(out string ? id, out time_t oldest, out time_t newest, out uint64 total_space, out uint64 free_space, out string ? icon) {
			id     = cronopete_settings.get_string(this.settings_id);
			icon   = this.icon_name;
			oldest = 0;
			this.last_backup_time = 0;
			newest      = 0;
			total_space = 0;
			free_space  = 0;
			if (this.folder_path != null) {
				this.get_backup_list(out oldest, out newest);
				this.get_free_space(out total_space, out free_space);
				return true;
			} else {
				return false;
			}
		}

		protected bool create_base_folder(string folder_path) {
			var main_folder = File.new_for_path(folder_path);
			if (false == main_folder.query_exists()) {
				try {
					main_folder.make_directory_with_parents();
				} catch (Error e) {
					this.send_error(_("Can't create the base folders for backups '%s'.").printf(folder_path));
					// Error: can't create the base directory
					return false;
				}
			}
			return true;
		}

		public override Gee.List<backup_element> ? get_backup_list(out time_t oldest, out time_t newest) {
			oldest = 0;
			newest = 0;
			if (this.folder_path == null) {
				return null;
			}
			Gee.List<backup_element> folder_list = new Gee.ArrayList<backup_element>();
			if (!this.create_base_folder(this.folder_path)) {
				return null;
			}
			var main_folder = File.new_for_path(this.folder_path);
			try {
				GLib.Regex regexBackups   = new GLib.Regex("^" + this.regex_backup);
				var        folder_content = main_folder.enumerate_children(FileAttribute.STANDARD_NAME, 0, null);

				FileInfo file_info;
				time_t   now = time_t();
				// Try to find the last directory, based in the origin's date of creation
				while ((file_info = folder_content.next_file(null)) != null) {
					// If the directory starts with 'B', it's a temporary directory from an
					// unfinished backup, or one being removed, so don't append it

					var dirname = file_info.get_name();
					if (!regexBackups.match(dirname)) {
						continue;
					}
					if (dirname.length < 21) {
						continue;
					}

					time_t backup_time = 0;
					bool   found_error = false;
					for (int i = 20; i < dirname.length; i++) {
						var c = dirname[i];
						if ((c >= '0') && (c <= '9')) {
							backup_time *= 10;
							backup_time += (time_t) (c - '0');
						} else {
							found_error = true;
							print("Error when converting %s to time_t\n".printf(dirname));
							break;
						}
					}
					// Also never append backups "from the future"
					if ((found_error == false) && (backup_time <= now) && (backup_time != 0)) {
						if ((oldest == 0) || (backup_time < oldest)) {
							oldest = backup_time;
						}
						if ((newest == 0) || (backup_time > newest)) {
							newest = backup_time;
							this.last_backup_time = newest;
						}
						folder_list.add(new rsync_element(backup_time, this.folder_path, file_info));
					}
				}
			} catch (Error e) {
				// Error: can't read the backups list
				return null;
			}
			return folder_list;
		}

		public override bool storage_is_available() {
			return (this.folder_path != null);
		}

		public override void abort_backup() {
			if (this.aborting) {
				return;
			}
			this.aborting = true;
			if (this.current_child_pid != -1) {
#if VALA_0_40
				Posix.kill(this.current_child_pid, Posix.Signal.TERM);
#else
				Posix.kill(this.current_child_pid, Posix.SIGTERM);
#endif
				this.current_child_pid = -1;
			}
		}

		public override bool get_filelist(backup_element backup, string current_path, out Gee.List<file_information ?> files) {
			FileInfo      info_file;
			FileType      typeinfo;
			rsync_element rbackup = backup as rsync_element;

			try {
				files = new Gee.ArrayList<file_information ?>();

				var finalpath = Path.build_filename(rbackup.full_path, current_path);

				var directory = File.new_for_path(finalpath);
				var listfile  = directory.enumerate_children(FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_ICON + "," + FileAttribute.STANDARD_FAST_CONTENT_TYPE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);

				while ((info_file = listfile.next_file(null)) != null) {
					var tmpinfo = file_information();

					typeinfo     = info_file.get_file_type();
					tmpinfo.name = info_file.get_name().dup();

					if (typeinfo == FileType.DIRECTORY) {
						tmpinfo.isdir = true;
						tmpinfo.type  = null;
					} else {
						tmpinfo.isdir = false;
						tmpinfo.type  = info_file.get_attribute_string(FileAttribute.STANDARD_FAST_CONTENT_TYPE);
					}

					tmpinfo.mod_time = info_file.get_modification_time();
					tmpinfo.size     = info_file.get_size();
					tmpinfo.icon     = (GLib.ThemedIcon)info_file.get_icon();

					files.add(tmpinfo);
				}
				return true;
			} catch {
				return false;
			}
		}

		public override bool restore_file_folder(backup_element backup, string path, string origin_filename, string destination_filename, bool is_folder) {
			var backup2 = backup as rsync_element;

			var origin_fullpath      = Path.build_filename(backup2.full_path, path, origin_filename);
			var destination_fullpath = Path.build_filename(path, destination_filename);
			print("Restoring %s to %s\n".printf(origin_fullpath, destination_fullpath));

			Pid      child_pid;
			string[] command = { "cp", "-a", origin_fullpath, destination_fullpath };
			string[] env     = Environ.get();
			this.debug_command(command);
			try {
				GLib.Process.spawn_async("/", command, env, SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out child_pid);
			} catch (GLib.SpawnError error) {
				this.send_error(_("Failed to launch cp to restore: %s").printf(error.message));
				return true;
			}
			this.current_child_pid = child_pid;
			ChildWatch.add(child_pid, (pid, status) => {
				Process.close_pid(pid);
				if (status == 0) {
				    this.ended_restore(true);
				} else {
				    this.ended_restore(false);
				}
			});
			return false;
		}

		public async override bool do_backup(string[] folder_list, string[] exclude_list, bool skip_hidden_at_home) {
			if (this.current_status != backup_current_status.IDLE) {
				return false;
			}

			if (this.folder_path == null) {
				return false;
			}

			var folders = new Gee.ArrayList<folder_container ?>();
			foreach (var folder in folder_list) {
				var container = folder_container(folder, exclude_list, skip_hidden_at_home);
				if (container.valid) {
					folders.add(container);
				}
			}

			this.start_time = time_t();
			// only each user can read and write in their backup folder
			Posix.chmod(this.folder_path, 0x01C0);
			if (this.base_drive_path != null) {
				// everybody can read and write in the CRONOPETE folder
				Posix.chmod(this.base_drive_path, 0x01FF);
			}

			this.send_message(_("Starting backup"));
			if (!this.create_base_folder(this.folder_path)) {
				this.current_status = backup_current_status.IDLE;
				return false;
			}

			time_t oldest;
			time_t newest;
			var    backups = this.get_backup_list(out oldest, out newest);
			if (backups == null) {
				return false;
			}
			rsync_element last_backup_element = null;
			foreach (var backup in backups) {
				var backup2 = backup as rsync_element;
				if (last_backup_element == null) {
					last_backup_element = backup2;
				} else {
					if (backup2.utc_time > last_backup_element.utc_time) {
						last_backup_element = backup2;
					}
				}
			}
			if (last_backup_element == null) {
				this.last_backup = null;
			} else {
				this.last_backup = last_backup_element.full_path;
			}
			this.current_backup_time = time_t();
			this.current_backup      = this.date_to_folder_name(this.current_backup_time);
			this.current_status      = backup_current_status.RUNNING;
			this.deleting_mode       = 0;
			this.aborting            = false;
			this.send_current_action(_("Cleaning incomplete backups"));
			print("Cleaning incomplete backups (B)\n");
			// delete aborted backups first
			yield this.delete_backup_folders("B");

			print("Cleaned\n");
			if (this.aborting) {
				this.end_abort();
				return false;
			}
			print("Backing up folders\n");
			foreach (var folder in folders) {
				yield this.do_backup_folder(folder);

				if (this.aborting) {
					this.end_abort();
					return false;
				}
			}
			yield this.do_sync();
			if (this.aborting) {
				this.end_abort();
				return false;
			}

			if (this.rename_current_backup()) {
				yield this.delete_backup_folders("B");
				print("Failed to rename the current backup\n");
				return false;
			}
			yield this.do_sync();

			if (this.aborting) {
				this.end_abort();
				return false;
			}
			this.current_status = backup_current_status.CLEANING;
			yield this.delete_old_backups(false);

			time_t elapsed = time_t() - this.start_time;
			this.send_message(_("Backup done. Elapsed time: %d:%02d".printf((int) (elapsed / 60), (int) (elapsed % 60))));
			this.current_status = backup_current_status.IDLE;
			return true;
		}

		private bool rename_current_backup() {
			print("Renaming backup\n");
			var current_folder = File.new_for_path(Path.build_filename(this.folder_path, "B" + this.current_backup));
			try {
				current_folder.set_display_name(this.current_backup);
			} catch (GLib.Error e) {
				print("Error when trying to rename %s\n".printf("B" + this.current_backup));
				this.send_warning(_("Failed to rename backup folder. Aborting backup"), true);
				this.current_status = backup_current_status.CLEANING;
				return true;
			}
			return false;
		}

		private string date_to_folder_name(time_t t) {
			var ctime = GLib.Time.local(t);
			return "%04d_%02d_%02d_%02d:%02d:%02d_%ld".printf(1900 + ctime.year, ctime.month + 1, ctime.day, ctime.hour, ctime.minute, ctime.second, t);
		}

		/**
		 * Sets everything as needed after an abort
		 */
		private void end_abort() {
			print("Aborted\n");
			this.current_child_pid = -1;
			this.aborting          = false;
			this.deleting_mode     = -1;
			this.current_status    = backup_current_status.IDLE;
			this.send_message(_("Backup aborted"));
		}

		/**
		 * This method deletes any backup with a name that starts with 'B' or 'C'
		 * because that's an aborted backup
		 *
		 * @param prefix A single letter which can be 'B' or 'C', specifying which group of backups should be removed
		 * @return True if there was an error; False if not
		 */
		private async bool delete_backup_folders(string prefix) {
			print("Deleting folders with prefix %s\n".printf(prefix));
			var main_folder = File.new_for_path(this.folder_path);
			// find the next folder to delete
			try {
				var folder_regexp  = new GLib.Regex("^" + prefix + this.regex_backup);
				var folder_content = yield main_folder.enumerate_children_async(FileAttribute.STANDARD_NAME, GLib.FileQueryInfoFlags.NONE, GLib.Priority.DEFAULT, null);

				FileInfo file_info;
				string[] command;
				string ? error_message;
				while ((file_info = folder_content.next_file(null)) != null) {
					if (this.aborting) {
						return true; // abort
					}
					// If the directory starts with 'prefix', it's a temporary directory from an
					// unfinished backup, or one being removed, so don't append it
					var dirname = file_info.get_name();
					if (!folder_regexp.match(dirname)) {
						continue;
					}
					print("Deleting path %s\n".printf(Path.build_filename(this.folder_path, dirname)));
					command = { "rm", "-rf", Path.build_filename(this.folder_path, dirname) };
					var retval = yield this.launch_command(command, out error_message);

					if (error_message != null) {
						print("Error 1 when trying to delete backup %s\n".printf(dirname));
						this.send_error(_("Failed to delete aborted backups: %s").printf(error_message));
						return true;
					}
					if (retval == 0) {
						continue;
					}
					print("Changing permissions inside path %s\n".printf(Path.build_filename(this.folder_path, dirname)));
					command = { "chmod", "-R", "700", Path.build_filename(this.folder_path, dirname) };
					// rm failed, so it is probable that there are files or folders with no write permission
					retval = yield this.launch_command(command, out error_message);

					if (error_message != null) {
						print("Error 2 when trying to delete backup %s\n".printf(dirname));
						this.send_error(_("Failed to delete aborted backups: %s").printf(error_message));
						continue;
					}
					if (retval != 0) {
						continue;
					}
					print("Deleting path (again) %s\n".printf(Path.build_filename(this.folder_path, dirname)));
					command = { "rm", "-rf", Path.build_filename(this.folder_path, dirname) };
					retval  = yield this.launch_command(command, out error_message);

					if (error_message != null) {
						print("Error 3 when trying to delete backup %s\n".printf(dirname));
						this.send_error(_("Failed to delete aborted backups: %s").printf(error_message));
						return true;
					}
					if (retval == 0) {
						continue;
					}
					print("RM returned status %d\n".printf(retval));
				}
			} catch (Error e) {
				print("Failed to delete folders: %s\n".printf(e.message));
				this.send_error(_("Failed to delete folders: %s").printf(e.message));
				return true;
			}
			return false;
		}

		/**
		 * This method backs up one folder
		 */
		private async void do_backup_folder(folder_container folder) {
			Pid child_pid;
			int standard_output;
			int standard_error;

			this.send_message(_("Backing up folder %s").printf(folder.folder));

			/* The backup is done to a temporary folder called like the final one, but preppended with a 'B' letter
			 * This way, if there is an big error (like if the computer hangs, or the electric suply fails), it will
			 * be easily identified as an incomplete backup and won't be used
			 */

			string out_folder   = Path.build_filename(this.folder_path, "B" + this.current_backup, folder.folder);
			var    out_folder_f = File.new_for_path(out_folder);
			try {
				out_folder_f.make_directory_with_parents();
			} catch (Error e) {
			}
			string[] command = { "rsync", "-aXv" };
			if (this.last_backup != null) {
				command += "--link-dest";
				command += Path.build_filename(this.last_backup, folder.folder);
			}
			foreach (var exclude in folder.exclude) {
				command += "--exclude";
				command += exclude;
				this.send_message(_("Excluding folder %s").printf(Path.build_filename(folder.folder, exclude)));
			}
			command += folder.folder;
			command += out_folder;
			string[] env = Environ.get();
			bool try_backup = true;
			while (try_backup) {
				this.debug_command(command);
				try {
					GLib.Process.spawn_async_with_pipes("/", command, env, SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out child_pid, null, out standard_output, out standard_error);
				} catch (GLib.SpawnError error) {
					this.send_error(_("Failed to launch rsync for '%s'. Aborting backup").printf(folder.folder));
					this.current_status = backup_current_status.IDLE;
					return;
				}
				this.current_child_pid = child_pid;
				if (cronopete_settings.get_boolean("reduce-priority-rsync")) {
					Posix.setpriority(Posix.PRIO_PROCESS, child_pid, 19);
				}
				ChildWatch.add(child_pid, (pid, status) => {
					Process.close_pid(pid);
					this.current_child_pid = -1;
					try_backup             = false;
					if ((!this.aborting) && (status != 0)) {
					    print("Exit status in rsync: %d\n".printf(status));
					    if ((status == 0x0B) || (status == 0x0B00)) {
					        // free disk space and try again if there is free space now
					        try_backup = true;
						} else {
					        this.send_warning(_("There was a problem when backing up the folder '%s'").printf(folder.folder), true);
						}
					}
					this.do_backup_folder.callback();
				});
				IOChannel output = new IOChannel.unix_new(standard_output);
				output.add_watch(IOCondition.IN | IOCondition.HUP, (channel, condition) => {
					if (condition == IOCondition.HUP) {
					    return false;
					}
					try {
					    string line;
					    channel.read_line(out line, null, null);
					    var line2 = line.strip();
					    this.send_current_action(_("Backing up %s").printf(Path.build_filename(folder.folder, line2)));
					} catch (IOChannelError e) {
					    return false;
					} catch (ConvertError e) {
					    return false;
					}
					return true;
				});
				IOChannel output_error = new IOChannel.unix_new(standard_error);
				output_error.add_watch(IOCondition.IN | IOCondition.HUP, (channel, condition) => {
					if (condition == IOCondition.HUP) {
					    return false;
					}
					try {
					    string line;
						channel.read_line(out line, null, null);
						print("Sending warning %s\n".printf(line.strip()));
					    this.send_warning(line.strip(), false);
					} catch (IOChannelError e) {
					    return false;
					} catch (ConvertError e) {
					    return false;
					}
					return true;
				});
				yield;
				print("Rsync done\n");
				// if we have to retry, first free disk space
				if (try_backup) {
					if (yield this.delete_old_backups(true)) {
						// if there is an error, abort
						try_backup    = false;
						this.aborting = true;
					}
				}
			}
		}

		/**
		 * When the backup is done, do a sync to ensure that the data is physically stored in the disk
		 */
		private async void do_sync() {
			print("Syncing\n");
			string[] command = { "sync" };
			this.send_message(_("Syncing disk"));
			this.send_current_action(_("Syncing disk"));
			this.current_status = backup_current_status.SYNCING;
			string ? error_message;
			yield this.launch_command(command, out error_message);

			if (error_message != null) {
				this.send_warning(_("Failed to launch sync command: %s").printf(error_message), true);
			}
		}

		private async int launch_command(string[] command, out string ? error_message) {
			Pid      child_pid;
			string[] env = Environ.get();
			this.debug_command(command);
			error_message = null;
			int retval = -1;
			try {
				GLib.Process.spawn_async("/", command, env, SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out child_pid);
			} catch (GLib.SpawnError error) {
				print("Error launching command: %s\n".printf(error.message));
				error_message = error.message;
				return -1;
			}
			this.current_child_pid = child_pid;
			ChildWatch.add(child_pid, (pid, status) => {
				Process.close_pid(pid);
				this.current_child_pid = -1;
				retval = status;
				this.launch_command.callback ();
			});
			yield;
			return retval;
		}

		/**
		 * Deletes old backups, ensuring that all the backups in the last 24 hours are kept,
		 * also one daily backup for the last mont, and one backup each week for the rest of
		 * the time.
		 *
		 * @param free_space If true, if no backup is deleted, the last backup will be deleted
		 * to make space for the current backup
		 *
		 * @return false if everything went fine; true if it there is free disk space but still wants to force free
		 */
		public async bool delete_old_backups(bool free_space) {
			this.send_current_action(_("Cleaning old backups"));

			bool forcing_deletion = false;
			var  backups          = this.eval_backups_to_delete(free_space, out forcing_deletion);

			if (backups == null) {
				print("No old backups\n");
				this.send_message(_("No old backups to delete"));
				return false;
			}

			if (forcing_deletion) {
				/* If we are deleting the last backup because we need free space,
				 * ensure that there is no free space, just to avoid deleting everything
				 * if there is a bug
				 */
				uint64 disk_total_space;
				uint64 disk_free_space;
				this.get_free_space(out disk_total_space, out disk_free_space);
				// if the free space is more than the 10% of the total space, don't delete
				// because there is already enough free space
				if (disk_free_space > (disk_total_space * 0.1)) {
					print("Special error!!!!! Aborting\n");
					// there is a problem with the backup, stop deleting
					this.send_error(_("Asked for freeing disk space when there is free space. Aborting backup"));
					this.aborting = true;
					return true;
				}
			}

			foreach (var backup_tmp in backups) {
				if (backup_tmp.keep) {
					continue;
				}
				var backup = backup_tmp as rsync_element;
				print("Renaming to C... old backup %s\n".printf(backup.path));
				this.send_message(_("Deleting old backup %s").printf(backup.path));
				File remove_folder = File.new_for_path(backup.full_path);
				// First rename every backup that must be deleted, by preppending a 'C' letter
				// This allows to mark them fast as "not usable" to avoid the recovery utility to list them
				try {
					remove_folder.set_display_name("C" + backup.path);
				} catch (GLib.Error e) {
					print("Error when renaming to C... the folder %s\n".printf(backup.path));
					this.send_warning(_("Failed to delete old backup %s: %s").printf(backup.path, e.message), true);
				}
			}
			// and now we delete those folders
			yield this.delete_backup_folders("C");

			return false;
		}

		private void debug_command(string[] command_list) {
			string debug_msg = "Launching command: ";
			foreach (var c in command_list) {
				debug_msg += c + " ";
			}
			print(debug_msg + "\n");
			this.send_debug(debug_msg);
		}
	}

	public class rsync_element : backup_element {
		/**
		 * Extending the "backup_element" class, to simplify managing the backups
		 * by keeping the folder where it is stored.
		 */

		private FileInfo file_info;
		public string path;
		public string full_path;

		public rsync_element(time_t t, string path, FileInfo f) {
			this.set_common_data(t);
			this.file_info = f;
			this.path      = f.get_name();
			this.full_path = Path.build_filename(path, this.path);
		}
	}
}
