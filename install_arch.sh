#!/bin/bash
set -euo pipefail

# === Глобальные переменные ===
EFI_PART="/dev/sda4"
ROOT_PART="/dev/sda5"
DISK="/dev/sda"
HOSTNAME="haruhi"
USERNAME="kyon"
LOCALE="ru_RU.UTF-8"
KEYMAP="ru"

main() {
  validate_disk_setup
  format_partitions
  mount_partitions
  enable_ntp
  install_base_system
  generate_fstab
  create_chroot_script
  execute_chroot_script
  install_grub
  unmount_and_reboot
}

validate_disk_setup() {
  if [[ ! -b $EFI_PART || ! -b $ROOT_PART ]]; then
    printf "Ошибка: Разделы EFI (%s) или ROOT (%s) не существуют\n" "$EFI_PART" "$ROOT_PART" >&2
    return 1
  fi
}

format_partitions() {
  printf "[+] Форматирование EFI (%s) в FAT32...\n" "$EFI_PART"
  mkfs.fat -F32 "$EFI_PART"

  printf "[+] Форматирование ROOT (%s) в ext4...\n" "$ROOT_PART"
  mkfs.ext4 "$ROOT_PART"
}

mount_partitions() {
  printf "[+] Монтирование корневого раздела...\n"
  mount "$ROOT_PART" /mnt

  printf "[+] Монтирование EFI...\n"
  mkdir -p /mnt/boot/efi
  mount "$EFI_PART" /mnt/boot/efi
}

enable_ntp() {
  printf "[+] Включение синхронизации времени...\n"
  timedatectl set-ntp true
}

install_base_system() {
  printf "[+] Установка базовой системы...\n"
  pacstrap /mnt base base-devel linux linux-firmware \
    intel-ucode nvidia nvidia-utils nvidia-dkms \
    xorg xorg-xinit gnome gdm \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    networkmanager network-manager-applet \
    steam lutris wine xorg-xrandr \
    acpilight xorg-xbacklight
}

generate_fstab() {
  printf "[+] Генерация fstab...\n"
  genfstab -U /mnt >> /mnt/etc/fstab
}

create_chroot_script() {
  cat > /mnt/root/chroot_script.sh << EOF
#!/bin/bash
set -euo pipefail

echo "=== Конфигурация системы ==="

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo "[*] Установка пароля для root"
passwd
useradd -m -G wheel,video -s /bin/bash ${USERNAME}
echo "[*] Установка пароля для ${USERNAME}"
passwd ${USERNAME}
grep -q '^%wheel' /etc/sudoers || echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

echo "[*] Включите multilib в /etc/pacman.conf"
read -n 1 -s -r -p "Нажмите любую клавишу для запуска nano..."
nano /etc/pacman.conf

pacman -Syu --noconfirm

echo "[*] Установка yay..."
runuser -u ${USERNAME} -- bash -c '
cd /home/${USERNAME}
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
'

echo "[*] Установка AUR-пакетов..."
runuser -u ${USERNAME} -- yay -S --noconfirm visual-studio-code-bin discord

echo "[*] Настройка Flatpak..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.mozilla.firefox org.telegram.desktop \
  md.obsidian.Obsidian com.obsproject.Studio org.kde.krita \
  org.gnome.Extensions org.libreoffice.LibreOffice

echo "[*] Включение сервисов..."
systemctl enable NetworkManager
systemctl enable gdm

echo "[*] Настройка управления яркостью..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/90-backlight.rules << UDEV
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
UDEV

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-intel.conf << XCONF
Section "Device"
  Identifier  "Intel Graphics"
  Driver      "intel"
  Option      "Backlight"  "intel_backlight"
EndSection
XCONF

echo "=== Конфигурация завершена ==="
EOF

  chmod +x /mnt/root/chroot_script.sh
}

execute_chroot_script() {
  printf "[+] Вход в chroot и запуск скрипта...\n"
  arch-chroot /mnt /root/chroot_script.sh
}

install_grub() {
  if [[ -d /sys/firmware/efi/efivars ]]; then
    printf "[+] Установка GRUB в UEFI...\n"
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  else
    printf "Ошибка: UEFI не обнаружен. Настройте BIOS на режим UEFI.\n" >&2
    return 1
  fi
}

unmount_and_reboot() {
  printf "[+] Отмонтирование разделов...\n"
  umount -R /mnt
  printf "Установка завершена. Перезагрузите систему.\n"
}

main "$@"
