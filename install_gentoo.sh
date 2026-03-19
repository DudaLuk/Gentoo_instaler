#!/bin/bash
# =============================================================================
# Gentoo Auto-Installer
# Uruchamiany z Ubuntu Live CD/USB na maszynie wirtualnej.
# Instaluje: system bazowy Gentoo + KDE Plasma + systemd
# Tworzy użytkownika: lukasz  (hasło: 666)
# =============================================================================
# Użycie:
#   sudo bash install_gentoo.sh [DYSK]
#   Np.: sudo bash install_gentoo.sh /dev/sda
#        sudo bash install_gentoo.sh /dev/vda
#   Jeśli DYSK nie zostanie podany, skrypt spróbuje go wykryć automatycznie.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Kolory do logowania
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Konfiguracja
# ---------------------------------------------------------------------------
GENTOO_MIRROR="https://distfiles.gentoo.org"
ARCH="amd64"
STAGE3_VARIANT="stage3-amd64-systemd"
MOUNTPOINT="/mnt/gentoo"
TIMEZONE="Europe/Warsaw"
HOSTNAME="gentoo-vm"
USERNAME="lukasz"
USER_PASSWORD="666"
ROOT_PASSWORD="toor"
SWAP_SIZE="2G"       # rozmiar partycji swap (tylko wartości MiB lub GiB, np. 2G lub 2048M)
BOOT_SIZE="512M"     # rozmiar partycji /boot lub EFI (tylko MiB, np. 512M)

# ---------------------------------------------------------------------------
# Funkcja pomocnicza: konwersja rozmiaru na MiB
# ---------------------------------------------------------------------------
parse_mib() {
    local s="${1^^}"
    if   [[ "$s" =~ ^([0-9]+)G$ ]]; then echo $(( BASH_REMATCH[1] * 1024 ))
    elif [[ "$s" =~ ^([0-9]+)M$ ]]; then echo "${BASH_REMATCH[1]}"
    else die "Nieobsługiwany format rozmiaru: $1 (użyj np. 512M lub 2G)"; fi
}

# make.conf – liczba wątków kompilacji
NCPU=$(nproc 2>/dev/null || echo 2)
MAKEOPTS="-j${NCPU}"

# ---------------------------------------------------------------------------
# Sprawdzenie: root
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Uruchom skrypt jako root (sudo)."

# ---------------------------------------------------------------------------
# Wykrywanie / wybór dysku
# ---------------------------------------------------------------------------
if [[ -n "${1:-}" ]]; then
    DISK="$1"
else
    # Automatyczne wykrycie – wybierz pierwszy dysk blokowy (nie pętla/cd)
    DISK=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v loop | head -1)
    [[ -n "$DISK" ]] || die "Nie znaleziono dysku. Podaj dysk jako argument: $0 /dev/sda"
    warn "Automatycznie wybrano dysk: $DISK"
fi

[[ -b "$DISK" ]] || die "Dysk $DISK nie istnieje lub nie jest urządzeniem blokowym."

# ---------------------------------------------------------------------------
# Wykrywanie trybu rozruchu: UEFI lub BIOS
# ---------------------------------------------------------------------------
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
    info "Wykryto tryb UEFI."
else
    BOOT_MODE="bios"
    info "Wykryto tryb BIOS/Legacy."
fi

# ---------------------------------------------------------------------------
# Ostrzeżenie – kasujemy dane!
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${RED}!!! UWAGA !!!"
echo "Skrypt skasuje WSZYSTKIE dane na dysku: ${DISK}"
echo "Tryb rozruchu : ${BOOT_MODE}"
echo "Punkt montowania : ${MOUNTPOINT}"
echo -e "Naciśnij ENTER aby kontynuować lub Ctrl+C aby przerwać.${RESET}"
read -r

