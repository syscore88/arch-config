#!/bin/bash
# ========================================
#  KOMPLEKSOWY SKRYPT KONFIGURACYJNY CachyOS
# ========================================

set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

detect_system_lang() {
    local sys_lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    if [[ "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[0;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/install-log.XXXXXX)"
LOG_FILE="$HOME/install_error_$(date +%Y%m%d_%H%M%S).log"

FAILED_PACKAGES=()
SUDOERS_TMP=""
LIBVIRT_NET_XML=""
LIBVIRT_NET_BAK=""
LIBVIRT_NET_RESTORE=0
SUDO_READY=0
USE_RUN0=0
SUDO_KEEPALIVE_PID=""
QUIET_WARNS=0
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
TEMP_SUDOERS="/etc/sudoers.d/99-temp-installer"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

_sudo_n() {
    if [ "${USE_RUN0:-0}" -eq 1 ]; then
        sudo "$@"
    else
        sudo -n "$@"
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    trap '' INT TERM HUP
    trap - ERR
    set +e

    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    declare -F restore_packagekit >/dev/null && restore_packagekit

    if [ "${SUDO_READY:-0}" = "1" ] && [ "${LIBVIRT_NET_RESTORE:-0}" = "1" ] && [ -s "${LIBVIRT_NET_BAK:-}" ]; then
        _sudo_n virsh net-define "$LIBVIRT_NET_BAK" &>/dev/null
        _sudo_n virsh net-start default &>/dev/null
        _sudo_n virsh net-autostart default &>/dev/null
    fi

    rm -f "$SUDOERS_TMP" "$LIBVIRT_NET_XML" "$LIBVIRT_NET_BAK"

    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ] || [ "${QUIET_WARNS:-0}" -gt 0 ]; then
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null
    else
        rm -f "$LOG_FILE"
    fi

    {
        printf '\033[?7h'
        if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
            echo -e "\n"
        fi
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}"
            else
                echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}"
            fi
        fi
    } >&3 2>/dev/null
    rm -f "$TMP_LOG"

    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        _sudo_n sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null; if [ "$3" = 1 ]; then systemctl reboot; fi' _ \
            "$RUN0_NOPASSWD_FILE" "$TEMP_SUDOERS" "$do_reboot"
    fi
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() { printf "\r\033[K" >&3 2>/dev/null || true; echo -e "$1" >&3 2>/dev/null || true; echo -e "$1"; cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}[OK] $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}[X] ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}[!] WARN: $m${NC}"; }
log_quiet() { local m; m="$(_pick_msg "$1" "$2")"; QUIET_WARNS=$((QUIET_WARNS + 1)); echo "[!] WARN: $m"; cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

# ==========================================================
# PACKAGEKIT + BLOKADA MENEDŻERA PAKIETÓW
# ==========================================================
PACKAGEKIT_MASKED=0
PACKAGEKIT_UNITS=(packagekit.service packagekit-offline-update.service)

disable_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] && return 0
    sudo systemctl stop "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    if command -v killall >/dev/null 2>&1; then
        sudo killall -q packagekitd 2>/dev/null || true
    else
        sudo pkill -x packagekitd 2>/dev/null || true
    fi
    sudo systemctl mask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=1
}

restore_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] || return 0
    _sudo_n systemctl unmask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=0
}

_pkg_lock_busy() {
    local f
    for f in /var/lib/pacman/db.lck; do
        [[ -e "$f" ]] || continue
        sudo fuser "$f" >/dev/null 2>&1 && return 0
    done
    pgrep -x 'pacman|packagekitd' >/dev/null 2>&1 && return 0
    return 1
}

wait_for_pacman_lock() {
    local timeout="${1:-300}" waited=0
    disable_packagekit
    while _pkg_lock_busy; do
        if (( waited >= timeout )); then
            log_warn "Blokada menedżera pakietów trwa ponad ${timeout}s - kontynuuję mimo to." \
                     "Package manager lock held for over ${timeout}s - continuing anyway."
            break
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
}

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(stty size </dev/tty 2>/dev/null || true)
    cols="${cols##* }"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=80

    local bar_width=50
    local reserved=14
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 3))}..."
    fi

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ $filled -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ $empty -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3 2>/dev/null || true
}

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    MSG_PHASE_1="[1/4] Przygotowywanie..."
    MSG_PHASE_2="[2/4] Instalacja..."
    MSG_PHASE_3="[3/4] Optymalizacja..."
    MSG_PHASE_4="[4/4] Finalizowanie..."
else
    MSG_PHASE_1="[1/4] Preparing..."
    MSG_PHASE_2="[2/4] Installing..."
    MSG_PHASE_3="[3/4] Optimizing..."
    MSG_PHASE_4="[4/4] Finalizing..."
fi

TOTAL_STEPS=10

if [[ "$EUID" -eq 0 ]]; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}[X] Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo.${NC}" >&3 2>/dev/null || true
    else
        echo -e "${ERR}[X] Do not run this script as root. Run as a normal user with sudo.${NC}" >&3 2>/dev/null || true
    fi
    exit 1
fi

CURRENT_USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf '\033[?7h\n' >&3 2>/dev/null || true

