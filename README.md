# Kano Audio Fix

Fixes the SOF (Sound Open Firmware) DSP crash loop on **Google Kano** Chromebooks running mainline Linux.

## Problem

On Google Kano (Raptor Lake, board name "Kano"), the SOF audio driver creates DMIC (digital microphone) PCM devices from the topology file. The BIOS does not provide an NHLT table, so the DSP has no routing information for the DMICs. When PipeWire's ACP (ALSA Card Profile) plugin probes the DMIC16kHz PCM device (`hw:0,100`) during device enumeration, the DSP rejects the stream parameters with IPC error -22, enters a wedged state, and all audio stops working.

**Symptoms:**
- Volume meters move but no sound output
- `dmesg` shows repeated `sof-audio-pci-intel-tgl: ipc tx error for 0x60010000`
- `dmesg` shows `NHLT table not found` and `DMICs detected in NHLT tables: 0`
- PipeWire logs `spa.alsa: snd_pcm_avail after recover: Broken pipe` on the speaker PCM
- Browser pages and video players freeze when attempting playback
- Audio stack appears to "power cycle" repeatedly
- Intermittently: brief bursts of audio between DSP crashes

## Hardware

- **Device**: Google Kano (Chromebook)
- **CPU**: Intel Raptor Lake P
- **Audio**: max98373 smart amplifiers (×2 stereo) + nau8825 headset codec on SoundWire/I2S, DMIC array, HDMI via i915
- **SOF topology**: `sof-rpl-max98373-nau8825.tplg` (symlink → `sof-adl-max98373-nau8825.tplg`)
- **Firmware**: `sof-rpl.ri` (symlink → `sof-tgl.ri`)
- **Tested on**: CachyOS (Arch-based), Linux 7.1.2-3-cachyos, PipeWire 1.6.7, WirePlumber 0.5.x

## Root Cause

Three interacting issues:

### 1. Missing NHLT table

The Chromebook BIOS does not provide a Non-HD Audio Link Table, so SOF cannot auto-detect DMIC routing or endpoint count. Without NHLT, the DSP has no information about how the DMIC array is physically connected.

### 2. Topology/DMIC mismatch

The SOF topology file (`sof-rpl-max98373-nau8825.tplg`) includes DMIC widgets (DMIC0, DMIC1, DMIC16kHz). The DSP tries to configure these widgets using the topology parameters, but without NHLT data, the hardware routing is incorrect. When any process opens the DMIC PCM, the DSP rejects the stream configuration with `-EINVAL` (IPC error -22).

### 3. PipeWire ACP probing

PipeWire's ALSA Card Profile (ACP) plugin, driven by WirePlumber's ALSA monitor, enumerates ALL PCM devices on the sound card during startup. It opens `hw:0,100` (DMIC16kHz) to query its capabilities. The DSP crashes. At cold boot, this crash is severe enough to also break the speaker and headset pipelines, triggering a full card re-enumeration. The re-enumeration probes the DMIC again, creating an infinite crash loop.

**Why runtime restarts sometimes work but cold boot doesn't:** At cold boot, all PCM pipelines are being initialized for the first time. The DMIC crash corrupts DSP state broadly enough to break the speaker/headset initialization. PipeWire/WirePlumber detect the speaker failure and restart, re-probing everything including the DMIC. At runtime restart, the speaker and headset pipelines are already configured and cached — the DMIC crash is isolated enough that the DSP recovers before it affects other pipelines.

## The Fix

Three components, applied together:

### Component 1: Kernel parameter — `dmic_num=0`

`/etc/default/limine` (or kernel cmdline): `snd_sof_intel_hda_generic.dmic_num=0`

This tells the SOF driver not to expose DMIC PCM devices to userspace. It partially hides them from `arecord -l` but does **not** remove them from `/proc/asound/`. This parameter alone is insufficient because PipeWire's ACP plugin accesses PCM devices through the ALSA card's internal device list, not through the user-facing device enumeration.

### Component 2: UCM profile override — `dmic.conf`

`/etc/alsa/ucm2/sof-soundwire/dmic.conf` — redirects the DMIC capture device to `hw:0,999` (a non-existent device).

