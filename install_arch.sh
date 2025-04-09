#!/bin/bash
# Автоматическая конвертация CRLF в LF (удаление \r)
sed -i 's/\r$//' "$0"

set -euo pipefail

# ============================================================
# Arch Linux Automated Installation
# Использование следующих шагов:
# 1. Форматирование разделов (EFI и ROOT)
# 2. Монтирование разделов
# 3. Синхронизация времени
# 4. Установка базовой системы и генерация fstab
# 5. Вход в chroot: настройка локали (русская), hostname, создание пользователя,
#    активация репозитория multilib, обновление системы (pacman -Syu),
#    установка GNOME, Flatpak-приложений, и установка GRUB.
# 6. Завершение установки: выход из chroot, размонтирование и перезагрузка.
# ============================================================

# === Этап 1: Форматирование разделов ===
echo "=== Arch Linux Automated Installer ==="
echo "Перед запуском отредактируйте этот скрипт, заменив:"
echo "  /dev/EFI_PART - на ваш EFI-раздел"
echo "  /dev/ROOT_PART - на ваш корневой раздел"
read -p "Нажмите любую клавишу для продолжения..."

echo "[+] Форматирование EFI-раздела /dev/EFI_PART в FAT32..."
mkfs.fat -F32 /dev/sda4

echo "[+] Форматирование корневого раздела /dev/ROOT_PART в ext4..."
mkfs.ext4 /dev/sda5

# === Этап 2: Монтирование разделов ===
echo "[+] Монтирование корневого раздела в /mnt..."
mount /dev/sda5 /mnt

echo "[+] Создание и монтирование точки /mnt/boot/efi..."
mkdir -p /mnt/boot/efi
mount /dev/sda4 /mnt/boot/efi

# === Этап 3: Синхронизация времени ===
echo "[+] Синхронизация времени (NTP)..."
timedatectl set-ntp true

# === Этап 4: Установка базовой системы ===
echo "[+] Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano git grub efibootmgr networkmanager

# === Этап 5: Генерация fstab ===
echo "[+] Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# === Этап 6: Конфигурация в chroot-среде ===
echo "[+] Создание chroot-скрипта..."
cat > /mnt/root/chroot_script.sh << 'EOF'
#!/bin/bash
set -euo pipefail
echo ""
echo "=== Конфигурация системы внутри chroot ==="

# --- Настройка времени и локали ---
echo "[*] Настройка временной зоны..."
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
cat > /etc/hosts << EOFHOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   haruhi.localdomain haruhi
EOFHOSTS

# --- Установка паролей и создание пользователя ---
echo "[*] Установка пароля для root..."
passwd
echo "[*] Создание пользователя kyon с правами sudo..."
useradd -m -G wheel -s /bin/bash kyon
echo "[*] Установка пароля для пользователя kyon..."
passwd kyon
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# --- Активация multilib-репозитория ---
echo "[*] Активируйте multilib-репозиторий вручную."
echo "   Откройте /etc/pacman.conf и раскомментируйте раздел [multilib] и строку:"
echo "       Include = /etc/pacman.d/mirrorlist"
read -n 1 -s -r -p "Нажмите любую клавишу для открытия редактора nano..."
nano /etc/pacman.conf

# --- Обновление системы ---
echo "[*] Обновление системы..."
pacman -Syu --noconfirm

# --- Установка GNOME и основных пакетов ---
echo "[*] Установка GNOME и базовых программ..."
pacman -S --noconfirm gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber networkmanager wireguard-tools steam
  

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
runuser -u kyon -- yay -S --noconfirm visual-studio-code-bin discord

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


# --- Настройка автозапуска сервисов ---
echo "[*] Включение сервисов..."
systemctl enable NetworkManager
systemctl enable gdm

echo ""
echo "=== Конфигурация в chroot завершена ==="
EOF

chmod +x /mnt/root/chroot_script.sh

# === Этап 7: Запуск chroot-скрипта ===
echo "[+] Запуск скрипта в chroot..."
arch-chroot /mnt /root/chroot_script.sh

# === Этап 8: Установка загрузчика GRUB (только в UEFI-режиме) ===
echo "[+] Проверка UEFI-режима..."
if [[ -d /sys/firmware/efi/efivars ]]; then
  echo "[*] UEFI режим активен. Установка GRUB..."
  arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
else
  echo "[!] Система загружена в режиме Legacy BIOS. Проверьте настройки BIOS."
  exit 1
fi

# === Этап 9: Отмонтирование и перезагрузка ===
echo "[+] Отмонтирование разделов..."
umount -R /mnt

echo ""
echo "=== Установка завершена. Перезагрузите систему! ==="
