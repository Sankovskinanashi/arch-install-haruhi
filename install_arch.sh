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
FAST_MODE="n"

main() {
    ask_fast_mode
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

ask_fast_mode() {
    printf "[?] Включить быстрый режим? (пропуск проверок PGP) [y/N]: "
    read -r FAST_MODE
    FAST_MODE="${FAST_MODE:-n}"
}

select_install_type() {
    printf "\n[?] Выберите тип установки:\n"
    printf "  [1] Полная (GNOME + приложения)\n"
    printf "  [2] Минимальная (базовая система)\n"
    printf "  [3] GNOME без дополнений\n"
    printf "  [4] XFCE (легковесный DE)\n"
    read -rp "Выбор [1-4]: " choice
    
    case "$choice" in
        1) INSTALL_TYPE="full" ;;
        2) INSTALL_TYPE="minimal" ;;
        3) INSTALL_TYPE="gnome" ;;
        4) INSTALL_TYPE="xfce" ;;
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

    printf "[+] Стираем разделы...\n"
    wipefs -a "$DISK" >/dev/null 2>&1
    
    printf "[+] Создаём таблицу разделов GPT...\n"
    parted -s "$DISK" mklabel gpt
    
    printf "[+] Создаём EFI раздел...\n"
    parted -s "$DISK" mkpart "$EFI_LABEL" fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    
    printf "[+] Создаём корневой раздел...\n"
    parted -s "$DISK" mkpart "$ROOT_LABEL" "$FS_TYPE" "$BOOT_SIZE" 100%
    
    sync
    
    # Определяем правильные имена разделов
    if [[ "$DISK" =~ nvme|mmc ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
    
    sleep 2

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
    printf "  [2] btrfs\n"
    printf "  [3] xfs\n"
    read -rp "Выбор [1-3]: " fs
    
    case "$fs" in
        1) FS_TYPE="ext4" ;;
        2) FS_TYPE="btrfs" ;;
        3) FS_TYPE="xfs" ;;
        *) 
            printf "[!] Неверный выбор, используем ext4\n"
            FS_TYPE="ext4"
            ;;
    esac
}

format_partition() {
    local part="$1" fstype="$2" label="$3"
    
    printf "[+] Форматируем %s в %s...\n" "$part" "$fstype"
    
    case "$fstype" in
        fat32)
            mkfs.fat -F32 -n "$label" "$part" >/dev/null 2>&1
            ;;
        ext4)
            mkfs.ext4 -L "$label" -F "$part" >/dev/null 2>&1
            ;;
        btrfs)
            mkfs.btrfs -f -L "$label" "$part" >/dev/null 2>&1
            ;;
        xfs)
            mkfs.xfs -f -L "$label" "$part" >/dev/null 2>&1
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
    
    local pacstrap_opts="--needed"
    if [[ "$FAST_MODE" =~ ^[Yy]$ ]]; then
        pacstrap_opts="$pacstrap_opts --ignore signature"
    fi
    
    # Базовые пакеты
    local packages="base base-devel linux linux-firmware sudo grub efibootmgr networkmanager"
    
    # Определяем процессор
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        packages="$packages intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        packages="$packages amd-ucode"
    fi
    
    # Добавляем полезные утилиты
    packages="$packages nano vim git wget curl htop"
    
    printf "[*] Устанавливаем: %s\n" "$packages"
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

# Настраиваем локализацию
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen

# Устанавливаем часовой пояс
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Настраиваем имя хоста
echo "haruhi" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
HOSTS

# Создаём пользователя
useradd -m -G wheel,storage,power -s /bin/bash kyon
echo "Установите пароль для root:"
until passwd; do
    echo "Попробуйте ещё раз:"
done
echo "Установите пароль для пользователя kyon:"
until passwd kyon; do
    echo "Попробуйте ещё раз:"
done

# Настраиваем sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Настраиваем pacman для быстрой загрузки
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

# Обновляем систему
if [[ -f /tmp/fast_mode && $(cat /tmp/fast_mode) == "y" ]]; then
    pacman -Syu --noconfirm --ignore signature --needed
else
    pacman -Syu --noconfirm --needed
fi

# Устанавливаем базовые утилиты
base_packages="bash-completion git wget curl htop"
pacman -S --noconfirm --needed $base_packages

# Определяем тип установки
INSTALL_TYPE=$(cat /tmp/install_type 2>/dev/null || echo "minimal")

case "$INSTALL_TYPE" in
    "full")
        echo "[*] Устанавливаем полное окружение GNOME..."
        
        gnome_packages="xorg xorg-server gnome gnome-extra gdm network-manager-applet"
        gnome_packages="$gnome_packages firefox vlc gimp libreoffice-fresh"
        
        pacman -S --noconfirm --needed $gnome_packages
        
        # Установка AUR помощника
        echo "[*] Устанавливаем yay из AUR..."
        cd /tmp
        git clone https://aur.archlinux.org/yay.git
        cd yay
        chown -R kyon:kyon .
        sudo -u kyon makepkg -si --noconfirm
        
        # AUR пакеты (опционально)
        echo "[*] Устанавливаем дополнительные пакеты из AUR..."
        aur_packages="visual-studio-code-bin google-chrome"
        sudo -u kyon yay -S --noconfirm $aur_packages
        
        systemctl enable gdm
        ;;
        
    "gnome")
        echo "[*] Устанавливаем GNOME..."
        
        gnome_minimal="xorg xorg-server gnome gdm"
        pacman -S --noconfirm --needed $gnome_minimal
        systemctl enable gdm
        ;;
        
    "xfce")
        echo "[*] Устанавливаем XFCE..."
        
        xfce_packages="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
        pacman -S --noconfirm --needed $xfce_packages
        systemctl enable lightdm
        ;;
        
    *)
        echo "[*] Минимальная установка (только консоль)..."
        ;;
esac

# Включаем NetworkManager
systemctl enable NetworkManager

# Установка GRUB
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH --recheck
else
    DISK_DEVICE=$(lsblk -no pkname /dev/$(mount | grep ' / ' | cut -d' ' -f1))
    grub-install --target=i386-pc "/dev/$DISK_DEVICE" --recheck
fi

grub-mkconfig -o /boot/grub/grub.cfg

# Создаём initramfs
mkinitcpio -P

echo "[✓] Настройка системы завершена!"
EOF
    
    # Сохраняем параметры для chroot
    echo "$INSTALL_TYPE" > /mnt/tmp/install_type
    echo "$FAST_MODE" > /mnt/tmp/fast_mode
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
    printf "[+] Настройка загрузчика завершена в chroot.\n"
}

cleanup_and_reboot() {
    printf "[+] Отмонтируем разделы...\n"
    umount -R /mnt 2>/dev/null || true
    
    printf "\n[✓] Установка Arch Linux завершена!\n"
    printf "\nДальнейшие действия:\n"
    printf "1. Извлеките установочный носитель\n"
    printf "2. Перезагрузите систему: reboot\n"
    printf "3. Войдите как пользователь 'kyon'\n"
    
    printf "\n[?] Перезагрузить сейчас? (y/N): "
    read -r choice
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Проверяем права root
if [[ $EUID -ne 0 ]]; then
    printf "[!] Скрипт должен запускаться от root!\n" >&2
    exit 1
fi

# Запускаем установку
main "$@"
