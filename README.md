# Kano Audio Fix

Complete fix for the SOF (Sound Open Firmware) DSP crash loop on **Google Kano** Chromebooks running mainline Linux. Stops the audio stack from crashing and makes DaVinci Resolve, pavucontrol, and all other applications work.

## The Problem

On Google Kano (Raptor Lake), the SOF topology includes DMIC (digital microphone) PCM devices, but the BIOS doesn't provide an NHLT table (`NHLT table not found`). The DSP can't route the DMIC stream. When PipeWire's ACP plugin probes `hw:0,100` (DMIC16kHz), the DSP crashes with `IPC error -22 (EINVAL)`.

**Three cascading failures make this catastrophic:**

1. **The DMIC probe crashes the DSP globally** — not just the microphone, but speakers, headset, HDMI, everything
2. **WirePlumber amplifies the crash** — its error recovery cycles the card profile (Off → On), re-probing the DMIC and creating an infinite loop
3. **The DSP crash is worse when idle** — if no audio is playing, the DMIC probe causes a "hard" crash that takes 15-30 seconds to recover from. When audio is actively flowing, the crash is "soft" and the DSP recovers instantly

## The Fix (Three Components)

### 1. WirePlumber ALSA Monitor Patch

Patches `/usr/share/wireplumber/scripts/monitors/alsa.lua` to remove the destructive profile cycling in `monitorNodeError()`. Instead of setting the card to "Off" and back (which kills all audio), it simply logs the error. This breaks the infinite crash loop.

### 2. PipeWire Suspend Timeout = 0

Sets `suspend-timeout = 0` so PipeWire never suspends ALSA nodes. The DSP stays in an active power state. DMIC probes cause "soft" crashes that recover instantly instead of "hard" crashes that wedge the DSP for 30 seconds.

### 3. DMIC Device Node Removal

Udev rule removes `/dev/snd/pcmC0D99c` and `/dev/snd/pcmC0D100c` so userspace ALSA applications (DaVinci Resolve, mpv with ALSA backend) can't open the DMIC directly. Combined with the warm DSP from fix #2, any remaining probe paths cause transient, harmless errors.

### Belt-and-Suspenders (included but not strictly necessary)

- **`dmic_num=0`** kernel parameter: Partially hides DMIC from `arecord -l`
- **UCM profile override**: Redirects DMIC to non-existent device 999
- **WirePlumber node.disabled rule**: Prevents DMIC from appearing as PulseAudio sources
- **udev SOUND_IGNORE**: Tags DMIC PCM devices as ignored

## Installation

```bash
git clone https://github.com/maxugly/kano-audio-fix
cd kano-audio-fix
sudo bash install.sh
sudo reboot
```

## Verification

```bash
# Audio playback works
paplay /usr/share/sounds/alsa/Front_Center.wav

# DMIC may crash once at boot, then never again
sudo dmesg | grep pcm100
```

## What You Lose

- **Built-in DMIC array**: Digital microphones will not work. Use USB or Bluetooth for mic input.
- **Headset microphone (nau8825)**: Should still work.

## Key Discoveries

### YouTube Fixes Everything

Early in debugging, we found that playing a YouTube video made all audio problems disappear. This was the crucial clue: **the DSP is fragile when idle.** When PipeWire suspends ALSA nodes (default: after 5 seconds of silence), the DSP enters a low-power state. DMIC probes during this state cause severe crashes. When audio flows, the DSP stays active and DMIC probes are harmless.

### DaVinci Resolve: The ALSA Direct Path

DaVinci appears in pavucontrol as `Pipewire [ALSA]:Resolve` — it uses PipeWire's ALSA plugin directly, not PulseAudio. Its Fairlight engine calls `snd_device_name_hint()` during startup, which opens every ALSA device including `hw:0,100` (DMIC16kHz). This is what was crashing the DSP and locking DaVinci's audio output.

### WirePlumber's Error Recovery Kills Everything

WirePlumber's `monitorNodeError()` function was designed to recover from transient USB/HDMI errors by cycling the card profile. On Chromebooks with unreliable DSPs, this created a self-sustaining crash loop. Every cycle also caused dangerous loud pops through the max98373 amplifiers.

## What We Tried (Full Debugging History)

### Attempts That Failed

| # | Attempt | Result | Why |
|---|---------|--------|-----|
| 1 | Legacy HDA (`dsp_driver=1`) | No sound card | Speakers on SoundWire, not HDA |
| 2 | AVS driver (`dsp_driver=4`) | Dummy output | No AVS firmware for Raptor Lake |
| 3 | Runtime PM disable | No effect | DSP isn't asleep — it's crashed |
| 4 | SOF + dmic_num=0 | Same crashes | pcm100 still in /proc/asound |
| 5 | AVS blacklist (`modprobe.blacklist`) | HDA loaded instead | AVS was stealing device |
| 6 | Clean boot (after removing leftover modprobe.d) | SOF loaded, DSP crashed | Back to square one |
| 7 | DMIC codec blacklist (`snd_soc_dmic`) | No sound card | Topology fails without DMIC widgets |
| 8 | `dmic_num=0` with actual SOF | pcm100 still crashes | Doesn't remove from topology |
| 9 | `asound.conf` null device | Works at runtime, fails at boot | ACP bypasses alsa-lib routing |
| 10 | WirePlumber `node.disabled` rule | Still crashes | Crash before node creation |
| 11 | udev `SOUND_IGNORE` rule | No effect | ACP doesn't check udev |
| 12 | `/dev/snd` node removal | Userspace stopped, ACP still probes | ACP uses card FD |
| 13 | `disable_function_topology=1` | No effect | Doesn't remove DMIC |
| 14 | LTS kernel (6.18) | Same behavior | Same firmware, same topology |
| 15 | Newer SOF firmware (v2025.12.2) | Identical files | No updates for RPL max98373-nau8825 |

### The modprobe.d Betrayal

A file written in Attempt 1 (`/etc/modprobe.d/snd-fix.conf` with `dsp_driver=1`) was accidentally left in place. For **6 subsequent reboot cycles**, it silently forced legacy HDA — making us believe we were testing SOF parameters when we were actually running HDA with HDMI-only audio. Always verify with `cat /sys/module/snd_intel_dspcfg/parameters/dsp_driver`.

### The AVS Turf War

On CachyOS with kernel 7.1.2, `snd_soc_avs` loads before `snd_sof_pci_intel_tgl` and claims the audio PCI device. AVS then fails because firmware is missing, but SOF never gets a chance. Blacklisting AVS fixes this, but then auto-detection may pick legacy HDA instead of SOF.

### What Finally Worked

The three-component fix documented above. Each component addresses a different layer of the cascade failure, and all three are needed:

1. **WirePlumber patch** → breaks the error recovery loop
2. **suspend-timeout=0** → keeps DSP warm (YouTube effect)
3. **Device node removal** → blocks userspace ALSA probes

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Full installer — applies all three fixes + belt-and-suspenders |
| `dmic-override.conf` | UCM profile override (belt-and-suspenders) |

## Related

- [chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) — Run this first for firmware symlinks and UCM profiles
- [kano-audio-fix](https://github.com/maxugly/kano-audio-fix) — This repo
- [SOF Project](https://thesofproject.github.io/latest/index.html)

## License

MIT
