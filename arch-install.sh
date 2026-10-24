#!/usr/bin/env bash
# ============================================================================
#  Installazione automatica Arch Linux  (UEFI + dual boot + GRUB + Hyprland)
#  Da lanciare come root dalla live USB:   bash arch-install.sh
#
#  NON formatta la partizione EFI (condivisa con Ubuntu): formatta SOLO ROOT_PART.
# ============================================================================
set -Eeuo pipefail

### ============================ CONFIGURAZIONE ==============================
EFI_PART="/dev/sda1"          # partizione EFI ESISTENTE (non viene formattata)
ROOT_PART="/dev/sda3"         # partizione root di Arch (VIENE FORMATTATA ext4)
FORMAT_ROOT="yes"             # "no" per riusare il filesystem esistente
HOSTNAME="archlinux"
USERNAME="nikynik"
TIMEZONE="Europe/Rome"
LOCALE="it_IT.UTF-8"
KEYMAP="it"
WIFI_SSID="TNCAP5013CC"       # la password viene chiesta durante l'esecuzione
RTC_LOCALTIME="yes"           # "yes" SOLO se hai anche Windows (Ubuntu usa UTC)
INSTALL_YAY="yes"             # installa yay (yay-bin, senza compilare Go)
INSTALL_CHROME="yes"          # google-chrome da AUR (richiede INSTALL_YAY=yes)
EXTRA_PKGS="vulkan-radeon"    # es. "vulkan-radeon" oppure "nvidia-open nvidia-utils"
### ==========================================================================

msg()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mAVVISO:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERRORE:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "fallito alla riga $LINENO (comando: $BASH_COMMAND)"' ERR

ask_pass() {  # ask_pass "Etichetta" NOMEVAR
    local p1 p2
    while :; do
        read -rsp "$1: " p1; echo
        read -rsp "Ripeti: " p2; echo
        [[ -n $p1 && $p1 == "$p2" ]] && break
        echo "Vuota o non coincidono, riprova."
    done
    printf -v "$2" '%s' "$p1"
}

### ------------------------------ Controlli --------------------------------
[[ $EUID -eq 0 ]]                    || die "Lancialo come root."
[[ -d /sys/firmware/efi/efivars ]]   || die "Avvio non UEFI: questo script richiede UEFI."
[[ -b $EFI_PART ]]                   || die "$EFI_PART non esiste."
[[ -b $ROOT_PART ]]                  || die "$ROOT_PART non esiste."
[[ $(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null) == vfat ]] \
                                     || die "$EFI_PART non e' FAT32: non sembra una partizione EFI."

### ------------------------------ Tastiera/font ----------------------------
loadkeys "$KEYMAP"
setfont ter-128b 2>/dev/null || true

### ------------------------------ Domande iniziali -------------------------
msg "Disposizione dischi"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
cat <<EOF

  EFI  (resta intatta) : $EFI_PART
  ROOT (FORMATTATA)    : $ROOT_PART   (format: $FORMAT_ROOT)
  Hostname / utente    : $HOSTNAME / $USERNAME
EOF
read -rp $'\nScrivi SI per procedere: ' ok
[[ $ok == SI ]] || die "Annullato."

ask_pass "Password di root" ROOT_PASS
ask_pass "Password di $USERNAME" USER_PASS
read -rsp "Password Wi-Fi '$WIFI_SSID' (invio = salta, es. se usi cavo): " WIFI_PASS; echo

### ------------------------------ Rete -------------------------------------
msg "Rete"
if ! ping -c1 -W3 archlinux.org &>/dev/null; then
    WLAN=$(ls /sys/class/net | grep -E '^wl' | head -n1 || true)
    [[ -n $WLAN && -n $WIFI_PASS ]] || die "Nessuna connessione e nessun Wi-Fi configurabile."
    iwctl station "$WLAN" scan
    sleep 4
    iwctl --passphrase "$WIFI_PASS" station "$WLAN" connect "$WIFI_SSID"
    sleep 5
    ping -c3 archlinux.org || die "Ancora nessuna rete."
fi
timedatectl set-ntp true
timedatectl set-timezone "$TIMEZONE" || true

### ------------------------------ Partizioni -------------------------------
msg "Partizioni"
umount -R /mnt 2>/dev/null || true
if [[ $FORMAT_ROOT == yes ]]; then
    mkfs.ext4 -F -L arch "$ROOT_PART"
fi
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi          # montata PRIMA di genfstab, cosi' finisce in fstab

