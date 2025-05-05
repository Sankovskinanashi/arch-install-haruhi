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
DESKTOP_ENV=""

main() {
    detect_disks
    select_disk
    list_partitions
    prompt_partition_action
    mount_partitions
    enable_ntp
    choose_desktop_environment
    install_base_system
    generate_fstab
    create_chroot_script
    run_chroot_script
    install_grub
    cleanup_and_reboot
}
choose_desktop_environment() {
    printf "\n[?] Выберите окружение рабочего стола:\n"
    printf "  [1] GNOME\n"
    printf "  [2] Hyprland (Wayland, современное, тайлинговое)\n"
    read -rp "Выбор: " choice
    case "$choice" in
        1) DESKTOP_ENV="gnome" ;;
        2) DESKTOP_ENV="hyprland" ;;
        *) printf "[!] Неверный выбор\n" >&2; return 1 ;;
    esac
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
    printf "[+] Установка базовой системы...\n"
    pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager
}

generate_fstab() {
    printf "[+] Генерация fstab...\n"
    genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
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
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

passwd
useradd -m -G wheel -s /bin/bash $USERNAME
passwd $USERNAME
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

$EDITOR /etc/pacman.conf

pacman -Syu --noconfirm

if [[ "$DESKTOP_ENV" == "gnome" ]]; then
    pacman -S --noconfirm gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber networkmanager wireguard-tools steam lutris wine dkms libva-nvidia-driver nvidia-dkms xorg-server xorg-xinit flatpak
    systemctl enable gdm

elif [[ "$DESKTOP_ENV" == "hyprland" ]]; then
    pacman -S --noconfirm \
        xorg-xwayland \
        wlroots \
        hyprland \
        waybar \
        foot \
        wofi\
        dunst \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        networkmanager wireguard-tools \
        lightdm lightdm-gtk-greeter \
        qt5-wayland qt6-wayland \
        grim slurp wl-clipboard brightnessctl \
        steam lutris wine \
        libva-nvidia-driver nvidia-dkms flatpak  wl-clipboard cliphist thunar firefox \
xdg-desktop-portal-hyprland qt5ct qt6ct hyprpaper ntfs-3g
    systemctl enable lightdm
fi

#!/bin/bash

# Монтируем Windows-раздел /dev/sda3, если он не смонтирован
if ! mountpoint -q /mnt/windows; then
    echo "→ Монтирую Windows-раздел /dev/sda3 в /mnt/windows..."
    sudo mkdir -p /mnt/windows
    sudo mount -t ntfs3 /dev/sda3 /mnt/windows || {
        echo "❌ Не удалось смонтировать /dev/sda3. Убедись, что раздел существует и не занят."
        exit 1
    }
fi

# Проверяем, существует ли изображение
if [ ! -f "/mnt/windows/Users/Kyon/Pictures/GCmG7WYbgAAP1RX.jpg" ]; then
    echo "❌ Обои не найдены: /mnt/windows/Users/Kyon/Pictures/GCmG7WYbgAAP1RX.jpg"
    exit 1
fi

# Копируем обои в домашнюю директорию пользователя
cp "/mnt/windows/Users/Kyon/Pictures/GCmG7WYbgAAP1RX.jpg" "/home/$USERNAME/.config/hypr/wallpapers/wallpaper.jpg"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/hypr/wallpapers/wallpaper.jpg"

runuser -u "$USERNAME" -- bash -c '
# Папки конфигураций
mkdir -p /home/$USER/.config/{hypr,waybar,rofi,hypr/wallpapers,gtk-3.0}
mkdir -p /home/$USER/.fonts

# Hyprland конфиг
cat > /home/$USER/.config/hypr/hyprland.conf <<EOF
# ----------------------
# Monitor
# ----------------------
monitor=,preferred,auto,1

# ----------------------
# Input
# ----------------------
input {
    kb_layout = us,ru
    kb_variant =
    kb_options = grp:alt_shift_toggle
    follow_mouse = 1

    touchpad {
        natural_scroll = yes
    }
}

# ----------------------
# General settings
# ----------------------
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee)
    col.inactive_border = rgba(222222aa)
    layout = dwindle
}

# ----------------------
# Decoration
# ----------------------
decoration {
    rounding = 10
    blur = yes
    blur_size = 5
    blur_passes = 1
    drop_shadow = yes
    shadow_range = 4
    shadow_render_power = 3
}

# ----------------------
# Autostart applications
# ----------------------
exec-once = waybar
exec-once = foot
exec-once = firefox
exec-once = thunar
exec-once = wl-paste --watch cliphist store &
exec-once = hyprpaper &

