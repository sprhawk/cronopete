#!/bin/bash

if [[ -z "${DESTDIR}" ]]; then
	if [[ -z "${MESON_INSTALL_PREFIX}" ]]; then
		prefix=/usr/local
	else
		prefix="${MESON_INSTALL_PREFIX}"
	fi
    datadir="${prefix}/share"
	echo Updating icon cache at ${datadir}/icons/hicolor...
	gtk-update-icon-cache -qtf "${datadir}/icons/hicolor"
fi
