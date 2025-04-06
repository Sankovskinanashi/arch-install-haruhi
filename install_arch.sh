#!/bin/bash
set -euo pipefail

# ============================================================
# Arch Linux Automated Installation for Dual-Boot Laptop
# Hostname: haruhi | User: kyon
# EFI (1 GB FAT32), root (59 GB ext4)
# GNOME, NVIDIA (с поддержкой Vulkan через nvidia-utils и vulkan-icd-loader),
# Flatpak, yay, multilib, и т.д.
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root."
  exit 1
fi

# === 1. Запрос разделов EFI и ROOT ===
echo "=== Arch Linux Dual-Boot Installer ==="
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

# === 4. Установка базовой системы ===
echo "[+] Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager

# === 5. Генерация fstab ===
echo "[+] Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# === 6. Создание скрипта для конфигурации в chroot ===
echo "[+] Создание chroot-скрипта..."
cat > /mnt/root/chroot_script.sh << 'EOF'
#!/bin/bash
set -euo pipefail
echo ""
echo "=== Конфигурация системы внутри chroot ==="

# --- Системные настройки ---
echo "[*] Настройка временной зоны и аппаратных часов..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

echo "[*] Генерация локали..."
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf

# --- Настройка hostname и hosts ---
echo "[*] Настройка hostname..."
echo haruhi > /etc/hostname
cat > /etc/hosts << H
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
H

# --- Настройка root и создание пользователя ---
echo "[*] Установка пароля для root..."
passwd
echo "[*] Создание пользователя kyon с правами sudo..."
useradd -m -G wheel -s /bin/bash kyon
echo "[*] Установка пароля для пользователя kyon..."
passwd kyon
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# --- Активация репозитория multilib ---
echo "[*] Активация multilib-репозитория..."
sed -i '/#\[multilib\]/s/^#//' /etc/pacman.conf
sed -i '/#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /etc/pacman.conf

# --- Очистка mirrorlist от лишних строк ---
sed -i '/^options/d' /etc/pacman.d/mirrorlist

echo "[*] Обновление системы..."
pacman -Syu --noconfirm

# --- Установка GNOME и основных пакетов ---
echo "[*] Установка GNOME и базовых программ..."
pacman -S --noconfirm --needed \
  gnome gdm gnome-tweaks gnome-shell-extensions flatpak ntfs-3g alacritty \
  mesa nvidia nvidia-utils vulkan-icd-loader vulkan-intel \
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
  networkmanager wireguard-tools openssh \
  obs-studio krita steam \
  htop wget curl bash-completion man-db man-pages neovim \
  nautilus gparted unzip p7zip rsync \
  bluez bluez-utils blueman

# --- Установка AUR-хелпера (yay) от пользователя kyon ---
echo "[*] Установка AUR-хелпера yay..."
runuser -u kyon -- bash -c '\n  cd /home/kyon\n  git clone https://aur.archlinux.org/yay.git\n  cd yay && makepkg -si --noconfirm\n'

# --- Установка AUR-пакетов ---
echo "[*] Установка AUR-пакетов..."
runuser -u kyon -- yay -S --noconfirm visual-studio-code-bin discord obsidian

# --- Установка Flatpak-приложений ---
echo "[*] Установка Flatpak-приложений..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.mozilla.firefox com.obsproject.Studio org.kde.krita

# --- Активация автозапуска сервисов ---
echo "[*] Включение сервисов..."
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth

echo ""
echo "=== Конфигурация в chroot завершена ==="
EOF

chmod +x /mnt/root/chroot_script.sh

# === 7. Запуск chroot-скрипта ===
echo "[+] Запуск скрипта в chroot..."
arch-chroot /mnt /root/chroot_script.sh

# === 8. Установка GRUB ===
echo "[+] Установка загрузчика GRUB..."
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# === 9. Финал: Отмонтирование разделов ===
echo "[+] Отмонтирование разделов..."
umount -R /mnt

echo ""
echo "=== Установка завершена. Перезагрузи систему! ==="
