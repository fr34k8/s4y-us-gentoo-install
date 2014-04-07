#!/bin/bash
mkdir -p /usr/portage
mkdir -p /usr/local/portage

source /etc/profile
env-update
export PS1="(chroot) $PS1"

# Prepare make.conf
wget https://raw.githubusercontent.com/doertedev/s4y-us-gentoo-install/master/make.conf --output-document=/etc/portage/make.conf

# Create Portage dirs
mkdir -p /etc/portage/{package.use,package.keywords,package.mask,package.unmask,package.env}

# sync portage tree
emerge-webrsync
emerge --sync

# select normal profile
eselect profile set default/linux/amd64/13.0
KERNEL="sys-kernel/gentoo-sources"

# set timezone
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data

# set locales
echo "en_US ISO-8859-1
en_US.UTF-8 UTF-8
de_DE ISO-8859-1
de_DE.UTF-8 UTF-8
de_DE@euro ISO-8859-15" >>/etc/locale.gen

locale-gen

eselect locale set en_US.UTF-8

echo 'LANG="en_US.UTF-8"
LC_COLLATE="C"' >/etc/env.d/02locale

# reload shell
env-update
source /etc/profile
export PS1="(chroot) $PS1"

# unmask kernel and genkernel and install it
echo "${KERNEL} ~amd64" >/etc/portage/package.keywords/sys-kernel
echo "sys-kernel/genkernel-next ~amd64" >>/etc/portage/package.keywords/sys-kernel
echo "sys-kernel/genkernel-next cryptsetup" >>/etc/portage/package.use/sys-kernel

emerge ${KERNEL} sys-kernel/genkernel-next mdadm cryptsetup lvm2

cd /usr/src/linux

# Get kernel config
wget https://raw.githubusercontent.com/doertedev/s4y-us-gentoo-install/master/.config --output-document=.config

# make and install
make -j9
make install modules_install

cd /root

# edit genkernel config
sed -i 's/#LVM="no"/LVM="yes"/' /etc/genkernel.conf
sed -i 's/#LUKS="no"/LUKS="yes"/' /etc/genkernel.conf
sed -i 's/#BUSYBOX="no"/BUSYBOX="yes"/' /etc/genkernel.conf
sed -i 's/#UDEV="no"/UDEV="yes"/' /etc/genkernel.conf
sed -i 's/#MDADM="no"/MDADM="yes"/' /etc/genkernel.conf
sed -i 's/#E2FSPROGS="no"/E2FSPROGS="yes"/' /etc/genkernel.conf
sed -i 's!#REAL_ROOT="/dev/one/two/gentoo"!REAL_ROOT="/dev/mapper/${lv_root}"!' /etc/genkernel.conf

# generate initramfs
genkernel initramfs

# Load vars from setup script
source doertedev_gentoo.vars

# get UUIDs from device names
uuid_boot=`blkid | grep ${boot_raid} | grep -Po '\bUUID="([^"]+)"'`
uuid_system=`blkid | grep  ${system_raid} | grep -Po '\bUUID="([^"]+)"'`
uuid_root=`blkid | grep  ${lv_root} | grep -Po '\bUUID="([^"]+)"'`
uuid_var=`blkid | grep ${lv_var} | grep -Po '\bUUID="([^"]+)"'`
uuid_storage=`blkid | grep  ${lv_storage} | grep -Po '\bUUID="([^"]+)"'`
uuid_swap=`blkid | grep  ${lv_swap} | grep -Po '\bUUID="([^"]+)"'`

# fstab
echo "${uuid_boot}       /boot            ext4        relatime                    1 2" >>/etc/fstab
echo "${uuid_root}       /                ext4        relatime                    0 1" >>/etc/fstab
echo "${uuid_home}       /home            ext4        relatime                    0 4" >>/etc/fstab
echo "${uuid_swap}       none             swap        sw                          0 0" >>/etc/fstab
echo "none               /tmp             tmpfs       rw,size=8G,nodev,noatime    0 0" >>/etc/fstab

# Set hostname
echo "hostname=\"XXXURHOSTNAMEXXX\"" >/etc/conf.d/hostname

# Network
IFACE=`udevadm test-builtin net_id /sys/class/net/eth0 2>/dev/null | grep ID_NET_NAME_PATH | awk -F= '{print $2}'`

echo "modules=( \"iproute2\" )" >/etc/conf.d/net
echo "" >>/etc/conf.d/net
echo "config_${IFACE}=\"XXXURIPXXX/24\"" >>/etc/conf.d/net
echo "routes_${IFACE}=(" >>/etc/conf.d/net
echo "    \"XXXURROUTEXXX dev ${IFACE}\"" >>/etc/conf.d/net
echo "    \"default via XXXURROUTEXXX\"" >>/etc/conf.d/net
echo ")" >>/etc/conf.d/net

cd /etc/init.d
ln -s net.lo net.${IFACE}
rc-update add net.${IFACE} default
cd /root

# Set SSH key
mkdir .ssh
echo "ssh-ed25519 XXXURKEYXXX" >.ssh/authorized_keys

# Install system tools
emerge syslog-ng sys-process/cronie logrotate iproute2
rc-update add syslog-ng default
rc-update add cronie default
rc-update add sshd default
rc-update add lvm default
rc-update add mdadm default

# Install bootloader
emerge sys-boot/grub
echo "GRUB_CMDLINE_LINUX=\"rootfstype=ext4 domdadm dolvm crypt_roots=${uuid_system} root_key=keyfile root_keydev=${uuid_boot}\"" >>/etc/default/grub
echo "GRUB_PRELOAD_MODULES=lvm" >>/etc/default/grub

grub2-install --recheck /dev/sda
grub2-mkconfig -o /boot/grub/grub.cfg

exit