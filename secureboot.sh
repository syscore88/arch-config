#!/usr/bin/env bash

set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
die()  { echo "${RED}[x]${RST} $*" >&2; exit 1; }

ENROLL_FLAGS="-m"
MODE=""
LABEL="Arch Linux"

usage() {
    cat <<EOF
Użycie: sudo $0 [opcje]
  --mode=systemd-boot|efistub   wymuś tryb (domyślnie autodetekcja)
  --label=NAZWA                 etykieta wpisu EFISTUB (domyślnie "Arch Linux")
  --no-microsoft                nie dodawaj kluczy Microsoft
  -h, --help                    pomoc
EOF
}

for arg in "$@"; do
    case "$arg" in
        --mode=*) MODE="${arg#--mode=}" ;;
        --label=*) LABEL="${arg#--label=}" ;;
        --no-microsoft) ENROLL_FLAGS="" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Nieznana opcja: $arg" ;;
    esac
done

case "$MODE" in
    ""|systemd-boot|efistub) ;;
    *) die "Nieprawidłowy tryb: $MODE" ;;
esac

[[ $EUID -eq 0 ]] || die "Uruchom jako root (sudo)."
[[ -d /sys/firmware/efi ]] || die "System nie jest uruchomiony w trybie UEFI."
command -v pacman >/dev/null || die "To nie jest Arch Linux (brak pacman)."

info "Instalacja wymaganych pakietów..."
pacman -S --needed --noconfirm sbctl efibootmgr

detect_esp() {
    local p
    if command -v bootctl >/dev/null 2>&1; then
        p=$(bootctl --print-esp-path 2>/dev/null || true)
        if [[ -n "$p" && -d "$p" ]]; then
            echo "$p"
            return 0
        fi
    fi
    for p in /efi /boot/efi /boot; do
        if findmnt -n -o FSTYPE "$p" 2>/dev/null | grep -qx vfat; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

ESP=$(detect_esp) || die "Nie można wykryć partycji ESP."
info "ESP: $ESP"

detect_mode() {
    if command -v bootctl >/dev/null 2>&1 && bootctl is-installed >/dev/null 2>&1; then
        echo systemd-boot
        return 0
    fi
    if efibootmgr -v 2>/dev/null | grep -qiE 'vmlinuz|EFI.Linux.*\.efi'; then
        echo efistub
        return 0
    fi
    if compgen -G "$ESP/vmlinuz-*" >/dev/null || compgen -G "$ESP/EFI/Linux/*.efi" >/dev/null; then
        echo efistub
        return 0
    fi
    return 1
}

if [[ -z "$MODE" ]]; then
    MODE=$(detect_mode) || die "Nie wykryto systemd-boot ani EFISTUB. Użyj --mode=."
    info "Wykryty tryb: $MODE"
else
    info "Wymuszony tryb: $MODE"
fi

info "Stan początkowy:"
sbctl status || true

IS_SETUP=0
if sbctl status 2>/dev/null | grep -i 'Setup Mode' | grep -qi 'enabled'; then
    IS_SETUP=1
fi

if sbctl status 2>/dev/null | grep -qi 'Installed:.*✓'; then
    info "Klucze sbctl już istnieją."
else
    info "Tworzenie kluczy Secure Boot..."
    sbctl create-keys
fi

sign_if_exists() {
    [[ -f "$1" ]] && sbctl sign -s "$1"
    return 0
}

esp_device_info() {
    local src disk part
    src=$(findmnt -n -o SOURCE "$ESP")
    disk="/dev/$(lsblk -no PKNAME "$src" | head -n1)"
    part=$(cat "/sys/class/block/$(basename "$src")/partition")
    echo "$disk $part"
}

build_cmdline() {
    local c
    if [[ -s /etc/kernel/cmdline ]]; then
        c=$(tr '\n' ' ' < /etc/kernel/cmdline)
    else
        c=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]*//; s/(^| )initrd=[^ ]*//g' /proc/cmdline)
    fi
    echo "$c" | sed -E 's/^ +| +$//g'
}

entry_exists() {
    efibootmgr -v 2>/dev/null | grep -qiF -- "$1"
}

