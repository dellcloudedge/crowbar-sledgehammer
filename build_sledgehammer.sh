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
# You will also need sudo rights to mount, umount, cp, rm, cpio, and chroot.

[[ $DEBUG ]] && {
    set -x
    export PS4='${BASH_SOURCE}@${LINENO}(${FUNCNAME[0]}): '
}

die() { echo "$@"; exit 1; }
shopt -s extglob

cleanup() {
    # Clean up any stray mounts we may have left behind.
    while read dev fs type opts rest; do
	sudo umount "$fs"
    done < <(tac /proc/self/mounts |grep "$CHROOT")
    [[ $webrick_pid ]] && kill -9 $webrick_pid
    # use lazy unmount other wise dev won't unmount and the rm will
    # will trash the real dev mount.
    sudo umount -l "$BUILD_DIR"
    sudo rm -rf "$BUILD_DIR" "$CHROOT" 
}

OS_BASIC_PACKAGES=(MAKEDEV SysVinit audit-libs basesystem bash beecrypt \
    bzip2-libs coreutils centos-release cracklib cracklib-dicts db4 \
    device-mapper e2fsprogs elfutils-libelf e2fsprogs-libs ethtool expat \
    filesystem findutils gawk gdbm glib2 glibc glibc-common grep info \
    initscripts iproute iputils krb5-libs libacl libattr libcap libgcc libidn \
    libselinux libsepol libstdc++ libsysfs libtermcap libxml2 libxml2-python \
    mcstrans mingetty mktemp module-init-tools ncurses neon net-tools nss \
    nspr openssl pam pcre popt procps psmisc python python-libs \
    python-elementtree python-sqlite python-urlgrabber python-iniparse \
    readline rpm rpm-libs rpm-python sed setup shadow-utils sqlite sysklogd \
    termcap tzdata udev util-linux yum yum-metadata-parser zlib)

EXTRA_REPOS=('http://mirror.centos.org/centos/5/updates/$basearch' \
    'http://mirror.centos.org/centos/5/extras/$basearch' \
    'http://mirror.pnl.gov/epel/5/$basearch' \
    'http://www.nanotechnologies.qc.ca/propos/linux/centos-live/$basearch/live' \
    'http://rbel.frameos.org/stable/el5/$basearch')


in_chroot() { sudo -H /usr/sbin/chroot "$CHROOT" "$@"; }
chroot_install() { in_chroot /usr/bin/yum -y install "$@"; }
chroot_fetch() { in_chroot /usr/bin/yum -y --downloadonly install "$@"; }

make_redhat_chroot() (
    postcmds=()
    mkdir -p "$CHROOT"
    cd "$BUILD_DIR/CentOS"
    # first, extract our core files into the chroot.
    for pkg in "${OS_BASIC_PACKAGES[@]}"; do
	for f in "$pkg"-[0-9]*+(noarch|x86_64).rpm; do
	    rpm2cpio "$f" | (cd "$CHROOT"; sudo cpio --extract \
		--make-directories --no-absolute-filenames \
		--preserve-modification-time)
	done
	if [[ $pkg =~ (centos|redhat)-release ]]; then
	    mkdir -p "$CHROOT/tmp"
	    cp "$f" "$CHROOT/tmp/$f"
	    postcmds+=("/bin/rpm -ivh --force --nodeps /tmp/$f")
	fi
    done
    # second, fix up the chroot to make sure we can use it
    sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
    for d in proc sys dev dev/pts; do
	mkdir -p "$CHROOT/$d"
	sudo mount --bind "/$d" "$CHROOT/$d"
    done
    # third, run any post cmds we got earlier
    for cmd in "${postcmds[@]}"; do
	in_chroot $cmd
    done
    repo=$(mktemp /tmp/crowbar-repo-XXXXXXXX)
    cat >"$repo" <<EOF
[redhat-base]
name=Redhat Base Repo
baseurl=http://127.0.0.1:54321/
enabled=1
gpgcheck=0
EOF
    sudo rm -f "$CHROOT/etc/yum.repos.d/"*
    sudo cp "$repo" "$CHROOT/etc/yum.repos.d/crowbar-build-base.repo"

    # Work around packages we don't have, but that the yum bootstrap
    # will grab for us.
    in_chroot mkdir -p "/usr/lib/python2.4/site-packages/urlgrabber.broke"
    for f in "$CHROOT/usr/lib/python2.4/site-packages/urlgrabber/keepalive"*; do
	in_chroot mv "${f#$CHROOT}" \
	    "/usr/lib/python2.4/site-packages/urlgrabber.broke/"
    done
    # Make sure yum does not throw away our caches for any reason.
    in_chroot /bin/sed -i -e '/keepcache/ s/0/1/' /etc/yum.conf
    in_chroot sh -c "echo 'exclude = *.i386' >>/etc/yum.conf"
    # fourth, have yum bootstrap everything else into usefulness
    chroot_install yum yum-downloadonly
)