This is the critical fix. PipeWire's ACP plugin reads the UCM (Use Case Manager) profile to discover which PCM devices to probe. The chromebook-linux-audio project installs a UCM profile at `/usr/share/alsa/ucm2/sof-soundwire/dmic.conf` that maps the DMIC. By overriding it to point to device 999, the ACP plugin gets a clean "no such device" error instead of opening the real DMIC and crashing the DSP.

### Component 3: WirePlumber disable rule (belt and suspenders)

`/etc/wireplumber/wireplumber.conf.d/51-disable-dmic.conf` — sets `node.disabled = true` on any ALSA nodes matching DMIC device numbers 99 or 100.

If the UCM override doesn't catch every probe path, this rule prevents WirePlumber from creating audio nodes for the DMIC devices. The crash occurs before node creation (at the SPA/ACP level), so this rule alone doesn't fix the problem — but it prevents any DMIC nodes from appearing in the audio UI.

## Installation

```bash
git clone https://github.com/maxugly/kano-audio-fix
cd kano-audio-fix
sudo bash install.sh
sudo reboot
```

After reboot, verify:

```bash
paplay /usr/share/sounds/alsa/Front_Center.wav
```

Check that no DMIC crashes appear in dmesg:

```bash
sudo dmesg | grep -i pcm100   # should return nothing
```

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Copies all config files, updates bootloader, rebuilds initramfs |
| `dmic-override.conf` | UCM profile override — redirects DMIC to non-existent device 999 |
| `51-disable-dmic.conf` | WirePlumber rule — disables DMIC audio nodes |
| `51-hide-dmic.rules` | Udev rule — sets SOUND_IGNORE on DMIC PCM devices (belt and suspenders) |
| `asound.conf` | ALSA null device config — redirects DMIC PCMs to null (runtime fallback) |

## What You Lose

- **DMIC (built-in digital microphone array)**: Will not work. If you need microphone input, use a USB or Bluetooth headset.
- **Voice input daemons**: Any daemon using `plughw:0,99` or `hw:0,100` will fail silently.

## What Still Works

- **Speakers**: max98373 stereo speakers
- **Headset output**: nau8825 headset jack
- **HDMI audio**: All HDMI/DisplayPort outputs
- **Bluetooth audio**: A2DP playback
- **Headset microphone**: The nau8825 codec's mic input via the 3.5mm jack (untested but expected to work)

## What We Tried (And Why It Failed)

This section documents the full debugging journey across 12+ reboots and 6 hours of investigation. It's here so the next person doesn't repeat our mistakes.

### Attempt 1: Legacy HDA driver (`dsp_driver=1`)

Wrote `/etc/modprobe.d/snd-fix.conf` with `options snd-intel-dspcfg dsp_driver=1`.

**Result:** No sound card. **Why:** The max98373 speakers and nau8825 headset are on SoundWire/I2S, not the HDA bus. The legacy HDA driver only handles HDA-attached codecs (HDMI). This file was accidentally left in place through 6 subsequent attempts, silently overriding all kernel command line changes and making us think we were testing SOF parameters when we were actually just running legacy HDA over and over.

### Attempt 2: AVS driver (`dsp_driver=4`)

Added `snd_intel_dspcfg.dsp_driver=4` to kernel command line.

**Result:** "Dummy output." **Why:** The AVS driver needs firmware at `intel/avs/adl/dsp_basefw.bin` which is not packaged for CachyOS. Firmware load fails, driver bails out.

### Attempt 3: Runtime PM fix

`echo on > /sys/bus/pci/devices/0000:00:1f.3/power/control` to disable audio DSP power management.

**Result:** No change. **Why:** The DSP wasn't asleep — it was actively wedged from the DMIC probe crash.

### Attempt 4: SOF with DMIC disabled (`dsp_driver=2 + dmic_num=0`)

Added both to kernel command line.

**Result:** No sound card. **Why:** `dsp_driver=2` on this kernel prevents the machine driver (`snd_soc_sof_nau8825`) from binding. But also: the modprobe.d file from Attempt 1 was still active, so we were actually running legacy HDA the whole time.

### Attempt 5: AVS vs SOF turf war discovery

