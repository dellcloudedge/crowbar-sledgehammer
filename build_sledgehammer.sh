#!/bin/bash
# Copyright 2011, Dell 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 
# Author: VictorLowther
#
# If you are running this on a Redhat derived system, SELinux needs to be
# disabled, and you will need to run this script as root.
# To run as non-root, you will need an sudoer entry that looks like this:
# user  ALL=(ALL)       NOPASSWD: /path/to/build_sledgehammer.sh
#
# If you are running this on a non-Redhat derived system, you will need to set
# up a chroot environment capable of building Sledgehammer.  Please follow
# the instructions in HOWTO.Non.Redhat to do so, and point this script at it
# using the SLEDGEHAMMER_CHROOT environment variable.
# You will also need sudo rights to mount, umount, cp, and chroot.

die() { local _r=$1; shift; echo "$@"; exit $1; }

[[ -f ${0##*/} ]] || \
    die 1 "You must run ${0##*/} from the Sledgehammer checkout, not from $PWD"

if ! [[ -f /etc/redhat-release && $UID = 0 ]]; then
    if [[ $SLEDGEHAMMER_CHROOT && \
	-f $SLEDGEHAMMER_CHROOT/etc/redhat-release ]]; then
	# Bind mount some important directories
	for d in dev dev/pts sys proc; do
	    grep -q "$SLEDGEHAMMER_CHROOT/$d" /proc/self/mounts || \
		sudo mount --bind "/$d" "${SLEDGEHAMMER_CHROOT}/${d}"
	done
	# Put ourselves in /mnt in the chroot.
	sudo mount --bind "$PWD" "$SLEDGEHAMMER_CHROOT/mnt"
	# Make sure we can resolve domain names.
	sudo cp /etc/resolv.conf "$SLEDGEHAMMER_CHROOT/etc/resolv.conf"
	# Invoke ourself in the chroot.
	sudo chroot "$SLEDGEHAMMER_CHROOT" /bin/bash -c "cd /mnt; ./${0##*/}"
	# Clean up any stray mounts we may have left behind.
	while read dev fs type opts rest; do
	    sudo umount "$fs"
	done < <(tac /proc/self/mounts |grep "$SLEDGEHAMMER_CHROOT")
	exit 0
    else
	echo "You are not running on a Redhat system, and SLEDGEHAMMER_CHROOT is not set."
	echo "Please set SLEDGEHAMMER_CHROOT at a Redhat or CentOS chroot."
	echo "See HOWTO.Non.Redhat for more details."
	exit 1
    fi
fi

if ! which livecd-creator livecd-iso-to-pxeboot &>/dev/null; then
    echo "livecd-creator packages are not installed, Sledgehammer needs them."
    echo "You can install them by following the instructions at:"
    echo "https://projects.centos.org/trac/livecd/wiki/GetToolset"
    exit 1
fi

mkdir -p cache bin

if ! [[ -f sledgehammer.iso ]]; then
    /usr/bin/livecd-creator --config=centos-sledgehammer.ks \
	--cache=./cache -f sledgehammer || \
	die 1 "Could not build full iso image"
fi

rm -fr tftpboot
/usr/bin/livecd-iso-to-pxeboot sledgehammer.iso || \
    die 1 "Could not generate PXE boot information from Sledgehammer"
rm sledgehammer.iso

mkdir -p bin || die -2 "Could not make bin directory"
tar czf bin/sledgehammer-tftpboot.tar.gz tftpboot

chmod -R ugo+w bin
rm -rf tftpboot
exit 0