### ------------------------------ Pacchetti --------------------------------
msg "Installazione sistema base + Hyprland (pacstrap)"
pacstrap -K /mnt \
    base base-devel linux linux-firmware amd-ucode \
    nano sudo git networkmanager wpa_supplicant \
    grub efibootmgr os-prober ntfs-3g dosfstools \
    hyprland kitty waybar rofi xdg-desktop-portal-hyprland polkit \
    sddm qt6-svg qt6-virtualkeyboard qt6-multimedia-ffmpeg quickshell \
    pipewire pipewire-pulse wireplumber \
    ttf-dejavu noto-fonts mesa \
    firefox nvim zsh \
    $EXTRA_PKGS

genfstab -U /mnt > /mnt/etc/fstab

### ------------------------------ Variabili per il chroot ------------------
{
    for v in HOSTNAME USERNAME TIMEZONE LOCALE KEYMAP WIFI_SSID RTC_LOCALTIME \
             INSTALL_YAY INSTALL_CHROME ROOT_PASS USER_PASS WIFI_PASS; do
        printf '%s=%q\n' "$v" "${!v}"
    done
} > /mnt/root/vars.sh
chmod 600 /mnt/root/vars.sh

### ------------------------------ Script eseguito in chroot ----------------
cat > /mnt/root/chroot-setup.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/vars.sh
msg() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

msg "Orario"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
if [[ $RTC_LOCALTIME == yes ]]; then hwclock --systohc --localtime; else hwclock --systohc; fi

msg "Lingua e tastiera"
sed -i "s/^#\(${LOCALE} UTF-8\)/\1/; s/^#\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE"   > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

msg "Hostname e rete"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS
systemctl enable NetworkManager

msg "SDDM (display manager)"
systemctl enable sddm

if [[ -n ${WIFI_PASS:-} ]]; then
    # profilo Wi-Fi gia' pronto: al primo avvio si connette da solo
    cat > "/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection" <<NMEOF
[connection]
id=$WIFI_SSID
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASS

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
    chmod 600 "/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
fi

msg "Utenti"
printf 'root:%s\n' "$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

msg "initramfs"
mkinitcpio -P

msg "GRUB (con os-prober per il dual boot)"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch --recheck
if grep -q '^#\?GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
    sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi
grub-mkconfig -o /boot/grub/grub.cfg

if [[ $INSTALL_YAY == yes ]]; then
    msg "yay (AUR) come utente $USERNAME"
    cleanup() { rm -f /etc/sudoers.d/99-tmp-nopasswd; }
    trap cleanup EXIT
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-tmp-nopasswd
    chmod 440 /etc/sudoers.d/99-tmp-nopasswd
    su - "$USERNAME" -c 'git clone https://aur.archlinux.org/yay-bin.git ~/yay-bin \
        && cd ~/yay-bin && makepkg -si --noconfirm && cd ~ && rm -rf ~/yay-bin' \
        || echo "AVVISO: installazione di yay fallita (si puo' rifare dopo)."
    if [[ $INSTALL_CHROME == yes ]] && command -v yay >/dev/null; then
        su - "$USERNAME" -c 'yay -S --noconfirm google-chrome' \
            || echo "AVVISO: google-chrome non installato (si puo' rifare dopo)."
    fi
    cleanup
fi

rm -f /root/vars.sh
CHROOT_EOF
chmod 700 /mnt/root/chroot-setup.sh

msg "Configurazione nel sistema appena installato"
arch-chroot /mnt /root/chroot-setup.sh
rm -f /mnt/root/chroot-setup.sh /mnt/root/vars.sh

### ------------------------------ Fine -------------------------------------
umount -R /mnt
msg "Installazione completata"
cat <<EOF

Dopo il riavvio:
  - togli la USB e accedi come $USERNAME
  - SDDM parte in automatico: scegli la sessione "Hyprland" dal menu in basso e accedi
    (in alternativa da TTY:  Start-Hyprland)
  - Quickshell: crea la tua config in ~/.config/quickshell/ e avvialo con:  quickshell
    (per lanciarlo con Hyprland aggiungi in hyprland.conf:  exec-once = quickshell)
  - Da Ubuntu aggiornare il menu GRUB con sudo update-grub
  - se RTC_LOCALTIME=yes:  sudo timedatectl set-local-rtc 1 --adjust-system-clock
  - Fare procedura installazione certificato di avvio per Archlinux

EOF
read -rp "Riavviare ora? [s/N] " r
[[ $r =~ ^[sSyY]$ ]] && reboot
