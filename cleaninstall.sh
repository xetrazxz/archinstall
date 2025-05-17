#!/bin/bash
set -e

echo "== Arch Linux Auto Installer for AMD (UEFI only) =="

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

# List drives
lsblk
read -rp "Enter target drive (e.g. /dev/sda): " drive

echo "Partition layout:"
echo "1) Single partition (EFI + full root)"
echo "2) Separate extra partition (EFI + root + extra)"
read -rp "Select mode (1 or 2): " partmode

if [[ "$partmode" == "2" ]]; then
  read -rp "Enter root partition size in GB (e.g. 40): " rootsize_gb
  rootsize="+${rootsize_gb}G"
fi

read -rp "Enter root password: " rootpass
read -rp "Enter username: " username
read -rp "Enter password for $username: " userpass
read -rp "Enter desired hostname: " hostname
read -rp "Enter keymap (default: us): " keymap
keymap=${keymap:-us}

echo "Wiping $drive..."
retry_cmd sgdisk --zap-all "$drive"

echo "Creating partitions..."
retry_cmd sgdisk -n1:0:+1G -t1:ef00 -c1:EFI "$drive"
if [[ "$partmode" == "1" ]]; then
  retry_cmd sgdisk -n2:0:0 -t2:8300 -c2:Root "$drive"
else
  retry_cmd sgdisk -n2:0:"$rootsize" -t2:8300 -c2:Root "$drive"
  retry_cmd sgdisk -n3:0:0 -t3:8300 -c3:Extra "$drive"
fi

partprobe "$drive"
sleep 2

# Handle NVMe device partition suffix style
if [[ "$drive" =~ nvme ]]; then
  efi="${drive}p1"
  root="${drive}p2"
  extra="${drive}p3"
else
  efi="${drive}1"
  root="${drive}2"
  extra="${drive}3"
fi

echo "Formatting EFI partition..."
retry_cmd mkfs.fat -F32 "$efi"

echo "Formatting root partition with Btrfs..."
retry_cmd mkfs.btrfs -f "$root"

if [[ "$partmode" == "2" ]]; then
  echo "Formatting extra partition with ext4..."
  retry_cmd mkfs.ext4 -F "$extra"
fi

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

if [[ "$partmode" == "2" ]]; then
  mkdir -p /mnt/drive
  mount "$extra" /mnt/drive
fi

echo "Installing base system..."
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers amd-ucode nano grub efibootmgr networkmanager btrfs-progs snapper grub-btrfs

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
echo "Setting locale and keymap..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
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

snapper -c root create-config /

systemctl enable grub-btrfsd.service || echo "grub-btrfsd service not found"
EOF

echo
echo "== Installation complete! =="
echo "Hostname: $hostname"
echo "User: $username"
echo "Root: $root with Btrfs subvolumes"
echo "EFI: $efi mounted at /efi"
if [[ "$partmode" == "2" ]]; then
  echo "Extra: $extra mounted at /mnt/drive"
else
  echo "Single root partition used"
fi
echo "You can now reboot into your new system.
