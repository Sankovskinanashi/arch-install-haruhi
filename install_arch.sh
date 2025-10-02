#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
EFI_LABEL="EFI"
ROOT_LABEL="ROOT"
BOOT_SIZE="512M"
FS_TYPE="ext4"
DISK=""
EFI_PART=""
ROOT_PART=""
HOSTNAME="arch-hyprland"
USERNAME="kyon"
LOCALE="ru_RU.UTF-8"
KEYMAP="ru"
TIMEZONE="Europe/Moscow"
GPU_TYPE=""
CONFIG_REPO="https://github.com/AvantParker/config.git"

# Function to print colored output
print_status() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен запускаться с правами root"
        exit 1
    fi
}

# Check UEFI
check_uefi() {
    if [[ ! -d /sys/firmware/efi ]]; then
        print_error "Система не запущена в UEFI режиме. Установка невозможна."
        exit 1
    fi
    print_status "UEFI режим обнаружен"
}

# Check internet
check_internet() {
    print_status "Проверка интернет-соединения..."
    if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
        print_error "Нет доступа к интернету"
        print_info "Настройте подключение:"
        print_info "Wi-Fi: iwctl station wlan0 connect SSID"
        print_info "Ethernet: dhcpcd или ip link set интерфейс up"
        exit 1
    fi
    print_status "Интернет доступен"
}

# Detect available disks
detect_disks() {
    print_status "Доступные диски:"
    lsblk -dno NAME,SIZE,MODEL -e 7,11 | while read -r line; do
        print_info "  /dev/$line"
    done
}

# Select disk for installation
select_disk() {
    while true; do
        read -rp "[?] Укажите диск для установки (например /dev/sda): " DISK
        if [[ -b "$DISK" ]]; then
            break
        fi
        print_error "Указанный диск не существует: $DISK"
    done
}

# Select GPU type
select_gpu() {
    print_info "Выберите тип видеокарты:"
    echo "  1) NVIDIA"
    echo "  2) AMD"
    echo "  3) Intel"
    echo "  4) Виртуальная машина (QEMU)"
    read -rp "Ваш выбор [1-4]: " gpu_choice
    
    case $gpu_choice in
        1) GPU_TYPE="nvidia" ;;
        2) GPU_TYPE="amd" ;;
        3) GPU_TYPE="intel" ;;
        4) GPU_TYPE="vm" ;;
        *) 
            print_warning "Неверный выбор, используем Intel"
            GPU_TYPE="intel" 
            ;;
    esac
}

# List existing partitions
list_partitions() {
    print_status "Существующие разделы на $DISK:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
}

# Prompt for partition action
prompt_partition_action() {
    print_info "Выберите действие с разделами:"
    echo "  1) Использовать существующие разделы"
    echo "  2) Удалить все и создать заново"
    read -rp "Ваш выбор [1-2]: " action
    
    case $action in
        1) select_existing_partitions ;;
        2) wipe_and_create_partitions ;;
        *) 
            print_error "Неверный выбор"
            exit 1
            ;;
    esac
}