USE_RUN0=0
SUDO_VERSION_OUT="$(sudo --version 2>/dev/null || true)"
if ! command -v visudo >/dev/null 2>&1 || grep -qi "run0" <<< "$SUDO_VERSION_OUT"; then
    USE_RUN0=1
fi

if [[ "$USE_RUN0" -eq 1 ]]; then
    if printf 'polkit.addRule(function(action, subject) {\n    if (subject.user == "%s") {\n        return polkit.Result.YES;\n    }\n});\n' "$CURRENT_USER" | sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null; then
        SUDO_READY=1
        sudo systemctl try-restart polkit 2>/dev/null || true
    else
        log_err "Nie udało się uzyskać uprawnień administratora." "Failed to obtain administrator privileges."
        exit 1
    fi
else
    sudo -v
    SUDO_READY=1

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

    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$TEMP_SUDOERS"
    else
        rm -f "$SUDOERS_TMP"
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}[X] Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3 2>/dev/null || true
        else
            echo -e "${ERR}[X] Invalid sudoers rule syntax - aborting.${NC}" >&3 2>/dev/null || true
        fi
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDOERS_TMP=""
fi

printf '\033[?7l' >&3 2>/dev/null || true

# =============================================================
#  ETAP 1/4: PRZYGOTOWYWANIE
# =============================================================
show_progress 0 $TOTAL_STEPS "$MSG_PHASE_1"

disable_packagekit

pkg_installed() {
    pacman -Qq "$1" &>/dev/null
}

install_pacman_pkgs() {
    wait_for_pacman_lock
    local valid_pkgs=()
    for pkg in "$@"; do
        pkg_installed "$pkg" && continue
        if pacman -Si "$pkg" &>/dev/null; then
            valid_pkgs+=("$pkg")
        else
            FAILED_PACKAGES+=("$pkg")
        fi
    done
    for pkg in "${valid_pkgs[@]}"; do
        sudo pacman -S --noconfirm --needed "$pkg" || FAILED_PACKAGES+=("$pkg")
    done
}

install_aur_pkgs() {
    wait_for_pacman_lock
    local valid_pkgs=()
    for pkg in "$@"; do
        pkg_installed "$pkg" && continue
        if paru -Si "$pkg" &>/dev/null; then
            valid_pkgs+=("$pkg")
        else
            FAILED_PACKAGES+=("$pkg")
        fi
    done
    for pkg in "${valid_pkgs[@]}"; do
        paru -S --noconfirm --needed --skipreview --cleanafter "$pkg" || FAILED_PACKAGES+=("$pkg")
    done
}

wait_for_pacman_lock
if ! sudo pacman -Syu --noconfirm; then
    log_err "pacman -Syu nie powiódł się - przerywam, żeby uniknąć częściowego upgrade'u." \
            "pacman -Syu failed - aborting to avoid a partial upgrade."
    exit 1
fi

install_pacman_pkgs dconf

if [ -f "$SCRIPT_DIR/.update.sh" ]; then
    cp -af "$SCRIPT_DIR/.update.sh" ~/.update.sh
    chmod +x ~/.update.sh
fi

if [ -d "$SCRIPT_DIR/.local" ]; then
    mkdir -p ~/.local
    cp -afT "$SCRIPT_DIR/.local" ~/.local
fi

if [ -d "$SCRIPT_DIR/.config" ]; then
    mkdir -p ~/.config
    cp -afT "$SCRIPT_DIR/.config" ~/.config
fi

show_progress 1 $TOTAL_STEPS "$MSG_PHASE_1"

