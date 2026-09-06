#!/bin/bash
set -uo pipefail

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

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[1;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/update-log.XXXXXX)"
LOG_FILE="$HOME/update_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

RESTART_NEEDED=false
KERNEL_UPDATED=false

cleanup_on_exit() {
    local exit_code=$?
    printf '\033[?25h' >&3
    echo "" >&3
    if [ "$exit_code" -ne 0 ]; then
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${ERR}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
        fi
    fi
    rm -f "$TMP_LOG"
}
trap cleanup_on_exit EXIT

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    local bar_width=50
    local reserved=12
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 1))}…"
    fi

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ $filled -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ $empty -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
}

print_pkg_list() {
    local title="$1"
    local list="$2"
    [ -z "$list" ] && return
    printf "\r\033[K" >&3
    echo -e "${INFO}${title}${NC}" >&3
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && echo -e "  ${SUCCESS}•${NC} $pkg" >&3
    done <<< "$list"
}

if [ "$SCRIPT_LANG" = "pl" ]; then
    MSG_TITLE="       KOMPLEKSOWY SKRYPT AKTUALIZACJI I CZYSZCZENIA  "
    MSG_ASK_PASS="Proszę podać hasło administratora (sudo):"
    MSG_PHASE_UPDATE="[1/4] Aktualizacja systemu i aplikacji..."
    MSG_PKGS_UPDATED="Aktualizowane pakiety:"
    MSG_PKGS_NONE="Brak pakietów do aktualizacji (system aktualny)."
    MSG_FLATPAK_UPDATED="Aktualizowane pakiety Flatpak:"
    MSG_PHASE_CLEAN_SYS="[2/4] Czyszczenie systemowe (sudo)..."
    MSG_PHASE_CLEAN_USER="[3/4] Czyszczenie użytkownika..."
    MSG_PHASE_RESTART="[4/4] Sprawdzanie konieczności restartu..."
    MSG_DONE="AKTUALIZACJA I CZYSZCZENIE ZAKOŃCZONE!"
    MSG_RESTART_WARN="UWAGA: Zalecany jest restart komputera"
    MSG_NO_RESTART="Restart systemu nie jest aktualnie wymagany."
    MSG_PRESS_ENTER="Naciśnij Enter, aby zamknąć okno..."
else
    MSG_TITLE="         COMPREHENSIVE UPDATE AND CLEANUP SCRIPT       "
    MSG_ASK_PASS="Please enter the administrator (sudo) password:"
    MSG_PHASE_UPDATE="[1/4] Updating system and applications..."
    MSG_PKGS_UPDATED="Updating packages:"
    MSG_PKGS_NONE="No packages to update (system is up to date)."
    MSG_FLATPAK_UPDATED="Updating Flatpak packages:"
    MSG_PHASE_CLEAN_SYS="[2/4] System cleanup (sudo)..."
    MSG_PHASE_CLEAN_USER="[3/4] User cleanup..."
    MSG_PHASE_RESTART="[4/4] Checking if a restart is needed..."
    MSG_DONE="UPDATE AND CLEANUP COMPLETE!"
    MSG_RESTART_WARN="WARNING: A system restart is recommended"
    MSG_NO_RESTART="A system restart is not currently required."
    MSG_PRESS_ENTER="Press Enter to close this window..."
fi

echo -e "${INFO}======================================================${NC}" >&3
echo -e "${INFO}${MSG_TITLE}${NC}" >&3
echo -e "${INFO}======================================================${NC}" >&3
echo -e "${WARN}${MSG_ASK_PASS}${NC}" >&3
sudo -v >&3

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!

TOTAL_STEPS=19
STEP=0
show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

# ---------------------------------------------------------------
# PHASE: UPDATE
# ---------------------------------------------------------------
sudo pacman -Sy archlinux-keyring --noconfirm
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

YAY_OUTPUT=$(yay -Syu --noconfirm 2>&1)
echo "$YAY_OUTPUT"

PKG_LINE=$(echo "$YAY_OUTPUT" | grep -m1 -E '^Packages? \([0-9]+\)')
if [ -n "$PKG_LINE" ]; then
    PKG_LIST=$(echo "$PKG_LINE" | sed -E 's/^Packages? \([0-9]+\) //' | tr ' ' '\n' | sed '/^$/d')
    print_pkg_list "$MSG_PKGS_UPDATED" "$PKG_LIST"
else
    printf "\r\033[K" >&3
    echo -e "${INFO}${MSG_PKGS_NONE}${NC}" >&3
fi

STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v flatpak &> /dev/null; then
    FLATPAK_OUTPUT=$(flatpak update -y 2>&1)
    echo "$FLATPAK_OUTPUT"

    FLATPAK_PKGS=$(echo "$FLATPAK_OUTPUT" | grep -E '\[Update\]' | awk '{print $3}')
    print_pkg_list "$MSG_FLATPAK_UPDATED" "$FLATPAK_PKGS"
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v gext &> /dev/null; then
    gext update
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v cinnamon-spice-updater &> /dev/null; then
    cinnamon-spice-updater --update-all
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v fwupdmgr &> /dev/null; then
    sudo fwupdmgr refresh --force
    FWUPD_OUT=$(sudo fwupdmgr update -y 2>&1)
    echo "$FWUPD_OUT"
    if echo "$FWUPD_OUT" | grep -qiE "restart|reboot"; then
        RESTART_NEEDED=true
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: SYSTEM CLEANUP (SUDO)
# ---------------------------------------------------------------
sudo rm -f /var/lib/pacman/db.lck
sudo find /var/lib/pacman/ -type f -name "*.part" -delete
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

ORPHANS=$(pacman -Qtdq 2>/dev/null)
if [ -n "$ORPHANS" ]; then
    sudo pacman -Rns $ORPHANS --noconfirm
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo rm -rf /var/cache/pacman/pkg/download-* 2>/dev/null
sudo rm -rf /var/cache/pacman/pkg/* 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v flatpak &> /dev/null; then
    sudo flatpak uninstall --unused --system --delete-data -y
    sudo flatpak repair --system

    USED_REMOTES=$(flatpak list --columns=origin 2>/dev/null | sort -u)
    ALL_REMOTES=$(flatpak remotes --columns=name 2>/dev/null)
    while IFS= read -r remote; do
        if [ -n "$remote" ] && ! echo "$USED_REMOTES" | grep -qx "$remote"; then
            sudo flatpak remote-delete --force "$remote" 2>/dev/null
        fi
    done <<< "$ALL_REMOTES"

    sudo rm -rf /var/tmp/flatpak-cache-* 2>/dev/null
    sudo rm -rf /var/lib/flatpak/repo/tmp/* 2>/dev/null
    sudo find /var/lib/flatpak -name "*.tmp" -delete 2>/dev/null
    sudo rm -f /var/lib/flatpak/history 2>/dev/null
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo journalctl --vacuum-time=7d
sudo find /var/log -type f -name "*.gz" -mtime +14 -exec rm -f {} +
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo find /tmp -type f -atime +5 -exec rm -f {} + 2>/dev/null
sudo find /var/tmp -type f -atime +5 -exec rm -f {} + 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

# ---------------------------------------------------------------
# PHASE: USER CLEANUP (NO SUDO)
# ---------------------------------------------------------------
yay -Scc --noconfirm
rm -rf ~/.cache/yay/* 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

if command -v flatpak &> /dev/null; then
    flatpak uninstall --unused --user --delete-data -y
    flatpak repair --user
    rm -f ~/.local/share/flatpak/history 2>/dev/null
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

find ~/.cache -type f -atime +14 \
    ! -path "*/mozilla/*" \
    ! -path "*/google-chrome/*" \
    ! -path "*/chromium/*" \
    ! -path "*/BraveSoftware/*" \
    ! -path "*/opera/*" \
    ! -path "*/vivaldi/*" \
    -exec rm -f {} + 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

find ~/.cache/thumbnails -type f -atime +14 -exec rm -f {} + 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

fc-cache -r
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

USER_ID=$(id -u)
if [ -S "/run/user/$USER_ID/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
fi
rm -rf "$HOME/.cache/virt-manager" 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_RESTART"

# ---------------------------------------------------------------
# PHASE: RESTART CHECK
# ---------------------------------------------------------------
if [ "$RESTART_NEEDED" = true ]; then
    : # fwupd already flagged a restart, keep the flag
fi

if command -v needrestart &> /dev/null; then
    NEEDRESTART_OUT=$(sudo needrestart -b 2>/dev/null)
    if echo "$NEEDRESTART_OUT" | grep -qE "NEEDRESTART-KSTA: [23]"; then
        RESTART_NEEDED=true
    fi
else
    if [ ! -d "/usr/lib/modules/$(uname -r)" ]; then
        RESTART_NEEDED=true
        KERNEL_UPDATED=true
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_RESTART"

kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null

echo -e "\n" >&3
echo -e "${SUCCESS}======================================================${NC}" >&3
echo -e "${SUCCESS}${MSG_DONE}${NC}" >&3
echo -e "${SUCCESS}======================================================${NC}" >&3

if [ "$RESTART_NEEDED" = true ]; then
    echo -e "${WARN}${MSG_RESTART_WARN}${NC}" >&3
    echo -e "${WARN}${MSG_PRESS_ENTER}${NC}" >&3
    read -r
else
    echo -e "${INFO}${MSG_NO_RESTART}${NC}" >&3
fi