# Select existing partitions
select_existing_partitions() {
    read -rp "[?] Укажите EFI раздел (например /dev/sda1): " EFI_PART
    read -rp "[?] Укажите ROOT раздел (например /dev/sda2): " ROOT_PART
    
    if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
        print_error "Один из указанных разделов не существует"
        exit 1
    fi
    
    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

# Wipe and create new partitions
wipe_and_create_partitions() {
    print_warning "Все данные на $DISK будут удалены!"
    read -rp "Продолжить? (yes/NO): " confirm
    [[ "$confirm" != "yes" ]] && exit 1

    print_status "Очистка диска..."
    wipefs -a "$DISK" > /dev/null 2>&1
    parted -s "$DISK" mklabel gpt

    print_status "Создание разделов..."
    parted -s "$DISK" mkpart primary fat32 1MiB "$BOOT_SIZE"
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary "$FS_TYPE" "$BOOT_SIZE" 100%

    # Wait for partitions to be recognized
    sync
    sleep 2

    # Determine partition paths
    if [[ "$DISK" =~ nvme ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi

    if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
        print_error "Не удалось обнаружить созданные разделы"
        exit 1
    fi

    choose_filesystem "$ROOT_PART"
    format_partition "$EFI_PART" fat32 "$EFI_LABEL"
    format_partition "$ROOT_PART" "$FS_TYPE" "$ROOT_LABEL"
}

# Choose filesystem type
choose_filesystem() {
    local part="$1"
    print_info "Выберите файловую систему для $part:"
    echo "  1) ext4 (рекомендуется)"
    echo "  2) btrfs"
    read -rp "Ваш выбор [1-2]: " fs_choice
    
    case $fs_choice in
        1) FS_TYPE="ext4" ;;
        2) FS_TYPE="btrfs" ;;
        *) 
            print_warning "Неверный выбор, используем ext4"
            FS_TYPE="ext4" 
            ;;
    esac
}

# Format partition
format_partition() {
    local part="$1" fstype="$2" label="$3"
    
    case "$fstype" in
        fat32)
            print_status "Форматирование $part в FAT32..."
            mkfs.fat -F32 -n "$label" "$part"
            ;;
        ext4)
            print_status "Форматирование $part в ext4..."
            mkfs.ext4 -F -L "$label" "$part"
            ;;
        btrfs)
            print_status "Форматирование $part в Btrfs..."
            mkfs.btrfs -f -L "$label" "$part"
            ;;
        *)
            print_error "Неизвестная файловая система: $fstype"
            exit 1
            ;;
    esac
}

