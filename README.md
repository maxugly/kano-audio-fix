# Kano Audio Fix

Fixes the SOF (Sound Open Firmware) DSP crash loop on **Google Kano** Chromebooks running mainline Linux.

## Problem

On Google Kano (Raptor Lake, board name "Kano"), the SOF audio driver creates DMIC (digital microphone) PCM devices from the topology file. The BIOS does not provide an NHLT table, so the DSP has no routing information for the DMICs. When PipeWire probes the DMIC16kHz PCM device (`hw:0,100`), the DSP rejects the stream parameters with IPC error -22, enters a wedged state, and all audio stops working.

**Symptoms:**
- Volume meters move but no sound output
- `dmesg` shows repeated `sof-audio-pci-intel-tgl: ipc tx error for 0x60010000`
- `dmesg` shows `NHLT table not found` and `DMICs detected in NHLT tables: 0`
- PipeWire logs `spa.alsa: snd_pcm_avail after recover: Broken pipe`
- Browser pages and video players freeze when attempting playback
- PipeWire/audio stack appears to "power cycle" repeatedly

## Hardware

- **Device**: Google Kano (Chromebook)
- **CPU**: Intel Raptor Lake P
- **Audio**: max98373 smart amplifiers (×2 stereo) + nau8825 headset codec on SoundWire/I2S, DMIC array, HDMI via i915
- **SOF topology**: `sof-rpl-max98373-nau8825.tplg` (symlink → `sof-adl-max98373-nau8825.tplg`)
- **Tested on**: CachyOS (Arch-based), Linux 7.1.2-3-cachyos, PipeWire 1.6.7

## Root Cause

Three interacting issues:

1. **Missing NHLT table**: The Chromebook BIOS does not provide a Non-HD Audio Link Table, so SOF cannot auto-detect DMIC routing or endpoint count.

2. **Topology/DMIC mismatch**: The SOF topology file includes DMIC widgets (DMIC0, DMIC1, DMIC16kHz) that the DSP cannot configure without NHLT data. When any userspace process opens the DMIC PCM, the DSP rejects the stream configuration with `-EINVAL`.

3. **PipeWire auto-probing**: PipeWire probes all ALSA PCM devices at startup. It opens `hw:0,100` (DMIC16kHz), the DSP crashes, and PipeWire restarts — creating an infinite crash loop that takes down all audio.

## Fix

Two-part fix:

### Part 1: Kernel parameter

Adds `snd_sof_intel_hda_generic.dmic_num=0` to the kernel command line. This tells the SOF driver not to expose DMIC PCM devices to userspace, partially hiding them from ALSA device listings.

### Part 2: ALSA null device

Creates `/etc/asound.conf` with null device overrides for the DMIC PCMs. This catches any remaining path where PipeWire might access the DMIC through the topology, redirecting the probe to a no-op null device instead of touching the DSP.

### Part 3: AVS conflict prevention

The AVS driver (`snd_soc_avs`) competes with SOF for the audio DSP on this hardware. It loads, fails to find firmware (`intel/avs/adl/dsp_basefw.bin` is not packaged), and can prevent SOF from binding. Not currently part of the fix script, but documented here.

## Installation

```bash
git clone https://github.com/YOUR_USER/kano-audio-fix
cd kano-audio-fix
sudo bash install.sh
sudo reboot
```

After reboot, verify:

```bash
paplay /usr/share/sounds/alsa/Front_Center.wav
```

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Copies config files and rebuilds initramfs |
| `asound.conf` | ALSA null device overrides for DMIC PCMs |
| `limine.conf` | Bootloader config snippet with `dmic_num=0` (Limine bootloader) |

## What You Lose

- **DMIC (digital microphone array)**: The built-in microphones will not work. If you need microphone input, use a USB or Bluetooth headset.
- **Internal microphone via headset jack**: The nau8825 headset codec microphone input should still work (untested).

## What Still Works

- **Speakers**: max98373 stereo speakers work normally
- **Headset output**: nau8825 headset jack works normally
- **HDMI audio**: HDMI/DisplayPort audio works normally
- **Bluetooth audio**: Bluetooth A2DP works normally
- **Voice input daemon**: If you use `voice-inputd` or similar, point it at a USB mic or disable it — DMIC is unavailable

## What Didn't Work

During debugging, these approaches were tested and ruled out:

| Approach | Result |
|----------|--------|
| Legacy HDA driver (`dsp_driver=1`) | No SoundWire/I2S support — speakers and headset are on SoundWire, only HDMI works |
| AVS driver (`dsp_driver=4`) | No firmware available for Raptor Lake; fails to boot |
| Force SOF (`dsp_driver=2`) | Prevents machine driver (`snd_soc_sof_nau8825`) from binding |
| Runtime PM disable | DSP is actively wedged, not sleeping |
| Blacklist `snd_soc_dmic` module | Topology file requires DMIC widgets to parse; topology load fails entirely |
| `dmic_num=0` alone | Partially hides DMIC from `arecord -l` but pcm100 still exists in `/proc/asound` and is probed through the topology path |
| SoundWire clock stop quirk | Untested |

## Related Projects

- [chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) — Prerequisite: run this first to install SOF firmware symlinks and UCM profiles
- [SOF Project](https://thesofproject.github.io/latest/index.html) — Sound Open Firmware documentation

## License

MIT
