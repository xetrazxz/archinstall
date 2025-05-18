#!/bin/bash
set -e

echo "
==================================================
    A R C H   D U A L B O O T   I N S T A L L E R
==================================================
"

# Check for UEFI
if [ ! -d /sys/firmware/efi ]; then
  echo "Error: This script is for UEFI systems only."
  exit 1
fi

retry_cmd() {
  local n=0
  local max=3
  local delay=2
  until "$@"; do
    n=$((n+1))
    if [ $n -ge $max ]; then
      echo "Command failed after $n attempts: $*"
      exit 1
    fi
    echo "Command failed: $*. Retrying in $delay seconds... ($n/$max)"
    sleep $delay
  done
}

echo "Detecting EFI partitions (FAT32 with boot or esp flags)..."
mapfile -t efi_partitions < <(lsblk -o NAME,FSTYPE,MOUNTPOINT,PARTFLAGS -nr | \
  awk '$2=="vfat" && ($4 ~ /boot/ || $4 ~ /esp/) {print "/dev/"$1}')

if [ ${#efi_partitions[@]} -eq 0 ]; then
  echo "No EFI partition detected automatically."
  lsblk -f
  read -rp "Enter EFI partition manually (e.g. /dev/sda1): " efi
else
  echo "EFI partitions found:"
  for i in "${!efi_partitions[@]}"; do
    echo "[$i] ${efi_partitions[$i]}"
  done
  if [ ${#efi_partitions[@]} -eq 1 ]; then
    efi="${efi_partitions[0]}"
    echo "Using EFI partition: $efi"
  else
    read -rp "Select EFI partition index: " idx
    efi="${efi_partitions[$idx]}"
  fi
fi

fs_type=$(lsblk -no FSTYPE "$efi")
if [[ "$fs_type" != "vfat" ]]; then
  echo "Warning: Selected EFI partition $efi is not FAT32 (vfat). Proceed carefully."
fi

drive=$(lsblk -no PKNAME "$efi")
drive="/dev/$drive"

echo "Target drive detected as $drive"

echo "Choose root partition (will be formatted as Btrfs):"
lsblk -f "$drive"
read -rp "Enter root partition (e.g. /dev/sda2): " root

if [[ -z "$root" ]]; then
  echo "Root partition is required."
  exit 1
fi

read -rp "Enter root password: " rootpass
read -rp "Enter username: " username
read -rp "Enter password for $username: " userpass
read -rp "Enter desired hostname: " hostname
read -rp "Enter keymap (default: us): " keymap
keymap=${keymap:-us}

echo "Formatting root partition with Btrfs..."
retry_cmd mkfs.btrfs -f "$root"

drive_base=$(basename "$drive")
rotational=$(cat /sys/block/"$drive_base"/queue/rotational)
if [[ "$rotational" == "0" ]]; then
  btrfs_opts="noatime,compress=lzo,discard=async"
else
  btrfs_opts="noatime,compress=lzo"
fi

mount -o subvol=@,$btrfs_opts "$root" /mnt
mkdir -p /mnt/{boot,efi,home,var/log,var/cache/pacman/pkg,.snapshots}
mount -o subvol=@home,$btrfs_opts "$root" /mnt/home
mount -o subvol=@log,$btrfs_opts "$root" /mnt/var/log
mount -o subvol=@pkg,$btrfs_opts "$root" /mnt/var/cache/pacman/pkg
mount -o subvol=@snapshots,$btrfs_opts "$root" /mnt/.snapshots
mount "$efi" /mnt/efi

echo "Installing base system..."
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers amd-ucode nano grub efibootmgr networkmanager btrfs-progs snapper grub-btrfs

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
echo "Setting locale and keymap..."
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$keymap" > /etc/vconsole.conf

echo "$hostname" > /etc/hostname
echo "127.0.0.1   localhost" > /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   $hostname.localdomain $hostname" >> /etc/hosts

echo "root:$rootpass" | chpasswd

useradd -m -G wheel -s /bin/bash "$username"
echo "$username:$userpass" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99_wheel
chmod 440 /etc/sudoers.d/99_wheel

systemctl enable NetworkManager

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo "ZRAM Setup"

arch-chroot /mnt /bin/bash <<EOF
pacman -Sy zram-generator
echo "[zram0]" > /etc/systemd/zram-generator.conf
echo "zram-size = ram" >> etc/systemd/zram-generator.conf
echo "compression-algorithm = zstd" >> etc/systemd/zram-generator.conf

echo "vm.swappiness = 180" > /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_boost_factor = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_scale_factor = 125" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.page-cluster = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf
EOF

echo
echo "== Installation complete! =="
echo "Hostname: $hostname"
echo "User: $username"
echo "Root: $root with Btrfs subvolumes"
echo "EFI: $efi mounted at /efi (not formatted)"
echo "Please reboot into your new system."
echo "Use nmtui in terminal to use wifi"