# Mount partitions
mount_partitions() {
    print_status "Монтирование разделов..."
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

# Enable NTP
enable_ntp() {
    print_status "Включение синхронизации времени..."
    timedatectl set-ntp true
}

# Detect and return microcode package
detect_microcode() {
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        echo "intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        echo "amd-ucode"
    else
        echo ""
    fi
}

# Configure mirrors using reflector (safe alternative to rate-mirrors)
configure_mirrors() {
    print_status "Настройка зеркал с помощью reflector..."
    
    # Install reflector
    pacman -Sy --noconfirm reflector
    
    # Configure mirrors for Russia
    reflector --country Russia --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    
    print_status "Обновление базы пакетов с новыми зеркалами..."
    pacman -Syy
}

# Install base system
install_base_system() {
    local microcode=$(detect_microcode)
    
    print_status "Установка базовой системы..."
    
    # Base packages
    local base_packages="base base-devel linux linux-firmware sudo nano git grub efibootmgr"
    
    # Add microcode if detected
    if [[ -n "$microcode" ]]; then
        base_packages="$base_packages $microcode"
    fi
    
    pacstrap /mnt $base_packages
}

# Generate fstab
generate_fstab() {
    print_status "Генерация fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
}

# Download and extract config without git
download_config() {
    local config_url="https://github.com/AvantParker/config/archive/refs/heads/main.tar.gz"
    local temp_dir="/tmp/config-download"
    
    print_status "Скачивание конфигурации AvantParker..."
    
    # Create temp directory
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # Download and extract config
    curl -L -o config.tar.gz "$config_url"
    tar -xzf config.tar.gz
    
    # Copy config files to user's home
    if [[ -d "config-main" ]]; then
        print_status "Копирование конфигурационных файлов..."
        
        # Create config directories
        mkdir -p "/home/$USERNAME/.config"
        
        # Copy essential configs
        local configs=("hypr" "waybar" "rofi" "kitty" "dunst" "fastfetch" "zathura" "picom")
        for config in "${configs[@]}"; do
            if [[ -d "config-main/$config" ]]; then
                cp -r "config-main/$config" "/home/$USERNAME/.config/"
            fi
        done
        
        # Copy dotfiles
        if [[ -f "config-main/.zshrc" ]]; then
            cp "config-main/.zshrc" "/home/$USERNAME/"
        fi
        
        print_status "Конфигурация успешно установлена"
    else
        print_warning "Не удалось найти конфигурационные файлы"
    fi
    
    # Cleanup
    cd /
    rm -rf "$temp_dir"
}

# Create minimal config if download fails
create_minimal_config() {
    print_status "Создание минимальной конфигурации Hyprland..."
    
    # Create hyprland config directory
    mkdir -p "/home/$USERNAME/.config/hypr"
    
    # Create basic hyprland config
    cat > "/home/$USERNAME/.config/hypr/hyprland.conf" << 'EOF'
# Basic Hyprland configuration
monitor=,preferred,auto,auto

exec-once = waybar &
exec-once = dunst &
exec-once = swaybg -i /usr/share/backgrounds/archlinux/arch-wallpaper.jpg

input {
    kb_layout = ru
    follow_mouse = 1
    touchpad {
        natural_scroll = no
    }
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    drop_shadow = yes
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(1a1a1aee)
}

animations {
    enabled = yes
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

dwindle {
    pseudotile = yes
    preserve_split = yes
}

master {
    new_is_master = true
}

gestures {
    workspace_swipe = off
}

# Keybindings
bind = SUPER, RETURN, exec, kitty
bind = SUPER, Q, killactive,
bind = SUPER, M, exit,
bind = SUPER, E, exec, thunar
bind = SUPER, D, exec, rofi -show drun
bind = SUPER, F, exec, firefox

bind = SUPER, left, movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, up, movefocus, u
bind = SUPER, down, movefocus, d

bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4
bind = SUPER, 5, workspace, 5

bind = SUPER SHIFT, 1, movetoworkspace, 1
bind = SUPER SHIFT, 2, movetoworkspace, 2
bind = SUPER SHIFT, 3, movetoworkspace, 3
bind = SUPER SHIFT, 4, movetoworkspace, 4
bind = SUPER SHIFT, 5, movetoworkspace, 5

bind = , PRINT, exec, grim -g "$(slurp)" - | wl-copy
bind = SUPER, PRINT, exec, grim - | wl-copy
EOF

    # Create basic waybar config
    mkdir -p "/home/$USERNAME/.config/waybar"
    cat > "/home/$USERNAME/.config/waybar/config" << 'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,
    "modules-left": ["hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["cpu", "memory", "battery", "pulseaudio", "network", "tray"],
    "hyprland/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "format": "{name}"
    },
    "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%Y-%m-%d}"
    },
    "cpu": {
        "format": "{usage}% ",
        "tooltip": false
    },
    "memory": {
        "format": "{}% "
    },
    "battery": {
        "format": "{capacity}% {icon}",
        "format-icons": ["", "", "", "", ""]
    },
    "network": {
        "format-wifi": "{essid} ({signalStrength}%)",
        "format-ethernet": "{ifname}",
        "format-disconnected": "Disconnected"
    },
    "pulseaudio": {
        "format": "{volume}% {icon}",
        "format-muted": "Muted",
        "format-icons": ["", "", ""]
    }
}
EOF

    cat > "/home/$USERNAME/.config/waybar/style.css" << 'EOF'
* {
    border: none;
    border-radius: 0;
    font-family: "JetBrains Mono Nerd Font";
    font-size: 12px;
    min-height: 0;
}

window#waybar {
    background: rgba(40, 40, 40, 0.9);
    color: white;
}

#workspaces button {
    padding: 0 5px;
    background: transparent;
    color: white;
    border-top: 2px solid transparent;
}

#workspaces button.focused {
    background: #64727D;
    border-top: 2px solid white;
}

#clock, #cpu, #memory, #battery, #pulseaudio, #network {
    padding: 0 8px;
    margin: 0 2px;
}
EOF

    print_status "Минимальная конфигурация создана"
}

