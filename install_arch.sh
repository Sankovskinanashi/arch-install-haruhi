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
    printf "  [1] Полная (i3 + все приложения)\n"
    printf "  [2] Минимальная (базовый i3)\n"
    read -rp "Выбор [1/2]: " choice
    
    case "$choice" in
        1) INSTALL_TYPE="full" ;;
        2) INSTALL_TYPE="minimal" ;;
        *) 
            printf "[!] Неверный выбор, используем минимальную установку\n"
            INSTALL_TYPE="minimal" 
            ;;
    esac
    
    # Сохраняем тип установки в файл для передачи в chroot
    echo "$INSTALL_TYPE" > /tmp/install_type
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
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PartLabel "$DISK" | grep -v "NAME"
}

show_disk_layout() {
    printf "\n[+] Текущая разметка диска %s:\n" "$DISK"
    fdisk -l "$DISK" | grep -E "^/dev/"
    printf "\n"
}

select_existing_partitions() {
    printf "\n[*] Выбор существующих разделов:\n"
    show_disk_layout
    
    printf "[?] Выберите EFI раздел (например /dev/sda1):\n"
    printf "Доступные разделы:\n"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PartLabel "$DISK" | grep -v "NAME"
    read -rp "EFI раздел: " EFI_PART
    
    if [[ ! -b "$EFI_PART" ]]; then
        printf "[!] Раздел %s не существует\n" "$EFI_PART" >&2
        return 1
    fi
    
    printf "\n[?] Выберите ROOT раздел (например /dev/sda2):\n"
    printf "Доступные разделы:\n"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PartLabel "$DISK" | grep -v "NAME"
    read -rp "ROOT раздел: " ROOT_PART
    
    if [[ ! -b "$ROOT_PART" ]]; then
        printf "[!] Раздел %s не существует\n" "$ROOT_PART" >&2
        return 1
    fi
    
    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

wipe_and_create_partitions() {
    printf "[!] Все данные на %s будут удалены!\n" "$DISK"
    printf "Текущая разметка:\n"
    show_disk_layout
    read -rp "Продолжить? (yes/[no]): " confirm
    [[ "$confirm" != "yes" ]] && return 1

    printf "[+] Очистка диска...\n"
    wipefs -a "$DISK"
    parted -s "$DISK" mklabel gpt

    printf "[+] Создание разделов...\n"
    printf "  - EFI раздел: 1MiB - %s\n" "$BOOT_SIZE"
    parted -s "$DISK" mkpart "$EFI_LABEL" fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    
    printf "  - ROOT раздел: %s - 100%%\n" "$BOOT_SIZE"
    parted -s "$DISK" mkpart "$ROOT_LABEL" "$FS_TYPE" "$BOOT_SIZE" 100%

    sync
    sleep 2

    printf "\n[+] Созданные разделы:\n"
    show_disk_layout

    # Автоматическое определение созданных разделов
    EFI_PART=""
    ROOT_PART=""
    
    # Для NVMe дисков (например /dev/nvme0n1p1)
    if [[ "$DISK" =~ nvme ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        # Для SATA дисков (например /dev/sda1)
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi

    printf "[+] Определены разделы:\n"
    printf "  EFI:  %s\n" "$EFI_PART"
    printf "  ROOT: %s\n" "$ROOT_PART"

    if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
        printf "[!] Не удалось обнаружить созданные разделы\n" >&2
        printf "[!] Пожалуйста, укажите разделы вручную:\n"
        printf "Доступные разделы:\n"
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PartLabel "$DISK" | grep -v "NAME"
        read -rp "EFI раздел: " EFI_PART
        read -rp "ROOT раздел: " ROOT_PART
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
    printf "[+] Выбрана файловая система: %s\n" "$FS_TYPE"
}

format_partition() {
    local part="$1" fstype="$2" label="$3"
    printf "[+] Форматирование %s как %s с меткой %s...\n" "$part" "$fstype" "$label"
    
    case "$fstype" in
        fat32)
            mkfs.fat -F32 -n "$label" "$part" || return 1
            ;;
        ext4)
            mkfs.ext4 -F -L "$label" "$part" || return 1
            ;;
        btrfs)
            mkfs.btrfs -f -L "$label" "$part" || return 1
            ;;
        *)
            printf "[!] Неизвестная ФС: %s\n" "$fstype" >&2
            return 1
            ;;
    esac
    printf "[✓] Раздел %s отформатирован\n" "$part"
}

mount_partitions() {
    printf "[+] Монтирование разделов...\n"
    printf "  - Корневой раздел %s -> /mnt\n" "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    
    printf "  - EFI раздел %s -> /mnt/boot/efi\n" "$EFI_PART"
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
    
    printf "[+] Текущая структура монтирования:\n"
    mount | grep "/mnt"
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
    printf "[!] Устанавливаемые пакеты: %s\n" "$packages"
    pacstrap /mnt $packages
}

generate_fstab() {
    printf "[+] Генерация fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
    printf "[+] Содержимое fstab:\n"
    cat /mnt/etc/fstab
}

create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    
    # Копируем файл с типом установки в chroot
    cp /tmp/install_type /mnt/root/install_type
    
    cat > "$script_path" <<'EOF'
#!/bin/bash
set -euo pipefail

# Читаем тип установки из файла
INSTALL_TYPE=$(cat /root/install_type)
echo "[+] Тип установки: $INSTALL_TYPE"

