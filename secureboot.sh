#!/usr/bin/env bash

set -euo pipefail

detect_system_lang() {
    local sys_lang="${LANG:-}"
    [[ -z "$sys_lang" ]] && sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    if [[ "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
info() { local m; m="$(_pick_msg "$1" "$2")"; echo "${GRN}[+]${RST} $m"; }
warn() { local m; m="$(_pick_msg "$1" "$2")"; echo "${YLW}[!]${RST} $m"; }
die()  { local m; m="$(_pick_msg "$1" "$2")"; echo "${RED}[x]${RST} $m" >&2; exit 1; }

SUDO_KEEPALIVE_PID=""
DO_REBOOT=0

cleanup_on_exit() {
    local exit_code=$?
    [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    if [[ "$exit_code" -eq 0 && "${DO_REBOOT:-0}" == "1" ]]; then
        sudo systemctl reboot
    fi
}
trap cleanup_on_exit EXIT

ENROLL_FLAGS="-m"
MODE=""
LABEL="Arch Linux"
GRUB_ID="GRUB"

usage() {
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        cat <<EOF
Użycie: $0 [opcje]
  --mode=systemd-boot|grub|efistub   wymuś tryb (domyślnie autodetekcja)
  --label=NAZWA                      etykieta wpisu EFISTUB (domyślnie "Arch Linux")
  --no-microsoft                     nie dodawaj kluczy Microsoft
  -h, --help                         pomoc
EOF
    else
        cat <<EOF
Usage: $0 [options]
  --mode=systemd-boot|grub|efistub   force the mode (autodetected by default)
  --label=NAME                       EFISTUB entry label (default "Arch Linux")
  --no-microsoft                     do not add Microsoft keys
  -h, --help                         help
EOF
    fi
}

for arg in "$@"; do
    case "$arg" in
        --mode=*) MODE="${arg#--mode=}" ;;
        --label=*) LABEL="${arg#--label=}" ;;
        --no-microsoft) ENROLL_FLAGS="" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Nieznana opcja: $arg" "Unknown option: $arg" ;;
    esac
done

case "$MODE" in
    ""|systemd-boot|grub|efistub) ;;
    *) die "Nieprawidłowy tryb: $MODE" "Invalid mode: $MODE" ;;
esac

[[ $EUID -ne 0 ]] || die "Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo." \
                         "Do not run this script as root. Run it as a regular user with sudo."
[[ -d /sys/firmware/efi ]] || die "System nie jest uruchomiony w trybie UEFI." "The system is not booted in UEFI mode."
command -v pacman >/dev/null || die "To nie jest Arch Linux (brak pacman)." "This is not Arch Linux (pacman not found)."

sudo -v

(
    set +e
    trap - ERR
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done
) &
SUDO_KEEPALIVE_PID=$!

info "Instalacja wymaganych pakietów..." "Installing required packages..."
sudo pacman -S --needed --noconfirm sbctl efibootmgr

find_files() {
    { sudo find "$1" -mindepth "$3" -maxdepth "$3" -type f -iname "$2" 2>/dev/null || true; } | sort
}

