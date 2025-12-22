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
INSTALL_TYPE=""

main() {
    check_internet
    update_pacman_keys  # Обновляем ключи в самом начале
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

# Функция для обновления PGP ключей
update_pacman_keys() {
    printf "[+] Обновление ключей Arch Linux...\n"
    
    # Убедимся, что база ключей инициализирована
    if [[ ! -d /etc/pacman.d/gnupg ]]; then
        printf "[*] Инициализация базы ключей...\n"
        pacman-key --init
    fi
    
    # Популируем ключи Arch
    printf "[*] Импорт ключей Arch Linux...\n"
    pacman-key --populate archlinux || {
        printf "[!] Не удалось импортировать ключи, пробуем принудительно...\n"
        pacman-key --init
        pacman-key --populate archlinux
    }
    
    # Обновляем ключевую базу
    printf "[*] Обновление archlinux-keyring...\n"
    pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
    
    # Обновляем ключи из сети
    printf "[*] Обновление ключей из сети...\n"
    pacman-key --refresh-keys 2>/dev/null || {
        printf "[*] Пропускаем обновление из сети (может не быть интернета)...\n"
    }
    
    # Проверяем ключи
    printf "[*] Проверка целостности ключей...\n"
    if ! pacman-key --list-sigs >/dev/null 2>&1; then
        printf "[!] Проблема с ключами. Пробуем исправить...\n"
        rm -rf /etc/pacman.d/gnupg
        pacman-key --init
        pacman-key --populate archlinux
    fi
    
    printf "[✓] Ключи обновлены\n"
}

# Функция для безопасной установки пакетов
safe_pacstrap() {
    local packages="$1"
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        printf "[*] Попытка установки пакетов ($((retry_count + 1))/$max_retries)...\n"
        
        if pacstrap -c /mnt $packages; then
            printf "[✓] Пакеты успешно установлены\n"
            return 0
        else
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                printf "[!] Ошибка установки. Повторная попытка через 5 секунд...\n"
                sleep 5
                
                # Обновляем ключи перед повторной попыткой
                printf "[*] Обновление ключей перед повторной попыткой...\n"
                pacman-key --refresh-keys 2>/dev/null || true
                pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true
            fi
        fi
    done
    
    printf "[!] Не удалось установить пакеты после $max_retries попыток\n"
    printf "[i] Попробуйте установить вручную с опцией --ignore signature:\n"
    printf "    pacstrap -c /mnt $packages --ignore signature\n"
    printf "[?] Продолжить с игнорированием подписей? (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        pacstrap -c /mnt $packages --ignore signature
    else
        printf "[!] Установка прервана\n"
        exit 1
    fi
}

select_install_type() {
    printf "\n[?] Выберите тип установки:\n"
    printf "  [1] Полная (GNOME + все приложения)\n"
    printf "  [2] Минимальная (базовая система)\n"
    read -rp "Выбор [1/2]: " choice
    
    case "$choice" in
        1) INSTALL_TYPE="full" ;;
        2) INSTALL_TYPE="minimal" ;;
        *) 
            printf "[!] Неверный выбор, используем полную установку\n"
            INSTALL_TYPE="full" 
            ;;
    esac
}

