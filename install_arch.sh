#!/bin/bash
set -euo pipefail

EFI_LABEL="EFI"
ROOT_LABEL="ROOT"
BOOT_SIZE="512M"
FS_TYPE="ext4"
DISK=""
EFI_PART=""
ROOT_PART=""
HOSTNAME="haruhi"
USERNAME="kyon"
LOCALE="ru_RU.UTF-8"
KEYMAP="ru"
TIMEZONE="Europe/Moscow"
EDITOR="nano"

main() {
    detect_disks
    select_disk
    choose_partitioning
    mount_partitions
    enable_ntp
    install_base
    gen_fstab
    setup_chroot
    chroot_exec
    install_grub
    finish
}

detect_disks() {
    printf "[*] Доступные диски:\n"
    lsblk -dno NAME,SIZE,MODEL | while read -r line; do printf "  /dev/%s\n" "$line"; done
}

select_disk() {
    read -rp "[?] Укажите диск (например /dev/sda): " DISK
    [[ ! -b "$DISK" ]] && printf "[!] Диск не найден: %s\n" "$DISK" >&2 && return 1
}

choose_partitioning() {
    printf "\n[?] Действие с разделами:\n  [1] Использовать существующие\n  [2] Очистить и создать заново\n"
    read -rp "Выбор: " opt
    [[ "$opt" == "1" ]] && reuse_parts || create_parts
}

reuse_parts() {
    read -rp "[?] EFI раздел: " EFI_PART
    read -rp "[?] ROOT раздел: " ROOT_PART
    format "$EFI_PART" fat32 "$EFI_LABEL"
    format "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

create_parts() {
    read -rp "[!] Удалить всё на $DISK? (yes/[no]): " ok
    [[ "$ok" != "yes" ]] && return 1
    wipefs -a "$DISK"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart "$EFI_LABEL" fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart "$ROOT_LABEL" "$FS_TYPE" "$BOOT_SIZE" 100%
    sync; sleep 1
    EFI_PART=$(ls "${DISK}"* | grep -E "^${DISK}p?1$" || true)
    ROOT_PART=$(ls "${DISK}"* | grep -E "^${DISK}p?2$" || true)
    [[ -z "$EFI_PART" || -z "$ROOT_PART" ]] && printf "[!] Разделы не найдены\n" >&2 && return 1
    format "$EFI_PART" fat32 "$EFI_LABEL"
    format "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

format() {
    local part="$1" fs="$2" label="$3"
    case "$fs" in
        fat32) mkfs.fat -F32 "$part" ;;
        ext4) mkfs.ext4 -L "$label" "$part" ;;
        btrfs) mkfs.btrfs -f -L "$label" "$part" ;;
        *) printf "[!] Неизвестная ФС: %s\n" "$fs" >&2 && return 1 ;;
    esac
}

mount_partitions() {
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

enable_ntp() {
    timedatectl set-ntp true
}

install_base() {
    pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode nano git grub efibootmgr networkmanager
}

gen_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}

setup_chroot() {
    local path="/mnt/root/chroot_script.sh"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
#!/bin/bash
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#\\($LOCALE\\)/\\1/' /etc/locale.gen
sed -i 's/^#\\(en_US.UTF-8\\)/\\1/' /etc/locale.gen
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "root:5489" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:4598" | chpasswd
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
$EDITOR /etc/pacman.conf
pacman -Syu --noconfirm

pacman -S --noconfirm gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber networkmanager wine-staging winetricks lutris steam steam-native-runtime gamemode goverlay mangohud lib32-mesa lib32-libglvnd lib32-vulkan-icd-loader lib32-nvidia-utils vulkan-tools vulkan-icd-loader nvidia-dkms nvidia-utils nvidia-settings opencl-nvidia

mkdir -p /etc/modules-load.d
printf "nvidia\\nnvidia_uvm\\nnvidia_drm\\nnvidia_modeset\\n" > /etc/modules-load.d/nvidia.conf
echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf

systemctl enable NetworkManager
systemctl enable gdm

if systemctl list-unit-files | grep -q '^gamemoded.service'; then
    systemctl enable gamemoded.service
else
    printf "[!] gamemoded.service не найден, пропускаем активацию\n" >&2
fi

if [[ -f /etc/mkinitcpio.conf ]]; then
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P
else
    printf "[!] /etc/mkinitcpio.conf не найден\n" >&2
fi
EOF

    chmod +x "$path"
}

chroot_exec() {
    arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
    [[ -d /sys/firmware/efi/efivars ]] || { printf "[!] Не EFI режим\n" >&2; return 1; }
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

finish() {
    umount -R /mnt
    printf "[✓] Установка завершена. Перезагрузите систему.\n"
}

main "$@"
