#!/bin/bash

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DETECTED_LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
if [ -z "$DETECTED_LOCALE" ] && command -v locale &> /dev/null; then
    DETECTED_LOCALE=$(locale 2>/dev/null | grep -m1 '^LANG=' | cut -d= -f2)
fi

if [[ "$DETECTED_LOCALE" == pl_PL* ]] || [[ "$DETECTED_LOCALE" == pl* ]]; then
    IS_PL=true
else
    IS_PL=false
fi

if [ "$IS_PL" = true ]; then
    MSG_TITLE="       KOMPLEKSOWY SKRYPT AKTUALIZACJI I CZYSZCZENIA  "
    MSG_ASK_PASS="Proszę podać hasło administratora (sudo) na potrzeby czyszczenia systemu:"
    MSG_UPDATE_KEYRING="==> Aktualizacja archlinux-keyring (zapobieganie błędom PGP)..."
    MSG_FULL_UPDATE="==> Wykonywanie pełnej aktualizacji systemu (YAY)..."
    MSG_FLATPAK_UPDATE="==> Wykonywanie aktualizacji aplikacji Flatpak..."
    MSG_FWUPD_REFRESH="==> Odświeżanie metadanych firmware (fwupd)..."
    MSG_FWUPD_UPDATE="==> Sprawdzanie i instalowanie aktualizacji firmware (fwupd)..."
    MSG_FWUPD_ABSENT="==> fwupdmgr nieobecny w systemie - pomijam aktualizację firmware."
    MSG_FWUPD_RESTART_NEEDED="UWAGA: Zainstalowano aktualizację firmware wymagającą restartu!"
    MSG_PHASE1_TITLE="       FAZA 1: KOMENDY SYSTEMOWE (SUDO)               "
    MSG_CLEAN_PACMAN_LIB="==> Czyszczenie /var/lib/pacman/ (blokady i pliki tymczasowe)..."
    MSG_REMOVE_ORPHANS="==> Usuwanie osieroconych pakietów..."
    MSG_NO_ORPHANS="Brak osieroconych pakietów."
    MSG_CLEAN_PACMAN_CACHE="==> Całkowite usuwanie zawartości cache pacmana..."
    MSG_FLATPAK_CLEAN_SYS="==> Kompleksowe czyszczenie Flatpak (System)..."
    MSG_FLATPAK_REMOTES="==> Usuwanie nieużywanych źródeł (remotes) Flatpak..."
    MSG_FLATPAK_REMOVING_REMOTE="Usuwanie nieużywanego źródła:"
    MSG_FLATPAK_ABSENT_SYS="==> Flatpak nieobecny w systemie - pomijam czyszczenie systemowe."
    MSG_CLEAN_LOGS="==> Czyszczenie logów w /var/log (rotate + usuwanie starych .gz)..."
    MSG_CLEAN_TMP="==> Czyszczenie starego /tmp i /var/tmp..."
    MSG_PHASE2_TITLE="       FAZA 2: KOMENDY UŻYTKOWNIKA (BEZ SUDO)         "
    MSG_CLEAN_YAY="==> Całkowite czyszczenie cache YAY i źródeł AUR..."
    MSG_FLATPAK_CLEAN_USER="==> Kompleksowe czyszczenie Flatpak (Użytkownik)..."
    MSG_FLATPAK_ABSENT_USER="==> Flatpak nieobecny w systemie - pomijam czyszczenie użytkownika."
    MSG_CLEAN_USER_CACHE="==> Czyszczenie starego cache użytkownika (omijanie przeglądarek)..."
    MSG_CLEAN_THUMBS="==> Czyszczenie starych miniatur (thumbnails)..."
    MSG_REBUILD_FONTS="==> Przebudowa cache czcionek..."
    MSG_CLEAN_VIRT="==> Czyszczenie virt-manager i reset dconf..."
    MSG_DCONF_DONE="==> dconf reset wykonany."
    MSG_PHASE3_TITLE="       FAZA 3: SPRAWDZANIE KONIECZNOŚCI RESTARTU      "
    MSG_NEEDRESTART_ANALYZE="==> Analiza zaktualizowanych pakietów (needrestart)..."
    MSG_RESTART_WARN1="UWAGA: Zaktualizowano kluczowe komponenty (np. kernel)!"
    MSG_RESTART_WARN2=" ZALECANY JEST RESTART KOMPUTERA!                     "
    MSG_NO_RESTART_NEEDED="==> Restart systemu nie jest aktualnie wymagany."
    MSG_NO_NEEDRESTART="Brak programu 'needrestart'. Używam metody zapasowej (sprawdzanie modułów)..."
    MSG_KERNEL_UPDATED="UWAGA: Zaktualizowano kernel!                        "
    MSG_NO_KERNEL_UPDATE="==> Nie wykryto aktualizacji kernela wymagającej restartu."
    MSG_DONE_TITLE="       AKTUALIZACJA I CZYSZCZENIE ZAKOŃCZONE!          "
    MSG_PRESS_ENTER="Naciśnij [ENTER], aby zakończyć..."
