#!/usr/bin/env bash

set -euo pipefail

detect_system_lang() {
    local sys_lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    sys_lang="${sys_lang//\"/}"
    sys_lang="${sys_lang//\'/}"
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
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    if [[ "$exit_code" -eq 0 && "${DO_REBOOT:-0}" == "1" ]]; then
        sudo systemctl reboot
    else
        sudo -k 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

ENROLL_ARGS=(-m)
MODE=""
LABEL="Arch Linux"
GRUB_ID="GRUB"
SIGNED_COUNT=0

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
        --no-microsoft) ENROLL_ARGS=() ;;
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
command -v sudo >/dev/null 2>&1 || die "Brak polecenia sudo." "sudo command not found."
[[ -d /sys/firmware/efi ]] || die "System nie jest uruchomiony w trybie UEFI." "The system is not booted in UEFI mode."
command -v pacman >/dev/null 2>&1 || die "To nie jest Arch Linux (brak pacman)." "This is not Arch Linux (pacman not found)."

sudo -v

(
    set +e
    trap - ERR
    while kill -0 "$$" 2>/dev/null; do
        sleep 50
        kill -0 "$$" 2>/dev/null || exit 0
        sudo -n -v 2>/dev/null || exit 0
    done
) </dev/null >/dev/null 2>&1 &
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
            sudo ls "$p" >/dev/null 2>&1 || true
            if findmnt -M "$p" -t vfat,msdos -no FSTYPE 2>/dev/null | grep -qxE 'vfat|msdos'; then
                echo "$p"
                return 0
            fi
        fi
    fi
    for p in /efi /boot/efi /boot; do
        [[ -d "$p" ]] || continue
        sudo ls "$p" >/dev/null 2>&1 || true
        if findmnt -M "$p" -t vfat,msdos -no FSTYPE 2>/dev/null | grep -qxE 'vfat|msdos'; then
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
sudo env ESP_PATH="$ESP" sbctl status || true

SB_STATUS="$(sudo env LC_ALL=C ESP_PATH="$ESP" sbctl status 2>/dev/null || true)"
IS_SETUP=0
IS_SECURE_BOOT=0
if grep -i 'Setup Mode' <<< "$SB_STATUS" | grep -qi 'enabled'; then
    IS_SETUP=1
fi
if grep -i 'Secure Boot' <<< "$SB_STATUS" | grep -qi 'enabled'; then
    IS_SECURE_BOOT=1
fi

if sudo test -f /var/lib/sbctl/keys/db/db.key || sudo test -f /usr/share/secureboot/keys/db/db.key; then
    info "Klucze sbctl już istnieją." "sbctl keys already exist."
else
    info "Tworzenie kluczy Secure Boot..." "Creating Secure Boot keys..."
    sudo env ESP_PATH="$ESP" sbctl create-keys
fi

sign_if_exists() {
    [[ -n "${1:-}" ]] || return 0
    if sudo test -f "$1"; then
        sudo env ESP_PATH="$ESP" sbctl sign -s "$1"
        SIGNED_COUNT=$((SIGNED_COUNT + 1))
    fi
    return 0
}

sign_bootx64_if_ours() {
    local boot_efi
    local -a boot_files
    mapfile -t boot_files < <(find_files "$ESP/EFI/BOOT" 'bootx64.efi' 1)
    for boot_efi in "${boot_files[@]}"; do
        [[ -n "$boot_efi" ]] || continue
        if sudo grep -aqiE 'GRUB|systemd-boot' "$boot_efi" 2>/dev/null; then
            sign_if_exists "$boot_efi"
        fi
    done
}

esp_device_info() {
    local src pkname disk part
    src=$(findmnt -M "$ESP" -t vfat,msdos -no SOURCE 2>/dev/null | head -n1)
    [[ -n "$src" ]] || return 1
    src=$(readlink -f "$src")
    pkname=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)
    [[ -n "$pkname" ]] || return 1
    disk="/dev/$pkname"
    if [[ -r "/sys/class/block/$(basename "$src")/partition" ]]; then
        part=$(cat "/sys/class/block/$(basename "$src")/partition")
    else
        part=$(lsblk -no PARTN "$src" 2>/dev/null | head -n1)
    fi
    [[ -b "$disk" && "$part" =~ ^[0-9]+$ ]] || return 1
    echo "$disk $part"
}

build_cmdline() {
    local c
    if [[ -s /etc/kernel/cmdline ]]; then
        c=$(grep -vE '^[[:space:]]*(#|$)' /etc/kernel/cmdline | tr '\n' ' ')
    else
        c=$(sed -E 's/(^| )BOOT_IMAGE=[^ ]*//g; s/(^| )initrd=[^ ]*//g' /proc/cmdline)
    fi
    echo "$c" | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g'
}

entry_exists() {
    efibootmgr -v 2>/dev/null | grep -qiF -- "File($1)"
}