TO_REMOVE=(
htop konqueror plasma-browser-integration plasma-vault
kontact kmail kontrast plasma-welcome imagemagick
kaddressbook kdepim-runtime akonadi akregator korganizer
gnome-software epiphany decibels rhythmbox showtime cosmic-store
cosmic-player parole gnome-calendar gnome-clocks gnome-music
gnome-user-docs gnome-contacts gnome-maps gnome-weather evolution
evolution-ews evolution-bogofilter evolution-spamassassin evolution-data-server
kwalletmanager elisa dragon transmission-gtk exaile mpv juk yelp
totem pragha transmission-qt discover
)
wait_for_pacman_lock
TO_REMOVE_RE="^($(IFS='|'; echo "${TO_REMOVE[*]}"))\$"
for meta in plasma-meta kde-applications-meta kde-pim-meta kde-multimedia-meta kde-network-meta gnome-extra; do
    pkg_installed "$meta" || continue
    mapfile -t META_DEPS < <(
        pacman -Qi "$meta" 2>/dev/null \
        | awk -F' : ' '/^Depends On/{print $2}' \
        | tr ' ' '\n' \
        | sed -E 's/[<>=].*//' \
        | grep -v '^None$' \
        | grep -Ev "$TO_REMOVE_RE" \
        | sort -u || true
    )
    if [[ ${#META_DEPS[@]} -gt 0 ]]; then
        readarray -t INSTALLED_META_DEPS < <(pacman -Qq "${META_DEPS[@]}" 2>/dev/null || true)
        [[ ${#INSTALLED_META_DEPS[@]} -gt 0 ]] && sudo pacman -D --asexplicit "${INSTALLED_META_DEPS[@]}" >/dev/null 2>&1 || true
    fi
    sudo pacman -R --noconfirm "$meta" 2>/dev/null || true
done
readarray -t INSTALLED_PACKAGES < <(pacman -Qq "${TO_REMOVE[@]}" 2>/dev/null || true)
if [ "${#INSTALLED_PACKAGES[@]}" -gt 0 ]; then
    if ! sudo pacman -Rs --noconfirm "${INSTALLED_PACKAGES[@]}"; then
        removed_any=1
        while [ "$removed_any" -eq 1 ]; do
            removed_any=0
            for pkg in "${INSTALLED_PACKAGES[@]}"; do
                pkg_installed "$pkg" || continue
                sudo pacman -Rs --noconfirm "$pkg" 2>/dev/null && removed_any=1
            done
        done
        STILL_INSTALLED=()
        for pkg in "${INSTALLED_PACKAGES[@]}"; do
            pkg_installed "$pkg" && STILL_INSTALLED+=("$pkg")
        done
        if [ "${#STILL_INSTALLED[@]}" -gt 0 ]; then
            log_quiet "Nie udało się usunąć: ${STILL_INSTALLED[*]}" "Could not remove: ${STILL_INSTALLED[*]}"
        fi
    fi
fi

if pacman -Qq plasma-desktop &>/dev/null || pacman -Qq plasma-workspace &>/dev/null; then
    mkdir -p ~/.config
    cat > ~/.config/kwalletrc << 'EOF'
[Wallet]
Close When Idle=false
Close on Screensaver=false
Default Wallet=kdewallet
Enabled=false
First Use=false
Idle Timeout=10
Launch Manager=false
Leave Manager Open=false
Leave Open=true
Prompt on Open=false
Use One Wallet=true

[org.freedesktop.secrets]
apiEnabled=false
EOF
fi
rm -rf ~/.local/share/akonadi ~/.local/share/kmail2 ~/.local/share/local-mail ~/.local/share/contacts ~/.local/share/korganizer ~/.local/share/akregator ~/.local/share/kontact ~/.local/share/konqueror
rm -rf ~/.config/akonadi* ~/.config/kmail* ~/.config/kontact* ~/.config/korganizer* ~/.config/kaddressbook* ~/.config/akregator* ~/.config/emailidentities ~/.config/mailtransports
rm -rf ~/.cache/akonadi* ~/.cache/kmail* ~/.cache/kontact* ~/.cache/korganizer* ~/.cache/kaddressbook* ~/.cache/akregator* ~/.cache/konqueror*
rm -rf ~/.local/share/{gnome-software,epiphany,decibels,rhythmbox,showtime,parole,evolution,gnome-calendar,gnome-clocks,gnome-music,gnome-contacts,gnome-maps,gnome-weather,yelp,dragonplayer,elisa,cosmic-store,cosmic-player,pragha,transmission,totem,exaile,mpv,juk}
rm -rf ~/.config/{gnome-software,epiphany,decibels,rhythmbox,showtime,parole,gnome-calendar,evolution,gnome-clocks,gnome-music,gnome-contacts,gnome-maps,gnome-weather,yelp,dragonplayer,elisa,cosmic-store,cosmic-player,pragha,transmission,totem,exaile,mpv,juk}
rm -rf ~/.cache/{gnome-software,epiphany,decibels,rhythmbox,showtime,parole,gnome-calendar,evolution,gnome-clocks,gnome-music,gnome-contacts,gnome-maps,gnome-weather,yelp,dragonplayer,elisa,cosmic-store,cosmic-player,pragha,transmission,totem,exaile,mpv,juk}
command -v dconf &>/dev/null && dconf reset -f /org/gnome/evolution/ || true

show_progress 2 $TOTAL_STEPS "$MSG_PHASE_1"

sudo sed -i 's/^[[:space:]]*CheckSpace/#CheckSpace/' /etc/pacman.conf || true

if ! grep -q "NoExtract = usr/share/locale" /etc/pacman.conf; then
    sudo sed -i '/^\[options\]/a NoExtract = usr/share/locale/* !usr/share/locale/pl* !usr/share/locale/en*\nNoExtract = usr/share/cups/doc/*' /etc/pacman.conf || true
fi
if ! grep -q "NoExtract = usr/share/man" /etc/pacman.conf; then
    sudo sed -i '/NoExtract = usr\/share\/cups\/doc/a NoExtract = usr/share/man/*\nNoExtract = usr/share/doc/*\nNoExtract = usr/share/info/*\nNoExtract = usr/share/gtk-doc/*\nNoExtract = usr/share/help/*' /etc/pacman.conf || true
fi
install_pacman_pkgs cups

sudo mkdir -p /etc/NetworkManager/conf.d
if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=1.1.1.2 1.0.0.2 2606:4700:4700::1112 2606:4700:4700::1002\n' | sudo tee /etc/systemd/resolved.conf.d/10-dns.conf > /dev/null
    sudo systemctl restart systemd-resolved.service 2>/dev/null || true
else
    echo -e "[main]\ndns=default\nrc-manager=symlink" | sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null
fi
echo -e "[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002" | sudo tee /etc/NetworkManager/conf.d/global-dns.conf > /dev/null

sudo nmcli general reload 2>/dev/null || sudo systemctl reload NetworkManager 2>/dev/null || true
ACTIVE_CONN="$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
    | awk -F: '$2 != "" && $2 != "lo" && $2 !~ /^(virbr|docker|br-|veth|tun|tap)/ {print $1; exit}' || true)"
if [[ -n "$ACTIVE_CONN" ]]; then
    sudo nmcli connection modify uuid "$ACTIVE_CONN" ipv4.dns "1.1.1.2,1.0.0.2" ipv6.dns "2606:4700:4700::1112,2606:4700:4700::1002" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes || true
    sudo nmcli connection up uuid "$ACTIVE_CONN" || true
fi

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_1"

# =============================================================
#  ETAP 2/4: INSTALACJA
# =============================================================
show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

SYSTEM_PKGS=(
    clang llvm cmake meson ninja just firefox firefox-i18n-pl
    python-pip python-tqdm python-defusedxml python-packaging
    partitionmanager bleachbit unrar mc xorg-xhost
    fsarchiver pv zenity innoextract android-tools dnsmasq vde2
    profile-sync-daemon dconf-editor geoclue fwupd fwupd-efi
    bluez-obex libayatana-appindicator flatpak timeshift
    faugus-launcher opencode-desktop dmemcg-booster
    ghostwriter ventoy-bin brave-origin-bin lsfg-vk
    vlc vlc-plugins-all libappimage handbrake
    gimp gmic gimp-plugin-gmic cdemu-client cdemu-daemon dkms vhba-module-dkms
    audacity qmmp mixxx kdenlive soundconverter
    discord telegram-desktop qbittorrent
    libreoffice-fresh libreoffice-fresh-pl hunspell-pl krita
    wine-staging winetricks gamemode gamescope mangohud vkd3d
    virt-manager qemu-desktop libvirt edk2-ovmf
    qt6-base qt6-declarative
)

while IFS= read -r kern; do
    [[ "$kern" =~ -(headers|nvidia|zfs|dbg|docs|api-headers)$ ]] && continue
    [[ "$kern" =~ -(nvidia-open|lts-headers)$ ]] && continue
    pacman -Si "${kern}-headers" &>/dev/null && SYSTEM_PKGS+=("${kern}-headers")
done < <(pacman -Qq 2>/dev/null | grep -E '^linux(-cachyos.*|-lts|-zen|-hardened)?$' || true)

PKGS_32BIT=(
    lib32-libxrandr lib32-libxrender lib32-gamemode lib32-vkd3d
    lib32-alsa-plugins lib32-libpulse lib32-mangohud lib32-pipewire
)

PKGS_CODECS=(
    gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg x264
)

if [ "${#SYSTEM_PKGS[@]}" -gt 0 ]; then
    readarray -t SYSTEM_PKGS < <(printf '%s\n' "${SYSTEM_PKGS[@]}" | awk '!seen[$0]++')
fi

install_pacman_pkgs "${SYSTEM_PKGS[@]}"
install_pacman_pkgs "${PKGS_32BIT[@]}"
install_pacman_pkgs "${PKGS_CODECS[@]}"

sudo depmod -a &>/dev/null || true

sudo systemctl disable --now cdemu-daemon 2>/dev/null || true
sudo systemctl mask cdemu-daemon 2>/dev/null || true
mkdir -p "$HOME/.config/autostart"
for f in /etc/xdg/autostart/gcdemu.desktop /etc/xdg/autostart/cdemu.desktop /usr/share/applications/gcdemu.desktop; do
    if [[ -f "$f" ]]; then
        cp -f "$f" "$HOME/.config/autostart/$(basename "$f")"
        if grep -q '^Hidden=' "$HOME/.config/autostart/$(basename "$f")"; then
            sed -i 's/^Hidden=.*/Hidden=true/' "$HOME/.config/autostart/$(basename "$f")" || true
        else
            echo "Hidden=true" >> "$HOME/.config/autostart/$(basename "$f")"
        fi
    fi
done
pkill -f gcdemu 2>/dev/null || true

show_progress 5 $TOTAL_STEPS "$MSG_PHASE_2"

if command -v flatpak &>/dev/null; then
    sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    sudo flatpak update --appstream || true
    for fp_app in com.github.tchx84.Flatseal; do
        flatpak info "$fp_app" &>/dev/null || sudo flatpak install -y flathub "$fp_app" || FAILED_PACKAGES+=("flatpak:$fp_app")
    done
fi

show_progress 6 $TOTAL_STEPS "$MSG_PHASE_2"

if ! command -v paru &>/dev/null; then
    install_pacman_pkgs paru
fi

if command -v paru &>/dev/null; then
    AUR_PKGS=(google-chrome makeself)
    install_aur_pkgs "${AUR_PKGS[@]}"
else
    FAILED_PACKAGES+=("paru")
fi

show_progress 7 $TOTAL_STEPS "$MSG_PHASE_2"

# =============================================================
#  ETAP 3/4: OPTYMALIZACJA
# =============================================================
show_progress 8 $TOTAL_STEPS "$MSG_PHASE_3"

restore_packagekit

CMDLINE="quiet splash loglevel=3 systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.ignore-serial-consoles mitigations=off"

missing_cmdline_args() {
    local existing="$1"
    existing="${existing//\"/ }"
    existing="${existing//\'/ }"
    existing="$(printf '%s' "$existing" | tr '\t\r\n' '   ')"
    local missing=""
    local arg
    for arg in $CMDLINE; do
        if [[ " $existing " != *" $arg "* ]]; then
            missing="${missing:+$missing }${arg}"
        fi
    done
    printf '%s' "$missing"
}

BOOT_METHODS_FOUND=()

declare -a LOADER_ROOTS=()
if command -v bootctl &>/dev/null; then
    for p in "$(bootctl --print-esp-path 2>/dev/null || true)" \
             "$(bootctl --print-boot-path 2>/dev/null || true)"; do
        [ -n "$p" ] && [ -d "$p" ] && LOADER_ROOTS+=("$p")
    done
fi
for p in /boot /efi /boot/efi; do
    [ -d "$p" ] && LOADER_ROOTS+=("$p")
done

if [ ${#LOADER_ROOTS[@]} -gt 0 ]; then
    readarray -t LOADER_ROOTS < <(printf '%s\n' "${LOADER_ROOTS[@]}" | awk '!seen[$0]++')
fi

broot_f() { sudo test -f "$1" 2>/dev/null; }
broot_d() { sudo test -d "$1" 2>/dev/null; }
sgrep() { sudo grep "$@" 2>/dev/null; }
broot_glob_first() { sudo find "$1" -maxdepth 1 -iname "$2" -print -quit 2>/dev/null; }

UKI_EFI_FOUND=false
UKI_CHANGED=0
for r in "${LOADER_ROOTS[@]}"; do
    if [ -n "$(broot_glob_first "$r/EFI/Linux" '*.efi')" ]; then
        UKI_EFI_FOUND=true
        break
    fi
done
if [ -f /etc/kernel/cmdline ] && \
   { sgrep -rlq '_uki=' /etc/mkinitcpio.d/*.preset 2>/dev/null || \
     [ "$UKI_EFI_FOUND" = true ]; }; then
    BOOT_METHODS_FOUND+=("uki")
    UKI_CUR="$(sudo cat /etc/kernel/cmdline 2>/dev/null | tr '\n' ' ' || true)"
    UKI_EXTRA="$(missing_cmdline_args "$UKI_CUR")"
    if [ -n "$UKI_EXTRA" ]; then
        sudo sed -i "s/\$/ $UKI_EXTRA/" /etc/kernel/cmdline || true
        sudo sed -i 's/  */ /g' /etc/kernel/cmdline || true
        UKI_CHANGED=1
    fi
fi

SYSTEMD_BOOT_DETECTED=false
for r in "${LOADER_ROOTS[@]}"; do
    broot_f "$r/loader/loader.conf" && SYSTEMD_BOOT_DETECTED=true
done
if command -v bootctl &>/dev/null && [ "$SYSTEMD_BOOT_DETECTED" = true ]; then
    BOOT_METHODS_FOUND+=("systemd-boot")
    for loader_root in "${LOADER_ROOTS[@]}"; do
        if broot_f "$loader_root/loader/loader.conf"; then
            if sgrep -q '^timeout ' "$loader_root/loader/loader.conf"; then
                sudo sed -i 's/^timeout .*/timeout 0/' "$loader_root/loader/loader.conf" || true
            else
                echo "timeout 0" | sudo tee -a "$loader_root/loader/loader.conf" >/dev/null
            fi
        fi
    done

    if [ -f /etc/sdboot-manage.conf ] && command -v sdboot-manage &>/dev/null; then
        SDBOOT_CUR="$(awk -F= '/^LINUX_OPTIONS=/{v=substr($0, index($0,"=")+1); gsub(/^["\047]|["\047]$/, "", v); last=v} END{print last}' /etc/sdboot-manage.conf 2>/dev/null || true)"
        SDBOOT_EXTRA="$(missing_cmdline_args "$SDBOOT_CUR")"
        if [ -n "$SDBOOT_EXTRA" ]; then
            SDBOOT_NEW="${SDBOOT_CUR:+$SDBOOT_CUR }${SDBOOT_EXTRA}"
            SDBOOT_NEW="$(printf '%s' "$SDBOOT_NEW" | sed 's/  */ /g; s/^ //; s/ $//')"
            if sgrep -q '^LINUX_OPTIONS=' /etc/sdboot-manage.conf; then
                sudo sed -i "s|^LINUX_OPTIONS=.*|LINUX_OPTIONS=\"${SDBOOT_NEW}\"|" /etc/sdboot-manage.conf || true
            else
                echo "LINUX_OPTIONS=\"${SDBOOT_NEW}\"" | sudo tee -a /etc/sdboot-manage.conf >/dev/null || true
            fi
            sudo sdboot-manage gen &>/dev/null || true
        fi
    else
        for loader_root in "${LOADER_ROOTS[@]}"; do
            if broot_d "$loader_root/loader/entries"; then
                while IFS= read -r -d '' entry; do
                    ENTRY_CUR="$(sudo awk '/^options[[:space:]]/{sub(/^options[[:space:]]+/, ""); print; exit}' "$entry" 2>/dev/null || true)"
                    ENTRY_EXTRA="$(missing_cmdline_args "$ENTRY_CUR")"
                    if [ -n "$ENTRY_EXTRA" ]; then
                        sudo sed -i "/^options/ s/\$/ $ENTRY_EXTRA/" "$entry" || true
                        sudo sed -i 's/  */ /g' "$entry" || true
                    fi
                done < <(sudo find "$loader_root/loader/entries" -maxdepth 1 -iname '*.conf' -print0 2>/dev/null)
            fi
        done
    fi
    sudo bootctl set-timeout 0 &>/dev/null || true
fi

if [ -f /etc/default/grub ] && command -v grub-mkconfig &>/dev/null; then
    BOOT_METHODS_FOUND+=("grub")
    if sgrep -q '^#\?GRUB_TIMEOUT=' /etc/default/grub; then
        sudo sed -i 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub || true
    else
        echo 'GRUB_TIMEOUT=0' | sudo tee -a /etc/default/grub >/dev/null || true
    fi
    GRUB_CMDLINE_CURRENT="$(awk -F= '/^GRUB_CMDLINE_LINUX_DEFAULT=/{v=substr($0, index($0,"=")+1); gsub(/^["\047]|["\047]$/, "", v); last=v} END{print last}' /etc/default/grub 2>/dev/null || true)"
    GRUB_EXTRA="$(missing_cmdline_args "$GRUB_CMDLINE_CURRENT")"
    if [ -n "$GRUB_EXTRA" ]; then
        GRUB_CMDLINE_NEW="${GRUB_CMDLINE_CURRENT:+$GRUB_CMDLINE_CURRENT }${GRUB_EXTRA}"
        GRUB_CMDLINE_NEW="$(printf '%s' "$GRUB_CMDLINE_NEW" | sed 's/  */ /g; s/^ //; s/ $//')"
        if sgrep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"|" /etc/default/grub || true
        else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"" | sudo tee -a /etc/default/grub >/dev/null || true
        fi
    fi
    sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
fi

declare -a LIMINE_CONFS=()
for candidate in /boot/limine.conf /efi/limine.conf \
                  /boot/EFI/Limine/limine.conf /efi/EFI/Limine/limine.conf \
                  /boot/EFI/BOOT/limine.conf /efi/EFI/BOOT/limine.conf \
                  /boot/limine.cfg /efi/limine.cfg; do
    broot_f "$candidate" && LIMINE_CONFS+=("$candidate")
done

patch_one_limine_conf() {
    local f="$1"
    local patch_cmdline="${2:-1}"
    local arg arg_re
    broot_f "$f" || return 0
    if [[ "$f" == *.conf ]]; then
        if sgrep -qiE '^timeout:' "$f"; then
            sudo sed -i -E 's/^timeout:.*/timeout: 0/I' "$f" || true
        else
            sudo sed -i '1i timeout: 0' "$f" || true
        fi
        if [ "$patch_cmdline" -eq 1 ]; then
            for arg in $CMDLINE; do
                arg_re="${arg//./\\.}"
                sudo sed -i -E "/^[[:space:]]*cmdline:/{/(^|[[:space:]:=])${arg_re}([[:space:]]|\$)/!s/\$/ ${arg}/}" "$f" || true
            done
        fi
    else
        if sgrep -qiE '^timeout=' "$f"; then
            sudo sed -i -E 's/^timeout=.*/TIMEOUT=0/I' "$f" || true
        else
            sudo sed -i '1i TIMEOUT=0' "$f" || true
        fi
        if [ "$patch_cmdline" -eq 1 ]; then
            for arg in $CMDLINE; do
                arg_re="${arg//./\\.}"
                sudo sed -i -E "/^[[:space:]]*CMDLINE=/{/(^|[[:space:]:=])${arg_re}([[:space:]]|\$)/!s/\$/ ${arg}/}" "$f" || true
            done
        fi
    fi
    sudo sed -i 's/[[:space:]]\{2,\}/ /g' "$f" || true
}

patch_limine_conf() {
    local patch_cmdline="${1:-1}"
    local f
    for f in "${LIMINE_CONFS[@]}"; do
        patch_one_limine_conf "$f" "$patch_cmdline"
    done
    if [ ${#LIMINE_CONFS[@]} -gt 1 ]; then
        local src="${LIMINE_CONFS[0]}"
        for f in "${LIMINE_CONFS[@]:1}"; do
            [[ "$src" == *.conf && "$f" == *.conf ]] && sudo cp -f "$src" "$f" 2>/dev/null || true
        done
    fi
}

if [ ${#LIMINE_CONFS[@]} -gt 0 ] || [ -f /etc/default/limine ]; then
    BOOT_METHODS_FOUND+=("limine")
    if [ -f /etc/default/limine ]; then
        LIMINE_CUR="$(sudo grep -E '^[[:space:]]*KERNEL_CMDLINE' /etc/default/limine 2>/dev/null || true)"
        LIMINE_EXTRA="$(missing_cmdline_args "$LIMINE_CUR")"
        if [ -n "$LIMINE_EXTRA" ]; then
            printf '\nKERNEL_CMDLINE[default]+=" %s"\n' "$LIMINE_EXTRA" | sudo tee -a /etc/default/limine >/dev/null || true
            command -v limine-update &>/dev/null && sudo limine-update &>/dev/null || true
        fi
        patch_limine_conf 0
    else
        patch_limine_conf 1
    fi
fi

REFIND_CONF=""
for candidate in /boot/EFI/refind/refind.conf /efi/EFI/refind/refind.conf \
                 /boot/refind_linux.conf /efi/refind_linux.conf; do
    broot_f "$candidate" && { REFIND_CONF="$candidate"; break; }
done
if [ -n "$REFIND_CONF" ]; then
    BOOT_METHODS_FOUND+=("refind")

    REFIND_MAIN_CONF=""
    for candidate in /boot/EFI/refind/refind.conf /efi/EFI/refind/refind.conf; do
        broot_f "$candidate" && { REFIND_MAIN_CONF="$candidate"; break; }
    done
    if [ -n "$REFIND_MAIN_CONF" ]; then
        if sgrep -qE '^timeout[[:space:]]' "$REFIND_MAIN_CONF"; then
            sudo sed -i -E 's/^timeout[[:space:]].*/timeout -1/' "$REFIND_MAIN_CONF" || true
        else
            echo "timeout -1" | sudo tee -a "$REFIND_MAIN_CONF" >/dev/null
        fi
    fi

    for rl_conf in /boot/refind_linux.conf /efi/refind_linux.conf \
                   /boot/EFI/Linux/refind_linux.conf /efi/EFI/Linux/refind_linux.conf; do
        broot_f "$rl_conf" || continue
        for arg in $CMDLINE; do
            arg_re="${arg//./\\.}"
            sudo sed -i -E "/(^|[[:space:]\"])${arg_re}([[:space:]\"]|\$)/! s/^([[:space:]]*\"[^\"]*\"[[:space:]]+\")([^\"]*)\"[[:space:]]*\$/\\1\\2 ${arg}\"/" "$rl_conf" || true
        done
    done
fi

EFISTUB_FOUND=false
if command -v efibootmgr &>/dev/null; then
    re_boot_line='^Boot([0-9A-Fa-f]{4})\*?[[:space:]]*(.*)$'
    re_file_node='/File\(([^)]*)\)(.*)$'
    re_partuuid='GPT,([0-9A-Fa-f-]{36})'
    while IFS= read -r line; do
        [[ "$line" =~ $re_boot_line ]] || continue
        boot_num="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        [[ "$rest" =~ $re_file_node ]] || continue
        loader_path="${BASH_REMATCH[1]}"
        cmdline_data="${BASH_REMATCH[2]}"
        [[ "$loader_path" == *.efi || "$loader_path" == *.EFI ]] && continue
        [[ "$loader_path" =~ [Vv][Mm][Ll][Ii][Nn][Uu][Zz] ]] || continue

        EFISTUB_FOUND=true

        EFISTUB_EXTRA="$(missing_cmdline_args "$cmdline_data")"
        if [ -n "$EFISTUB_EXTRA" ]; then
            partuuid=""
            [[ "$rest" =~ $re_partuuid ]] && partuuid="${BASH_REMATCH[1]}"
            label="${rest%%$'\t'*}"
            if [ -n "$partuuid" ] && command -v blkid &>/dev/null; then
                part_dev="$(blkid --match-token "PARTUUID=$partuuid" -o device 2>/dev/null || true)"
                if [ -n "$part_dev" ]; then
                    re_nvme_part='^(.*[0-9])p([0-9]+)$'
                    re_sata_part='^(.*[a-zA-Z])([0-9]+)$'
                    if [[ "$part_dev" =~ $re_nvme_part ]]; then
                        disk_dev="${BASH_REMATCH[1]}"; part_num="${BASH_REMATCH[2]}"
                    elif [[ "$part_dev" =~ $re_sata_part ]]; then
                        disk_dev="${BASH_REMATCH[1]}"; part_num="${BASH_REMATCH[2]}"
                    else
                        disk_dev=""; part_num=""
                    fi
                    if [ -n "$disk_dev" ] && [ -n "$part_num" ]; then
                        loader_path_bs="$(sed 's#/#\\#g' <<<"$loader_path")"
                        new_cmdline="$(sed 's/[[:space:]]*$//' <<<"$cmdline_data") $EFISTUB_EXTRA"
                        new_cmdline="$(sed 's/  */ /g' <<<"$new_cmdline")"
                        if sudo efibootmgr -c -d "$disk_dev" -p "$part_num" \
                            -L "$label" -l "$loader_path_bs" -u "$new_cmdline" &>/dev/null; then
                            sudo efibootmgr -b "$boot_num" -B &>/dev/null || true
                        fi
                    fi
                fi
            fi
        fi
    done < <(efibootmgr -v 2>/dev/null)
fi
[ "$EFISTUB_FOUND" = true ] && BOOT_METHODS_FOUND+=("efistub")

if [[ " ${BOOT_METHODS_FOUND[*]} " != *" systemd-boot "* ]] && \
   [[ " ${BOOT_METHODS_FOUND[*]} " != *" grub "* ]] && \
   [[ " ${BOOT_METHODS_FOUND[*]} " != *" limine "* ]] && \
   [[ " ${BOOT_METHODS_FOUND[*]} " != *" refind "* ]] && \
   command -v efibootmgr &>/dev/null; then
    sudo efibootmgr -t 0 &>/dev/null || true
fi

if [ "$UKI_CHANGED" -eq 1 ] && command -v mkinitcpio &>/dev/null; then
    sudo mkinitcpio -P || true
fi

show_progress 9 $TOTAL_STEPS "$MSG_PHASE_3"

sudo systemctl enable --now geoclue.service || true
echo "options btusb enable_autosuspend=0" | sudo tee /etc/modprobe.d/btusb.conf > /dev/null

sudo systemctl enable --now libvirtd || true

LIBVIRT_NET="192.168.122.0/24"
if ip -4 -o addr show 2>/dev/null | awk '$2 != "virbr0" && $4 ~ /^192\.168\.122\./ {found=1} END {exit !found}'; then
    LIBVIRT_NET="192.168.150.0/24"
fi

if ! sudo virsh net-info default &>/dev/null; then
    sudo virsh net-define /usr/share/libvirt/networks/default.xml || true
fi

if [[ "$LIBVIRT_NET" == "192.168.150.0/24" ]]; then
    LIBVIRT_NET_XML="$(mktemp)"
    LIBVIRT_NET_BAK="$(mktemp)"
    if sudo virsh net-dumpxml default --inactive 2>/dev/null > "$LIBVIRT_NET_XML" && grep -q '192\.168\.122\.' "$LIBVIRT_NET_XML"; then
        cp -f "$LIBVIRT_NET_XML" "$LIBVIRT_NET_BAK"
        sed -i 's/192\.168\.122\./192.168.150./g' "$LIBVIRT_NET_XML" || true
        LIBVIRT_NET_RESTORE=1
        sudo virsh net-destroy default 2>/dev/null || true
        sudo virsh net-undefine default 2>/dev/null || true
        if ! sudo virsh net-define "$LIBVIRT_NET_XML"; then
            sudo virsh net-define "$LIBVIRT_NET_BAK" || true
        fi
        LIBVIRT_NET_RESTORE=0
    fi
    rm -f "$LIBVIRT_NET_XML" "$LIBVIRT_NET_BAK"
fi

sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default 2>/dev/null || true

if command -v ufw &>/dev/null; then
    [[ -f /etc/default/ufw ]] && sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    sudo ufw allow in on virbr0 || true
    sudo ufw allow out on virbr0 || true
    sudo ufw allow from "$LIBVIRT_NET" || true
    if pkg_installed openssh || [[ -x /usr/bin/sshd ]] || [[ -x /usr/sbin/sshd ]] \
        || systemctl is-active --quiet sshd 2>/dev/null; then
        SSH_PORT="$(sudo sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
        [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
        sudo ufw allow "${SSH_PORT}/tcp" || true
    fi
    if sudo ufw status 2>/dev/null | grep -qi '^Status: active'; then
        sudo ufw reload || true
    fi
fi

if command -v dconf &>/dev/null; then
    dconf load /org/virt-manager/virt-manager/ <<'EOF' || true
[/]
manager-window-height=297
manager-window-width=478
xmleditor-enabled=true

[confirm]
delete-storage=false
forcepoweroff=false

[connections]
autoconnect=['qemu:///system']
uris=['qemu:///system']

[conns/qemu:system]
window-size=(800, 600)

[details]
show-toolbar=true

[new-vm]
cpu-default='host-passthrough'
firmware='uefi'
graphics-type='spice'
storage-format='raw'

[stats]
enable-disk-poll=true
enable-memory-poll=true
enable-net-poll=true

[vmlist-fields]
disk-usage=false
network-traffic=false
EOF
fi

for grp in libvirt kvm; do
    getent group "$grp" &>/dev/null && sudo usermod -aG "$grp" "$CURRENT_USER" || true
done

# =============================================================
#  ETAP 4/4: CZYSZCZENIE
# =============================================================
show_progress 10 $TOTAL_STEPS "$MSG_PHASE_4"
printf '\n\n' >&3 2>/dev/null || true

if [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
    log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}" "Failed to install: ${FAILED_PACKAGES[*]}"
fi

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}[OK] KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3 2>/dev/null || true
else
    echo -e "${SUCCESS}[OK] CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3 2>/dev/null || true
fi

# =============================================================
#  RESTART SYSTEMU
# =============================================================
if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${INFO}==> ${RESTART_PROMPT}${NC}" >&3 2>/dev/null || true
RESTART_CHOICE=""
read -r RESTART_CHOICE < /dev/tty || true
case "$RESTART_CHOICE" in
    [YyTt]*)
        DO_REBOOT=1
        ;;
esac
exit 0
