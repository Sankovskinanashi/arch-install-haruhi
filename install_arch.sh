#!/bin/bash
set -euo pipefail

# Конфигурационные переменные
EFI_LABEL="EFI"
ROOT_LABEL="ARCH"
BOOT_SIZE="512M"
FS_TYPE="ext4"
DISK=""
EFI_PART=""
ROOT_PART=""
HOSTNAME="archlinux"
USERNAME="user"
LOCALE="ru_RU.UTF-8"
KEYMAP="ru"
TIMEZONE="Europe/Moscow"
CPU_VENDOR=""
GPU_VENDOR=""
INSTALL_AMD_DRIVERS=false
INSTALL_NVIDIA_DRIVERS=false
INSTALL_TYPE=""

# Проверка наличия интернета
check_internet() {
    printf "[*] Проверка интернет-соединения...\n"
    if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
        printf "[!] Нет доступа к интернету. Настройте подключение и перезапустите установку.\n" >&2
        exit 1
    fi
    printf "[+] Интернет доступен.\n"
}

# Определение железа
detect_hardware() {
    CPU_VENDOR=$(lscpu | grep -i "vendor id" | awk '{print $3}' 2>/dev/null || echo "unknown")
    GPU_VENDOR=$(lspci | grep -i "vga\|3d\|display" | awk -F: '{print $3}' | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "unknown")
    
    [[ "$GPU_VENDOR" == *"nvidia"* ]] && INSTALL_NVIDIA_DRIVERS=true
    [[ "$GPU_VENDOR" == *"amd"* || "$GPU_VENDOR" == *"radeon"* ]] && INSTALL_AMD_DRIVERS=true
    
    printf "[*] Определено оборудование:\n"
    printf "    CPU: %s\n" "$CPU_VENDOR"
    printf "    GPU: %s\n" "$GPU_VENDOR"
}

# Выбор типа установки
select_install_type() {
    printf "\n[?] Выберите тип установки:\n"
    printf "  [1] GNOME (полноценное окружение рабочего стола)\n"
    printf "  [2] Минимальный Arch (только базовая система)\n"
    
    while true; do
        read -rp "Ваш выбор [1/2]: " install_choice
        case "$install_choice" in
            1) INSTALL_TYPE="gnome"; break ;;
            2) INSTALL_TYPE="minimal"; break ;;
            *) printf "[!] Неверный выбор\n" >&2 ;;
        esac
    done
    printf "[+] Выбрано: %s\n" "$INSTALL_TYPE"
}

# Выбор диска
select_disk() {
    printf "\n[*] Доступные диски:\n"
    lsblk -dno NAME,SIZE,MODEL -e 7,11 | while read -r line; do
        printf "  /dev/%s\n" "$line"
    done
    
    while true; do
        read -rp "[?] Укажите диск для установки (например /dev/sda): " DISK
        if [[ ! -b "$DISK" ]]; then
            printf "[!] Указанный диск не существует: %s\n" "$DISK" >&2
        else
            break
        fi
    done
}

# Функция для удаления и создания разделов
wipe_and_create_partitions() {
    printf "[!] Все данные на %s будут удалены!\n" "$DISK"
    read -rp "Продолжить? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 1

    # Очистка диска
    wipefs -a "$DISK" >/dev/null 2>&1
    parted -s "$DISK" mklabel gpt

    # Создание разделов
    parted -s "$DISK" mkpart "$EFI_LABEL" fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart "$ROOT_LABEL" "$FS_TYPE" "$BOOT_SIZE" 100%

    sync
    sleep 2

    # Определение разделов
    if [[ "$DISK" =~ "nvme" ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi

    if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
        printf "[!] Не удалось обнаружить созданные разделы\n" >&2
        return 1
    fi

    # Форматирование разделов
    printf "[+] Форматирование %s в FAT32...\n" "$EFI_PART"
    mkfs.fat -F32 -n "$EFI_LABEL" "$EFI_PART"
    
    printf "[+] Форматирование %s в %s...\n" "$ROOT_PART" "$FS_TYPE"
    case "$FS_TYPE" in
        ext4) mkfs.ext4 -L "$ROOT_LABEL" "$ROOT_PART" ;;
        btrfs) mkfs.btrfs -f -L "$ROOT_LABEL" "$ROOT_PART" ;;
        xfs) mkfs.xfs -f -L "$ROOT_LABEL" "$ROOT_PART" ;;
    esac
}

# Монтирование разделов
mount_partitions() {
    printf "\n[+] Монтирование корневого раздела...\n"
    mount "$ROOT_PART" /mnt
    
    printf "[+] Создание EFI директории...\n"
    mkdir -p /mnt/boot/efi
    
    printf "[+] Монтирование EFI раздела...\n"
    mount "$EFI_PART" /mnt/boot/efi
}

