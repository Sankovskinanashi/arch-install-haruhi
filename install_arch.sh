#!/bin/bash
set -euo pipefail

# ============================================================
# Arch Linux Automated Installation for Dual-Boot Laptop
# (EFI 1 GB FAT32, root 59 GB ext4; hostname=haruhi, user=kyon)
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root."
  exit 1
fi

echo "=== Arch Linux Dual‑Boot Installer ==="
read -p "Введите путь к EFI‑разделу (FAT32): " EFI_PART
read -p "Введите путь к корневому разделу (ext4): " ROOT_PART
echo "Будут отформатированы следующие разделы: $EFI_PART и $ROOT_PART"
read -p "OK? (y/n): " c
if [[ "$c" != "y" ]]; then
  echo "Отмена установки."
  exit 1
fi

echo "Форматирование EFI‑раздела $EFI_PART в FAT32..."
mkfs.fat -F32 "$EFI_PART"

echo "Форматирование корневого раздела $ROOT_PART в ext4..."
mkfs.ext4 "$ROOT_PART"

echo "Монтирование корневого раздела $ROOT_PART в /mnt..."
mount "$ROOT_PART" /mnt

echo "Создание и монтирование точки /mnt/boot/efi..."
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

echo "Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager

echo "Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Создание скрипта для конфигурации в chroot..."
cat > /mnt/root/chroot_script.sh << 'EOF'
#!/bin/bash
set -euo pipefail
echo "=== Начало конфигурации в chroot ==="

# --- Системные настройки ---
echo "Настройка временной зоны и аппаратных часов..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf

# --- Настройка hostname и hosts ---
echo haruhi > /etc/hostname
cat > /etc/hosts << H
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
H

# --- Настройка root и создание пользователя ---
echo "Установка пароля для root..."
passwd
echo "Создание пользователя kyon с правами sudo..."
useradd -m -G wheel -s /bin/bash kyon
echo "Установите пароль для пользователя kyon:"
passwd kyon
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# --- Репозиторий multilib ---
sed -i '/#\[multilib\]/s/^#//' /etc/pacman.conf
sed -i '/#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /etc/pacman.conf

echo "Обновление системы..."
pacman -Syu --noconfirm

# --- Установка основных пакетов и приложений ---
pacman -S --noconfirm \
  gnome gdm gnome-tweaks gnome-shell-extensions flatpak ntfs-3g alacritty \
  mesa nvidia nvidia-utils vulkan-icd-loader vulkan-intel vulkan-nvidia \
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
  networkmanager wireguard-tools openssh \
  obs-studio telegram-desktop krita wine steam \
  htop wget curl bash-completion man-db man-pages neovim \
  nautilus gparted unzip p7zip rsync \
  bluez bluez-utils blueman

# --- Установка AUR-хелпера и AUR-пакетов ---
if ! command -v yay &>/dev/null; then
  cd /opt
  git clone https://aur.archlinux.org/yay.git
  chown -R $(whoami):$(whoami) yay
  cd yay
  makepkg -si --noconfirm
fi
yay -S --noconfirm visual-studio-code-bin discord obsidian

# --- Установка Flatpak-приложений ---
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
  org.mozilla.firefox \
  org.telegram.desktop \
  md.obsidian.Obsidian \
  com.obsproject.Studio \
  org.kde.krita

# --- Включение автозапуска сервисов ---
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth

echo "=== Конфигурация в chroot завершена ==="
EOF

chmod +x /mnt/root/chroot_script.sh

echo "Запуск конфигурационного скрипта в chroot..."
arch-chroot /mnt /root/chroot_script.sh

echo "Установка GRUB-загрузчика..."
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

echo "Отмонтирование разделов..."
umount -R /mnt

echo "Установка завершена — перезагрузи систему!"