# Базовая системная конфигурация
printf "[+] Настройка времени...\n"
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

printf "[+] Настройка локали...\n"
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

# Установка паролей
echo "Установка пароля root:"
passwd
useradd -m -G wheel -s /bin/bash kyon
echo "Установка пароля для пользователя kyon:"
passwd kyon

# Настройка sudo без пароля для установки
echo "kyon ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Настройка pacman
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

# Включение multilib репозитория (для 32-битных приложений)
sed -i '/^#\[multilib\]/,+1 s/^#//' /etc/pacman.conf

# Обновление базы пакетов
pacman -Syu --noconfirm

# Установка i3 и зависимостей
printf "[+] Установка Xorg и i3...\n"
pacman -S --noconfirm xorg xorg-xinit xorg-server i3-wm i3status i3lock dmenu alacritty

if [ "$INSTALL_TYPE" = "full" ]; then
    printf "[+] Установка дополнительных пакетов...\n"
    pacman -S --noconfirm \
        firefox \
        thunar thunar-archive-plugin file-roller \
        ristretto \
        pavucontrol \
        papirus-icon-theme \
        lightdm lightdm-gtk-greeter \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        network-manager-applet \
        git htop \
        flatpak \
        noto-fonts noto-fonts-cjk noto-fonts-emoji \
        ttf-dejavu ttf-liberation

    # Установка Go для сборки yay
    printf "[+] Установка Go...\n"
    pacman -S --noconfirm go

    # Установка AUR helper (yay)
    printf "[+] Установка yay...\n"
    runuser -u kyon -- bash -c '
    cd /home/kyon
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm --needed
    '

    # Установка AUR пакетов
    printf "[+] Установка AUR пакетов...\n"
    runuser -u kyon -- yay -S --noconfirm --answeredit None --answerclean None --answerdiff None \
        visual-studio-code-bin \
        discord

    # Установка Flatpak
    printf "[+] Настройка Flatpak...\n"
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    runuser -u kyon -- flatpak install -y flathub \
        org.telegram.desktop \
        md.obsidian.Obsidian \
        com.spotify.Client

    # Включение LightDM
    systemctl enable lightdm
else
    # Минимальная установка - только базовый i3
    printf "[+] Минимальная установка - только i3 и необходимые пакеты\n"
    pacman -S --noconfirm \
        firefox \
        alacritty \
        network-manager-applet \
        noto-fonts
fi

# Удаление временной настройки sudo без пароля
sed -i "/kyon ALL=(ALL) NOPASSWD: ALL/d" /etc/sudoers

# Настройка обычного sudo с паролем
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Настройка автозапуска i3
if [ "$INSTALL_TYPE" = "minimal" ]; then
    printf "[i] Для запуска i3 добавьте 'exec i3' в ~/.xinitrc и используйте 'startx'\n"
fi

# Создание конфига i3 для пользователя
runuser -u kyon -- mkdir -p /home/kyon/.config/i3
runuser -u kyon -- bash -c 'if [ -f /etc/i3/config ]; then cp /etc/i3/config /home/kyon/.config/i3/config; fi'

# Включение NetworkManager
systemctl enable NetworkManager

# Настройка .xinitrc для минимальной установки
if [ "$INSTALL_TYPE" = "minimal" ]; then
    runuser -u kyon -- bash -c 'echo "exec i3" > /home/kyon/.xinitrc'
    runuser -u kyon -- chmod +x /home/kyon/.xinitrc
fi

# Удаляем временный файл
rm -f /root/install_type

printf "\n[✓] Установка завершена!\n"
if [ "$INSTALL_TYPE" = "full" ]; then
    printf "[i] Система будет запускать i3 через LightDM\n"
else
    printf "[i] Для запуска i3 выполните: startx\n"
fi
printf "[i] Не забудьте настроить i3 под свои нужды\n"
EOF

    chmod +x "$script_path"
}

run_chroot_script() {
    printf "[+] Выполнение конфигурации в chroot...\n"
    arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        printf "[+] UEFI режим обнаружен. Установка GRUB...\n"
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        printf "[✓] GRUB установлен в %s\n" "$EFI_PART"
    else
        printf "[!] Система не в UEFI режиме. Установка невозможна.\n" >&2
        return 1
    fi
}

cleanup_and_reboot() {
    # Удаляем временный файл
    rm -f /tmp/install_type
    
    printf "[+] Отмонтирование разделов...\n"
    umount -R /mnt
    printf "[✓] Установка завершена!\n"
    printf "\n[i] Команды для перезагрузки:\n"
    printf "    umount -R /mnt  # если не отмонтировалось\n"
    printf "    reboot\n"
    printf "\n[i] После перезагрузки:\n"
    if [ "$INSTALL_TYPE" = "full" ]; then
        printf "    - Система запустится в LightDM\n"
        printf "    - Войдите под пользователем kyon\n"
    else
        printf "    - Войдите под пользователем kyon\n"
        printf "    - Выполните: startx\n"
    fi
}

prompt_partition_action() {
    printf "\n[?] Что вы хотите сделать с разделами?\n"
    printf "  [1] Использовать существующие\n"
    printf "  [2] Удалить все и создать зановo\n"
    read -rp "Выбор: " action
    case "$action" in
        1) select_existing_partitions ;;
        2) wipe_and_create_partitions ;;
        *) printf "[!] Неверный выбор\n" >&2; return 1 ;;
    esac
}

main "$@"