# ---------------------------------------------------------------------------
# Instalacja narzędzi potrzebnych w Ubuntu Live
# ---------------------------------------------------------------------------
info "Aktualizacja list pakietów i instalacja wymaganych narzędzi…"
apt-get update -qq
apt-get install -y -qq \
    wget curl parted dosfstools e2fsprogs arch-install-scripts \
    gnupg2 xz-utils lzma bzip2 > /dev/null

# ---------------------------------------------------------------------------
# Partycjonowanie
# ---------------------------------------------------------------------------
info "Partycjonowanie dysku ${DISK}…"

# Oblicz granice partycji w MiB
BOOT_MIB=$(parse_mib "$BOOT_SIZE")
SWAP_MIB=$(parse_mib "$SWAP_SIZE")

# Odmontuj ewentualne montowania
swapoff -a 2>/dev/null || true
umount -R "${MOUNTPOINT}" 2>/dev/null || true

# Usuń stary GPT/MBR
sgdisk --zap-all "${DISK}" 2>/dev/null || parted -s "${DISK}" mklabel gpt

if [[ "$BOOT_MODE" == "uefi" ]]; then
    # EFI: 1MiB .. BOOT_MIB
    # swap: BOOT_MIB .. (BOOT_MIB + SWAP_MIB)
    # root: (BOOT_MIB + SWAP_MIB) .. 100%
    SWAP_END=$(( BOOT_MIB + SWAP_MIB ))
    parted -s "${DISK}" \
        mklabel gpt \
        mkpart "EFI"  fat32      1MiB          "${BOOT_MIB}MiB" \
        set 1 esp on \
        mkpart "swap" linux-swap "${BOOT_MIB}MiB"  "${SWAP_END}MiB" \
        mkpart "root" ext4       "${SWAP_END}MiB"  100%
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
else
    # BIOS: mała partycja BIOS boot (1-3 MiB) + boot + swap + root
    # boot: 3MiB .. (3 + BOOT_MIB)
    # swap: (3 + BOOT_MIB) .. (3 + BOOT_MIB + SWAP_MIB)
    # root: (3 + BOOT_MIB + SWAP_MIB) .. 100%
    BIOS_END=3
    BOOT_END=$(( BIOS_END + BOOT_MIB ))
    SWAP_END=$(( BOOT_END + SWAP_MIB ))
    parted -s "${DISK}" \
        mklabel gpt \
        mkpart "BIOS" 1MiB "${BIOS_END}MiB" \
        set 1 bios_grub on \
        mkpart "boot" ext4       "${BIOS_END}MiB"  "${BOOT_END}MiB" \
        mkpart "swap" linux-swap "${BOOT_END}MiB"  "${SWAP_END}MiB" \
        mkpart "root" ext4       "${SWAP_END}MiB"  100%
    BOOT_PART="${DISK}2"
    SWAP_PART="${DISK}3"
    ROOT_PART="${DISK}4"
fi

# Odśwież tablicę partycji
partprobe "${DISK}" 2>/dev/null || true
sleep 2

# ---------------------------------------------------------------------------
# Formatowanie
# ---------------------------------------------------------------------------
info "Formatowanie partycji…"

if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.fat -F32 -n EFI "${EFI_PART}"
else
    mkfs.ext4 -L boot -q "${BOOT_PART}"
fi

mkswap -L swap "${SWAP_PART}"
swapon "${SWAP_PART}"
mkfs.ext4 -L root -q "${ROOT_PART}"

# ---------------------------------------------------------------------------
# Montowanie
# ---------------------------------------------------------------------------
info "Montowanie systemu plików…"
mkdir -p "${MOUNTPOINT}"
mount "${ROOT_PART}" "${MOUNTPOINT}"

if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkdir -p "${MOUNTPOINT}/boot/efi"
    mount "${EFI_PART}" "${MOUNTPOINT}/boot/efi"
else
    mkdir -p "${MOUNTPOINT}/boot"
    mount "${BOOT_PART}" "${MOUNTPOINT}/boot"
fi

