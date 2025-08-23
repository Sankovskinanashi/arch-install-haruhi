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
CPU_VENDOR=""
GPU_VENDOR=""
INSTALL_AMD_DRIVERS=false
INSTALL_NVIDIA_DRIVERS=false
DE_CHOICE=""
HYPRLAND_CONFIG=""

# Проверка наличия интернета
check_internet() {
    printf "[*] Проверка интернет-соединения...\n"
    if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
        printf "[!] Нет доступа к интернету. Настройте подключение и перезапустите установку.\n" >&2
        printf "[i] Подключение Wi-Fi:\n"
        printf "    1. iwctl\n"
        printf "    2. station wlan0 scan\n"
        printf "    3. station wlan0 get-networks\n"
        printf "    4. station wlan0 connect <SSID>\n"
        printf "[i] Подключение Ethernet: dhcpcd\n" >&2
        exit 1
    fi
    printf "[+] Интернет доступен.\n"
}

# Определение железа
detect_hardware() {
    CPU_VENDOR=$(lscpu | grep -i "vendor id" | awk '{print $3}')
    GPU_VENDOR=$(lspci | grep -i "vga\|3d\|display" | awk -F: '{print $3}' | tr '[:upper:]' '[:lower:]')
    
    [[ "$GPU_VENDOR" == *"nvidia"* ]] && INSTALL_NVIDIA_DRIVERS=true
    [[ "$GPU_VENDOR" == *"amd"* || "$GPU_VENDOR" == *"radeon"* ]] && INSTALL_AMD_DRIVERS=true
    
    printf "[*] Определено оборудование:\n"
    printf "    CPU: %s\n" "$CPU_VENDOR"
    printf "    GPU: %s\n" "$GPU_VENDOR"
    printf "    Установка драйверов NVIDIA: %s\n" "$INSTALL_NVIDIA_DRIVERS"
    printf "    Установка драйверов AMD: %s\n" "$INSTALL_AMD_DRIVERS"
}

# Выбор окружения рабочего стола
select_desktop_environment() {
    printf "\n[?] Выберите окружение рабочего стола:\n"
    printf "  [1] GNOME (классическое, с поддержкой Wayland)\n"
    printf "  [2] Hyprland (современный Wayland compositor)\n"
    
    while true; do
        read -rp "Ваш выбор [1/2]: " de_choice
        case "$de_choice" in
            1) DE_CHOICE="gnome"; break ;;
            2) DE_CHOICE="hyprland"; break ;;
            *) printf "[!] Неверный выбор\n" >&2 ;;
        esac
    done
    printf "[+] Выбрано: %s\n" "$DE_CHOICE"
}

# Генерация конфига для Hyprland
generate_hyprland_config() {
    HYPRLAND_CONFIG=$(cat <<'HYPRCONF'
# ~/.config/hypr/hyprland.conf
# Исправленный конфиг для Hyprland

# Монитор
monitor=,preferred,auto,1.25

# Входные устройства
input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle,caps:escape
    repeat_rate = 35
    repeat_delay = 250
    
    touchpad {
        natural_scroll = true
        tap-to-click = true
        disable_while_typing = true
    }
}

# Общие настройки
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgb(89b4fa) rgb(f5c2e7) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
    resize_on_border = true
}

# Настройки окон
dwindle {
    pseudotile = true
    preserve_split = true
}

master {
    new_is_master = true
}

# Разное
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    vfr = true
    vrr = 1
    enable_swallow = true
    swallow_regex = ^(kitty|Alacritty)$
    focus_on_activate = true
}

# Оформление
decoration {
    rounding = 10
    active_opacity = 0.95
    inactive_opacity = 0.85
    fullscreen_opacity = 1.0
    
    blur {
        enabled = true
        size = 5
        passes = 2
        new_optimizations = true
        ignore_opacity = true
    }
    
    drop_shadow = true
    shadow_range = 10
    shadow_render_power = 3
    shadow_ignore_window = true
    col.shadow = rgba(00000099)
}

# Анимации
animations {
    enabled = true
    bezier = linear, 0.0, 0.0, 1.0, 1.0
    bezier = easeOut, 0.0, 0.0, 0.58, 1.0
    
    animation = windows, 1, 4, easeOut
    animation = windowsOut, 1, 4, easeOut
    animation = border, 1, 4, linear
    animation = fade, 1, 4, easeOut
    animation = workspaces, 1, 4, easeOut
}