else
    MSG_TITLE="         COMPREHENSIVE UPDATE AND CLEANUP SCRIPT       "
    MSG_ASK_PASS="Please enter the administrator (sudo) password for system cleanup:"
    MSG_UPDATE_KEYRING="==> Updating archlinux-keyring (preventing PGP errors)..."
    MSG_FULL_UPDATE="==> Performing a full system update (YAY)..."
    MSG_FLATPAK_UPDATE="==> Updating Flatpak applications..."
    MSG_FWUPD_REFRESH="==> Refreshing firmware metadata (fwupd)..."
    MSG_FWUPD_UPDATE="==> Checking for and installing firmware updates (fwupd)..."
    MSG_FWUPD_ABSENT="==> fwupdmgr not present on the system - skipping firmware update."
    MSG_FWUPD_RESTART_NEEDED="WARNING: A firmware update requiring a restart was installed!"
    MSG_PHASE1_TITLE="       PHASE 1: SYSTEM COMMANDS (SUDO)                "
    MSG_CLEAN_PACMAN_LIB="==> Cleaning /var/lib/pacman/ (locks and temporary files)..."
    MSG_REMOVE_ORPHANS="==> Removing orphaned packages..."
    MSG_NO_ORPHANS="No orphaned packages found."
    MSG_CLEAN_PACMAN_CACHE="==> Completely clearing the pacman cache..."
    MSG_FLATPAK_CLEAN_SYS="==> Comprehensive Flatpak cleanup (System)..."
    MSG_FLATPAK_REMOTES="==> Removing unused Flatpak remotes..."
    MSG_FLATPAK_REMOVING_REMOTE="Removing unused remote:"
    MSG_FLATPAK_ABSENT_SYS="==> Flatpak not present on the system - skipping system cleanup."
    MSG_CLEAN_LOGS="==> Cleaning logs in /var/log (rotate + removing old .gz files)..."
    MSG_CLEAN_TMP="==> Cleaning old /tmp and /var/tmp..."
    MSG_PHASE2_TITLE="       PHASE 2: USER COMMANDS (NO SUDO)               "
    MSG_CLEAN_YAY="==> Completely clearing YAY cache and AUR sources..."
    MSG_FLATPAK_CLEAN_USER="==> Comprehensive Flatpak cleanup (User)..."
    MSG_FLATPAK_ABSENT_USER="==> Flatpak not present on the system - skipping user cleanup."
    MSG_CLEAN_USER_CACHE="==> Cleaning old user cache (skipping browsers)..."
    MSG_CLEAN_THUMBS="==> Cleaning old thumbnails..."
    MSG_REBUILD_FONTS="==> Rebuilding font cache..."
    MSG_CLEAN_VIRT="==> Cleaning virt-manager and resetting dconf..."
    MSG_DCONF_DONE="==> dconf reset completed."
    MSG_PHASE3_TITLE="       PHASE 3: CHECKING IF A RESTART IS NEEDED       "
    MSG_NEEDRESTART_ANALYZE="==> Analyzing updated packages (needrestart)..."
    MSG_RESTART_WARN1="WARNING: Critical components have been updated (e.g. kernel)!"
    MSG_RESTART_WARN2=" A SYSTEM RESTART IS RECOMMENDED!                     "
    MSG_NO_RESTART_NEEDED="==> A system restart is not currently required."
    MSG_NO_NEEDRESTART="'needrestart' not found. Using fallback method (checking modules)..."
    MSG_KERNEL_UPDATED="WARNING: The kernel has been updated!                "
    MSG_NO_KERNEL_UPDATE="==> No kernel update detected that would require a restart."
    MSG_DONE_TITLE="       UPDATE AND CLEANUP COMPLETE!                    "
    MSG_PRESS_ENTER="Press [ENTER] to finish..."
