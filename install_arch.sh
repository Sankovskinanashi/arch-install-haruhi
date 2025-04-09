#!/bin/bash
# Автоматическая конвертация CRLF в LF в самом скрипте (удаление \r)
sed -i 's/\r$//' "$0"

set -euo pipefail

# ============================================================
# Arch Linux Automated Installation for Dual-Boot Laptop
# Hostname: haruhi | User: kyon
# EFI: 1 GB FAT32, ROOT: 59 GB ext4
# GNOME, NVIDIA/Intel GPU (универсальное управление яркостью), Flatpak, AUR (yay), multilib и прочее.
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root."
  exit 1
fi

echo "=== Arch Linux Dual-Boot Installer ==="

# === 1. Запрос разделов EFI и ROOT ===
read -p "Введите путь к EFI-разделу (FAT32): " EFI_PART
read -p "Введите путь к корневому разделу (ext4): " ROOT_PART
echo ""
echo "Будут отформатированы следующие разделы: $EFI_PART и $ROOT_PART"
read -p "Продолжить? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
  echo "Отмена установки."
  exit 1
fi

# === 2. Форматирование разделов ===
echo ""
echo "[+] Форматирование EFI ($EFI_PART) в FAT32..."
mkfs.fat -F32 "$EFI_PART"

echo "[+] Форматирование корневого раздела ($ROOT_PART) в ext4..."
mkfs.ext4 "$ROOT_PART"

# === 3. Монтирование разделов ===
echo "[+] Монтирование корневого раздела в /mnt..."
mount "$ROOT_PART" /mnt

echo "[+] Создание и монтирование точки /mnt/boot/efi..."
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# === 4. Проверка и синхронизация времени ===
echo "[+] Синхронизация времени..."
timedatectl set-ntp true

# === 5. Установка базовой системы ===
echo "[+] Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager reflector

# === 6. Генерация fstab ===
echo "[+] Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# === 7. Создание скрипта для конфигурации в chroot ===
echo "[+] Создание chroot-скрипта..."
cat > /mnt/root/chroot_script.sh << 'EOF'
#!/bin/bash
set -euo pipefail
echo ""
echo "=== Конфигурация системы внутри chroot ==="

# --- Системные настройки и локаль ---
echo "[*] Настройка временной зоны и аппаратных часов..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

echo "[*] Генерация локали..."
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf

# --- Настройка hostname и hosts ---
echo "[*] Настройка hostname..."
echo haruhi > /etc/hostname
cat > /etc/hosts << H
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
H

# --- Root и создание пользователя ---
echo "[*] Установка пароля для root..."
passwd
echo "[*] Создание пользователя kyon с правами sudo..."
useradd -m -G wheel -s /bin/bash kyon
echo "[*] Установка пароля для пользователя kyon..."
passwd kyon
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# --- Активация multilib-репозитория ---
echo "[*] Активация multilib-репозитория..."
sed -i '/#\[multilib\]/s/^#//' /etc/pacman.conf
sed -i '/#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /etc/pacman.conf

# --- Обновление списка зеркал ---
echo "[*] Обновление списка зеркал..."
reflector --latest 10 --protocol https --sort rate --download-timeout 20 --save /etc/pacman.d/mirrorlist || {
  echo "[!] Reflector не смог обновить зеркала. Обновляю вручную..."
  curl -s "https://archlinux.org/mirrorlist/?country=all&protocol=https&use_mirror_status=on" | \
  sed -e 's/^#Server/Server/' -e '/^#/d' > /etc/pacman.d/mirrorlist
}

echo "[*] Обновление системы..."
pacman -Syu --noconfirm

# --- Установка GNOME и универсального управления яркостью ---
echo "[*] Установка GNOME и драйверов NVIDIA/Intel..."
pacman -S --noconfirm --needed \
  gnome gdm gnome-tweaks gnome-shell-extensions flatpak ntfs-3g alacritty \
  mesa nvidia-dkms nvidia-utils nvidia-settings vulkan-icd-loader vulkan-intel \
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
  networkmanager wireguard-tools openssh \
  obs-studio krita steam \
  htop wget curl bash-completion man-db man-pages neovim \
  nautilus gparted unzip p7zip rsync \
  bluez bluez-utils blueman

# --- Настройка универсального управления яркостью ---
echo "[*] Настройка универсального управления яркостью..."
cat << 'EOL' > /etc/udev/rules.d/90-backlight.rules
# Intel GPU
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"

# NVIDIA GPU
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="nvidia_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="nvidia_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOL

echo "[*] Настройка завершена."

# --- Настройка автозапуска сервисов ---
echo "[*] Включение сервисов..."
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth

echo ""
echo "=== Конфигурация в chroot завершена ==="
EOF

chmod +x /mnt/root/chroot_script.sh

# === 8. Запуск chroot-скрипта ===
echo "[+] Запуск скрипта в chroot..."
arch-chroot /mnt /root/chroot_script.sh

# === 9. Установка GRUB ===
echo "[+] Установка загрузчика GRUB..."
if [[ -d /sys/firmware/efi/efivars ]]; then
  echo "[*] UEFI режим активен."
  arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  echo "[!] Система загружена в режиме Legacy BIOS. Проверьте настройки BIOS."
  exit 1
fi

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# === 10. Финал: Отмонтирование разделов ===
echo "[+] Отмонтирование разделов..."
umount -R /mnt

echo ""
echo "=== Установка завершена. Перезагрузи систему! ==="