# ---------------------------------------------------------------------------
# Pobieranie stage3
# ---------------------------------------------------------------------------
info "Pobieranie aktualnego stage3 (${STAGE3_VARIANT})…"
LATEST_FILE_URL="${GENTOO_MIRROR}/releases/${ARCH}/autobuilds/latest-${STAGE3_VARIANT}.txt"
# Plik latest-*.txt jest podpisany PGP – odfiltruj nagłówki PGP, komentarze i puste linie,
# a następnie wyciągnij pierwszą kolumnę z linii zawierającej ścieżkę do tarballa.
LATEST_PATH=$(wget -qO- "${LATEST_FILE_URL}" | grep '\.tar\.' | grep -v '^#' | awk '{print $1}' | head -1)
[[ -n "$LATEST_PATH" ]] || die "Nie udało się odczytać ścieżki stage3."

STAGE3_URL="${GENTOO_MIRROR}/releases/${ARCH}/autobuilds/${LATEST_PATH}"
STAGE3_FILE=$(basename "${LATEST_PATH}")

info "Pobieranie: ${STAGE3_URL}"
wget -q --show-progress -O "/tmp/${STAGE3_FILE}" "${STAGE3_URL}"
wget -q -O "/tmp/${STAGE3_FILE}.DIGESTS" "${STAGE3_URL}.DIGESTS" || \
    wget -q -O "/tmp/${STAGE3_FILE}.sha256" "${STAGE3_URL}.sha256" || true

# Weryfikacja sumy kontrolnej (jeśli plik z sumami dostępny)
if [[ -f "/tmp/${STAGE3_FILE}.sha256" ]]; then
    info "Weryfikacja sumy SHA256…"
    (cd /tmp && sha256sum -c "${STAGE3_FILE}.sha256" 2>/dev/null) || \
        warn "Nie można zweryfikować sumy – kontynuję."
fi

# ---------------------------------------------------------------------------
# Rozpakowywanie stage3
# ---------------------------------------------------------------------------
info "Rozpakowywanie stage3 do ${MOUNTPOINT}…"
tar xpf "/tmp/${STAGE3_FILE}" \
    --xattrs-include='*.*' \
    --numeric-owner \
    -C "${MOUNTPOINT}"
success "Stage3 rozpakowany."

# ---------------------------------------------------------------------------
# Kopiowanie resolv.conf (DNS)
# ---------------------------------------------------------------------------
cp /etc/resolv.conf "${MOUNTPOINT}/etc/resolv.conf"

# ---------------------------------------------------------------------------
# Montowanie wirtualnych systemów plików
# ---------------------------------------------------------------------------
info "Montowanie wirtualnych FS dla chroot…"
mount --types proc  /proc "${MOUNTPOINT}/proc"
mount --rbind       /sys  "${MOUNTPOINT}/sys"
mount --make-rslave       "${MOUNTPOINT}/sys"
mount --rbind       /dev  "${MOUNTPOINT}/dev"
mount --make-rslave       "${MOUNTPOINT}/dev"
mount --rbind       /run  "${MOUNTPOINT}/run" 2>/dev/null || true
mount --make-rslave       "${MOUNTPOINT}/run" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Konfiguracja make.conf
# ---------------------------------------------------------------------------
info "Konfiguracja /etc/portage/make.conf…"
cat > "${MOUNTPOINT}/etc/portage/make.conf" << EOF
# Gentoo make.conf – wygenerowane przez install_gentoo.sh
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="${MAKEOPTS}"

# Systemd + Plasma USE flags
USE="systemd dbus udev X wayland alsa pulseaudio bluetooth networkmanager \
     kde plasma qt5 -gnome -gtk3 -minimal"

# Portage
PORTDIR="/var/db/repos/gentoo"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"

# Akceptacja licencji (wolne + redystrybuowalne binarne, np. linux-firmware)
ACCEPT_LICENSE="@FREE @BINARY-REDISTRIBUTABLE"