fi

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${YELLOW}${MSG_ASK_PASS}${NC}"
sudo -v

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!

echo -e "\n${GREEN}${MSG_UPDATE_KEYRING}${NC}"
sudo pacman -Sy archlinux-keyring --noconfirm

echo -e "\n${GREEN}${MSG_FULL_UPDATE}${NC}"
yay -Syu --noconfirm

if command -v flatpak &> /dev/null; then
    echo -e "\n${GREEN}${MSG_FLATPAK_UPDATE}${NC}"
    flatpak update -y
fi

FWUPD_RESTART_NEEDED=false
if command -v fwupdmgr &> /dev/null; then
    echo -e "\n${GREEN}${MSG_FWUPD_REFRESH}${NC}"
    sudo fwupdmgr refresh --force

    echo -e "\n${GREEN}${MSG_FWUPD_UPDATE}${NC}"
    FWUPD_OUT=$(sudo fwupdmgr update -y 2>&1)
    echo "$FWUPD_OUT"

    if echo "$FWUPD_OUT" | grep -qiE "restart|reboot"; then
        FWUPD_RESTART_NEEDED=true
    fi
else
    echo -e "\n${YELLOW}${MSG_FWUPD_ABSENT}${NC}"
fi

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_PHASE1_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${GREEN}${MSG_CLEAN_PACMAN_LIB}${NC}"
sudo rm -f /var/lib/pacman/db.lck
sudo find /var/lib/pacman/ -type f -name "*.part" -delete

echo -e "${GREEN}${MSG_REMOVE_ORPHANS}${NC}"
ORPHANS=$(pacman -Qtdq)
if [ -n "$ORPHANS" ]; then
    sudo pacman -Rns $ORPHANS --noconfirm
else
    echo "$MSG_NO_ORPHANS"
fi