# Create chroot installation script
create_chroot_script() {
    local script_path="/mnt/root/chroot_script.sh"
    
    cat > "$script_path" << 'EOF'
#!/bin/bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[!]${NC} $1"; }

# Basic system configuration
print_status "Базовая настройка системы..."
ln -sf /usr/share/zoneinfo/TIMEZONE_PLACEHOLDER /etc/localtime
hwclock --systohc

# Locale configuration
print_status "Настройка локали..."
sed -i 's|^#\(LOCALE_PLACEHOLDER\)|\1|' /etc/locale.gen
sed -i 's|^#\(en_US.UTF-8\)|\1|' /etc/locale.gen
locale-gen

echo "LANG=LOCALE_PLACEHOLDER" > /etc/locale.conf
echo "KEYMAP=KEYMAP_PLACEHOLDER" > /etc/vconsole.conf
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname

# Hosts file
cat > /etc/hosts << HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   HOSTNAME_PLACEHOLDER.localdomain HOSTNAME_PLACEHOLDER
HOSTS_EOF

# User setup
print_status "Настройка пользователей..."
echo "Установите пароль для root:"
until passwd; do
    print_warning "Попробуйте еще раз"
done

useradd -m -G wheel -s /bin/bash USERNAME_PLACEHOLDER
echo "Установите пароль для пользователя USERNAME_PLACEHOLDER:"
until passwd USERNAME_PLACEHOLDER; do
    print_warning "Попробуйте еще раз"
done

# Sudo configuration
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Install GPU drivers
print_status "Установка драйверов для GPU_TYPE_PLACEHOLDER..."
case "GPU_TYPE_PLACEHOLDER" in
    nvidia)
        pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
        ;;
    amd)
        pacman -S --noconfirm mesa vulkan-radeon libva-mesa-driver
        ;;
    intel)
        pacman -S --noconfirm mesa vulkan-intel intel-media-driver
        ;;
    vm)
        pacman -S --noconfirm mesa xf86-video-qxl
        ;;
esac

# Install Hyprland and essential packages
print_status "Установка Hyprland и окружения..."
pacman -S --noconfirm hyprland waybar rofi dunst kitty thunar \
    firefox swaybg swaylock grim slurp wl-clipboard polkit-gnome \
    networkmanager blueman pipewire pipewire-alsa pipewire-pulse \
    wireplumber brightnessctl fastfetch zathura picom \
    ttf-firacode-nerd ttf-jetbrains-mono-nerd noto-fonts \
    noto-fonts-emoji noto-fonts-cjk papirus-icon-theme \
    gnome-themes-extra xdg-desktop-portal-hyprland \
    zsh starship bat exa fzf ripgrep fd curl

# Try to download config, fallback to minimal config
download_config() {
    print_status "Попытка скачать конфигурацию..."
    local config_url="https://github.com/AvantParker/config/archive/refs/heads/main.tar.gz"
    local temp_dir="/tmp/config-download"
    
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    if curl -L -o config.tar.gz "$config_url" && tar -xzf config.tar.gz && [[ -d "config-main" ]]; then
        print_status "Копирование конфигурационных файлов..."
        mkdir -p "/home/USERNAME_PLACEHOLDER/.config"
        
        configs=("hypr" "waybar" "rofi" "kitty" "dunst" "fastfetch" "zathura" "picom")
        for config in "${configs[@]}"; do
            if [[ -d "config-main/$config" ]]; then
                cp -r "config-main/$config" "/home/USERNAME_PLACEHOLDER/.config/"
            fi
        done
        
        if [[ -f "config-main/.zshrc" ]]; then
            cp "config-main/.zshrc" "/home/USERNAME_PLACEHOLDER/"
        fi
        
        print_status "Конфигурация успешно установлена"
    else
        print_warning "Не удалось скачать конфигурацию, создаем базовую..."
        create_minimal_config
    fi
    
    cd /
    rm -rf "$temp_dir"
}

