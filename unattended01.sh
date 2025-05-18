#!/bin/bash
set -euo pipefail

DISK="/dev/sda"  # <-- Replace with your actual disk
EFI_PART="${DISK}1"
ARCH_PART="${DISK}2"
TEST_PART="${DISK}3"
DATA_PART="${DISK}4"

echo "=== Arch Linux Installer ==="
echo "Disk: $DISK"
echo
echo "1) Wipe entire disk and create all partitions"
echo "2) Skip wipe, format only EFI and ArchLinux partitions"
read -rp "Select option [1-2]: " CHOICE

if [[ "$CHOICE" == "1" ]]; then
    echo "!! WARNING: This will erase all data on $DISK !!"
    read -rp "Type YES to confirm: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Aborted."
        exit 1
    fi

    wipefs -a "$DISK"
    sgdisk -Z "$DISK"
    sgdisk -n 1:0:+1G     -t 1:ef00 -c 1:EFI "$DISK"
    sgdisk -n 2:0:+128G   -t 2:8300 -c 2:ArchLinux "$DISK"
    sgdisk -n 3:0:+64G    -t 3:8300 -c 3:TestOS "$DISK"
    sgdisk -n 4:0:0       -t 4:8300 -c 4:Data "$DISK"
    partprobe "$DISK"
    sleep 2
elif [[ "$CHOICE" == "2" ]]; then
    echo "Using:"
    echo " - EFI partition: $EFI_PART"
    echo " - ArchLinux partition: $ARCH_PART"
    read -rp "Continue? [y/N]: " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
else
    echo "Invalid option."
    exit 1
fi

mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$ARCH_PART"

mount "$ARCH_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o noatime,compress=lzo,subvol=@ "$ARCH_PART" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,efi}
mount -o noatime,compress=lzo,subvol=@home         "$ARCH_PART" /mnt/home
mount -o noatime,compress=lzo,subvol=@log          "$ARCH_PART" /mnt/var/log
mount -o noatime,compress=lzo,subvol=@pkg          "$ARCH_PART" /mnt/var/cache/pacman/pkg
mount -o noatime,compress=lzo,subvol=@snapshots    "$ARCH_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/efi

pacstrap /mnt base linux linux-firmware nano amd-ucode dhcpcd iwd grub efibootmgr btrfs-progs zram-generator

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<'EOF'
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "archlinux" > /etc/hostname
echo -e "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\tarchlinux.localdomain archlinux" > /etc/hosts

echo root:root | chpasswd
useradd -m -G wheel -s /bin/bash xetra
echo xetra:dark | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable dhcpcd
systemctl enable iwd

mkdir -p /etc/systemd/zram-generator.conf
cat <<ZZZ > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram
compression-algorithm = lzo
ZZZ

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo "[*] Installation complete. You can now reboot."
