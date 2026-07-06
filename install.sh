#!/bin/bash
# install.sh — Kano Audio Fix
# Full fix for SOF DSP crash loop on Google Kano Chromebooks.
# Three components that work together:
#   1. WirePlumber alsa.lua patch (stops destructive profile cycling)
#   2. suspend-timeout=0 (keeps DSP warm — prevents hard crashes)
#   3. DMIC device node removal (stops userspace ALSA probes)
# Plus belt-and-suspenders:
#   4. dmic_num=0 kernel param (hides DMIC from arecord)
#   5. UCM profile override (redirects DMIC in UCM-based probing)
#   6. udev rule (SOUND_IGNORE for DMIC PCM devices)
# Run as root.

set -e

echo "=== Kano Audio Fix Installer ==="
echo ""

DID_ANYTHING=0

# ---- [1/6] WirePlumber alsa.lua patch ----
echo "[1/6] Patching WirePlumber ALSA monitor..."
ALSA_LUA="/usr/share/wireplumber/scripts/monitors/alsa.lua"
if [ -f "$ALSA_LUA" ]; then
    if ! grep -q "not cycling profile" "$ALSA_LUA" 2>/dev/null; then
        # Backup original
        cp "$ALSA_LUA" "${ALSA_LUA}.kano-backup"
        # Apply patch using sed
        # This removes the Off/restore profile cycling in monitorNodeError
        sed -i '/-- Close the ALSA device by setting the profile to Off/,/end)/{
            /-- Close the ALSA device by setting the profile to Off/{
                i\      -- PATCHED by kano-audio-fix: do not cycle profile on error
                i\      log:info (string.format(
                i\          "ALSA node %s on device %s error -- NOT cycling profile",
                i\          node_name, dev_name))
            }
            d
        }' "$ALSA_LUA"
        echo "       Patched $ALSA_LUA"
        echo "       Backup saved to ${ALSA_LUA}.kano-backup"
        DID_ANYTHING=1
    else
        echo "       Already patched"
    fi
else
    echo "       WARNING: $ALSA_LUA not found — is wireplumber installed?"
fi

# ---- [2/6] suspend-timeout = 0 ----
echo "[2/6] Setting suspend-timeout=0 (keeps DSP warm)..."
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/99-kano-no-suspend.conf << 'PWCONF'
# Kano audio fix: never suspend ALSA nodes
# Keeps the SOF DSP active, preventing hard crashes when DMIC is probed
context.properties = {
    # default is 5 seconds; 0 = never suspend
    mem.allow-suspend = false
}
context.modules = [
    {   name = libpipewire-module-session-manager
        args = {
            suspend-timeout = 0
        }
    }
]
PWCONF
echo "       Installed /etc/pipewire/pipewire.conf.d/99-kano-no-suspend.conf"
DID_ANYTHING=1

# ---- [3/6] DMIC device node removal ----
echo "[3/6] Installing udev rule to remove DMIC device nodes..."
cat > /etc/udev/rules.d/51-kano-hide-dmic.rules << 'UDEV'
# Kano audio fix: remove DMIC PCM device nodes
# Prevents userspace ALSA apps (DaVinci, etc.) from opening DMIC directly
# Note: PipeWire's ACP plugin bypasses /dev/snd, so this alone is insufficient
SUBSYSTEM=="sound", KERNEL=="pcmC0D99c", ACTION=="add", RUN+="/usr/bin/rm -f /dev/snd/pcmC0D99c"
SUBSYSTEM=="sound", KERNEL=="pcmC0D100c", ACTION=="add", RUN+="/usr/bin/rm -f /dev/snd/pcmC0D100c"

# Also set SOUND_IGNORE as belt-and-suspenders
SUBSYSTEM=="sound", KERNEL=="pcmC0D99c", ENV{SOUND_IGNORE}="1"
SUBSYSTEM=="sound", KERNEL=="pcmC0D100c", ENV{SOUND_IGNORE}="1"
UDEV
udevadm control --reload-rules 2>/dev/null || true
echo "       Installed /etc/udev/rules.d/51-kano-hide-dmic.rules"
DID_ANYTHING=1

# ---- [4/6] UCM profile override ----
echo "[4/6] Installing UCM DMIC override..."
mkdir -p /etc/alsa/ucm2/sof-soundwire
cat > /etc/alsa/ucm2/sof-soundwire/dmic.conf << 'UCM'
# Override: disable DMIC to prevent SOF DSP crash on Google Kano
SectionDevice."Mic" {
	Comment "Digital Microphone (DISABLED — crashes DSP)"
	Value {
		CapturePriority 0
		CapturePCM "hw:${CardId},999"
	}
}
UCM
echo "       Installed /etc/alsa/ucm2/sof-soundwire/dmic.conf"
DID_ANYTHING=1

# ---- [5/6] WirePlumber node.disabled rule ----
echo "[5/6] Installing WirePlumber DMIC disable rule..."
mkdir -p /etc/wireplumber/wireplumber.conf.d
cat > /etc/wireplumber/wireplumber.conf.d/51-kano-disable-dmic.conf << 'WP'
# Kano audio fix: disable DMIC ALSA nodes
monitor.alsa.rules = [
  {
    matches = [
      { device.profile.name = "pro-input-99" }
    ]
    actions = { update-props = { node.disabled = true } }
  },
  {
    matches = [
      { device.profile.name = "pro-input-100" }
    ]
    actions = { update-props = { node.disabled = true } }
  }
]
WP
echo "       Installed /etc/wireplumber/wireplumber.conf.d/51-kano-disable-dmic.conf"
DID_ANYTHING=1

# ---- [6/6] Kernel parameter ----
echo "[6/6] Adding kernel parameter dmic_num=0..."
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

# ---- Remove DMIC nodes immediately ----
rm -f /dev/snd/pcmC0D99c /dev/snd/pcmC0D100c 2>/dev/null || true

echo ""
echo "=== Installation complete ==="
echo "Three components installed:"
echo "  1. WirePlumber patch — stops profile cycling on DMIC errors"
echo "  2. suspend-timeout=0 — keeps DSP warm, prevents hard crashes"
echo "  3. DMIC device node removal — stops userspace ALSA probes"
echo ""
echo "Reboot: sudo reboot"
echo "Verify: paplay /usr/share/sounds/alsa/Front_Center.wav"
echo "        sudo dmesg | grep pcm100  # may show one crash at boot, then stable"