# Автозапуск
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = waybar
exec-once = swaync
exec-once = nm-applet --indicator
exec-once = blueman-applet
exec-once = wl-paste --watch cliphist store
exec-once = fcitx5 -d

# Горячие клавиши
$mainMod = SUPER

# Запуск приложений
bind = $mainMod, RETURN, exec, kitty
bind = $mainMod, B, exec, firefox
bind = $mainMod, E, exec, nautilus
bind = $mainMod, Q, killactive
bind = $mainMod, F, fullscreen
bind = $mainMod, SPACE, togglefloating
bind = $mainMod, R, exec, wofi --show drun

# Движение фокуса
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Рабочие пространства
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5

# Перемещение окон между рабочими пространствами
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5

# Управление звуком
bind = , XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = , XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%
bind = , XF86AudioMute, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle

# Правила окон
windowrule = float, ^(pavucontrol)$
windowrule = float, ^(blueman-manager)$
windowrule = float, ^(nm-connection-editor)$
windowrule = center, ^(pavucontrol)$
windowrule = size 800 600, ^(pavucontrol)$
HYPRCONF
)
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

# Управление разделами
manage_partitions() {
    printf "\n[*] Существующие разделы на %s:\n" "$DISK"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
    
    printf "\n[?] Что вы хотите сделать с разделами?\n"
    printf "  [1] Использовать существующие\n"
    printf "  [2] Удалить все и создать заново\n"
    printf "  [3] Ручное разбиение (cfdisk)\n"
    
    while true; do
        read -rp "Выбор: " action
        case "$action" in
            1) select_existing_partitions; break ;;
            2) wipe_and_create_partitions; break ;;
            3) manual_partitioning; break ;;
            *) printf "[!] Неверный выбор\n" >&2 ;;
        esac
    done
}

# Функция для использования существующих разделов
select_existing_partitions() {
    printf "\n[?] Вы будете использовать существующие разделы. Убедитесь, что:\n"
    printf "  - Имеется раздел EFI (FAT32) размером не менее 100M\n"
    printf "  - Имеется корневой раздел для Arch Linux\n"
    
    read -rp "[?] Укажите EFI раздел (например /dev/sda1): " EFI_PART
    read -rp "[?] Укажите ROOT раздел (например /dev/sda2): " ROOT_PART

    # Проверка существования разделов
    if [[ ! -b "$EFI_PART" ]]; then
        printf "[!] EFI раздел не существует: %s\n" "$EFI_PART" >&2
        return 1
    fi
    if [[ ! -b "$ROOT_PART" ]]; then
        printf "[!] ROOT раздел не существует: %s\n" "$ROOT_PART" >&2
        return 1
    fi

    # Подтверждение форматирования
    printf "\n[!] ВНИМАНИЕ: Эти разделы будут отформатированы:\n"
    printf "  EFI: %s -> FAT32\n" "$EFI_PART"
    printf "  ROOT: %s -> %s\n" "$ROOT_PART" "$FS_TYPE"
    read -rp "Продолжить? (yes/[no]): " confirm
    [[ "$confirm" != "yes" ]] && return 1

    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

# Функция для удаления и создания разделов
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

# Ручное разбиение
manual_partitioning() {
    printf "\n[!] Запуск cfdisk для ручного разбиения %s\n" "$DISK"
    cfdisk "$DISK"
    
    printf "\n[*] Новые разделы:\n"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
    
    read -rp "[?] Укажите EFI раздел (например /dev/sda1): " EFI_PART
    read -rp "[?] Укажите ROOT раздел (например /dev/sda2): " ROOT_PART
    
    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

# Выбор файловой системы
choose_filesystem() {
    local part="$1"
    printf "\n[?] Выберите файловую системы для %s:\n" "$part"
    printf "  [1] ext4 (рекомендуется)\n"
    printf "  [2] btrfs (с поддержкой снапшотов)\n"
    printf "  [3] xfs (высокая производительность)\n"
    
    while true; do
        read -rp "Выбор: " fs
        case "$fs" in
            1) FS_TYPE="ext4"; break ;;
            2) FS_TYPE="btrfs"; break ;;
            3) FS_TYPE="xfs"; break ;;
            *) printf "[!] Неверный выбор\n" >&2 ;;
        esac
    done
}

