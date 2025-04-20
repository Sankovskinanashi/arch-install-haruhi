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
    sync && sleep 1

    EFI_PART=$(ls "${DISK}"* | grep -E "^${DISK}p?1$" || true)
    ROOT_PART=$(ls "${DISK}"* | grep -E "^${DISK}p?2$" || true)

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
    printf "[+] Монтирование ROOT...\n"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

enable_ntp() {
    printf "[+] Включение синхронизации времени...\n"
    timedatectl set-ntp true
}

install_base_system() {
    printf "[+] Установка базовой системы...\n"
    pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware intel-ucode nano git grub efibootmgr networkmanager
}

generate_fstab() {
    printf "[+] Генерация fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    mkdir -p "$(dirname "$script_path")"

    cat > "$script_path" <<EOF
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

mkdir -p /etc/profile.d
cat > /etc/profile.d/game-performance.sh <<GAMEENV
export __GL_THREADED_OPTIMIZATIONS=1
export __GL_SYNC_TO_VBLANK=0
export __GL_SHADER_CACHE=1
export __GL_SHADER_DISK_CACHE=1
export __GL_YIELD="USLEEP"
export MANGOHUD=1
export DXVK_HUD=0
export VKD3D_CONFIG=dxr11
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
export VK_LAYER_PATH=/usr/share/vulkan/implicit_layer.d
GAMEENV
chmod +x /etc/profile.d/game-performance.sh

mkdir -p /etc/modules-load.d
printf "nvidia\\nnvidia_uvm\\nnvidia_drm\\nnvidia_modeset\\n" > /etc/modules-load.d/nvidia.conf

mkdir -p /etc/modprobe.d
echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf

cat > /etc/systemd/system/set-governor.service <<'GOVERNOR'
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'shopt -s nullglob; for c in /sys/devices/system/cpu/cpufreq/policy*; do echo performance > "\${c}/scaling_governor"; done; shopt -u nullglob'

[Install]
WantedBy=multi-user.target
GOVERNOR

systemctl enable NetworkManager
systemctl enable gdm

if systemctl list-unit-files | grep -q '^gamemoded.service'; then
    systemctl enable gamemoded.service
else
    printf "[!] gamemoded.service не найден, пропускаем активацию\n" >&2
fi

systemctl enable set-governor.service

if [[ -f /etc/mkinitcpio.conf ]]; then
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P
else
    printf "[!] Файл /etc/mkinitcpio.conf не найден. Пропускаем сборку ядра.\n" >&2
fi
EOF

    chmod +x "$script_path"
}



run_chroot_script() {
    printf "[+] Запуск конфигурации в chroot...\n"
    arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        printf "[+] UEFI режим обнаружен. Установка GRUB...\n"
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    else
        printf "[!] Система загружена в режиме BIOS. Установка невозможна.\n" >&2
        return 1
    fi
}

cleanup_and_reboot() {
    printf "[+] Отмонтирование /mnt...\n"
    umount -R /mnt
    printf "[✓] Установка завершена. Перезагрузите систему вручную.\n"
}

main "$@"
