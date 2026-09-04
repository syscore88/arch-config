# 🏔️ Arch Linux Post-Install Setup Script

A comprehensive, automated Bash post-installation script for **Arch Linux**. It goes well beyond desktop theming: it configures pacman, detects your GPU and installs the matching drivers, removes unwanted default apps, installs a large curated set of system/multimedia/gaming/virtualization packages plus Flatpak and AUR (via `yay`) packages, configures the boot splash across virtually any bootloader, enables key system services, and sets up Zsh with Oh My Zsh and Powerlevel10k.

The script auto-detects the system language (Polish/English) from the `LANG`/`LC_ALL` locale and prints all status messages accordingly.

---

## 🚀 Script Features

- **Temporary Passwordless Sudo**: Requests the admin password once at the start, then configures a temporary `NOPASSWD` rule (via `/etc/sudoers.d/`, or a `polkit`/`run0` rule on systems without `visudo`) so the rest of the script can run unattended. The rule is automatically removed at the end.
- **GPU Detection & Driver Setup**: Detects NVIDIA/AMD/Intel GPUs (and hybrid setups) via `lspci`, installs the matching 32-bit (`lib32-*`) Vulkan/driver packages, and later adds the correct kernel modules (`nvidia*`, `amdgpu`, `i915`) to `mkinitcpio.conf`.
- **Bloatware Removal**: Uninstalls a long list of default KDE/GNOME/Cosmic apps not needed on a customized setup (e.g. `konqueror`, `kontact`, `kmail`, `korganizer`, `akonadi-server`, `gnome-software`, `epiphany`, `rhythmbox`, `evolution`, `htop`, `nano`, and more), along with their leftover config/cache directories, and disables the KWallet secret service.
- **Pacman Optimization**: Enables colored/verbose output, `ILoveCandy`, parallel downloads (10), disables `CheckSpace`, and skips extracting unneeded locales/man pages/docs (`NoExtract`) to speed up installs.
- **DNS Configuration**: Sets Cloudflare (`1.1.1.1`/`1.0.0.1` + IPv6) as the system and NetworkManager global DNS, and applies it to the currently active connection.
- **Package Installation**: Installs a large curated `SYSTEM_PKGS` set covering dev tools (`base-devel`, `git`, `gcc`, `cmake`, `python-pip`...), office/media apps (LibreOffice, Thunderbird, VLC, GIMP, Krita, Kdenlive, Audacity...), gaming/Proton stack (`wine-staging`, `gamemode`, `gamescope`, `mangohud`, `vkd3d`...), and virtualization (`virt-manager`, `qemu-desktop`, `libvirt`, `edk2-ovmf`), plus GPU-specific 32-bit driver packages.
- **Flatpak & AUR**: Adds the Flathub remote and installs Flatseal; bootstraps `yay` if missing (cloning from the AUR, with a tarball fallback and retry logic) and installs a curated AUR package list (Ventoy, Google Chrome, Brave, Faugus Launcher, etc.).
- **Universal Boot Splash Configuration**: Auto-detects whichever bootloader is present — **systemd-boot**, **GRUB**, **Limine**, **rEFInd**, **UKI (Unified Kernel Image)**, or raw **EFISTUB** entries — and patches each one's timeout/kernel cmdline to enable a silent Plymouth splash (`quiet splash loglevel=3 ...`), sets the Plymouth theme to `bgrt`, updates `mkinitcpio` hooks/presets, resolves UKI filename collisions between kernels, and rebuilds the initramfs.
- **Services & Firewall**: Configures UFW (allows SSH, allows `virbr0` traffic) and enables it; enables `geoclue`, `ananicy-cpp`, `fstrim.timer`, `bluetooth` (with autosuspend disabled), and `libvirtd`; defines/starts/autostarts the default `libvirt` network; imports default `virt-manager` `dconf` preferences; adds the current user to the `libvirt`/`kvm` groups.
- **System Tuning**: Shortens systemd's default stop/start timeouts to 3s, disables `NetworkManager-wait-online.service`, and vacuums the journal to 2 days.
- **Shell Setup**: If `zsh` is available, sets it as the default shell, installs Oh My Zsh (unattended) and the Powerlevel10k theme, and updates `~/.zshrc` (theme, plugins, locale exports, `fastfetch` on login, syntax-highlighting/autosuggestions sourcing).
- **Dotfiles & Config Copy**: Copies an optional `.update.sh` helper script plus `.local`/`.config` directories from the script folder into the user's home directory.
- **Progress Bar & Logging**: Displays a live progress bar across 3 phases / 12 steps. On failure, a detailed log is saved to `~/install_error_<timestamp>.log`.
- **Optional Reboot Prompt**: Unlike a silent forced reboot, this script asks **"Do you want to restart the system now? [Y/N]"** at the end.