# Форматирование раздела
format_partition() {
    local part="$1" fstype="$2" label="$3"
    printf "\n[!] ВСЕ ДАННЫЕ НА %s БУДУТ УДАЛЕНЫ!\n" "$part"
    read -rp "Продолжить форматирование? (yes/[no]): " confirm
    [[ "$confirm" != "yes" ]] && return
    
    case "$fstype" in
        fat32)
            printf "[+] Форматирование %s в FAT32...\n" "$part"
            mkfs.fat -F32 -n "$label" "$part"
            ;;
        ext4)
            printf "[+] Форматирование %s в ext4...\n" "$part"
            mkfs.ext4 -L "$label" "$part"
            ;;
        btrfs)
            printf "[+] Форматирование %s в Btrfs...\n" "$part"
            mkfs.btrfs -f -L "$label" "$part"
            ;;
        xfs)
            printf "[+] Форматирование %s в XFS...\n" "$part"
            mkfs.xfs -f -L "$label" "$part"
            ;;
        *)
            printf "[!] Неизвестная ФС: %s\n" "$fstype" >&2
            return 1
            ;;
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
    
    # Для btrfs создаем подтома
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        printf "[+] Создание подтомов Btrfs...\n"
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        btrfs subvolume create /mnt/@snapshots
        umount /mnt
        
        printf "[+] Монтирование подтомов...\n"
        mount -o compress=zstd,subvol=@ "$ROOT_PART" /mnt
        mkdir -p /mnt/{home,.snapshots,boot/efi}
        mount -o compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
        mount -o compress=zstd,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
        mount "$EFI_PART" /mnt/boot/efi
    fi
}

# Установка базовой системы
install_base_system() {
    local packages="base base-devel linux linux-firmware nano git grub efibootmgr networkmanager"
    
    # Добавляем микрокод
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
    
    # Для btrfs добавляем опции
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        sed -i 's|subvol=/@ |subvol=/@,compress=zstd |' /mnt/etc/fstab
        sed -i 's|subvol=/@home|subvol=/@home,compress=zstd|' /mnt/etc/fstab
        sed -i 's|subvol=/@snapshots|subvol=/@snapshots,compress=zstd|' /mnt/etc/fstab
    fi
}

# Скрипт для chroot
create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    
    # Определяем драйвера для установки
    local gpu_drivers="mesa libva-mesa-driver"
    [[ "$INSTALL_AMD_DRIVERS" == true ]] && gpu_drivers+=" vulkan-radeon libva-mesa-driver"
    [[ "$INSTALL_NVIDIA_DRIVERS" == true ]] && gpu_drivers+=" nvidia nvidia-utils nvidia-settings"
    
    cat > "$script_path" <<EOF
#!/bin/bash
set -euo pipefail

# Настройка времени
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Локализация
sed -i 's/^#\\($LOCALE\\)/\\1/' /etc/locale.gen
sed -i 's/^#\\(en_US.UTF-8\\)/\\1/' /etc/locale.gen
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
passwd

useradd -m -G wheel -s /bin/bash $USERNAME
echo "Установка пароля для $USERNAME:"
passwd $USERNAME

# Настройка sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Активация multilib для Steam и 32-битных библиотек
echo "Включение multilib репозитория..."
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Sy

# Проверка, что multilib активирован
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo "[!] ОШИБКА: Не удалось активировать multilib!" >&2
    exit 1
fi

# Обновление системы
pacman -Syu --noconfirm

# Установка дополнительных системных пакетов
pacman -S --noconfirm openssh

# Установка окружения рабочего стола
if [[ "$DE_CHOICE" == "gnome" ]]; then
    # Установка GNOME
    pacman -S --noconfirm gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber xdg-user-dirs $gpu_drivers
    systemctl enable gdm
    systemctl enable NetworkManager
    pacman -S --noconfirm firefox libreoffice-fresh gimp vlc
    
elif [[ "$DE_CHOICE" == "hyprland" ]]; then
    # Установка Hyprland и компонентов
    pacman -S --noconfirm hyprland waybar swaync sddm wofi cliphist swappy grim slurp wl-clipboard xdg-desktop-portal-hyprland $gpu_drivers
    pacman -S --noconfirm ttf-font-awesome noto-fonts noto-fonts-emoji ttf-jetbrains-mono
    
    # Дополнительные пакеты для игр
    pacman -S --noconfirm steam lutris wine gamemode lib32-gamemode
    
    # Настройка SDDM
    systemctl enable sddm
    systemctl enable NetworkManager
    
    # Создание конфига Hyprland
    mkdir -p /home/$USERNAME/.config/hypr
    cat > /home/$USERNAME/.config/hypr/hyprland.conf << 'HYPRCONF'