# Architektura
ACCEPT_KEYWORDS="amd64"

# Locale
L10N="pl"
LINGUAS="pl"

# Funkcje portage
FEATURES="parallel-fetch"

# Lustro
GENTOO_MIRRORS="${GENTOO_MIRROR}"

# Video (VirtualBox/QEMU – dostosuj jeśli potrzeba)
VIDEO_CARDS="vmware virtualbox qxl"
INPUT_DEVICES="libinput keyboard mouse"
EOF

# ---------------------------------------------------------------------------
# Portage – katalogi konfiguracyjne
# ---------------------------------------------------------------------------
mkdir -p "${MOUNTPOINT}/etc/portage/repos.conf"
cat > "${MOUNTPOINT}/etc/portage/repos.conf/gentoo.conf" << 'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
sync-rsync-verify-jobs = 1
sync-rsync-verify-metamanifest = yes
sync-rsync-verify-max-age = 24
trust-manifests = signed
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
sync-openpgp-keyserver = hkps://keys.gentoo.org
sync-openpgp-key-refresh-retry-count = 40
sync-openpgp-key-refresh-retry-overall-timeout = 1200
sync-openpgp-key-refresh-retry-delay-exp-base = 2
sync-openpgp-key-refresh-retry-delay-max = 60
sync-openpgp-key-refresh-retry-delay-multiple-of-key-count = 4
EOF

# ---------------------------------------------------------------------------
# Skrypt chroot – faza 1 (konfiguracja bazowa + portage sync + kernel)
# ---------------------------------------------------------------------------
info "Tworzenie skryptu chroot faza 1…"
cat > "${MOUNTPOINT}/tmp/chroot_phase1.sh" << 'CHROOT1'
#!/bin/bash
set -euo pipefail

info()    { echo -e "\e[0;36m[CHROOT1]\e[0m $*"; }
die()     { echo -e "\e[0;31m[ERROR]\e[0m $*" >&2; exit 1; }

# Wczytaj profil powłoki
source /etc/profile
export PS1="(chroot) ${PS1}"

# ---------------------------------------------------------------------------
# Synchronizacja Portage
# ---------------------------------------------------------------------------
info "Synchronizacja drzewa Portage (emerge --sync)…"
emerge-webrsync -q || emerge --sync -q

# Profil – systemd + Plasma
info "Ustawianie profilu: desktop/plasma/systemd…"
PLASMA_PROFILE=$(eselect profile list | grep -i "plasma/systemd" | grep -v "developer\|hardened" | head -1 | awk '{print $2}')
if [[ -z "$PLASMA_PROFILE" ]]; then
    # Fallback na desktop/systemd
    PLASMA_PROFILE=$(eselect profile list | grep "desktop/systemd" | grep -v "developer\|hardened" | head -1 | awk '{print $2}')
fi
[[ -n "$PLASMA_PROFILE" ]] || die "Nie znaleziono profilu plasma/systemd. Sprawdź listę: eselect profile list"
eselect profile set "${PLASMA_PROFILE}"
info "Ustawiony profil: ${PLASMA_PROFILE}"

# ---------------------------------------------------------------------------
# Strefa czasowa
# ---------------------------------------------------------------------------
info "Ustawianie strefy czasowej…"
echo "Europe/Warsaw" > /etc/timezone
emerge --config sys-libs/timezone-data -q

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------
info "Konfiguracja locale…"
cat > /etc/locale.gen << 'EOF'
pl_PL.UTF-8 UTF-8
pl_PL ISO-8859-2
en_US.UTF-8 UTF-8
en_US ISO-8859-1
EOF
locale-gen
eselect locale set pl_PL.UTF-8

# Wczytaj środowisko locale
env-update && source /etc/profile

# ---------------------------------------------------------------------------
# Aktualizacja systemu (world)
# ---------------------------------------------------------------------------
info "Aktualizacja systemu bazowego…"
emerge -uDN --with-bdeps=y --quiet-build @world

