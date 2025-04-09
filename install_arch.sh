#!/bin/bash
# Автоматическая конвертация CRLF → LF, чтобы не требовалось вручную запускать sed.
sed -i 's/\r$//' "$0"

set -euo pipefail

# ============================================================
# Arch Linux Automated Installation for Dual-Boot Laptop
# Hostname: haruhi | User: kyon
# Использует 60 ГБ свободного пространства:
#   Создаются 2 раздела: EFI (1 GB FAT32) и ROOT (~59 GB ext4)
# GNOME, NVIDIA/Intel GPU (универсальное управление яркостью),
# Flatpak, AUR (yay), multilib и прочее.
# ============================================================

# --- 1. Запрос диска для разметки ---
echo "=== Arch Linux Automated Installation ==="
echo "На указанном диске будет создано 2 новых раздела из свободного пространства:"
echo " - EFI-раздел: 1 ГБ (FAT32)"
echo " - ROOT-раздел: оставшиеся ~59 ГБ (ext4)"
read -p "Введите диск, на котором имеется 60 ГБ свободного места (например, /dev/sda или /dev/nvme0n1): " DISK
echo ""
echo "Будет произведена разметка диска $DISK."
read -p "Продолжить? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
  echo "Отмена установки."
  exit 1
fi

# --- 2. Создание разделов из свободного пространства ---
echo "[*] Создание новых разделов на диске $DISK..."
# Используем sfdisk для создания двух новых разделов:
# Первая запись: размер 1G, тип EF (EFI System Partition).
# Вторая запись: остальное свободное пространство, тип Linux.
sfdisk --no-reread "$DISK" <<EOF
,1G,EF
,,L
EOF

# Определяем имена новых разделов. Для NVMe-устройств нужно использовать суффикс p (например, /dev/nvme0n1p1).
if [[ "$DISK" =~ nvme ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

echo "[*] Новые разделы: EFI: $EFI_PART, ROOT: $ROOT_PART"

# --- 3. Форматирование разделов ---
echo "[+] Форматирование EFI-раздела $EFI_PART в FAT32..."
mkfs.fat -F32 "$EFI_PART"

echo "[+] Форматирование ROOT-раздела $ROOT_PART в ext4..."
mkfs.ext4 "$ROOT_PART"

# --- 4. Монтирование разделов ---
echo "[+] Монтирование ROOT-раздела в /mnt..."
mount "$ROOT_PART" /mnt

echo "[+] Создание и монтирование точки /mnt/boot/efi..."
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# --- 5. Синхронизация времени ---
echo "[+] Синхронизация времени (NTP)..."
timedatectl set-ntp true

# --- 6. Установка базовой системы ---
echo "[+] Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager reflector

# --- 7. Генерация fstab ---
echo "[+] Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- 8. Создание скрипта для конфигурации в chroot ---
echo "[+] Создание chroot-скрипта..."
cat > /mnt/root/chroot_script.sh << 'EOF'
#!/bin/bash
set -euo pipefail
echo ""
echo "=== Конфигурация системы внутри chroot ==="

# --- Системные настройки и локали ---
echo "[*] Настройка временной зоны и аппаратных часов..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

echo "[*] Генерация локали..."
# Раскомментируем ru_RU.UTF-8 и en_US.UTF-8 в /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
# Устанавливаем русский язык:
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

# --- Установка паролей и создание пользователя ---
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

# --- Обновление зеркал ---
echo "[*] Обновление списка зеркал с помощью reflector..."
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "[*] Обновление системы..."
pacman -Syu --noconfirm

# --- Установка GNOME и базовых пакетов ---
echo "[*] Установка GNOME и базовых программ..."
pacman -S --noconfirm --needed \
  gnome gdm gnome-tweaks gnome-shell-extensions flatpak ntfs-3g alacritty \
  mesa xf86-video-intel vulkan-intel \
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
  networkmanager wireguard-tools openssh \
  obs-studio krita steam \
  htop wget curl bash-completion man-db man-pages neovim \
  nautilus gparted unzip p7zip rsync \
  bluez bluez-utils blueman

# --- Установка драйверов NVIDIA (если понадобится) ---
echo "[*] Проприетарные драйверы NVIDIA можно установить позже, например с помощью:"
echo "    pacman -S --noconfirm nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils"
# Раскомментируйте и настройте этот блок, если требуется драйвер NVIDIA.

# --- Установка AUR-хелпера (yay) от пользователя kyon ---
echo "[*] Установка AUR-хелпера yay..."
runuser -u kyon -- bash -c '
cd /home/kyon
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
'

# --- Установка AUR-пакетов ---
echo "[*] Установка AUR-пакетов..."
runuser -u kyon -- yay -S --noconfirm visual-studio-code-bin discord obsidian

# --- Установка Flatpak-приложений ---
echo "[*] Установка Flatpak-приложений..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
  org.mozilla.firefox \
  org.telegram.desktop \
  md.obsidian.Obsidian \
  com.obsproject.Studio \
  org.kde.krita \
  org.gnome.Extensions \
  org.libreoffice.LibreOffice

# --- Настройка управления яркостью (универсальное правило) ---
echo "[*] Настройка правил управления яркостью..."
cat << 'EOL' > /etc/udev/rules.d/90-backlight.rules
# Правила для Intel GPU
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
# Правила для NVIDIA GPU (если поддерживается)
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="nvidia_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="nvidia_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOL

# --- Активация автозапуска сервисов ---
echo "[*] Включение сервисов..."
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth

echo ""
echo "=== Конфигурация в chroot завершена ==="
EOF

chmod +x /mnt/root/chroot_script.sh

# === 9. Запуск chroot-скрипта ===
echo "[+] Запуск скрипта в chroot..."
arch-chroot /mnt /root/chroot_script.sh

# === 10. Установка GRUB (только в UEFI-режиме) ===
echo "[+] Проверка UEFI-режима..."
if [[ -d /sys/firmware/efi/efivars ]]; then
  echo "[*] UEFI режим активен. Установка GRUB..."
  arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
else
  echo "[!] Система загружена в режиме Legacy BIOS. Проверьте настройки BIOS."
  exit 1
fi

# === 11. Финал: Отмонтирование разделов ===
echo "[+] Отмонтирование разделов..."
umount -R /mnt

echo ""
echo "=== Установка завершена. Перезагрузи систему! ==="