echo -e "${GREEN}${MSG_CLEAN_PACMAN_CACHE}${NC}"
sudo rm -rf /var/cache/pacman/pkg/download-* 2>/dev/null
sudo rm -rf /var/cache/pacman/pkg/* 2>/dev/null

if command -v flatpak &> /dev/null; then
    echo -e "${GREEN}${MSG_FLATPAK_CLEAN_SYS}${NC}"
    sudo flatpak uninstall --unused --system --delete-data -y
    sudo flatpak repair --system

    echo -e "${GREEN}${MSG_FLATPAK_REMOTES}${NC}"
    USED_REMOTES=$(flatpak list --columns=origin 2>/dev/null | sort -u)
    ALL_REMOTES=$(flatpak remotes --columns=name 2>/dev/null)

    while IFS= read -r remote; do
        if [ -n "$remote" ] && ! echo "$USED_REMOTES" | grep -qx "$remote"; then
            echo -e "${YELLOW}${MSG_FLATPAK_REMOVING_REMOTE} $remote${NC}"
            sudo flatpak remote-delete --force "$remote" 2>/dev/null
        fi
    done <<< "$ALL_REMOTES"

    sudo rm -rf /var/tmp/flatpak-cache-* 2>/dev/null
    sudo rm -rf /var/lib/flatpak/repo/tmp/* 2>/dev/null
    sudo find /var/lib/flatpak -name "*.tmp" -delete 2>/dev/null
    sudo rm -f /var/lib/flatpak/history 2>/dev/null
else
    echo -e "${YELLOW}${MSG_FLATPAK_ABSENT_SYS}${NC}"
fi

echo -e "${GREEN}${MSG_CLEAN_LOGS}${NC}"
sudo journalctl --vacuum-time=7d
sudo find /var/log -type f -name "*.gz" -mtime +14 -exec rm -f {} +

echo -e "${GREEN}${MSG_CLEAN_TMP}${NC}"
sudo find /tmp -type f -atime +5 -exec rm -f {} + 2>/dev/null
sudo find /var/tmp -type f -atime +5 -exec rm -f {} + 2>/dev/null

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_PHASE2_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${GREEN}${MSG_CLEAN_YAY}${NC}"
yay -Scc --noconfirm
rm -rf ~/.cache/yay/* 2>/dev/null

if command -v flatpak &> /dev/null; then
    echo -e "${GREEN}${MSG_FLATPAK_CLEAN_USER}${NC}"
    flatpak uninstall --unused --user --delete-data -y
    flatpak repair --user
    rm -f ~/.local/share/flatpak/history 2>/dev/null
else
    echo -e "${YELLOW}${MSG_FLATPAK_ABSENT_USER}${NC}"
fi

echo -e "${GREEN}${MSG_CLEAN_USER_CACHE}${NC}"
find ~/.cache -type f -atime +14 \
    ! -path "*/mozilla/*" \
    ! -path "*/google-chrome/*" \
    ! -path "*/chromium/*" \
    ! -path "*/BraveSoftware/*" \
    ! -path "*/opera/*" \
    ! -path "*/vivaldi/*" \
    -exec rm -f {} + 2>/dev/null

echo -e "${GREEN}${MSG_CLEAN_THUMBS}${NC}"
find ~/.cache/thumbnails -type f -atime +14 -exec rm -f {} + 2>/dev/null

echo -e "${GREEN}${MSG_REBUILD_FONTS}${NC}"
fc-cache -r

echo -e "${GREEN}${MSG_CLEAN_VIRT}${NC}"
USER_ID=$(id -u)
if [ -S "/run/user/$USER_ID/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
    echo -e "$MSG_DCONF_DONE"
fi
rm -rf "$HOME/.cache/virt-manager" 2>/dev/null

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_PHASE3_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

if [ "$FWUPD_RESTART_NEEDED" = true ]; then
    echo -e "\n${RED}******************************************************${NC}"
    echo -e "${RED} ${MSG_FWUPD_RESTART_NEEDED} ${NC}"
    echo -e "${YELLOW}${MSG_RESTART_WARN2}${NC}"
    echo -e "${RED}******************************************************${NC}\n"
fi

if command -v needrestart &> /dev/null; then
    echo -e "${GREEN}${MSG_NEEDRESTART_ANALYZE}${NC}"

    NEEDRESTART_OUT=$(sudo needrestart -b 2>/dev/null)

    if echo "$NEEDRESTART_OUT" | grep -qE "NEEDRESTART-KSTA: [23]"; then
        echo -e "\n${RED}******************************************************${NC}"
        echo -e "${RED} ${MSG_RESTART_WARN1} ${NC}"
        echo -e "${YELLOW}${MSG_RESTART_WARN2}${NC}"
        echo -e "${RED}******************************************************${NC}\n"
    else
        echo -e "${GREEN}${MSG_NO_RESTART_NEEDED}${NC}"
    fi
else
    echo -e "${YELLOW}${MSG_NO_NEEDRESTART}${NC}"
    if [ ! -d "/usr/lib/modules/$(uname -r)" ]; then
        echo -e "\n${RED}******************************************************${NC}"
        echo -e "${RED} ${MSG_KERNEL_UPDATED}${NC}"
        echo -e "${YELLOW}${MSG_RESTART_WARN2}${NC}"
        echo -e "${RED}******************************************************${NC}\n"
    else
        echo -e "${GREEN}${MSG_NO_KERNEL_UPDATE}${NC}"
    fi
fi

kill $SUDO_KEEP_ALIVE_PID 2>/dev/null

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}${MSG_DONE_TITLE}${NC}"
echo -e "${GREEN}======================================================${NC}"
echo "$MSG_PRESS_ENTER"
read -r