configure_grub() {
    local f grub_efi_path grub_parent
    local -a grub_files

    sudo pacman -S --needed --noconfirm grub

    grub_efi_path=$(sudo find "$ESP/EFI" -mindepth 2 -maxdepth 2 -type f -iname grubx64.efi ! -ipath "$ESP/EFI/BOOT/*" 2>/dev/null | head -n1 || true)
    if [[ -n "$grub_efi_path" ]]; then
        grub_parent="${grub_efi_path%/*}"
        GRUB_ID="${grub_parent##*/}"
    fi

    info "Instalacja GRUB na ESP ($ESP, ID: $GRUB_ID)..." "Installing GRUB on the ESP ($ESP, ID: $GRUB_ID)..."
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP" \
        --bootloader-id="$GRUB_ID" --modules="tpm" --disable-shim-lock

    info "Generowanie konfiguracji GRUB..." "Generating GRUB configuration..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg

    mapfile -t grub_files < <(sudo find "$ESP/EFI" -mindepth 2 -maxdepth 2 -type f -iname grubx64.efi ! -ipath "$ESP/EFI/Microsoft/*" 2>/dev/null | sort -u)
    for f in "${grub_files[@]}"; do
        sign_if_exists "$f"
    done
    sign_bootx64_if_ours
}

configure_efistub() {
    local esp_info disk part cmdline k name initrds loader uki ucode
    local -a ukis kernels

    if [[ "$ESP" != "/boot" ]] && compgen -G "/boot/vmlinuz-*" >/dev/null && [[ -z "$(find_files "$ESP" 'vmlinuz-*' 1)" ]]; then
        warn "Kernele leżą w /boot poza ESP - EFISTUB wymaga kernela na ESP." \
             "Kernels are in /boot outside the ESP - EFISTUB requires the kernel on the ESP."
        warn "Zamontuj ESP pod /boot lub użyj UKI." \
             "Mount the ESP at /boot or use UKI."
    fi

    esp_info=$(esp_device_info) || die "Nie udało się ustalić urządzenia partycji ESP ($ESP)." "Failed to determine the ESP partition device ($ESP)."
    read -r disk part <<< "$esp_info"
    cmdline=$(build_cmdline)
    [[ -n "$cmdline" ]] || die "Pusta linia poleceń kernela." "Empty kernel command line."
    info "Dysk ESP: $disk, partycja: $part" "ESP disk: $disk, partition: $part"
    info "Cmdline: $cmdline" "Cmdline: $cmdline"

    ucode=""
    if grep -q 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        sudo test -f "$ESP/amd-ucode.img" && ucode=" initrd=\\amd-ucode.img"
    elif grep -q 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        sudo test -f "$ESP/intel-ucode.img" && ucode=" initrd=\\intel-ucode.img"
    fi

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
        mapfile -t sd_boot_files < <(find_files "$ESP/EFI/systemd" 'systemd-bootx64.efi' 1)
        for f in "${sd_boot_files[@]}"; do
            sign_if_exists "$f"
        done
        sign_bootx64_if_ours
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

(( SIGNED_COUNT > 0 )) || die "Nie znaleziono żadnych plików EFI ani jąder do podpisania – przerywam przed rejestracją kluczy." \
                              "No EFI binaries or kernels found to sign - aborting before enrolling keys."

if [[ $IS_SETUP -eq 1 ]]; then
    info "Setup Mode aktywny - rejestracja kluczy..." "Setup Mode is active - enrolling keys..."
    sudo env ESP_PATH="$ESP" sbctl enroll-keys "${ENROLL_ARGS[@]}"
elif [[ $IS_SECURE_BOOT -eq 1 ]]; then
    info "Secure Boot jest już włączony - pomijam rejestrację kluczy." \
         "Secure Boot is already enabled - skipping key enrollment."
else
    warn "Firmware nie jest w Setup Mode - klucze nie zostały zarejestrowane." \
         "Firmware is not in Setup Mode - keys have not been enrolled."
    warn "Jeśli klucze sbctl nie zostały jeszcze zarejestrowane, wyczyść klucze Secure Boot w UEFI, a następnie wykonaj:" \
         "If sbctl keys have not been enrolled yet, clear the Secure Boot keys in UEFI, then run:"
    if (( ${#ENROLL_ARGS[@]} > 0 )); then
        warn "  sudo sbctl enroll-keys ${ENROLL_ARGS[*]}" "  sudo sbctl enroll-keys ${ENROLL_ARGS[*]}"
    else
        warn "  sudo sbctl enroll-keys" "  sudo sbctl enroll-keys"
    fi
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
        warn "Po każdej aktualizacji pakietu grub uruchom ponownie ten skrypt (lub grub-install i sbctl sign-all), aby odnowić instalację i podpisy." \
             "After every grub package update, run this script again (or grub-install and sbctl sign-all) to renew the installation and signatures."
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
sudo env ESP_PATH="$ESP" sbctl --esp "$ESP" verify || true
echo
sudo env ESP_PATH="$ESP" sbctl status || true
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
RESTART_CHOICE=""
if [[ -r /dev/tty ]]; then
    read -r RESTART_CHOICE < /dev/tty || RESTART_CHOICE=""
else
    read -r RESTART_CHOICE || RESTART_CHOICE=""
fi
case "$RESTART_CHOICE" in
    [YyTt]*)
        DO_REBOOT=1
        ;;
esac
exit 0