# ---------------------------------------------------------------------------
# Jądro systemu (binarne – szybka instalacja)
# ---------------------------------------------------------------------------
info "Instalacja jądra (gentoo-kernel-bin)…"
echo "sys-kernel/gentoo-kernel-bin ~amd64" >> /etc/portage/package.accept_keywords
emerge --quiet-build sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware

# ---------------------------------------------------------------------------
# Narzędzia systemowe
# ---------------------------------------------------------------------------
info "Instalacja narzędzi systemowych…"
emerge --quiet-build \
    sys-fs/e2fsprogs \
    sys-fs/dosfstools \
    net-misc/networkmanager \
    sys-apps/systemd-utils \
    app-admin/sudo

# Włącz NetworkManager
systemctl enable NetworkManager

CHROOT1
chmod +x "${MOUNTPOINT}/tmp/chroot_phase1.sh"

# ---------------------------------------------------------------------------
# Skrypt chroot – faza 2 (GRUB + Plasma + użytkownik)
# ---------------------------------------------------------------------------
info "Tworzenie skryptu chroot faza 2…"
cat > "${MOUNTPOINT}/tmp/chroot_phase2.sh" << CHROOT2
#!/bin/bash
set -euo pipefail

info()    { echo -e "\e[0;36m[CHROOT2]\e[0m \$*"; }
die()     { echo -e "\e[0;31m[ERROR]\e[0m \$*" >&2; exit 1; }

source /etc/profile
export PS1="(chroot) \${PS1}"

BOOT_MODE="${BOOT_MODE}"
DISK="${DISK}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
HOSTNAME_VAL="${HOSTNAME}"

# ---------------------------------------------------------------------------
# GRUB
# ---------------------------------------------------------------------------
info "Instalacja GRUB…"
if [[ "\$BOOT_MODE" == "uefi" ]]; then
    echo "sys-boot/grub:2 ~amd64" >> /etc/portage/package.accept_keywords 2>/dev/null || true
    emerge --quiet-build sys-boot/grub:2 sys-boot/efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo
else
    emerge --quiet-build sys-boot/grub:2
    grub-install --target=i386-pc "\${DISK}"
fi
grub-mkconfig -o /boot/grub/grub.cfg
success() { echo -e "\e[0;32m[OK]\e[0m \$*"; }
success "GRUB zainstalowany."

# ---------------------------------------------------------------------------
# KDE Plasma + SDDM + X
# ---------------------------------------------------------------------------
info "Instalacja KDE Plasma (to zajmie dużo czasu)…"

# Xorg
emerge --quiet-build x11-base/xorg-server x11-base/xorg-drivers

# Plasma
emerge --quiet-build kde-plasma/plasma-meta

# SDDM (Display Manager)
emerge --quiet-build kde-plasma/sddm-kcm x11-misc/sddm
systemctl enable sddm

# Podstawowe aplikacje KDE
emerge --quiet-build \
    kde-apps/konsole \
    kde-apps/dolphin \
    kde-apps/kate \
    app-editors/nano \
    www-client/firefox

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------
info "Ustawianie hostname…"
echo "\${HOSTNAME_VAL}" > /etc/hostname
hostnamectl set-hostname "\${HOSTNAME_VAL}" 2>/dev/null || true

# /etc/hosts
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   \${HOSTNAME_VAL}.localdomain  \${HOSTNAME_VAL}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# ---------------------------------------------------------------------------
# fstab
# ---------------------------------------------------------------------------
info "Generowanie /etc/fstab…"
# Pobierz UUID partycji
ROOT_UUID=\$(blkid -s UUID -o value "${ROOT_PART}")
SWAP_UUID=\$(blkid -s UUID -o value "${SWAP_PART}")

if [[ "\${BOOT_MODE}" == "uefi" ]]; then
    EFI_UUID=\$(blkid -s UUID -o value "${EFI_PART}")
    cat > /etc/fstab << EOF
