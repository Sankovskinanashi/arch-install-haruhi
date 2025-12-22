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
INSTALL_TYPE=""

main() {
    check_internet
    detect_disks
    select_disk
    select_install_type
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

select_install_type() {
    printf "\n[?] Выберите тип установки:\n"
    printf "  [1] Полная (GNOME + все приложения)\n"
    printf "  [2] Минимальная (базовая система)\n"
    printf "  [3] Только базовое окружение (без GNOME)\n"
    read -rp "Выбор [1/2/3]: " choice
    
    case "$choice" in
        1) INSTALL_TYPE="full" ;;
        2) INSTALL_TYPE="minimal" ;;
        3) INSTALL_TYPE="basic" ;;
        *) 
            printf "[!] Неверный выбор, используем минимальную установку\n"
            INSTALL_TYPE="minimal" 
            ;;
    esac
}

check_internet() {
    printf "[*] Проверка интернет-соединения...\n"
    if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
        printf "[!] Нет доступа к интернету. Настройте подключение и перезапустите установку.\n" >&2
        exit 1
    fi
    printf "[+] Интернет доступен.\n"
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
        exit 1
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
    read -rp "Выбор [1/2]: " action
    
    case "$action" in
        1) select_existing_partitions ;;
        2) wipe_and_create_partitions ;;
        *) 
            printf "[!] Неверный выбор\n" >&2
            exit 1
            ;;
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
    [[ "$confirm" != "yes" ]] && exit 1

    printf "[+] Стираем разделы на %s...\n" "$DISK"
    wipefs -a "$DISK" >/dev/null 2>&1
    
    printf "[+] Создаём новую таблицу разделов...\n"
    parted -s "$DISK" mklabel gpt
    
    printf "[+] Создаём EFI раздел...\n"
    parted -s "$DISK" mkpart "$EFI_LABEL" fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    
    printf "[+] Создаём корневой раздел...\n"
    parted -s "$DISK" mkpart "$ROOT_LABEL" "$FS_TYPE" "$BOOT_SIZE" 100%
    
    sync
    sleep 2

    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
    
    if [[ ! -b "$EFI_PART" ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    fi
    
    if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
        printf "[!] Не удалось обнаружить созданные разделы\n" >&2
        exit 1
    fi

    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

choose_filesystem() {
    local part="$1"
    printf "\n[?] Выберите файловую систему для %s:\n" "$part"
    printf "  [1] ext4 (рекомендуется)\n"
    printf "  [2] btrfs (с поддержкой снапшотов)\n"
    read -rp "Выбор [1/2]: " fs
    
    case "$fs" in
        1) FS_TYPE="ext4" ;;
        2) FS_TYPE="btrfs" ;;
        *) 
            printf "[!] Неверный выбор, используем ext4\n"
            FS_TYPE="ext4"
            ;;
    esac
}

format_partition() {
    local part="$1" fstype="$2" label="$3"
    
    case "$fstype" in
        fat32)
            printf "[+] Форматируем %s в FAT32...\n" "$part"
            mkfs.fat -F32 -n "$label" "$part" >/dev/null 2>&1
            ;;
        ext4)
            printf "[+] Форматируем %s в ext4...\n" "$part"
            mkfs.ext4 -L "$label" -F "$part" >/dev/null 2>&1
            ;;
        btrfs)
            printf "[+] Форматируем %s в Btrfs...\n" "$part"
            mkfs.btrfs -f -L "$label" "$part" >/dev/null 2>&1
            ;;
        *)
            printf "[!] Неизвестная ФС: %s\n" "$fstype" >&2
            exit 1
            ;;
    esac
}