detect_esp() {
    local p
    if command -v bootctl >/dev/null 2>&1; then
        p=$(sudo bootctl --print-esp-path 2>/dev/null || true)
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

ESP=$(detect_esp) || die "Nie można wykryć partycji ESP." "Unable to detect the ESP partition."
info "ESP: $ESP" "ESP: $ESP"

detect_mode() {
    if command -v bootctl >/dev/null 2>&1 && sudo bootctl is-installed >/dev/null 2>&1; then
        echo systemd-boot
        return 0
    fi
    if command -v grub-install >/dev/null 2>&1; then
        if [[ -n "$(find_files "$ESP/EFI" grubx64.efi 2)" ]] || efibootmgr -v 2>/dev/null | grep -qi 'grubx64'; then
            echo grub
            return 0
        fi
    fi
    if efibootmgr -v 2>/dev/null | grep -qiE 'vmlinuz|EFI.Linux.*\.efi'; then
        echo efistub
        return 0
    fi
    if [[ -n "$(find_files "$ESP" 'vmlinuz-*' 1)" ]] || [[ -n "$(find_files "$ESP/EFI/Linux" '*.efi' 1)" ]]; then
        echo efistub
        return 0
    fi
    return 1
}

if [[ -z "$MODE" ]]; then
    MODE=$(detect_mode) || die "Nie wykryto systemd-boot, GRUB ani EFISTUB. Użyj --mode=." \
                               "Neither systemd-boot, GRUB nor EFISTUB was detected. Use --mode=."
    info "Wykryty tryb: $MODE" "Detected mode: $MODE"
else
    info "Wymuszony tryb: $MODE" "Forced mode: $MODE"
fi

info "Stan początkowy:" "Initial state:"
sudo sbctl status || true

IS_SETUP=0
if sudo sbctl status 2>/dev/null | grep -i 'Setup Mode' | grep -qi 'enabled'; then
    IS_SETUP=1
fi

if sudo sbctl status 2>/dev/null | grep -qi 'Installed:.*✓'; then
    info "Klucze sbctl już istnieją." "sbctl keys already exist."
else
    info "Tworzenie kluczy Secure Boot..." "Creating Secure Boot keys..."
    sudo sbctl create-keys
fi

sign_if_exists() {
    sudo test -f "$1" && sudo sbctl sign -s "$1"
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

configure_grub() {
    local f
    local -a grub_files

    sudo pacman -S --needed --noconfirm grub

    info "Instalacja GRUB na ESP ($ESP)..." "Installing GRUB on the ESP ($ESP)..."
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP" \
        --bootloader-id="$GRUB_ID" --modules="tpm" --disable-shim-lock

    info "Generowanie konfiguracji GRUB..." "Generating GRUB configuration..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg

    mapfile -t grub_files < <({ find_files "$ESP/EFI" grubx64.efi 2; find_files "$ESP/EFI/BOOT" BOOTX64.EFI 1; } | sort -u)
    for f in "${grub_files[@]}"; do
        sign_if_exists "$f"
    done
}

configure_efistub() {
    local disk part cmdline k name initrds loader uki ucode
    local -a ukis kernels

    if [[ "$ESP" != "/boot" ]] && compgen -G "/boot/vmlinuz-*" >/dev/null && [[ -z "$(find_files "$ESP" 'vmlinuz-*' 1)" ]]; then
        warn "Kernele leżą w /boot poza ESP - EFISTUB wymaga kernela na ESP." \
             "Kernels are in /boot outside the ESP - EFISTUB requires the kernel on the ESP."
        warn "Zamontuj ESP pod /boot lub użyj UKI." \
             "Mount the ESP at /boot or use UKI."
    fi

    read -r disk part < <(esp_device_info)
    cmdline=$(build_cmdline)
    [[ -n "$cmdline" ]] || die "Pusta linia poleceń kernela." "Empty kernel command line."
    info "Dysk ESP: $disk, partycja: $part" "ESP disk: $disk, partition: $part"
    info "Cmdline: $cmdline" "Cmdline: $cmdline"

    ucode=""
    sudo test -f "$ESP/amd-ucode.img"   && ucode+=" initrd=\\amd-ucode.img"
    sudo test -f "$ESP/intel-ucode.img" && ucode+=" initrd=\\intel-ucode.img"

    mapfile -t ukis < <(find_files "$ESP/EFI/Linux" '*.efi' 1)
    for uki in "${ukis[@]}"; do
        loader="\\EFI\\Linux\\$(basename "$uki")"
        if entry_exists "$loader"; then
            info "Wpis dla $loader już istnieje." "Entry for $loader already exists."
            continue
        fi
        info "Tworzenie wpisu UEFI dla UKI: $loader" "Creating UEFI entry for UKI: $loader"
        sudo efibootmgr --create --disk "$disk" --part "$part" \
            --label "$LABEL ($(basename "$uki" .efi))" --loader "$loader" --quiet
    done

    mapfile -t kernels < <(find_files "$ESP" 'vmlinuz-*' 1)
    for k in "${kernels[@]}"; do
        name=${k##*/vmlinuz-}
        if ! sudo test -f "$ESP/initramfs-$name.img"; then
            warn "Brak $ESP/initramfs-$name.img - pomijam $k" "Missing $ESP/initramfs-$name.img - skipping $k"
            continue
        fi
        loader="\\vmlinuz-$name"
        initrds="$ucode initrd=\\initramfs-$name.img"
        if entry_exists "$loader"; then
            info "Wpis dla $loader już istnieje." "Entry for $loader already exists."
            continue
        fi
        info "Tworzenie wpisu UEFI dla kernela: $loader" "Creating UEFI entry for kernel: $loader"
        sudo efibootmgr --create --disk "$disk" --part "$part" \
            --label "$LABEL ($name)" --loader "$loader" \
            --unicode "$cmdline$initrds" --quiet
    done
}

case "$MODE" in
    systemd-boot)
        if ! sudo bootctl is-installed >/dev/null 2>&1; then
            info "Instalacja systemd-boot..." "Installing systemd-boot..."
            sudo bootctl install
        fi
        sign_if_exists "$ESP/EFI/systemd/systemd-bootx64.efi"
        sign_if_exists "$ESP/EFI/BOOT/BOOTX64.EFI"
        ;;
    grub)
        configure_grub
        ;;
    efistub)
        configure_efistub
        ;;