# Create minimal config if download fails
create_minimal_config() {
    print_status "Создание минимальной конфигурации..."
    
    mkdir -p "/home/USERNAME_PLACEHOLDER/.config/hypr"
    cat > "/home/USERNAME_PLACEHOLDER/.config/hypr/hyprland.conf" << 'HYPR_EOF'
monitor=,preferred,auto,auto
exec-once = waybar &
exec-once = dunst &
input { kb_layout = ru }
general { gaps_in = 5, gaps_out = 10 }
bind = SUPER, RETURN, exec, kitty
bind = SUPER, Q, killactive
bind = SUPER, D, exec, rofi -show drun
bind = SUPER, F, exec, firefox
HYPR_EOF
    
    mkdir -p "/home/USERNAME_PLACEHOLDER/.config/waybar"
    cat > "/home/USERNAME_PLACEHOLDER/.config/waybar/config" << 'WAYBAR_EOF'
{
    "layer": "top", "position": "top",
    "modules-left": ["hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["cpu", "memory", "pulseaudio", "network"]
}
WAYBAR_EOF

    print_status "Минимальная конфигурация создана"
}

# Download or create config
download_config

# Setup Zsh
print_status "Настройка Zsh..."
sudo -u USERNAME_PLACEHOLDER sh -c "RUNZSH=no sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\""
chsh -s /bin/zsh USERNAME_PLACEHOLDER

# Enable services
print_status "Включение служб..."
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable pipewire pipewire-pulse

# Create desktop entry for Hyprland
mkdir -p "/home/USERNAME_PLACEHOLDER/.local/share/wayland-sessions"
cat > "/home/USERNAME_PLACEHOLDER/.local/share/wayland-sessions/hyprland.desktop" << DESKTOP_EOF
[Desktop Entry]
Name=Hyprland
Comment=Hyprland Wayland compositor
Exec=Hyprland
Type=Application
DESKTOP_EOF

# Fix permissions
chown -R USERNAME_PLACEHOLDER:USERNAME_PLACEHOLDER "/home/USERNAME_PLACEHOLDER"

print_status "Настройка в chroot завершена!"
EOF

    # Replace placeholder variables in the script using different delimiters
    sed -i "s|TIMEZONE_PLACEHOLDER|$TIMEZONE|g" "$script_path"
    sed -i "s|LOCALE_PLACEHOLDER|$LOCALE|g" "$script_path"
    sed -i "s|KEYMAP_PLACEHOLDER|$KEYMAP|g" "$script_path"
    sed -i "s|HOSTNAME_PLACEHOLDER|$HOSTNAME|g" "$script_path"
    sed -i "s|USERNAME_PLACEHOLDER|$USERNAME|g" "$script_path"
    sed -i "s|GPU_TYPE_PLACEHOLDER|$GPU_TYPE|g" "$script_path"
    
    chmod +x "$script_path"
}

# Run chroot script
run_chroot_script() {
    print_status "Выполнение настройки в chroot..."
    arch-chroot /mnt /root/chroot_script.sh
}

# Install GRUB
install_grub() {
    print_status "Установка GRUB..."
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

# Cleanup and reboot
cleanup_and_reboot() {
    print_status "Отмонтирование разделов..."
    umount -R /mnt
    
    print_status "Установка завершена!"
    echo ""
    print_warning "СИСТЕМА БУДЕТ ПЕРЕЗАГРУЖЕНА ЧЕРЕЗ 10 СЕКУНД!"
    echo ""
    print_info "После перезагрузки:"
    print_info "1. На экране входа выберите сессию 'Hyprland'"
    print_info "2. Основные комбинации клавиш:"
    print_info "   - Super + Return: терминал (kitty)"
    print_info "   - Super + D: запуск приложений (rofi)"
    print_info "   - Super + Q: закрыть окно"
    print_info "   - Super + Shift + E: выход"
    
    sleep 10
    reboot
}

# Main installation function
main() {
    print_status "Начало установки Arch Linux с Hyprland..."
    
    check_root
    check_uefi
    check_internet
    detect_disks
    select_disk
    select_gpu
    list_partitions
    prompt_partition_action
    mount_partitions
    enable_ntp
    configure_mirrors
    install_base_system
    generate_fstab
    create_chroot_script
    run_chroot_script
    install_grub
    cleanup_and_reboot
}

# Run main function
main "$@"