mount_partitions() {
    printf "[+] Монтируем корневой раздел...\n"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

enable_ntp() {
    printf "[+] Включаем синхронизацию времени...\n"
    timedatectl set-ntp true >/dev/null 2>&1
}

install_base_system() {
    printf "[+] Устанавливаем базовую систему...\n"
    
    # Используем опцию для пропуска проверки подписей
    local pacstrap_opts="--needed --ignore signature"
    
    # Минимальный набор пакетов
    local packages="base base-devel linux linux-firmware nano sudo grub efibootmgr networkmanager"
    
    # Добавляем микрокод в зависимости от процессора
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        packages="$packages intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        packages="$packages amd-ucode"
    fi
    
    printf "[*] Устанавливаем пакеты: %s\n" "$packages"
    pacstrap /mnt $packages $pacstrap_opts
}

generate_fstab() {
    printf "[+] Генерируем fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    
    cat > "$script_path" <<'EOF'
#!/bin/bash
set -euo pipefail

# Устанавливаем локаль
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf
echo "FONT=cyr-sun16" >> /etc/vconsole.conf

# Настраиваем локаль
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen

# Устанавливаем часовой пояс
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc --utc

# Настраиваем имя хоста
echo "haruhi" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
HOSTS

# Создаём пользователя
useradd -m -G wheel -s /bin/bash kyon
echo "Установите пароль для root:"
passwd
echo "Установите пароль для пользователя kyon:"
passwd kyon

# Настраиваем sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Обновляем систему (пропускаем проверку подписей)
pacman -Syu --noconfirm --ignore signature

# Устанавливаем базовые утилиты
pacman -S --noconfirm --ignore signature \
    bash-completion \
    git \
    wget \
    curl \
    htop \
    neofetch \
    ntfs-3g \
    exfat-utils \
    unzip \
    unrar \
    p7zip

# Определяем тип установки
INSTALL_TYPE=$(cat /tmp/install_type 2>/dev/null || echo "minimal")

if [[ "$INSTALL_TYPE" == "full" ]]; then
    echo "[*] Устанавливаем полное окружение GNOME..."
    
    pacman -S --noconfirm --ignore signature \
        xorg xorg-server xorg-xinit xorg-xrandr xorg-xset \
        gnome gnome-extra gdm \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        firefox \
        vlc \
        gimp \
        libreoffice-fresh \
        steam \
        wine-staging \
        lutris
    
    systemctl enable gdm
    systemctl enable NetworkManager

elif [[ "$INSTALL_TYPE" == "basic" ]]; then
    echo "[*] Устанавливаем базовое X11 окружение..."
    
    pacman -S --noconfirm --ignore signature \
        xorg xorg-server xorg-xinit xorg-xrandr \
        lightdm lightdm-gtk-greeter \
        awesome \
        alacritty \
        firefox \
        thunar \
        pavucontrol
    
    systemctl enable lightdm
    systemctl enable NetworkManager

else
    echo "[*] Минимальная установка (только консоль)..."
    systemctl enable NetworkManager
fi

# Настраиваем GRUB
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
else
    grub-install --target=i386-pc "$(lsblk -no pkname /dev/sda1)" --recheck
fi

grub-mkconfig -o /boot/grub/grub.cfg

# Создаём initramfs
mkinitcpio -P

echo "[✓] Настройка системы завершена!"
EOF
    
    # Сохраняем тип установки
    echo "$INSTALL_TYPE" > /mnt/tmp/install_type
    chmod +x "$script_path"
}

run_chroot_script() {
    printf "[+] Запускаем настройку в chroot...\n"
    
    # Копируем DNS для работы в chroot
    cp /etc/resolv.conf /mnt/etc/resolv.conf
    
    # Запускаем скрипт
    arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
    printf "[+] Проверяем режим загрузки...\n"
    
    if [[ -d /sys/firmware/efi ]]; then
        printf "[+] Обнаружен UEFI режим.\n"
    else
        printf "[+] Обнаружен BIOS режим.\n"
    fi
}

cleanup_and_reboot() {
    printf "[+] Отмонтируем разделы...\n"
    umount -R /mnt 2>/dev/null || true
    
    printf "\n[✓] Установка Arch Linux завершена!\n"
    printf "\nДальнейшие действия:\n"
    printf "1. Извлеките установочный носитель\n"
    printf "2. Перезагрузите систему: reboot\n"
    
    printf "\n[?] Перезагрузить сейчас? (y/N): "
    read -r choice
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        reboot
    else
        printf "[+] Не забудьте перезагрузить систему вручную!\n"
    fi
}

# Проверяем права root
if [[ $EUID -ne 0 ]]; then
    printf "[!] Скрипт должен запускаться от root!\n" >&2
    exit 1
fi

# Запускаем установку
main "$@"