$HYPRLAND_CONFIG
HYPRCONF
    
    # Создание скрипта для скриншотов
    mkdir -p /home/$USERNAME/.config/hypr/scripts
    cat > /home/$USERNAME/.config/hypr/scripts/screenshot.sh << 'SCR'
#!/bin/sh
grim -g "\$(slurp)" - | swappy -f -
SCR
    chmod +x /home/$USERNAME/.config/hypr/scripts/screenshot.sh
    
    # Установка обоев
    mkdir -p /home/$USERNAME/Pictures
    curl -L -o /home/$USERNAME/Pictures/wallpaper.jpg https://raw.githubusercontent.com/mateosss/arch-builder/main/wallpapers/anime-arch.jpg
    
    # Права на файлы
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
    chown $USERNAME:$USERNAME /home/$USERNAME/Pictures/wallpaper.jpg
fi

# Установка AUR helper
runuser -u $USERNAME -- bash -c '
cd /home/$USERNAME
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
'

# Установка AUR пакетов
if [[ "$DE_CHOICE" == "hyprland" ]]; then
    runuser -u $USERNAME -- yay -S --noconfirm swaylock-effects visual-studio-code-bin discord
elif [[ "$DE_CHOICE" == "gnome" ]]; then
    runuser -u $USERNAME -- yay -S --noconfirm visual-studio-code-bin discord
fi

# Общие приложения
pacman -S --noconfirm firefox libreoffice-fresh gimp vlc

# Flatpak
pacman -S --noconfirm flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --noninteractive -y flathub org.telegram.desktop md.obsidian.Obsidian com.obsproject.Studio

# Включение служб
systemctl enable NetworkManager
systemctl enable sshd

# ПЕРЕМОНТИРОВАНИЕ EFI ПЕРЕД УСТАНОВКОЙ GRUB
echo "Проверка монтирования EFI раздела..."
if ! mount | grep -q '/boot/efi'; then
    echo "Перемонтирование EFI раздела..."
    umount /boot/efi 2>/dev/null || true
    mkdir -p /boot/efi
    mount $EFI_PART /boot/efi
fi

# Проверка файловой системы EFI
if ! findmnt -n -o FSTYPE /boot/efi | grep -q 'fat'; then
    echo "ОШИБКА: Файловая система EFI не является FAT32!"
    echo "Убедитесь, что раздел $EFI_PART отформатирован правильно."
    exit 1
fi

# Настройка GRUB
echo "Установка GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Автозапуск Wayland для NVIDIA (только для GNOME)
if [[ "$INSTALL_NVIDIA_DRIVERS" == true && "$DE_CHOICE" == "gnome" ]]; then
    echo "Добавление Wayland для NVIDIA в GDM..."
    [ -f /etc/gdm/custom.conf ] && sed -i 's/^#WaylandEnable=false/WaylandEnable=true/' /etc/gdm/custom.conf
fi

# Настройка игрового режима для Hyprland
if [[ "$DE_CHOICE" == "hyprland" ]]; then
    echo "Настройка игрового режима..."
    usermod -a -G gamemode $USERNAME
    echo "export SDL_VIDEODRIVER=wayland" >> /home/$USERNAME/.bashrc
    echo "export CLUTTER_BACKEND=wayland" >> /home/$USERNAME/.bashrc
    echo "export MOZ_ENABLE_WAYLAND=1" >> /home/$USERNAME/.bashrc
fi
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
    printf "    Для входа в систему используйте имя пользователя: $USERNAME\n"
    printf "    Пароль, который вы установили во время установки\n\n"
    
    if [[ "$DE_CHOICE" == "hyprland" ]]; then
        printf "    Рекомендуемые действия после установки Hyprland:\n"
        printf "    1. Проверьте настройки монитора: hyprctl monitors\n"
        printf "    2. Настройте Waybar: ~/.config/waybar/config\n"
        printf "    3. Добавьте нужные приложения в автозапуск\n\n"
    fi
    
    read -rp "Перезагрузить систему сейчас? (yes/[no]): " reboot_confirm
    [[ "$reboot_confirm" == "yes" ]] && reboot
}

# Основной процесс
main() {
    check_internet
    detect_hardware
    select_desktop_environment
    generate_hyprland_config
    select_disk
    manage_partitions
    mount_partitions
    install_base_system
    generate_fstab
    create_chroot_script
    run_chroot_script
    cleanup_and_reboot
}

main "$@"
