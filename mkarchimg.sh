#!/bin/bash -xe

# mkarchimg.sh
# simple script to create a minimal Arch image
# author: Ruben Kerhof <ruben@rubenkerkhof.com>

export LANG=C

trap _cleanup EXIT

_mkimage() {
	image=$(mktemp --tmpdir=/var/tmp)
	mp=$(mktemp -d)
	truncate --size 4G $image
	parted -s $image mklabel msdos mkpart primary ext4 1MB 100% set 1 boot on
	dd if=/usr/lib/syslinux/bios/mbr.bin of=${image} bs=440 conv=notrunc status=none
	loop="$(losetup -P --find --show ${image})"
	sleep 1

	mkfs.ext4 -L ROOT -q -E lazy_itable_init=0,lazy_journal_init=0 "${loop}p1"
	mount ${loop}p1 ${mp}
}

_install() {
	pacstrap -c -M "${mp}" \
		coreutils \
		file \
		findutils \
		iproute2 \
		iputils \
		linux-lts \
		lzop \
		openssh \
		pacman \
		procps-ng \
		systemd-sysvcompat \
		vi \
		tilaa/openssl
}

_syslinux() {
	mkdir -p ${mp}/boot/syslinux
	cp /usr/lib/syslinux/bios/ldlinux.c32 ${mp}/boot/syslinux/
	cp /usr/lib/syslinux/bios/menu.c32 ${mp}/boot/syslinux/
	cp /usr/lib/syslinux/bios/libutil.c32 ${mp}/boot/syslinux/

	cat <<-EOF > ${mp}/boot/syslinux/syslinux.cfg
DEFAULT arch
PROMPT 0
TIMEOUT 50
UI menu.c32

LABEL arch-lts
MENU LABEL Arch Linux (LTS)
LINUX ../vmlinuz-linux-lts
APPEND root=LABEL=ROOT rw quiet
INITRD ../initramfs-linux-lts.img
EOF
	extlinux --install ${mp}/boot/syslinux
}

_mkinitcpio() {
	sed -i 's/#COMPRESSION="lzop"/COMPRESSION="lzop"/' ${mp}/etc/mkinitcpio.conf
	sed -i 's/^HOOKS=".*"/HOOKS="base systemd modconf block keyboard fsck"/' ${mp}/etc/mkinitcpio.conf
	sed -i 's/^MODULES=".*"/MODULES="ext4"/' ${mp}/etc/mkinitcpio.conf
	sed -i "s#PRESETS=('default' 'fallback')#PRESETS=('default')#" ${mp}/etc/mkinitcpio.d/linux-lts.preset
	arch-chroot ${mp} mkinitcpio --preset linux-lts --nocolor
	rm -vf ${mp}/boot/initramfs-linux-lts-fallback.img
	chmod o-r /boot/initramfs-linux-lts.img /boot/vmlinuz-linux-lts
}

_customize() {
	# pacman
	sed -i 's/^#Color/Color/' ${mp}/etc/pacman.conf
	cp -p /etc/pacman.d/mirrorlist ${mp}/etc/pacman.d/

	# locales
	sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' ${mp}/etc/locale.gen
	arch-chroot ${mp} locale-gen
	echo "LANG=en_US.utf-8" > ${mp}/etc/locale.conf

	# services
	cat <<-EOF > ${mp}/etc/systemd/network/default.network
[Network]
DHCP=true
EOF
	arch-chroot ${mp} systemctl enable systemd-networkd.service
	arch-chroot ${mp} systemctl enable sshd.socket
	ln -frs ${mp}/run/systemd/network/resolv.conf ${mp}/etc/resolv.conf
	ln -frs ${mp}/usr/share/zoneinfo/UTC ${mp}/etc/localtime
	cp -p ${mp}/etc/skel/.bash* ${mp}/root/
	echo 'blacklist i2c_piix4' > ${mp}/etc/modprobe.d/blacklist.conf
	echo 'kernel.kptr_restrict = 1' > ${mp}/etc/sysctl.d/90-kptr_restrict.conf
	echo 'kernel.dmesg_restrict = 1' > ${mp}/etc/sysctl.d/90-dmesg_restrict.conf
}

_cleanup_image() {
	find ${mp}/var/lib/pacman -maxdepth 1 -type f -delete
	find ${mp}/var/cache/pacman/pkg -type f -delete
	find ${mp}/var/log -type f -delete
	find ${mp}/usr/src -type f -name vmlinux -delete
	find ${mp}/usr/share/locale -type f -name '*.mo' -delete
	find ${mp}/usr/share/locale -type l -name '*.mo' -delete
	find ${mp}/usr/share/man -type f -name '*.gz' -delete
	find ${mp}/usr/share/man -type l -name '*.gz' -delete
	find ${mp}/usr/share/i18n/locales -type f -not -name 'en_US' -delete
	find ${mp}/usr/share/i18n/charmaps -maxdepth 1 -type f -delete
	find ${mp}/usr/share/doc -type f -delete
	find ${mp}/usr/share/zoneinfo -type f -not name UTC -delete
	find ${mp}/usr/share/kbd/consoletrans -type f -name '*.trans' -delete
	find ${mp}/usr/share/kbd/consoletrans -type f -name '*.trans' -delete
	rmdir -v ${mp}/var/log/journal
	rm -vf ${mp}/etc/machine-id
	rm -vf ${mp}/etc/fstab
	chmod o-r ${mp}/boot/initramfs-linux-lts.img
	chmod o-r ${mp}/boot/vmlinuz-linux-lts
	umount ${mp}
	rmdir ${mp}
}

function _zerofree() {
	zerofree ${loop}p1
}

function _convert() {
	qemu-img convert -p -O qed -f raw ${image} archlinux.qed
}

function _tar() {
	tar -Szcvf archlinux.tar.gz archlinux.qed && rm -vf archlinux.qed
}

function _cleanup() {
	(
	mountpoint -q ${mp} && umount ${mp} || :
	losetup -d ${loop} || :
	[ -d ${mp} ] && rmdir ${mp}
	rm -f ${image}
	) 2>&1 >/dev/null
}

_mkimage
_install
_syslinux
_customize
_mkinitcpio
_cleanup_image
_zerofree
_convert
_tar