# ----------------------
# Environment for themes, cursor, etc.
# ----------------------
env = XCURSOR_THEME,Bibata-Modern-Ice
env = XCURSOR_SIZE,24
env = GTK_THEME,Adwaita-dark
env = QT_QPA_PLATFORMTHEME,qt5ct

# ----------------------
# Window Rules
# ----------------------
windowrule = float, ^(pavucontrol)$
windowrule = float, ^(Gimp|gimp-2.10)$
windowrule = workspace 2, ^(firefox)$

# ----------------------
# Keybindings
# ----------------------
\$mod = SUPER

bind = \$mod, RETURN, exec, foot
bind = \$mod, Q, killactive,
bind = \$mod, M, exit,
bind = \$mod, V, togglefloating,
bind = \$mod, F, fullscreen

bind = \$mod, H, movefocus, l
bind = \$mod, L, movefocus, r
bind = \$mod, K, movefocus, u
bind = \$mod, J, movefocus, d

bind = \$mod, 1, workspace, 1
bind = \$mod, 2, workspace, 2
bind = \$mod, 3, workspace, 3
bind = \$mod, 4, workspace, 4
bind = \$mod, 5, workspace, 5
EOF

# hyprpaper config
cat > /home/$USER/.config/hypr/hyprpaper.conf <<EOF
preload = /home/$USER/.config/hypr/wallpapers/wallpaper.jpg
wallpaper = ,/home/$USER/.config/hypr/wallpapers/wallpaper.jpg
EOF

# waybar config
cat > /home/$USER/.config/waybar/config <<EOF
{
  "layer": "top",
  "position": "top",
  "modules-left": ["workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["language", "pulseaudio", "network", "battery"],

  "clock": {
    "format": " {:%H:%M  %d.%m}"
  },
  "language": {
    "format": "{}",
    "format-en": "EN",
    "format-ru": "RU"
  },
  "pulseaudio": {
    "format": " {volume}%"
  },
  "network": {
    "format-wifi": " {essid}",
    "format-ethernet": " {ifname}",
    "format-disconnected": " Disconnected"
  },
  "battery": {
    "format": "{capacity}% {icon}",
    "format-icons": ["", "", "", "", ""]
  }
}
EOF

# waybar style
cat > /home/$USER/.config/waybar/style.css <<EOF
* {
    font-family: JetBrainsMono Nerd Font, monospace;
    font-size: 13px;
    border: none;
    border-radius: 0;
    color: #ffffff;
}

window#waybar {
    background: linear-gradient(90deg, rgba(25,0,64,0.9), rgba(80,0,120,0.85), rgba(0,0,64,0.8));
    border-bottom: 2px solid #9b5de5;
}

#workspaces button {
    padding: 0 5px;
    background: transparent;
    border-bottom: 2px solid transparent;
}

#workspaces button.focused {
    border-bottom: 2px solid #f15bb5;
    background: rgba(255, 255, 255, 0.1);
}

#clock, #pulseaudio, #network, #cpu, #memory, #battery, #language {
    padding: 0 10px;
}

#language {
    color: #ffee93;
}
EOF

# GTK theme
cat > /home/$USER/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-theme-name=Adwaita-dark
icon-theme-name=Papirus
EOF

# rofi config
cat > /home/$USER/.config/rofi/config.rasi <<EOF
* {
  background: #1e1e2e;
  foreground: #cdd6f4;
  border-color: #9b5de5;
}
EOF

# Копируем обои (предполагается, что заранее положили wallpaper.jpg)
# cp /путь/к/твоим/обоям.jpg /home/$USER/.config/hypr/wallpapers/wallpaper.jpg

chown -R $USER:$USER /home/$USER/.config
'

# LightDM (опционально)
mkdir -p /etc/lightdm/lightdm.conf.d
echo -e "[Seat:*]\ngreeter-session=lightdm-gtk-greeter" > /etc/lightdm/lightdm.conf.d/20-greeter.conf
systemctl enable lightdm
'


# yay + AUR + Flatpak (общие для обоих окружений)
runuser -u $USERNAME -- bash -c 
cd /home/$USERNAME
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
yay -S --noconfirm visual-studio-code-bin discord


flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.mozilla.firefox org.telegram.desktop md.obsidian.Obsidian com.obsproject.Studio org.kde.krita org.gnome.Extensions org.libreoffice.LibreOffice

systemctl enable NetworkManager
EOF

    chmod +x "$script_path"
}


run_chroot_script() {
    echo "DESKTOP_ENV=$DESKTOP_ENV" > /mnt/root/desktop_env.conf
    echo "source /root/desktop_env.conf" >> /mnt/root/chroot_script.sh
    printf "[+] Выполнение конфигурации в chroot...\n"
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
    umount -R /mnt
    printf "[✓] Установка завершена. Перезагрузите систему вручную.\n"
}

main "$@"