# <fs>               <mp>        <type>  <opts>              <dump> <pass>
UUID=\${ROOT_UUID}   /           ext4    defaults,noatime    0 1
UUID=\${EFI_UUID}    /boot/efi   vfat    umask=0077          0 2
UUID=\${SWAP_UUID}   none        swap    sw                  0 0
EOF
else
    BOOT_UUID=\$(blkid -s UUID -o value "${BOOT_PART:-${DISK}2}")
    cat > /etc/fstab << EOF
# <fs>               <mp>        <type>  <opts>              <dump> <pass>
UUID=\${ROOT_UUID}   /           ext4    defaults,noatime    0 1
UUID=\${BOOT_UUID}   /boot       ext4    defaults,noatime    0 2
UUID=\${SWAP_UUID}   none        swap    sw                  0 0
EOF
fi

# ---------------------------------------------------------------------------
# Hasło roota
# ---------------------------------------------------------------------------
info "Ustawianie hasła root…"
echo "root:\${ROOT_PASSWORD}" | chpasswd

# ---------------------------------------------------------------------------
# Tworzenie użytkownika
# ---------------------------------------------------------------------------
info "Tworzenie użytkownika \${USERNAME}…"
useradd -m -G users,wheel,audio,video,plugdev,portage \
    -s /bin/bash "\${USERNAME}" 2>/dev/null || \
    usermod -aG users,wheel,audio,video,plugdev "\${USERNAME}"
echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd

# sudo dla grupy wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || \
    echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

# ---------------------------------------------------------------------------
# Usługi systemd
# ---------------------------------------------------------------------------
info "Włączanie usług systemd…"
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable systemd-timesyncd

info "Konfiguracja gotowa!"
CHROOT2
chmod +x "${MOUNTPOINT}/tmp/chroot_phase2.sh"

# ---------------------------------------------------------------------------
# Uruchomienie fazy 1 w chroot
# ---------------------------------------------------------------------------
info "Uruchamianie chroot faza 1 (Portage sync + jądro)…"
chroot "${MOUNTPOINT}" /bin/bash /tmp/chroot_phase1.sh

# ---------------------------------------------------------------------------
# Uruchomienie fazy 2 w chroot
# ---------------------------------------------------------------------------
info "Uruchamianie chroot faza 2 (GRUB + Plasma + użytkownik)…"
chroot "${MOUNTPOINT}" /bin/bash /tmp/chroot_phase2.sh

# ---------------------------------------------------------------------------
# Sprzątanie i odmontowywanie
# ---------------------------------------------------------------------------
info "Odmontowywanie i sprzątanie…"
rm -f "${MOUNTPOINT}/tmp/chroot_phase1.sh" "${MOUNTPOINT}/tmp/chroot_phase2.sh"
rm -f "/tmp/${STAGE3_FILE}" 2>/dev/null || true

umount -R "${MOUNTPOINT}/dev"  2>/dev/null || true
umount -R "${MOUNTPOINT}/sys"  2>/dev/null || true
umount -R "${MOUNTPOINT}/proc" 2>/dev/null || true
umount -R "${MOUNTPOINT}/run"  2>/dev/null || true
umount -R "${MOUNTPOINT}"      2>/dev/null || true
swapoff "${SWAP_PART}"         2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}============================================="
echo "  Instalacja Gentoo zakończona pomyślnie!"
echo "=============================================${RESET}"
echo ""
echo "  Dysk          : ${DISK}"
echo "  Tryb rozruchu : ${BOOT_MODE}"
echo "  Hostname      : ${HOSTNAME}"
echo "  Użytkownik    : ${USERNAME}  (hasło: ${USER_PASSWORD})"
echo "  Root hasło    : ${ROOT_PASSWORD}"
echo "  Desktop       : KDE Plasma 6"
echo ""
echo -e "${YELLOW}Uruchom ponownie maszynę: reboot${RESET}"
echo ""
