#!/bin/bash
PWD=`pwd`
RAID_BOOT=""
RAID_SYSTEM=""

if [ ! -f $PWD/.config ]; then
	echo "Gimme a frikkin kernel config!"
	exit 1
fi

# Test for tools
TOOLS="sgdisk mdadm openssl cryptsetup pvcreate vgcreate lvcreate mkfs.ext4 mkswap mount wget chroot"
for tool in $TOOLS; do
	available=`which $tool`
	if [ "x${tool}" = "x" ]; then
		echo "necessary tool $tool not found! INSTALL!"
		exit 1
	fi
done

sgdisk=`which sgdisk`
mdadm=`which mdadm`
openssl=`which openssl`
cryptsetup=`which cryptsetup`
pvcreate=`which pvcreate`
vgcreate=`which vgcreate`
lvcreate=`which lvcreate`
mkfs=`which mkfs.ext4`
mkswap=`which mkswap`
mkdir=`which mkdir`
mount=`which mount`
wget=`which wget`
chroot=`which chroot`

boot_parts=""
system_parts=""

DISKS="/dev/sda /dev/sdb"

# partition disks
disknr=0
for disk in $DISKS; do

	partitionnr=1

	$sgdisk --clear --set-alignment=2048 --mbrtogpt $disk

	$sgdisk --new=$partitionnr:2048:+4M $disk

	$sgdisk --typecode=$partitionnr:ef02 $disk

	(( partitionnr++ ))

	$sgdisk --new=$partitionnr:10240:+102M $disk

	$sgdisk --typecode=$partitionnr:fd00 $disk

	boot_parts="${boot_parts} ${disk}${partitionnr}"

	(( partitionnr++ ))

	$sgdisk --largest-new=$partitionnr $disk

	$sgdisk --typecode=$partitionnr:fd00 $disk

	system_parts="${system_parts} ${disk}${partitionnr}"

	echo "disk layout for ${disk}:"
	$sgdisk --print $disk

	(( disknr++ ))
done

echo "partitions for boot raid: ${boot_parts}"
echo "partitions for root raid: ${system_parts}"

mdadm --zero-superblock /dev/sda2
mdadm --zero-superblock /dev/sdb2

# Create raids
raidnr=0
boot_raid=""
while [[ -z $boot_raid  ]]; do
	if [ ! -e "/dev/md${raidnr}" ]; then
		boot_raid="/dev/md${raidnr}"
	fi
	(( raidnr++ ))
	if (( r > 127 )); then
		echo "no raid device found!"
		exit 1;
	fi
done
udevadm control --stop-exec-queue
$mdadm --create $boot_raid --raid-devices=2 --level=1 --metadata=0.9 $boot_parts
udevadm control --start-exec-queue

if [ $? != 0 ]; then
	exit 1
fi

mdadm --zero-superblock /dev/sda3
mdadm --zero-superblock /dev/sdb3

system_raid=""
while [[ -z $system_raid  ]]; do
	if [ ! -e "/dev/md${raidnr}" ]; then
		system_raid="/dev/md${raidnr}"
	fi
	(( raidnr++ ))
	if (( raidnr > 127 )); then
		echo "no raid device found!"
		exit 1;
	fi
done
udevadm control --stop-exec-queue
$mdadm --create $system_raid --raid-devices=2 --level=1 $system_parts
udevadm control --start-exec-queue

if [ $? != 0 ]; then
	exit 1
fi

# Generate keyfile for system LUKS
$openssl rand -base64 48 >keyfile
if [ $? != 0 ]; then
	exit 1
fi

# Setup luks
$cryptsetup --cipher=aes-xts-plain64 --key-size=512 --hash=sha512  --iter-time=5000 --use-random --batch-mode --key-file=$PWD/keyfile luksFormat $system_raid
if [ $? != 0 ]; then
	exit 1
fi
$cryptsetup --key-file=$PWD/keyfile luksOpen $system_raid system
if [ $? != 0 ]; then
	exit 1
fi

system_luks="/dev/mapper/system"

# Setup LVM
$pvcreate $system_luks

system_vg="vg0"
$vgcreate $system_vg $system_luks

$lvcreate --name=swap --size=4G $system_vg
$lvcreate --name=root --size=50G $system_vg
$lvcreate --name=home --extents=100%FREE $system_vg
lv_swap="/dev/mapper/${system_vg}-swap"
lv_root="/dev/mapper/${system_vg}-root"
lv_home="/dev/mapper/${system_vg}-home"

# Setup filesystems
$mkfs -L boot $boot_raid
$mkfs -L root $lv_root
$mkfs -L home $lv_home
$mkswap -L swap $lv_swap

# Mount devices
$mkdir -p /mnt/gentoo

$mount $lv_root /mnt/gentoo
$mkdir -p /mnt/gentoo/{boot,home}

$mount $boot_raid /mnt/gentoo/boot
$mount $lv_home /mnt/gentoo/home

mv keyfile /mnt/gentoo/boot/keyfile

# Get stage3 - They just pinged the fastest...
cd /mnt/gentoo
$wget http://gentoo.mirrors.pair.com/releases/amd64/current-iso/stage3-amd64-20140403.tar.bz2
tar xjpf stage3-amd64-20140403.tar.bz2

# Prepare chroot
$mount -t proc none /mnt/gentoo/proc
$mount --rbind /dev /mnt/gentoo/dev
$mount --rbind /sys /mnt/gentoo/sys
cp -L /etc/resolv.conf /mnt/gentoo/etc/resolv.conf

# Export vars for chroot
echo "boot_raid=\"${boot_raid}\"
system_raid=\"${system_raid}\"
lv_root=\"${lv_root}\"
lv_home=\"${lv_home}\"
lv_swap=\"${lv_swap}\"" >> $PWD/configvars.sh

cp $PWD/configvars.sh /mnt/gentoo/root/
cp $PWD/.config /mnt/gentoo/root/
cp $PWD/make.conf /mnt/gentoo/root/
cp $PWD/setup_postchroot.sh /mnt/gentoo/root/

# chroot
$chroot /mnt/gentoo /root/setup_postchroot.sh