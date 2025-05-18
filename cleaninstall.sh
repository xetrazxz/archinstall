#!/bin/bash
set -euo pipefail

echo "== Arch Linux Auto Installer =="

# UEFI check
if [ ! -d /sys/firmware/efi ]; then
    echo " UEFI not detected. This script requires UEFI."
    exit 1
fi

# Disk selection
echo "Available drives:"
lsblk -dpno NAME,SIZE | grep -v "loop"
echo
read -rp "Enter target drive (e.g. /dev/sda or /dev/nvme0n1): " drive

if [[ ! -b "$drive" ]]; then
    echo " Invalid drive: $drive"
    exit 1
fi

# Partition mode
echo "1) Wipe all and install USE Full Space for OS"
echo "2) Wipe all and install Use Custom OS size and leave rest space"
read -rp "Choose layout (1 or 2): " partmode

if [[ "$partmode" == "2" ]]; then
    read -rp "Enter root partition size in GB (e.g. 40): " rootsize
    rootsize="+${rootsize}G"
fi

# User config
read -rp "Set root password: " rootpass
read -rp "Create username: " username
read -rp "Set password for $username: " userpass
read -rp "Set hostname: " hostname
read -rp "Keyboard layout (default: us): " keymap
keymap=${keymap:-us}

# Partitioning
echo "[*] Wiping $drive"
sgdisk --zap-all "$drive"

echo "[*] Creating partitions..."
sgdisk -n1:0:+1G -t1:ef00 -c1:EFI "$drive"
if [[ "$partmode" == "1" ]]; then
    sgdisk -n2:0:0 -t2:8300 -c2:Root "$drive"
else
    sgdisk -n2:0:"$rootsize" -t2:8300 -c2:Root "$drive"
    sgdisk -n3:0:0 -t3:8300 -c3:Extra "$drive"
fi
partprobe "$drive"
sleep 2

# Partition names
if [[ "$drive" =~ nvme ]]; then
    efi="${drive}p1"
    root="${drive}p2"
    extra="${drive}p3"
else
    efi="${drive}1"
    root="${drive}2"
    extra="${drive}3"
fi

echo "[*] Formatting partitions..."
mkfs.fat -F32 "$efi"
mkfs.btrfs -f "$root"
if [[ "$partmode" == "2" ]]; then
    mkfs.ext4 -F "$extra"
fi

# Mount root and create subvolumes
mount "$root" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var-cache
btrfs subvolume create /mnt/@var-log
umount /mnt

# Mount with compression
rotational=$(cat /sys/block/$(basename "$drive")/queue/rotational)
if [[ "$rotational" == "0" ]]; then
    opts="noatime,compress=lzo,discard=async"
else
    opts="noatime,compress=lzo"
fi

mount -o subvol=@,$opts "$root" /mnt
mkdir -p /mnt/{efi,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o subvol=@home,$opts "$root" /mnt/home
mount -o subvol=@var-cache,$opts "$root" /mnt/var/cache
mount -o subvol=@var-log,$opts "$root" /mnt/var/log
mount -o subvol=@snapshots,$opts "$root" /mnt/.snapshots
mount "$efi" /mnt/efi
if [[ "$partmode" == "2" ]]; then
    mkdir -p /mnt/drive
    mount "$extra" /mnt/drive
fi

# Base install
echo "[*] Installing base packages..."
pacstrap -K /mnt base base-devel linux linux-firmware linux-zen linux-zen-headers amd-ucode \
nano networkmanager btrfs-progs snapper grub efibootmgr zram-generator

genfstab -U /mnt >> /mnt/etc/fstab

# chroot system setup
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$keymap" > /etc/vconsole.conf

# Hostname
echo "$hostname" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
HOSTS

# Users
echo "root:$rootpass" | chpasswd
useradd -m -G wheel -s /bin/bash "$username"
echo "$username:$userpass" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99_wheel
chmod 440 /etc/sudoers.d/99_wheel

# ZRAM
mkdir -p /etc/systemd
cat <<ZCFG > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram
compression-algorithm = lzo
ZCFG

# Enable services
systemctl enable NetworkManager

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo
echo " Done! You may now reboot."
clear
echo "USE 'nmtui' in arch terminal to show networks"
