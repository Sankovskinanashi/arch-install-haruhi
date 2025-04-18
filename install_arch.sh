#!/bin/bash
set -euo pipefail

EFI_LABEL="EFI"
ROOT_LABEL="ROOT"
BOOT_SIZE="512MiB"
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
    list_partitions
    prompt_partition_action
    mount_partitions
    enable_ntp
    install_base_system
    generate_fstab
    create_chroot_script
    run_chroot_script
    install_grub
    cleanup_and_reboot
}

detect_disks() {
    printf "[*] Доступные диски:\n"
    lsblk -dno NAME,SIZE,MODEL | while read -r line; do
        printf "  /dev/%s\n" "$line"
    done
}

select_disk() {
    read -rp "[?] Укажите диск для установки (например /dev/sda): " DISK
    if [[ ! -b "$DISK" ]]; then
        printf "[!] Указанный диск не существует: %s\n" "$DISK" >&2
        return 1
    fi
}

list_partitions() {
    printf "\n[*] Существующие разделы на %s:\n" "$DISK"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
}

prompt_partition_action() {
    printf "\n[?] Что вы хотите сделать с разделами?\n"
    printf "  [1] Использовать существующие\n"
    printf "  [2] Удалить все и создать заново\n"
    read -rp "Выбор: " action
    case "$action" in
        1) select_existing_partitions ;;
        2) wipe_and_create_partitions ;;
        *) printf "[!] Неверный выбор\n" >&2; return 1 ;;
    esac
}

select_existing_partitions() {
    read -rp "[?] Укажите EFI раздел (например /dev/sda1): " EFI_PART
    read -rp "[?] Укажите ROOT раздел (например /dev/sda2): " ROOT_PART
    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

wipe_and_create_partitions() {
    printf "[!] Все данные на %s будут удалены!\n" "$DISK"
    read -rp "Продолжить? (yes/[no]): " confirm
    [[ "$confirm" != "yes" ]] && return 1

    wipefs -a "$DISK"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart "$EFI_LABEL" fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart "$ROOT_LABEL" "$FS_TYPE" "$BOOT_SIZE" 100%
    partprobe "$DISK"
    sleep 2

    EFI_PART=$(lsblk -rno NAME "$DISK" | grep -E '^.+1$' | sed "s|^|/dev/|")
    ROOT_PART=$(lsblk -rno NAME "$DISK" | grep -E '^.+2$' | sed "s|^|/dev/|")

    if [[ -z "$EFI_PART" || -z "$ROOT_PART" ]]; then
        printf "[!] Не удалось обнаружить созданные разделы\n" >&2
        return 1
    fi

    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

choose_filesystem() {
    local part="$1"
    printf "\n[?] Выберите файловую систему для %s:\n" "$part"
    printf "  [1] ext4\n"
    printf "  [2] btrfs\n"
    read -rp "Выбор: " fs
    case "$fs" in
        1) FS_TYPE="ext4" ;;
        2) FS_TYPE="btrfs" ;;
        *) printf "[!] Неверный выбор\n" >&2; return 1 ;;
    esac
}

format_partition() {
    local part="$1" fstype="$2" label="$3"
    case "$fstype" in
        fat32)
            printf "[+] Форматирование %s в FAT32...\n" "$part"
            mkfs.fat -F32 "$part" || return 1
            ;;
        ext4)
            printf "[+] Форматирование %s в ext4...\n" "$part"
            mkfs.ext4 -L "$label" "$part" || return 1
            ;;
        btrfs)
            printf "[+] Форматирование %s в Btrfs...\n" "$part"
            mkfs.btrfs -f -L "$label" "$part" || return 1
            ;;
        *)
            printf "[!] Неизвестная ФС: %s\n" "$fstype" >&2
            return 1
            ;;
    esac
}

mount_partitions() {
    printf "[+] Монтирование ROOT (%s)...\n" "$ROOT_PART"
    mount "$ROOT_PART" /mnt

    printf "[+] Монтирование EFI (%s)...\n" "$EFI_PART"
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

enable_ntp() {
    timedatectl set-ntp true
}

install_base_system() {
    pacstrap /mnt base base-devel linux linux-firmware \
        intel-ucode nvidia nvidia-utils nvidia-dkms \
        xorg xorg-xinit gnome gdm \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        networkmanager network-manager-applet \
        steam lutris wine xorg-xrandr \
        acpilight xorg-xbacklight brightnessctl
}

generate_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
    cat > /mnt/root/chroot_script.sh <<EOF
#!/bin/bash
set -euo pipefail

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

passwd
useradd -m -G wheel,video -s /bin/bash ${USERNAME}
passwd ${USERNAME}
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

pacman -Syu --noconfirm
runuser -u ${USERNAME} -- bash -c '
cd /home/${USERNAME}
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
yay -S --noconfirm visual-studio-code-bin discord
'

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.mozilla.firefox org.telegram.desktop \
  md.obsidian.Obsidian com.obsproject.Studio org.kde.krita \
  org.gnome.Extensions org.libreoffice.LibreOffice

mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/90-backlight.rules <<UDEV
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
UDEV

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-nvidia.conf <<XORG
Section "Device"
  Identifier "Nvidia Card"
  Driver "nvidia"
EndSection
XORG

systemctl enable NetworkManager
systemctl enable gdm
EOF

    chmod +x /mnt/root/chroot_script.sh
}

run_chroot_script() {
    arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

cleanup_and_reboot() {
    umount -R /mnt
    printf "[✓] Установка завершена. Перезагрузите систему.\n"
}

main "$@"
