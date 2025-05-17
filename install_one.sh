#!/bin/bash
set -e

echo "Starting full Arch install..."

# 0 - Partition disk (no labels)
echo "Partitioning disk..."
sgdisk -Z /dev/sda
sgdisk -n1:0:+1G   -t1:ef00 /dev/sda
sgdisk -n2:0:+128G -t2:8300 /dev/sda
sgdisk -n3:0:+64G  -t3:8300 /dev/sda
sgdisk -n4:0:0     -t4:8300 /dev/sda
lsblk /dev/sda

# 1 - Format and mount partitions, create subvolumes
echo "Formatting EFI and root partitions..."
mkfs.fat -F32 -n boot /dev/sda1
mkfs.btrfs -f -L archlinux /dev/sda2
mkfs.btrfs -f -L gentoo /dev/sda3
yes | mkfs.ext4 -L drive /dev/sda4

echo "Creating Btrfs subvolumes..."
mount /dev/sda2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var-cache
btrfs subvolume create /mnt/@var-log
umount /mnt

echo "Mounting subvolumes..."
mount -o noatime,compress=lzo,subvol=@ /dev/sda2 /mnt
mkdir -p /mnt/{home,root,.snapshots,var/cache,var/log,efi}

mount -o noatime,compress=lzo,subvol=@home /dev/sda2 /mnt/home
mount -o noatime,compress=lzo,subvol=@root /dev/sda2 /mnt/root
mount -o noatime,compress=lzo,subvol=@snapshots /dev/sda2 /mnt/.snapshots
mount -o noatime,compress=lzo,subvol=@var-cache /dev/sda2 /mnt/var/cache
mount -o noatime,compress=lzo,subvol=@var-log /dev/sda2 /mnt/var/log

mount /dev/sda1 /mnt/efi

# 2 - Install base system
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware btrfs-progs grub efibootmgr amd-ucode nano

# 3 - Generate fstab
echo "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab

# 4 - Chroot configuration
echo "Configuring system in chroot..."
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "archlinux" > /etc/hostname

echo "127.0.0.1   localhost" > /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   archlinux.localdomain archlinux" >> /etc/hosts

echo root:root | chpasswd

echo -e "KEYMAP=us\nFONT=lat9w-16" > /etc/vconsole.conf
EOF

# 5 - Install and configure bootloader
echo "Installing GRUB bootloader..."
arch-chroot /mnt /bin/bash <<EOF
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# 6 - Create user and enable network services
echo "Creating user and enabling network..."
arch-chroot /mnt /bin/bash <<EOF
useradd -m -G wheel xetra
echo xetra:dark | chpasswd

echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

pacman -Sy --noconfirm dhcpcd iwd
systemctl enable dhcpcd
systemctl enable iwd
EOF

echo "Installation complete! You can now reboot."

