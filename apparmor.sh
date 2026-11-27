#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

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
SCRIPT_LANG="${SCRIPT_LANG:-$(detect_system_lang)}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
info() { local m; m="$(_pick_msg "$1" "$2")"; echo "${GRN}[+]${RST} $m"; }
warn() { local m; m="$(_pick_msg "$1" "$2")"; echo "${YLW}[!]${RST} $m"; }
die()  { local m; m="$(_pick_msg "$1" "$2")"; echo "${RED}[x]${RST} $m" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash -- "$0" "$@"
    elif command -v doas >/dev/null 2>&1; then
        exec doas bash -- "$0" "$@"
    elif command -v su >/dev/null 2>&1; then
        exec su root -c "$(printf '%q ' bash -- "$0" "$@")"
    else
        die "Brak sudo, doas lub su. Uruchom skrypt jako root." \
            "Missing sudo, doas, or su. Run this script as root."
    fi
fi

command -v pacman >/dev/null 2>&1 || die "To nie jest Arch Linux (brak pacman)." "This is not Arch Linux (pacman not found)."

LSM_PARAM="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
BOOTLOADER_CONFIGURED=false
LSM_ALREADY_SET=false
TMP_FILE=""
declare -A SEEN_FILES=()

cleanup() {
    [[ -n "${TMP_FILE:-}" ]] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

has_uncommented_lsm() {
    grep -qE '^[[:space:]]*[^#]*([[:space:]"'"'"'=:]|^)lsm=' "$@" 2>/dev/null
}

apply_if_changed() {
    local file="$1"
    local tmp="$2"
    if ! cmp -s "$file" "$tmp"; then
        cat "$tmp" > "$file"
        rm -f "$tmp"
        TMP_FILE=""
        return 0
    fi
    rm -f "$tmp"
    TMP_FILE=""
    return 1
}

mark_seen() {
    local real
    real="$(realpath -e "$1" 2>/dev/null)" || return 1
    if [[ -n "${SEEN_FILES[$real]:-}" ]]; then
        return 1
    fi
    SEEN_FILES[$real]=1
    return 0
}

configure_uki() {
    local mkinitcpio_uki=false
    local dracut_uki=false
    local has_uki_efi=false

    local presets=(/etc/mkinitcpio.d/*.preset)
    if (( ${#presets[@]} > 0 )) && grep -qE '^[[:space:]]*[a-zA-Z0-9_]+_uki=["'"'"']?[^[:space:]"'"'"']+' "${presets[@]}"; then
        mkinitcpio_uki=true
    fi

    local dracut_confs=(/etc/dracut.conf /etc/dracut.conf.d/*.conf)
    local existing_dracut=()
    for f in "${dracut_confs[@]}"; do
        [[ -f "$f" ]] && existing_dracut+=("$f")
    done
    if (( ${#existing_dracut[@]} > 0 )) && grep -qE '^[[:space:]]*uefi="?yes"?' "${existing_dracut[@]}"; then
        dracut_uki=true
    fi

    local uki_efis=(/boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi /boot/efi/EFI/Linux/*.efi)
    if (( ${#uki_efis[@]} > 0 )); then
        has_uki_efi=true
    fi

    if [[ "$mkinitcpio_uki" == false && "$dracut_uki" == false && "$has_uki_efi" == false ]]; then
        return
    fi

    info "Wykryto UKI (Unified Kernel Image)." "Detected UKI (Unified Kernel Image)."
    local uki_updated=false
    local cmdline_d=(/etc/cmdline.d/*.conf)
    local check_files=()
    [[ -f /etc/kernel/cmdline ]] && check_files+=(/etc/kernel/cmdline)
    (( ${#cmdline_d[@]} > 0 )) && check_files+=("${cmdline_d[@]}")

    if (( ${#check_files[@]} > 0 )) && has_uncommented_lsm "${check_files[@]}"; then
        warn "Parametr lsm= jest już obecny w konfiguracji cmdline UKI – sprawdź go ręcznie." \
             "Parameter lsm= is already present in UKI cmdline configuration – check it manually."
        LSM_ALREADY_SET=true
        return
    fi

    if [[ -s /etc/kernel/cmdline ]] && grep -qvE '^[[:space:]]*(#|$)' /etc/kernel/cmdline; then
        TMP_FILE="$(mktemp)"
        awk -v param="$LSM_PARAM" '
            !done && $0 !~ /^[[:space:]]*#/ && $0 ~ /[^[:space:]]/ {
                sub(/[[:space:]]+$/, "")
                $0 = $0 " " param
                done = 1
            }
            { print }
        ' /etc/kernel/cmdline > "$TMP_FILE"
        if apply_if_changed /etc/kernel/cmdline "$TMP_FILE"; then
            info "Zaktualizowano /etc/kernel/cmdline." "Updated /etc/kernel/cmdline."
            uki_updated=true
        fi
    elif (( ${#cmdline_d[@]} > 0 )); then
        echo "$LSM_PARAM" > /etc/cmdline.d/99-apparmor.conf
        info "Utworzono /etc/cmdline.d/99-apparmor.conf." "Created /etc/cmdline.d/99-apparmor.conf."
        uki_updated=true
    elif [[ "$dracut_uki" == true ]]; then
        mkdir -p /etc/dracut.conf.d
        if ! has_uncommented_lsm "${existing_dracut[@]}"; then
            echo "kernel_cmdline+=\" ${LSM_PARAM} \"" > /etc/dracut.conf.d/99-apparmor.conf
            info "Utworzono /etc/dracut.conf.d/99-apparmor.conf." "Created /etc/dracut.conf.d/99-apparmor.conf."
            uki_updated=true
        else
            warn "Parametr lsm= jest już obecny w konfiguracji dracut." \
                 "Parameter lsm= is already present in dracut configuration."
            LSM_ALREADY_SET=true
        fi
    else
        warn "Wykryto UKI, ale nie znaleziono aktywnej konfiguracji w /etc/kernel/cmdline ani /etc/cmdline.d/*.conf." \
             "UKI detected, but no active configuration was found in /etc/kernel/cmdline or /etc/cmdline.d/*.conf."
        warn "Nie utworzono nowego pliku automatycznie, aby nie nadpisać parametru root=. Dodaj ręcznie:" \
             "No new file was created automatically to avoid overriding root=. Add manually:"
        echo "  $LSM_PARAM"
    fi

    if [[ "$uki_updated" == true ]]; then
        if [[ "$mkinitcpio_uki" == true ]] && command -v mkinitcpio >/dev/null 2>&1; then
            info "Przebudowywanie obrazów UKI (mkinitcpio -P)..." "Rebuilding UKI images (mkinitcpio -P)..."
            mkinitcpio -P
        elif [[ "$dracut_uki" == true ]] && command -v dracut >/dev/null 2>&1; then
            info "Przebudowywanie obrazów UKI (dracut)..." "Rebuilding UKI images (dracut)..."
            dracut --regenerate-all --force
        else
            warn "Przebuduj obrazy UKI ręcznie (np. ukify / kernel-install)." \
                 "Rebuild UKI images manually (e.g. ukify / kernel-install)."
        fi
        BOOTLOADER_CONFIGURED=true
    fi
}

configure_grub() {
    if [[ ! -f /etc/default/grub ]] || ! command -v grub-mkconfig >/dev/null 2>&1; then
        return
    fi
    mark_seen /etc/default/grub || return

    info "Wykryto GRUB." "Detected GRUB."
    if grep -qE '^GRUB_CMDLINE_LINUX(_DEFAULT)?=("[^"]*lsm=[^"]*"|'\''[^'\'']*lsm=[^'\'']*'\'')' /etc/default/grub; then
        warn "Parametr lsm= jest już obecny w /etc/default/grub – sprawdź go ręcznie." \
             "Parameter lsm= is already present in /etc/default/grub – check it manually."
        LSM_ALREADY_SET=true
        return
    fi

    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=("[^"]*"|'\''[^'\'']*'\'')[[:space:]]*$' /etc/default/grub; then
        TMP_FILE="$(mktemp)"
        awk -v param="$LSM_PARAM" '
            /^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"[[:space:]]*$/ {
                sub(/"[[:space:]]*$/, "")
                if ($0 ~ /="$/) {
                    $0 = $0 param "\""
                } else {
                    $0 = $0 " " param "\""
                }
            }
            /^GRUB_CMDLINE_LINUX_DEFAULT='\''[^'\'']*'\''[[:space:]]*$/ {
                sub(/'\''[[:space:]]*$/, "")
                if ($0 ~ /='\''$/) {
                    $0 = $0 param "'\''"
                } else {
                    $0 = $0 " " param "'\''"
                }
            }
            { print }
        ' /etc/default/grub > "$TMP_FILE"

        if apply_if_changed /etc/default/grub "$TMP_FILE"; then
            local grub_cfg="/boot/grub/grub.cfg"
            for candidate in /boot/grub/grub.cfg /efi/grub/grub.cfg /boot/efi/grub/grub.cfg; do
                if [[ -f "$candidate" ]]; then
                    grub_cfg="$candidate"
                    break
                fi
            done
            grub-mkconfig -o "$grub_cfg"
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano GRUB ($grub_cfg)." "Updated GRUB ($grub_cfg)."
        fi
    else
        warn "Nie znaleziono standardowej linii GRUB_CMDLINE_LINUX_DEFAULT w /etc/default/grub." \
             "Standard GRUB_CMDLINE_LINUX_DEFAULT line not found in /etc/default/grub."
    fi
}

configure_systemd_boot() {
    local dir entry name
    for dir in /boot/loader/entries /efi/loader/entries /boot/efi/loader/entries; do
        [[ -d "$dir" ]] || continue
        local entries=("$dir"/*.conf)
        (( ${#entries[@]} > 0 )) || continue

        info "Wykryto systemd-boot w $dir." "Detected systemd-boot in $dir."
        for entry in "${entries[@]}"; do
            mark_seen "$entry" || continue
            name="$(basename "$entry")"

            if [[ "${name,,}" == *fallback* ]]; then
                info "Pominięto wpis awaryjny: $name" "Skipped fallback entry: $name"
                continue
            fi
            if grep -qE '^[[:space:]]*options[[:space:]]+.*(^|[[:space:]])lsm=' "$entry"; then
                warn "$name zawiera już parametr lsm= – pominięto." \
                     "$name already contains lsm= parameter – skipped."
                LSM_ALREADY_SET=true
                continue
            fi
            if grep -qE '^[[:space:]]*options[[:space:]]+' "$entry"; then
                TMP_FILE="$(mktemp)"
                awk -v param="$LSM_PARAM" '
                    !done && /^[[:space:]]*options[[:space:]]+/ {
                        sub(/[[:space:]]+$/, "")
                        $0 = $0 " " param
                        done = 1
                    }
                    { print }
                ' "$entry" > "$TMP_FILE"
                if apply_if_changed "$entry" "$TMP_FILE"; then
                    BOOTLOADER_CONFIGURED=true
                    info "Zaktualizowano wpis systemd-boot: $name" "Updated systemd-boot entry: $name"
                fi
            fi
        done
    done
}

configure_refind() {
    local f

    # 1. Automatyczne wpisy w refind_linux.conf
    for f in /boot/refind_linux.conf /efi/refind_linux.conf /boot/efi/refind_linux.conf; do
        [[ -f "$f" ]] || continue
        mark_seen "$f" || continue

        info "Wykryto rEFInd ($f)." "Detected rEFInd ($f)."
        if has_uncommented_lsm "$f"; then
            warn "$f zawiera już parametr lsm= – pominięto." \
                 "$f already contains lsm= parameter – skipped."
            LSM_ALREADY_SET=true
            continue
        fi

        TMP_FILE="$(mktemp)"
        awk -v param="$LSM_PARAM" '
            /^[[:space:]]*"[^"]+"[[:space:]]+"[^"]*"[[:space:]]*$/ {
                title = $0
                sub(/^[[:space:]]*"/, "", title)
                sub(/".*$/, "", title)
                if (tolower(title) !~ /fallback|minimal|single/ && $0 !~ /lsm=/) {
                    if ($0 ~ /""[[:space:]]*$/) {
                        sub(/"[[:space:]]*$/, param "\"")
                    } else {
                        sub(/"[[:space:]]*$/, " " param "\"")
                    }
                }
            }
            { print }
        ' "$f" > "$TMP_FILE"

        if apply_if_changed "$f" "$TMP_FILE"; then
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano $f." "Updated $f."
        fi
    done

    # 2. Ręczne sekcje menuentry w refind.conf
    for f in /boot/EFI/refind/refind.conf /efi/EFI/refind/refind.conf /boot/efi/EFI/refind/refind.conf; do
        [[ -f "$f" ]] || continue
        mark_seen "$f" || continue

        if ! grep -qE '^[[:space:]]*options[[:space:]]+"[^"]*"' "$f"; then
            continue
        fi

        info "Wykryto ręczne wpisy rEFInd ($f)." "Detected manual rEFInd entries ($f)."
        if grep -qE '^[[:space:]]*options[[:space:]]+"[^"]*lsm=[^"]*"' "$f"; then
            LSM_ALREADY_SET=true
        fi

        TMP_FILE="$(mktemp)"
        awk -v param="$LSM_PARAM" '
            BEGIN { depth = 0; skip_depth = 0 }
            /^[[:space:]]*(menuentry|submenuentry)[[:space:]]+/ {
                depth++
                if (skip_depth == 0 && tolower($0) ~ /fallback|minimal|single/) {
                    skip_depth = depth
                }
                print
                next
            }
            /^[[:space:]]*\}[[:space:]]*$/ {
                if (skip_depth == depth) {
                    skip_depth = 0
                }
                if (depth > 0) depth--
                print
                next
            }
            skip_depth == 0 && /^[[:space:]]*options[[:space:]]+"[^"]*"[[:space:]]*$/ && $0 !~ /lsm=/ {
                if ($0 ~ /""[[:space:]]*$/) {
                    sub(/"[[:space:]]*$/, param "\"")
                } else {
                    sub(/"[[:space:]]*$/, " " param "\"")
                }
            }
            { print }
        ' "$f" > "$TMP_FILE"

        if apply_if_changed "$f" "$TMP_FILE"; then
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano wpisy w $f." "Updated entries in $f."
        fi
    done
}

configure_limine() {
    # 1. limine-entry-tool / limine-mkinitcpio-hook
    if [[ -f /etc/default/limine ]] && command -v limine-update >/dev/null 2>&1; then
        mark_seen /etc/default/limine || return
        info "Wykryto Limine zarządzane przez limine-entry-tool (/etc/default/limine)." \
             "Detected Limine managed by limine-entry-tool (/etc/default/limine)."
        if has_uncommented_lsm /etc/default/limine; then
            warn "/etc/default/limine zawiera już parametr lsm= – sprawdź go ręcznie." \
                 "/etc/default/limine already contains lsm= parameter – check it manually."
            LSM_ALREADY_SET=true
            return
        fi
        printf '\nKERNEL_CMDLINE[default]+=" %s"\n' "$LSM_PARAM" >> /etc/default/limine
        limine-update
        BOOTLOADER_CONFIGURED=true
        info "Zaktualizowano /etc/default/limine i wykonano limine-update." \
             "Updated /etc/default/limine and ran limine-update."
        return
    fi

    # 2. Bezpośrednie pliki limine.conf
    local candidates=(
        /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf
        /efi/limine.conf /efi/limine/limine.conf /efi/EFI/limine/limine.conf
        /boot/efi/limine.conf /boot/efi/limine/limine.conf /boot/efi/EFI/limine/limine.conf
    )

    local f
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] || continue
        mark_seen "$f" || continue

        info "Wykryto Limine ($f)." "Detected Limine ($f)."
        if has_uncommented_lsm "$f"; then
            warn "$f zawiera już parametr lsm= – pominięto." \
                 "$f already contains lsm= parameter – skipped."
            LSM_ALREADY_SET=true
            continue
        fi

        TMP_FILE="$(mktemp)"
        awk -v param="$LSM_PARAM" '
            /^[[:space:]]*\/+/ {
                skip = (tolower($0) ~ /fallback/)
            }
            !skip && /^[[:space:]]*(kernel_)?cmdline:[[:space:]]*/ && $0 !~ /lsm=/ {
                sub(/[[:space:]]+$/, "")
                $0 = $0 " " param
            }
            { print }
        ' "$f" > "$TMP_FILE"

        if apply_if_changed "$f" "$TMP_FILE"; then
            BOOTLOADER_CONFIGURED=true
            info "Zaktualizowano $f." "Updated $f."
        fi
    done
}

info "Instalacja pakietów apparmor i audit..." "Installing apparmor and audit packages..."
pacman -S --needed --noconfirm apparmor audit

info "Włączanie cache'owania profili (/etc/apparmor/parser.conf)..." \
     "Enabling profile caching (/etc/apparmor/parser.conf)..."
if [[ -f /etc/apparmor/parser.conf ]]; then
    if grep -qE '^[[:space:]]*#[[:space:]]*write-cache' /etc/apparmor/parser.conf; then
        sed -i -E 's/^[[:space:]]*#[[:space:]]*write-cache/write-cache/' /etc/apparmor/parser.conf
    elif ! grep -qE '^[[:space:]]*write-cache' /etc/apparmor/parser.conf; then
        echo "write-cache" >> /etc/apparmor/parser.conf
    fi
fi

info "Aktywacja usług apparmor.service oraz auditd.service..." \
     "Enabling apparmor.service and auditd.service..."
systemctl enable apparmor.service auditd.service

info "Wykrywanie i konfiguracja bootloadera / UKI..." \
     "Detecting and configuring bootloader / UKI..."
configure_uki
configure_grub
configure_systemd_boot
configure_refind
configure_limine

if [[ "$BOOTLOADER_CONFIGURED" == false && "$LSM_ALREADY_SET" == false ]]; then
    echo
    warn "Nie wprowadzono automatycznych zmian w parametrach jądra." \
         "No automatic changes were made to kernel parameters."
    warn "Dodaj ręcznie do linii poleceń jądra:" \
         "Add manually to the kernel command line:"
    echo "  $LSM_PARAM"
fi

echo
info "Gotowe. Po restarcie zweryfikuj działanie poleceniami:" \
     "Done. After rebooting, verify with:"
echo "  aa-enabled"
echo "  sudo aa-status"
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
        info "Restartowanie systemu..." "Restarting the system..."
        systemctl reboot
        ;;
    *)
        warn "Pominięto restart. Uruchom system ponownie ręcznie, aby aktywować AppArmor." \
             "Reboot skipped. Restart the system manually to activate AppArmor."
        ;;
esac
exit 0