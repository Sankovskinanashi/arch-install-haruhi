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
    
    echo "$INSTALL_TYPE" > /tmp/install_type
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

    EFI_PART=""
    ROOT_PART=""
    
    if [[ "$DISK" =~ nvme ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
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
    pacstrap /mnt $packages
}

generate_fstab() {
    printf "[+] Генерация fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    
    cp /tmp/install_type /mnt/root/install_type
    
    cat > "$script_path" <<'EOF'
#!/bin/bash
set -euo pipefail

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
sed -i '/^#\[multilib\]/,+1 s/^#//' /etc/pacman.conf

# Обновление системы
pacman -Syu --noconfirm

# КРИТИЧЕСКИ ВАЖНЫЕ ПАКЕТЫ ДЛЯ i3
printf "[+] Установка критически важных пакетов для i3...\n"
pacman -S --noconfirm \
    xorg-server xorg-xinit xorg-xrandr xorg-xsetroot \
    xorg-fonts-misc ttf-dejavu ttf-liberation noto-fonts \
    i3-wm i3status i3lock dmenu \
    xterm alacritty \
    firefox \
    network-manager-applet \
    lightdm lightdm-gtk-greeter

if [ "$INSTALL_TYPE" = "full" ]; then
    printf "[+] Установка дополнительных пакетов...\n"
    pacman -S --noconfirm \
        thunar thunar-archive-plugin file-roller \
        ristretto \
        pavucontrol \
        papirus-icon-theme \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        git htop \
        noto-fonts-cjk noto-fonts-emoji

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
    runuser -u kyon -- yay -S --noconfirm --answerclean None --answerdiff None \
        visual-studio-code-bin \
        discord

    # Включение LightDM
    systemctl enable lightdm
else
    # Минимальная установка
    printf "[+] Минимальная установка...\n"
    pacman -S --noconfirm \
        thunar \
        pavucontrol \
        pipewire pipewire-alsa pipewire-pulse wireplumber
fi

# Создание базового конфига i3
printf "[+] Создание конфигурации i3...\n"
mkdir -p /home/kyon/.config/i3
cat > /home/kyon/.config/i3/config << 'I3CONFIG'
# i3 config file (v4)
set $mod Mod4

font pango:DejaVu Sans Mono 9

# Use Mouse+$mod to drag floating windows to their wanted position
floating_modifier $mod

# start a terminal
bindsym $mod+Return exec i3-sensible-terminal
bindsym $mod+Shift+Return exec xterm

# start dmenu
bindsym $mod+d exec dmenu_run

# kill focused window
bindsym $mod+Shift+q kill

# start program launcher
bindsym $mod+p exec dmenu_run

# change focus
bindsym $mod+j focus left
bindsym $mod+k focus down
bindsym $mod+l focus up
bindsym $mod+semicolon focus right

# move focused window
bindsym $mod+Shift+j move left
bindsym $mod+Shift+k move down
bindsym $mod+Shift+l move up
bindsym $mod+Shift+semicolon move right

# split in horizontal orientation
bindsym $mod+h split h

# split in vertical orientation
bindsym $mod+v split v

# enter fullscreen mode for the focused container
bindsym $mod+f fullscreen toggle

# change container layout (stacked, tabbed, toggle split)
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# toggle tiling / floating
bindsym $mod+Shift+space floating toggle

# change focus between tiling / floating windows
bindsym $mod+space focus mode_toggle

# focus the parent container
bindsym $mod+a focus parent

# focus the child container
bindsym $mod+z focus child

# switch to workspace
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5
bindsym $mod+6 workspace 6
bindsym $mod+7 workspace 7
bindsym $mod+8 workspace 8
bindsym $mod+9 workspace 9
bindsym $mod+0 workspace 10

# move focused container to workspace
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4
bindsym $mod+Shift+5 move container to workspace 5
bindsym $mod+Shift+6 move container to workspace 6
bindsym $mod+Shift+7 move container to workspace 7
bindsym $mod+Shift+8 move container to workspace 8
bindsym $mod+Shift+9 move container to workspace 9
bindsym $mod+Shift+0 move container to workspace 10

# reload the configuration file
bindsym $mod+Shift+c reload

# restart i3 inplace (preserves your layout/session, can be used to upgrade i3)
bindsym $mod+Shift+r restart

# exit i3 (logs you out of your X session)
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'You pressed the exit shortcut. Do you really want to exit i3? This will end your X session.' -b 'Yes, exit i3' 'i3-msg exit'"

# resize window (you can also use the mouse for that)
mode "resize" {
        bindsym j resize shrink width 10 px or 10 ppt
        bindsym k resize grow height 10 px or 10 ppt
        bindsym l resize shrink height 10 px or 10 ppt
        bindsym semicolon resize grow width 10 px or 10 ppt

        bindsym Return mode "default"
        bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# Start specific programs
bindsym $mod+Shift+f exec firefox

# Status bar
bar {
        status_command i3status
}
I3CONFIG

# Установка прав на конфиг
chown -R kyon:kyon /home/kyon/.config

# Создание .xinitrc для минимальной установки
if [ "$INSTALL_TYPE" = "minimal" ]; then
    printf "[i] Для минимальной установки создаем .xinitrc\n"
    cat > /home/kyon/.xinitrc << XINITRC
#!/bin/sh
exec i3
XINITRC
    chown kyon:kyon /home/kyon/.xinitrc
    chmod +x /home/kyon/.xinitrc
fi

# Удаление временной настройки sudo
sed -i "/kyon ALL=(ALL) NOPASSWD: ALL/d" /etc/sudoers
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Включение NetworkManager
systemctl enable NetworkManager

# Удаляем временный файл
rm -f /root/install_type

printf "\n[✓] Установка завершена!\n"
printf "[i] Горячие клавиши i3:\n"
printf "    ⊞ Win + Enter - терминал\n"
printf "    ⊞ Win + d - dmenu\n"
printf "    ⊞ Win + 1-9 - переключение рабочих столов\n"
printf "    ⊞ Win + Shift + q - закрыть окно\n"
if [ "$INSTALL_TYPE" = "full" ]; then
    printf "[i] Система будет запускать i3 через LightDM\n"
else
    printf "[i] Для запуска i3 выполните: startx\n"
fi
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
        
        # Монтируем EFI vars для доступа к загрузочным записям
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
        
        # Очищаем старые загрузочные записи (если нужно)
        printf "[+] Очистка старых загрузочных записей...\n"
        if command -v efibootmgr >/dev/null 2>&1; then
            # Удаляем все записи GRUB
            for entry in $(efibootmgr | grep -i grub | awk -F'[^0-9]+' '{print $2}'); do
                efibootmgr -b "$entry" -B 2>/dev/null || true
            done
        fi
        
        # Устанавливаем GRUB с дополнительными параметрами
        printf "[+] Установка GRUB в EFI раздел...\n"
        
        # Сначала устанавливаем в chroot
        if arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck; then
            printf "[✓] GRUB установлен успешно\n"
        else
            printf "[!] Стандартная установка GRUB не удалась, пробуем альтернативный метод...\n"
            # Альтернативный метод - установка как removable
            arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
        fi
        
        # Создаем конфиг GRUB
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        
        # Проверяем загрузочные записи
        printf "[+] Проверка загрузочных записей EFI...\n"
        if command -v efibootmgr >/dev/null 2>&1; then
            efibootmgr -v
        fi
        
        printf "[✓] GRUB установлен в %s\n" "$EFI_PART"
    else
        printf "[!] Система не в UEFI режиме. Установка невозможна.\n" >&2
        return 1
    fi
}

cleanup_and_reboot() {
    rm -f /tmp/install_type
    printf "[+] Отмонтирование разделов...\n"
    umount -R /mnt 2>/dev/null || true
    printf "[✓] Установка завершена!\n"
    printf "\n[i] Важные заметки:\n"
    printf "    - Если были ошибки GRUB, вы можете установить загрузчик позже\n"
    printf "    - Для перезагрузки: reboot\n"
    printf "    - Если система не загружается, используйте установочный USB для восстановления\n"
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
