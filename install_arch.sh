#!/bin/bash
set -euo pipefail

# ============================================================
# Arch Linux Automated Installation for Dual-Boot Laptop
#
# Условия:
# - Windows 10 уже установлена на SSD (238 ГБ)
# - 1 ГБ для EFI (FAT32) и 59 ГБ для корневой системы (ext4) выделено для Arch Linux
#
# Скрипт устанавливает базовую систему, GNOME, драйверы (Intel + NVIDIA),
# аудио (Pipewire), сеть (NetworkManager, WireGuard), поддержку Bluetooth,
# а также рекомендуемые и дополнительные утилиты и приложения.
#
# Сервисы, такие как NetworkManager, GDM и Bluetooth, будут настроены для автозапуска.
#
# Настраиваем hostname = haruhi, пользователя = kyon (с правами sudo).
#
# WARNING: Этот скрипт отформатирует указанные разделы! Используй его на свой страх и риск.
# ============================================================

# Проверка запуска от root
if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт от root (например, через sudo)."
    exit 1
fi

echo "=== Arch Linux Dual-Boot Installation ==="
echo "Будет установлена Arch Linux на основе:"
echo "  - EFI-раздел: 1 ГБ (FAT32)"
echo "  - Корневой раздел: 59 ГБ (ext4)"
echo "Windows 10 остаётся нетронутой."
echo "Hostname будет установлен как haruhi, а пользователь – kyon."
echo "========================================"

# ====== 1. Ввод информации о разделах ======
read -p "Введите путь к EFI-разделу (например, /dev/nvme0n1pX): " EFI_PART
read -p "Введите путь к корневому разделу (например, /dev/nvme0n1pY): " ROOT_PART

echo "Внимание! Будут отформатированы следующие разделы:"
echo "  EFI-раздел: $EFI_PART (будет отформатирован в FAT32)"
echo "  Корневой раздел: $ROOT_PART (будет отформатирован в ext4)"
read -p "Подтверждаете? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "Отмена установки."
    exit 1
fi

# ====== 2. Форматирование и монтирование ======
echo "Форматирование EFI-раздела $EFI_PART в FAT32..."
mkfs.fat -F32 "$EFI_PART"

echo "Форматирование корневого раздела $ROOT_PART в ext4..."
mkfs.ext4 "$ROOT_PART"

echo "Монтирование корневого раздела $ROOT_PART в /mnt..."
mount "$ROOT_PART" /mnt

echo "Создание точки монтирования для EFI-раздела..."
mkdir -p /mnt/boot/efi
echo "Монтирование EFI-раздела $EFI_PART в /mnt/boot/efi..."
mount "$EFI_PART" /mnt/boot/efi

# ====== 3. Установка базовой системы ======
echo "Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager

echo "Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ====== 4. Создание скрипта для конфигурации в chroot ======
echo "Создание скрипта для конфигурации в chroot..."
cat << 'EOF' > /mnt/root/chroot_script.sh
#!/bin/bash
set -euo pipefail
echo "=== Начало конфигурации в chroot ==="

# --- Системные настройки ---
echo "Настройка временной зоны и часов..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

echo "Генерация локали..."
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf

# --- Настройка hostname и hosts ---
echo "Установка hostname в haruhi..."
echo "haruhi" > /etc/hostname
cat << HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
HOSTS_EOF

# --- Настройка root и создание пользователя ---
echo "Установка пароля для root..."
passwd

echo "Создание пользователя kyon..."
useradd -m -G wheel -s /bin/bash kyon
echo "Установите пароль для пользователя kyon:"
passwd kyon

# Разрешаем группе wheel использовать sudo (если строки нет, добавляем)
if ! grep -q "^%wheel" /etc/sudoers; then
  echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
fi

# --- Включение сервисов ---
echo "Включение автозапуска сервисов..."
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth

# --- Включение репозитория multilib (для Wine, Steam и др.) ---
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  sed -i '/#\[multilib\]/s/^#//' /etc/pacman.conf
  sed -i '/#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /etc/pacman.conf
fi

echo "Обновление системы..."
pacman -Syu --noconfirm

# --- Установка драйверов и графической среды ---
echo "Установка GNOME, драйверов (Intel + NVIDIA) и видео-библиотек..."
pacman -S --noconfirm \
    gnome gnome-tweaks gnome-shell-extensions flatpak ntfs-3g alacritty \
    mesa nvidia nvidia-utils vulkan-icd-loader vulkan-intel vulkan-nvidia

# --- Установка аудио-стека ---
echo "Установка аудиосистемы на базе Pipewire..."
pacman -S --noconfirm \
    pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol

# --- Установка сетевых инструментов и VPN ---
echo "Установка WireGuard и дополнительных сетевых утилит..."
pacman -S --noconfirm wireguard-tools openssh

# --- Установка приложений из официальных репозиториев ---
echo "Установка основных приложений..."
pacman -S --noconfirm \
    obs-studio telegram-desktop krita wine steam

# --- Установка дополнительных утилит и разработческих инструментов ---
echo "Установка дополнительных утилит..."
pacman -S --noconfirm \
    htop wget curl bash-completion man-db man-pages neovim \
    nautilus gparted unzip p7zip rsync

# --- Установка Bluetooth-пакетов ---
echo "Установка пакетов для Bluetooth..."
pacman -S --noconfirm bluez bluez-utils blueman

# --- Установка AUR-хелпера yay ---
echo "Установка AUR-хелпера yay..."
if ! command -v yay &> /dev/null; then
    cd /opt
    git clone https://aur.archlinux.org/yay.git
    chown -R $(whoami):$(whoami) yay
    cd yay
    makepkg -si --noconfirm
fi

# --- Установка AUR-пакетов ---
echo "Установка AUR-пакетов (Visual Studio Code, Discord, Obsidian)..."
yay -S --noconfirm visual-studio-code-bin discord obsidian

# --- Установка Flatpak-приложений из Flathub ---
echo "Настройка Flatpak и установка приложений из Flathub..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
    org.mozilla.firefox \
    org.telegram.desktop \
    md.obsidian.Obsidian \
    com.obsproject.Studio \
    org.kde.krita

echo "=== Конфигурация в chroot завершена ==="
EOF

chmod +x /mnt/root/chroot_script.sh

# ====== 5. Вход в chroot и выполнение скрипта ======
echo "Входим в chroot и запускаем конфигурационный скрипт..."
arch-chroot /mnt /root/chroot_script.sh

# ====== 6. Установка загрузчика (GRUB) ======
echo "Установка GRUB-загрузчика..."
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# ====== 7. Завершение установки ======
echo "Отмонтирование разделов..."
umount -R /mnt

echo "Установка завершена! Перезагрузите систему для входа в Arch Linux."