# Установка базовой системы
install_base_system() {
    local packages="base base-devel linux linux-firmware nano git grub efibootmgr networkmanager"
    
    # Добавление микрокода в зависимости от процессора
    case "$CPU_VENDOR" in
        GenuineIntel) packages+=" intel-ucode" ;;
        AuthenticAMD) packages+=" amd-ucode" ;;
    esac
    
    printf "\n[+] Установка базовой системы...\n"
    pacstrap /mnt $packages
}

# Генерация fstab
generate_fstab() {
    printf "\n[+] Генерация fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
}

# Скрипт для chroot
create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    
    # Определение драйверов для GNOME
    local gpu_drivers=""
    if [[ "$INSTALL_TYPE" == "gnome" ]]; then
        gpu_drivers="mesa libva-mesa-driver"
        [[ "$INSTALL_AMD_DRIVERS" == true ]] && gpu_drivers+=" vulkan-radeon libva-mesa-driver"
        [[ "$INSTALL_NVIDIA_DRIVERS" == true ]] && gpu_drivers+=" nvidia nvidia-utils nvidia-settings"
    fi
    
    cat > "$script_path" <<EOF
#!/bin/bash
set -euo pipefail

# Настройка времени
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Локализация
sed -i "s/^#\\($LOCALE\\)/\\1/" /etc/locale.gen
sed -i "s/^#\\(en_US.UTF-8\\)/\\1/" /etc/locale.gen
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Сетевые настройки
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Пользователи
echo "Установка пароля root:"
until passwd; do
    echo "Попробуйте снова"
done

useradd -m -G wheel -s /bin/bash $USERNAME
echo "Установка пароля для $USERNAME:"
until passwd $USERNAME; do
    echo "Попробуйте снова"
done

# Настройка sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Активация multilib
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Sy

# Обновление системы
pacman -Syu --noconfirm

# Установка дополнительных системных пакетов
pacman -S --noconfirm openssh sudo

# Установка выбранного типа системы
if [[ "$INSTALL_TYPE" == "gnome" ]]; then
    printf "\n[+] Установка GNOME...\n"
    pacman -S --noconfirm gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber xdg-user-dirs $gpu_drivers
    pacman -S --noconfirm firefox libreoffice-fresh gimp vlc
    
    # Включение служб
    systemctl enable gdm
    systemctl enable NetworkManager
    
    # Настройка Wayland для NVIDIA
    if [[ "$INSTALL_NVIDIA_DRIVERS" == true ]]; then
        echo "Добавление Wayland для NVIDIA в GDM..."
        [ -f /etc/gdm/custom.conf ] && sed -i 's/^#WaylandEnable=false/WaylandEnable=true/' /etc/gdm/custom.conf
    fi
    
elif [[ "$INSTALL_TYPE" == "minimal" ]]; then
    printf "\n[+] Установка минимальной системы...\n"
    # Дополнительные пакеты для минимальной системы
    pacman -S --noconfirm sudo vi openssh
    
    # Включение служб
    systemctl enable NetworkManager
fi

# Включение служб
systemctl enable sshd

# Установка GRUB
printf "\n[+] Установка GRUB...\n"
if mount | grep -q '/boot/efi'; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "[!] Ошибка: EFI раздел не смонтирован!"
    exit 1
fi

# Завершение
echo "[+] Установка завершена!"
EOF

    chmod +x "$script_path"
}

# Запуск скрипта в chroot
run_chroot_script() {
    printf "\n[+] Выполнение конфигурации в chroot...\n"
    arch-chroot /mnt /root/chroot_script.sh
}

# Завершение установки
cleanup_and_reboot() {
    printf "\n[+] Отмонтирование разделов...\n"
    umount -R /mnt
    
    printf "\n[✓] Установка завершена!\n"
    if [[ "$INSTALL_TYPE" == "gnome" ]]; then
        printf "    Система перезагрузится в графическое окружение GNOME\n"
    else
        printf "    После перезагрузки войдите в систему с помощью вашего имени пользователя и пароля\n"
    fi
    
    read -rp "Перезагрузить систему сейчас? (y/N): " reboot_confirm
    if [[ "$reboot_confirm" == "y" || "$reboot_confirm" == "Y" ]]; then
        reboot
    else
        printf "Вы можете перезагрузить систему вручную командой: reboot\n"
    fi
}

# Основной процесс
main() {
    printf "=== Установщик Arch Linux ===\n\n"
    
    # Запрос имени пользователя и хоста
    read -rp "Введите имя хоста (по умолчанию: $HOSTNAME): " input_hostname
    [[ -n "$input_hostname" ]] && HOSTNAME="$input_hostname"
    
    read -rp "Введите имя пользователя (по умолчанию: $USERNAME): " input_username
    [[ -n "$input_username" ]] && USERNAME="$input_username"
    
    check_internet
    detect_hardware
    select_install_type
    select_disk
    wipe_and_create_partitions
    mount_partitions
    install_base_system
    generate_fstab
    create_chroot_script
    run_chroot_script
    cleanup_and_reboot
}

main "$@"