[[ -f ${0##*/} ]] || \
    die "You must run ${0##*/} from the Sledgehammer checkout, not from $PWD"

if ! which cpio &>/dev/null; then
    die "Cannot find cpio, we cannot proceed."
fi

if ! which rpm rpm2cpio &>/dev/null; then
    die "Cannot find rpm and rpm2cpio, we cannot proceed."
fi

if ! which ruby &>/dev/null; then
    die "You must have Ruby installed to run this script.  We cannot proceed."
fi

[[ $CENTOS_ISO && -f $CENTOS_ISO ]] || {
    cat <<EOF
You need to download the CentOS 5.6 x86_64 DVD in order to stage the
Sledgehammer build.  You can download it via bittorrent using the following
.torrent file:
http://mirror.cs.vt.edu/pub/CentOS/5.6/isos/x86_64/CentOS-5.6-x86_64-bin-DVD.torrent

If you cannot download the DVD using bittorrent, you can also download it via 
direct download from:
http://mirror.cs.vt.edu/pub/CentOS/5.6/isos/x86_64/CentOS-5.6-x86_64-bin-DVD-1of2.iso

Once you have downloaded the CentOS 5.6 DVD isos, point CENTOS_ISO at the first
ISO image and run build_sledgehammer.sh:
CENTOS_ISO=/path/to/CentOS-5.6-x86_64-bin-DVD-1of2.iso ./build_sledgehammer.sh

EOF
    die "You must have the Centos 5.6 install DVD downloaded, and CENTOS_ISO must point to it."
}

# Make a directory for chroots and to mount the ISO on.
[[ $CHROOT ]] || CHROOT=$(mktemp -d "$HOME/.sledgehammer_chroot.XXXXX")
[[ $BUILD_DIR ]] || BUILD_DIR=$(mktemp -d "$HOME/.centos-image.XXXXXX")
trap cleanup 0 INT QUIT TERM
sudo mount -o loop "$CENTOS_ISO" "$BUILD_DIR"
# Fire up Webrick to serve out the contents of the iso.
(   cd "$BUILD_DIR"
    exec ruby -rwebrick -e \
	'WEBrick::HTTPServer.new(:BindAddress=>"127.0.0.1",:Port=>54321,:DocumentRoot=>".").start' ) &
    webrick_pid=$!
make_redhat_chroot

# Put ourselves in /mnt in the chroot.
sudo mount --bind "$PWD" "$CHROOT/mnt"
# build our extra yum repositories.
rnum=0
for repo in "${EXTRA_REPOS[@]}"; do
    rt=$(mktemp "/tmp/r${rnum}-XXX.repo")
    cat > "$rt" <<EOF
[r${rnum}]
name=Repo $rnum
baseurl=$repo
gpgcheck=0
enabled=1
EOF
    rnum=$(($rnum + 1))
    sudo cp "$rt" "$CHROOT/etc/yum.repos.d/"
    rm -f "$rt"
done

# Install the livecd tools and prerequisites.
chroot_install livecd-tools livecd-installer rhpl kudzu
in_chroot /bin/mkdir -p /mnt/cache /mnt/bin
# Force livecd-creator to use ext2 instead of ext3.
in_chroot /bin/sed -i -e '/self.__fstype/ s/ext3/ext2/' \
    /usr/lib/python2.4/site-packages/imgcreate/creator.py

# Regenerate the slectehammer.iso if it is not already there.
if ! [[ -f $CHROOT/mnt/sledgehammer.iso ]]; then
    in_chroot /bin/bash -c 'cd /mnt; /usr/bin/livecd-creator --config=centos-sledgehammer.ks --cache=./cache -f sledgehammer' || \
	die "Could not build full iso image"
fi

# Clear out the old tftpboot directory, otherwise the next command will fail.
in_chroot /bin/rm -fr /mnt/tftpboot

# Turn the ISO into a kernel/huge initramfs pair for PXE.
in_chroot /bin/bash -c 'cd /mnt; /usr/bin/livecd-iso-to-pxeboot sledgehammer.iso' || die "Could not generate PXE boot information from Sledgehammer"
in_chroot /bin/rm /mnt/sledgehammer.iso

in_chroot /bin/mkdir -p /mnt/bin || die "Could not make bin directory"
in_chroot /bin/bash -c 'cd /mnt; tar czf bin/sledgehammer-tftpboot.tar.gz tftpboot'

in_chroot chmod -R ugo+w /mnt/bin
in_chroot /bin/rm -rf /mnt/tftpboot

exit 0
