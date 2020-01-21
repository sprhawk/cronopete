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
// using GIO
using Gee;

[DBus(name = "org.freedesktop.DBus.ObjectManager")]
interface UDisk2_if : GLib.Object {
	public signal void InterfacesAdded(ObjectPath object_path, GLib.HashTable<string, GLib.HashTable<string, Variant> > interfaces_and_properties);

	public signal void InterfacesRemoved(ObjectPath object_path, string[] interfaces);

	public abstract void GetManagedObjects(out GLib.HashTable<ObjectPath, GLib.HashTable<string, GLib.HashTable<string, Variant> > > path) throws GLib.IOError, GLib.DBusError;
}

[DBus(name = "org.freedesktop.DBus.Introspectable")]
interface Introspectable_if : GLib.Object {
	public abstract void Introspect(out string xml_data) throws GLib.IOError, GLib.DBusError;
}

[DBus(timeout = 1000000, name = "org.freedesktop.UDisks2.Block")]
interface Block_if : GLib.Object {
	public abstract string IdLabel { owned get; }
	public abstract string IdUUID { owned get; }
	public abstract ObjectPath Drive { owned get; }
	public abstract uint64 Size { owned get; }
	public abstract string HintIconName { owned get; }
	public abstract string IdType { owned get; }
	public abstract bool ReadOnly { owned get; }

	public abstract async void Format(string type, GLib.HashTable<string, Variant> options) throws GLib.IOError, GLib.DBusError;
}

[DBus(timeout = 100000, name = "org.freedesktop.UDisks2.Filesystem")]
interface Filesystem_if : GLib.Object {
	public abstract uint64 Size { owned get; }
	[DBus(signature = "aay")]
	public abstract Variant MountPoints { owned get; }

	public abstract async void Mount(GLib.HashTable<string, Variant> options, out string mount_path) throws GLib.IOError, GLib.DBusError;
	public abstract async void Unmount(GLib.HashTable<string, Variant> options) throws GLib.IOError, GLib.DBusError;
}

[DBus(name = "org.freedesktop.UDisks2.Drive")]
interface Drive_if : GLib.Object {
	public abstract uint64 Size { owned get; }
	public abstract bool MediaAvailable { owned get; }
	public abstract bool MediaRemovable { owned get; }
	public abstract bool Removable { owned get; }
	public abstract string ConnectionBus { owned get; }
}

class udisk2_cronopete {
	GLib.DBusConnection dbus_connection;
	UDisk2_if udisk;

	public signal void InterfacesAdded();
	public signal void InterfacesRemoved();

	public udisk2_cronopete() {
		try {
			this.dbus_connection = Bus.get_sync(BusType.SYSTEM);

			this.udisk = this.dbus_connection.get_proxy_sync<UDisk2_if>("org.freedesktop.UDisks2", "/org/freedesktop/UDisks2");
			this.udisk.InterfacesAdded.connect((object_path, interfaces_and_properties) => { this.InterfacesAdded(); });
			this.udisk.InterfacesRemoved.connect((object_path, interfaces) => { this.InterfacesRemoved(); });
		} catch (GLib.IOError e) {
			this.udisk           = null;
			this.dbus_connection = null;
		}
	}

	public Filesystem_if get_filesystem_if(string device) throws GLib.IOError {
		return this.dbus_connection.get_proxy_sync<Filesystem_if>("org.freedesktop.UDisks2", device);
	}

	public Block_if get_block_if(string device) throws GLib.IOError {
		return this.dbus_connection.get_proxy_sync<Block_if>("org.freedesktop.UDisks2", device);
	}

	public void get_drives(out Gee.HashMap<ObjectPath, Drive_if> drives, out Gee.HashMap<ObjectPath, Block_if> blocks, out Gee.HashMap<ObjectPath, Filesystem_if> filesystems) throws GLib.IOError, GLib.DBusError {
		GLib.HashTable<ObjectPath, GLib.HashTable<string, GLib.HashTable<string, Variant> > > objects;

		drives      = new Gee.HashMap<ObjectPath, Drive_if>();
		blocks      = new Gee.HashMap<ObjectPath, Block_if>();
		filesystems = new Gee.HashMap<ObjectPath, Filesystem_if>();

		if (this.dbus_connection == null) {
			return;
		}

		udisk.GetManagedObjects(out objects);
		foreach (var o in objects.get_keys()) {
			Introspectable_if intro = this.dbus_connection.get_proxy_sync<Introspectable_if>("org.freedesktop.UDisks2", o);
			string            data;
			intro.Introspect(out data);
			intro = null;
			if ((data.contains("org.freedesktop.UDisks2.Block") && data.contains("org.freedesktop.UDisks2.Filesystem"))) {
				var block = this.dbus_connection.get_proxy_sync<Block_if>("org.freedesktop.UDisks2", o);
				blocks.set(o, block);
				var filesystem = this.dbus_connection.get_proxy_sync<Filesystem_if>("org.freedesktop.UDisks2", o);
				filesystems.set(o, filesystem);
				continue;
			}
			if (data.contains("org.freedesktop.UDisks2.Drive")) {
				var drive = Bus.get_proxy_sync<Drive_if>(BusType.SYSTEM, "org.freedesktop.UDisks2", o);
				drives.set(o, drive);
				continue;
			}
		}
	}
}