---

## 🔍 Module Details

### 1. Permissions, GPU Detection & Cleanup
Verifies the script is **not** run as root, grants temporary `NOPASSWD` sudo, detects GPU vendor(s) via `lspci`, installs matching 32-bit driver packages, copies dotfiles, and removes the pre-defined bloatware package list along with related config/cache.

### 2. Pacman & Network Tuning
Adjusts `/etc/pacman.conf` (color, parallel downloads, `NoExtract` rules), installs `cups`, and configures Cloudflare DNS both system-wide (NetworkManager `conf.d`) and on the active connection.

### 3. Package Installation
Runs a full `pacman -Syu`, then installs the curated system package set (validating each package exists via `pacman -Si` before attempting install), sets up Flatpak/Flathub, bootstraps `yay`, and installs the AUR package list.

### 4. Boot Splash & Bootloader Configuration
Detects every present bootloader mechanism and patches its config to set a 0-second timeout and add the silent-splash kernel command line, handling `systemd-boot` entries, `GRUB`'s `grub-mkconfig`, `Limine`'s `.conf`/`.cfg` files (including syncing between ESP/boot copies), `rEFInd`'s main config and per-kernel `refind_linux.conf`, and raw EFISTUB boot entries via `efibootmgr`. Also updates `mkinitcpio.conf` hooks/modules and rebuilds the initramfs.

### 5. Services, Firewall & Virtualization
Enables UFW with SSH and `virbr0` rules, enables `geoclue`/`ananicy-cpp`/`fstrim.timer`/`bluetooth`/`libvirtd`, sets up the default `libvirt` NAT network, and imports default `virt-manager` GUI preferences via `dconf load`.

### 6. Shell & Finalization
Sets up Zsh + Oh My Zsh + Powerlevel10k (if `zsh` is present), removes the temporary sudo/polkit rule, and prompts the user to reboot immediately or exit without rebooting.

---

## 🛠️ How to Use

1. Clone the repository to your disk
   ```bash
   git clone https://gitlab.com/syscore88/arch-config.git
   ```

2. Navigate to the folder
   ```bash
   cd arch-config
   ```

3. Make the script executable
   ```bash
   chmod +x install.sh
   ```

4. Run the script (without `sudo`!)
   ```bash
   ./install.sh
   ```

5. Running inside a chroot
   ```bash
   sudo -u username ./install.sh
   
---

### ☕ Support the Project

If you find this tool helpful and it saved you some time, consider buying me a coffee to support further development! 

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/bartekszczecinski)

---

## ⚠️ Requirements & Notes

- A base **Arch Linux** installation with `pacman` and an internet connection (packages are installed from official repos, Flathub, and the AUR).
- `sudo` access for the current user.
- The following optional files, placed alongside `install.sh`, are picked up automatically if present: `.update.sh`, `.local/`, `.config/`.
- The script **installs a large number of packages** (development, multimedia, gaming, and full KVM/QEMU virtualization stacks) — review `SYSTEM_PKGS` and `AUR_PKGS` before running if you want a lighter setup.
- Boot splash configuration modifies bootloader configs and kernel command lines directly; a working bootloader setup is assumed to already be in place before running the script.
- On failure, check the generated `install_error_<timestamp>.log` file in your home directory for details.