configure_efistub() {
    local disk part cmdline k name initrds loader uki ucode

    if [[ "$ESP" != "/boot" ]] && compgen -G "/boot/vmlinuz-*" >/dev/null && ! compgen -G "$ESP/vmlinuz-*" >/dev/null; then
        warn "Kernele leżą w /boot poza ESP - EFISTUB wymaga kernela na ESP."
        warn "Zamontuj ESP pod /boot lub użyj UKI."
    fi

    read -r disk part < <(esp_device_info)
    cmdline=$(build_cmdline)
    [[ -n "$cmdline" ]] || die "Pusta linia poleceń kernela."
    info "Dysk ESP: $disk, partycja: $part"
    info "Cmdline: $cmdline"

    ucode=""
    [[ -f "$ESP/amd-ucode.img"   ]] && ucode+=" initrd=\\amd-ucode.img"
    [[ -f "$ESP/intel-ucode.img" ]] && ucode+=" initrd=\\intel-ucode.img"

    for uki in "$ESP"/EFI/Linux/*.efi; do
        [[ -f "$uki" ]] || continue
        loader="\\EFI\\Linux\\$(basename "$uki")"
        if entry_exists "$loader"; then
            info "Wpis dla $loader już istnieje."
            continue
        fi
        info "Tworzenie wpisu UEFI dla UKI: $loader"
        efibootmgr --create --disk "$disk" --part "$part" \
            --label "$LABEL ($(basename "$uki" .efi))" --loader "$loader" --quiet
    done

    for k in "$ESP"/vmlinuz-*; do
        [[ -f "$k" ]] || continue
        name=${k##*/vmlinuz-}
        if [[ ! -f "$ESP/initramfs-$name.img" ]]; then
            warn "Brak $ESP/initramfs-$name.img - pomijam $k"
            continue
        fi
        loader="\\vmlinuz-$name"
        initrds="$ucode initrd=\\initramfs-$name.img"
        if entry_exists "$loader"; then
            info "Wpis dla $loader już istnieje."
            continue
        fi
        info "Tworzenie wpisu UEFI dla kernela: $loader"
        efibootmgr --create --disk "$disk" --part "$part" \
            --label "$LABEL ($name)" --loader "$loader" \
            --unicode "$cmdline$initrds" --quiet
    done
}

if [[ "$MODE" == "systemd-boot" ]]; then
    if ! bootctl is-installed >/dev/null 2>&1; then
        info "Instalacja systemd-boot..."
        bootctl install
    fi
    sign_if_exists "$ESP/EFI/systemd/systemd-bootx64.efi"
    sign_if_exists "$ESP/EFI/BOOT/BOOTX64.EFI"
else
    configure_efistub
fi

info "Podpisywanie kerneli i UKI..."
for dir in "$ESP" /boot; do
    for f in "$dir"/vmlinuz-* "$dir"/EFI/Linux/*.efi; do
        sign_if_exists "$f"
    done
done

sbctl verify 2>/dev/null | grep -E '✗|not signed' | awk '{print $NF}' | while read -r f; do
    [[ -f "$f" ]] && sbctl sign -s "$f" || true
done

if [[ $IS_SETUP -eq 1 ]]; then
    info "Setup Mode aktywny - rejestracja kluczy..."
    sbctl enroll-keys $ENROLL_FLAGS
else
    warn "Firmware nie jest w Setup Mode - klucze nie zostały zarejestrowane."
    warn "Wyczyść klucze Secure Boot w UEFI, a następnie wykonaj:"
    warn "  sudo sbctl enroll-keys $ENROLL_FLAGS"
fi

if [[ "$MODE" == "systemd-boot" ]]; then
    systemctl enable --now systemd-boot-update.service 2>/dev/null || \
        warn "Nie udało się włączyć systemd-boot-update.service."
else
    warn "EFISTUB: linia poleceń kernela leży w NVRAM i nie jest chroniona przez Secure Boot."
    warn "Dla pełnej ochrony użyj UKI (mkinitcpio/dracut) w $ESP/EFI/Linux."
fi

echo
info "Weryfikacja podpisów:"
sbctl verify || true
echo
sbctl status || true
echo
info "Gotowe. Zrestartuj komputer i włącz Secure Boot w UEFI."
echo "  Sprawdzenie po starcie: sbctl status"
echo "  Odzyskiwanie: wyłącz Secure Boot w UEFI."