check_internet() {
    printf "[*] Проверка интернет-соединения...\n"
    if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
        printf "[!] Нет доступа к интернету. Настройте подключение и перезапустите установку.\n" >&2
        printf "[i] Подключение Wi-Fi: iwctl\n" >&2
        printf "[i] Подключение Ethernet: systemctl start dhcpcd или ip link set <интерфейс> up\n" >&2
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

    sync
    sleep 1

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
    printf "[+] Монтирование корневого раздела...\n"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

enable_ntp() {
    printf "[+] Включение синхронизации времени...\n"
    timedatectl set-ntp true
}

install_base_system() {
    local packages="base base-devel linux linux-firmware nano git grub efibootmgr networkmanager"
    
    if [ "$INSTALL_TYPE" = "full" ]; then
        packages+=" intel-ucode"
    fi

    printf "[+] Установка базовой системы...\n"
    safe_pacstrap "$packages"
}

generate_fstab() {
    printf "[+] Генерация fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    cat > "$script_path" <<'EOF'
#!/bin/bash
set -euo pipefail

# Функция для обновления ключей в chroot
update_chroot_keys() {
    printf "[*] Обновление ключей в установленной системе...\n"
    
    # Устанавливаем archlinux-keyring
    pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || {
        printf "[!] Не удалось установить archlinux-keyring, пробуем другой способ...\n"
        pacman-key --init
        pacman-key --populate archlinux
    }
    
    # Обновляем ключи
    pacman-key --refresh-keys 2>/dev/null || true
    
    printf "[✓] Ключи обновлены\n"
}

# Функция для безопасной установки пакетов в chroot
safe_pacman_install() {
    local packages="$1"
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        printf "[*] Попытка установки ($((retry_count + 1))/$max_retries)...\n"
        
        if pacman -S --noconfirm $packages; then
            printf "[✓] Пакеты установлены успешно\n"
            return 0
        else
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                printf "[!] Ошибка установки. Обновление ключей и повтор...\n"
                update_chroot_keys
                sleep 2
            fi
        fi
    done
    
    printf "[!] Не удалось установить пакеты после $max_retries попыток\n"
    printf "[?] Продолжить с игнорированием подписей? (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        pacman -S --noconfirm $packages --ignore signature
    else
        printf "[!] Продолжаем без установки этих пакетов\n"
        return 1
    fi
}

# Обновляем ключи перед началом
update_chroot_keys

# Настройка локали и времени
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen

echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf
echo "haruhi" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
HOSTS

# Настройка пользователей
echo "Установка пароля для root:"
passwd
useradd -m -G wheel -s /bin/bash kyon
echo "Установка пароля для пользователя kyon:"
passwd kyon

# Настройка sudo
if ! grep -q '^%wheel' /etc/sudoers; then
    echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
fi

# Редактирование pacman.conf (опционально)
echo "Хотите отредактировать /etc/pacman.conf? (y/N): "
read -r edit_pacman
if [[ "$edit_pacman" =~ ^[Yy]$ ]]; then
    nano /etc/pacman.conf
fi

# Обновление системы
safe_pacman_install ""

# Проверяем тип установки
if [[ -f /tmp/install_type && $(cat /tmp/install_type) == "full" ]]; then
    printf "[*] Начинаем установку полной системы...\n"
    
    # Установка GNOME и базовых пакетов
    safe_pacman_install "gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber"
    
    # Дополнительные пакеты
    safe_pacman_install "networkmanager network-manager-applet xdg-user-dirs xdg-utils"
    safe_pacman_install "firefox vlc gimp libreoffice-fresh"
    
    # Игровые пакеты
    safe_pacman_install "steam wine-staging lutris"
    
    # Установка AUR помощника (yay)
    echo "[*] Установка yay из AUR..."
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    chown -R kyon:kyon .
    sudo -u kyon makepkg -si --noconfirm
    
    # Установка AUR пакетов через yay
    echo "[*] Установка AUR пакетов..."
    sudo -u kyon yay -S --noconfirm visual-studio-code-bin discord spotify
    
    # Настройка Flatpak
    echo "[*] Настройка Flatpak..."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub org.mozilla.firefox org.telegram.desktop com.obsproject.Studio
    
    # Включение служб
    systemctl enable gdm
fi

# Включение NetworkManager
systemctl enable NetworkManager

# Создание конфигурации mkinitcpio
mkinitcpio -P

# Установка GRUB (если не UEFI, то пропускаем)
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "[!] Система не в UEFI режиме. Установите загрузчик вручную."
fi

echo "[✓] Конфигурация завершена!"
EOF

    # Сохраняем тип установки для использования в chroot
    echo "$INSTALL_TYPE" > /mnt/tmp/install_type
    
    chmod +x "$script_path"
}

run_chroot_script() {
    printf "[+] Выполнение конфигурации в chroot...\n"
    
    # Копируем resolv.conf для DNS
    cp /etc/resolv.conf /mnt/etc/resolv.conf
    
    # Выполняем скрипт в chroot
    arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        printf "[+] UEFI режим обнаружен. Установка GRUB...\n"
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    else
        printf "[!] Система не в UEFI режиме. Установка невозможна.\n" >&2
        return 1
    fi
}

cleanup_and_reboot() {
    printf "[+] Отмонтирование /mnt...\n"
    umount -R /mnt 2>/dev/null || true
    
    printf "\n[✓] Установка завершена!\n"
    printf "\nИнструкции после установки:\n"
    printf "1. Извлеките установочный носитель\n"
    printf "2. Перезагрузите систему: reboot\n"
    printf "3. Войдите как пользователь 'kyon'\n"
    
    printf "\n[?] Перезагрузить сейчас? (y/N): "
    read -r reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Проверяем, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   printf "[!] Этот скрипт должен запускаться от root\n" >&2
   exit 1
fi

main "$@"