Tried `dsp_driver=2` with AVS blacklisted. Discovered that even with `dsp_driver=2`, `snd_soc_avs` binds to the audio PCI device first, fails to load firmware, and blocks SOF.

**Fix:** Blacklisted `snd_soc_avs` in modprobe.d. But the modprobe.d from Attempt 1 still overrode everything to legacy HDA.

### Attempt 6: No params, AVS blacklist only

Clean kernel cmdline, `blacklist snd_soc_avs` in modprobe.d.

**Result:** Legacy HDA loaded (HDMI-only). **Why:** Without `dsp_driver=2`, auto-detection picked HDA over SOF. And the Attempt 1 file was still there forcing `dsp_driver=1` anyway.

### Attempt 7: The snd-fix.conf discovery

Found `/etc/modprobe.d/snd-fix.conf` from Attempt 1 still in place, forcing `dsp_driver=1` through every test. Deleted it.

**Result:** SOF finally loaded. `sof-nau8825` card appeared. But back to the original broken pipe + DMIC crash loop.

**Lesson:** Modprobe.d configs override kernel command line for module parameters. Always clean up test files.

### Attempt 8: DMIC module blacklist (`modprobe.blacklist=snd_soc_dmic`)

**Result:** No sound card. **Why:** The topology file requires DMIC widgets (`snd_soc_dmic`) to parse. Without it, topology loading fails, and no sound card is created.

### Attempt 9: `dmic_num=0` with SOF actually running

Finally tested `dmic_num=0` with real SOF. DMIC devices disappeared from `arecord -l` but pcm100 still existed in `/proc/asound/` and was still probed through the UCM/ACP path.

### Attempt 10: ALSA null device (`asound.conf`)

Created `/etc/asound.conf` with null device overrides for pcm99 and pcm100. Worked at runtime (restart wireplumber → DSP recovered after one crash) but failed at cold boot because PipeWire's ACP plugin opens devices through the UCM path, bypassing alsa-lib's PCM routing.

### Attempt 11: WirePlumber node.disabled rule

Created `/etc/wireplumber/wireplumber.conf.d/51-disable-dmic.conf` to disable DMIC nodes. Reduced crashes from infinite loop to ~3 bursts, then stable.

**Why partially effective:** WirePlumber's rules only prevent node CREATION, not device PROBING. The ACP plugin probes the DMIC during enumeration (before node creation), so the crash still happens — but with fewer nodes to error-handle, the DSP recovers faster.

### Attempt 12: Udev SOUND_IGNORE

Created `/etc/udev/rules.d/51-hide-dmic.rules` setting `SOUND_IGNORE=1` on pcmC0D99c and pcmC0D100c.

**Result:** No effect. **Why:** PipeWire's ACP plugin opens devices through the sound card's file descriptor, not through `/dev/snd/` nodes. The udev flag isn't checked at this level.

### Attempt 13: Permissions lockout

`chmod 000` on `/dev/snd/pcmC0D99c` and `/dev/snd/pcmC0D100c`.

**Result:** No effect. Same reason as above — the ACP plugin uses the card FD, not the device nodes.

### Attempt 14 (THE FIX): UCM profile override

Created `/etc/alsa/ucm2/sof-soundwire/dmic.conf` redirecting DMIC to `hw:0,999`.

**Result:** Complete fix. PipeWire's ACP plugin reads the UCM profile, sees DMIC mapped to device 999, tries to open it, gets "no such device," and moves on. The real DMIC (devices 99, 100) is never touched. No DSP crash. Stable audio.

**Why this works when nothing else did:** The ACP plugin's device enumeration is driven entirely by the UCM profile. It doesn't blindly probe all PCM devices — it only probes what the UCM tells it to. By replacing the DMIC entry with a dead-end device number, we prevent the DSP crash at its source: the ALSA device open call.

## Related Projects

- [chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) — Prerequisite: run this first to install SOF firmware symlinks and UCM profiles
- [WirePlumber](https://pipewire.pages.freedesktop.org/wireplumber/) — Session manager documentation
- [SOF Project](https://thesofproject.github.io/latest/index.html) — Sound Open Firmware documentation

## License

MIT
