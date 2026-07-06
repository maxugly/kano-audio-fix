#!/bin/bash
# install.sh — Kano Audio Fix
# Fixes SOF DSP crash loop on Google Kano Chromebooks by neutering DMIC PCM probes.
# Run as root.

set -e

echo "=== Kano Audio Fix Installer ==="
echo ""

# Detect bootloader
if [ -f /etc/default/limine ]; then
    BOOTLOADER="limine"
elif [ -f /etc/default/grub ]; then
    BOOTLOADER="grub"
elif [ -f /etc/kernel/cmdline ]; then
    BOOTLOADER="cmdline"
else
    echo "WARNING: Unknown bootloader. You may need to add kernel param manually:"
    echo "  snd_sof_intel_hda_generic.dmic_num=0"
    echo ""
    BOOTLOADER="unknown"
fi

echo "Detected bootloader: ${BOOTLOADER}"

# Install ALSA null device config
echo "Installing /etc/asound.conf..."
cp asound.conf /etc/asound.conf

# Install kernel parameter based on bootloader
case "${BOOTLOADER}" in
    limine)
        echo "Updating /etc/default/limine..."
        # Append dmic_num=0 if not already present
        if ! grep -q "dmic_num=0" /etc/default/limine 2>/dev/null; then
            # Add to the KERNEL_CMDLINE line
            sed -i 's/KERNEL_CMDLINE\[default\]+="\(.*\)"/KERNEL_CMDLINE[default]+="\1 snd_sof_intel_hda_generic.dmic_num=0"/' /etc/default/limine
        fi
        ;;
    grub)
        echo "Updating /etc/default/grub..."
        if ! grep -q "dmic_num=0" /etc/default/grub 2>/dev/null; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 snd_sof_intel_hda_generic.dmic_num=0"/' /etc/default/grub
        fi
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    cmdline)
        echo "Updating /etc/kernel/cmdline..."
        if ! grep -q "dmic_num=0" /etc/kernel/cmdline 2>/dev/null; then
            echo " snd_sof_intel_hda_generic.dmic_num=0" >> /etc/kernel/cmdline
        fi
        ;;
    *)
        echo "Add this to your kernel command line: snd_sof_intel_hda_generic.dmic_num=0"
        ;;
esac

# Rebuild initramfs
echo "Rebuilding initramfs..."
if command -v mkinitcpio &>/dev/null; then
    mkinitcpio -P
elif command -v dracut &>/dev/null; then
    dracut --force --regenerate-all
else
    echo "WARNING: Could not find mkinitcpio or dracut. You may need to rebuild initramfs manually."
fi

echo ""
echo "=== Installation complete ==="
echo "Reboot to apply: sudo reboot"
echo "After reboot, verify with: paplay /usr/share/sounds/alsa/Front_Center.wav"