esac

info "Podpisywanie kerneli i UKI..." "Signing kernels and UKI..."
mapfile -t to_sign < <({
    find_files "$ESP" 'vmlinuz-*' 1
    find_files /boot 'vmlinuz-*' 1
    find_files "$ESP/EFI/Linux" '*.efi' 1
    find_files /boot/EFI/Linux '*.efi' 1
} | sort -u)
for f in "${to_sign[@]}"; do
    sign_if_exists "$f"
done

sudo sbctl verify 2>/dev/null | grep -E '✗|not signed' | awk '{print $2}' | while read -r f; do
    sudo test -f "$f" && sudo sbctl sign -s "$f" || true
done || true

if [[ $IS_SETUP -eq 1 ]]; then
    info "Setup Mode aktywny - rejestracja kluczy..." "Setup Mode is active - enrolling keys..."
    sudo sbctl enroll-keys $ENROLL_FLAGS
else
    warn "Firmware nie jest w Setup Mode - klucze nie zostały zarejestrowane." \
         "Firmware is not in Setup Mode - keys have not been enrolled."
    warn "Wyczyść klucze Secure Boot w UEFI, a następnie wykonaj:" \
         "Clear the Secure Boot keys in UEFI, then run:"
    warn "  sudo sbctl enroll-keys $ENROLL_FLAGS" "  sudo sbctl enroll-keys $ENROLL_FLAGS"
fi

case "$MODE" in
    systemd-boot)
        sudo systemctl enable --now systemd-boot-update.service 2>/dev/null || \
            warn "Nie udało się włączyć systemd-boot-update.service." \
                 "Failed to enable systemd-boot-update.service."
        ;;
    grub)
        warn "GRUB: plik grub.cfg nie jest chroniony przez Secure Boot." \
             "GRUB: grub.cfg is not protected by Secure Boot."
        warn "Po aktualizacji GRUB uruchom ponownie ten skrypt, aby odnowić instalację i podpisy." \
             "After a GRUB update, run this script again to renew the installation and signatures."
        ;;
    efistub)
        warn "EFISTUB: linia poleceń kernela leży w NVRAM i nie jest chroniona przez Secure Boot." \
             "EFISTUB: the kernel command line is stored in NVRAM and is not protected by Secure Boot."
        warn "Dla pełnej ochrony użyj UKI (mkinitcpio/dracut) w $ESP/EFI/Linux." \
             "For full protection use UKI (mkinitcpio/dracut) in $ESP/EFI/Linux."
        ;;
esac

echo
info "Weryfikacja podpisów:" "Verifying signatures:"
sudo sbctl verify || true
echo
sudo sbctl status || true
echo
info "Gotowe. Zrestartuj komputer i włącz Secure Boot w UEFI." "Done. Restart the computer and enable Secure Boot in UEFI."
if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo "  Sprawdzenie po starcie: sbctl status"
    echo "  Odzyskiwanie: wyłącz Secure Boot w UEFI."
else
    echo "  Check after boot: sbctl status"
    echo "  Recovery: disable Secure Boot in UEFI."
fi
echo

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${BLU}==> ${RESTART_PROMPT}${RST}"
read -r RESTART_CHOICE < /dev/tty
case "$RESTART_CHOICE" in
    [YyTt]*)
        DO_REBOOT=1
        ;;
esac
exit 0
