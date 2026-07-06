#!/bin/bash
# install.sh — Kano Audio Fix
# Fixes SOF DSP crash loop on Google Kano Chromebooks.
# Three components:
#   1. dmic_num=0 kernel param (partial — hides DMIC from arecord)
#   2. UCM profile override (THE FIX — redirects DMIC to dead device)
#   3. WirePlumber disable rule (belt and suspenders)
# Run as root.

set -e

echo "=== Kano Audio Fix Installer ==="
echo ""

DID_ANYTHING=0

# ---- UCM profile override (critical fix) ----
echo "[1/4] Installing UCM DMIC override..."
mkdir -p /etc/alsa/ucm2/sof-soundwire
cp dmic-override.conf /etc/alsa/ucm2/sof-soundwire/dmic.conf
echo "       /etc/alsa/ucm2/sof-soundwire/dmic.conf"
DID_ANYTHING=1

# ---- WirePlumber disable rule ----
echo "[2/4] Installing WirePlumber disable rule..."
mkdir -p /etc/wireplumber/wireplumber.conf.d
cp 51-disable-dmic.conf /etc/wireplumber/wireplumber.conf.d/51-disable-dmic.conf
echo "       /etc/wireplumber/wireplumber.conf.d/51-disable-dmic.conf"
DID_ANYTHING=1

# ---- udev SOUND_IGNORE rule (belt and suspenders) ----
echo "[3/4] Installing udev SOUND_IGNORE rule..."
cp 51-hide-dmic.rules /etc/udev/rules.d/51-hide-dmic.rules
udevadm control --reload-rules 2>/dev/null || true
echo "       /etc/udev/rules.d/51-hide-dmic.rules"
DID_ANYTHING=1

# ---- Kernel parameter (bootloader-dependent) ----
echo "[4/4] Adding kernel parameter dmic_num=0..."
KPARAM="snd_sof_intel_hda_generic.dmic_num=0"

if [ -f /etc/default/limine ] && grep -q "KERNEL_CMDLINE" /etc/default/limine; then
    if ! grep -q "dmic_num=0" /etc/default/limine 2>/dev/null; then
        sed -i "s/KERNEL_CMDLINE\[default\]+=\"\(.*\)\"/KERNEL_CMDLINE[default]+=\"\1 ${KPARAM}\"/" /etc/default/limine
        echo "       Updated /etc/default/limine"
        DID_ANYTHING=1
    else
        echo "       Already present in /etc/default/limine"
    fi
    REBUILD=1
elif [ -f /etc/default/grub ] && grep -q "GRUB_CMDLINE_LINUX" /etc/default/grub; then
    if ! grep -q "dmic_num=0" /etc/default/grub 2>/dev/null; then
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${KPARAM}\"/" /etc/default/grub
        echo "       Updated /etc/default/grub"
        DID_ANYTHING=1
    else
        echo "       Already present in /etc/default/grub"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    REBUILD=0
elif [ -f /etc/kernel/cmdline ]; then
    if ! grep -q "dmic_num=0" /etc/kernel/cmdline 2>/dev/null; then
        echo " ${KPARAM}" >> /etc/kernel/cmdline
        echo "       Updated /etc/kernel/cmdline"
        DID_ANYTHING=1
    else
        echo "       Already present in /etc/kernel/cmdline"
    fi
    REBUILD=1
else
    echo "       WARNING: Unknown bootloader. Add manually: ${KPARAM}"
    REBUILD=0
fi

# ---- Rebuild initramfs ----
if [ "${REBUILD}" = "1" ]; then
    echo ""
    echo "Rebuilding initramfs..."
    if command -v mkinitcpio &>/dev/null; then
        mkinitcpio -P
    elif command -v dracut &>/dev/null; then
        dracut --force --regenerate-all
    fi
fi

echo ""
echo "=== Installation complete ==="
echo "Reboot: sudo reboot"
echo "Verify: paplay /usr/share/sounds/alsa/Front_Center.wav"
echo "        sudo dmesg | grep pcm100  # should be empty"
