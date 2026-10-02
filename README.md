# Tantō

A Mac editor and librarian for the BOSS Katana-100 MkII guitar amplifier, as an alternative to BOSS TONE STUDIO for
KATANA MkII.

- Edit the live sound: the front panel's knobs and the pages of every effect, with undo and redo.
- Turn a knob by dragging, scrolling or with the arrow keys, or type its value.
- Switch channels, save the live sound to a channel, rename channels, and back up and restore all eight.
- Panic, the toolbar button or Esc, sets the amp's VOLUME to 0.

## Install

1. Download `Tanto-0.1.0.dmg` from the [latest release](https://github.com/pwhofman/tanto/releases/latest).
2. Open it and drag Tantō onto Applications.
3. Open Tantō. The first time, macOS refuses, because the app is not notarized by Apple: close the message, open System
   Settings → Privacy & Security, scroll down to Security, click Open Anyway next to the message about Tantō, and
   confirm. This is needed once for each new version.

## Requirements

- A Mac with Apple Silicon and macOS 15 or later. Tantō is developed and tested only on macOS 27.
- A BOSS Katana-100 MkII connected over USB. Tantō has been tried only on this model and refuses the other Katana
  models for now.
- BOSS's KATANA Driver for macOS, 1.0.4 or later, from the amp's
  [Updates & Drivers](https://www.boss.info/global/support/by_product/katana-100_mk2/updates_drivers/) page. Without
  it, the amp does not appear as a MIDI device.

## Safety

Tantō writes to your amp, and a careless write can make it very loud. It guards against that, within limits:

- It raises VOLUME, GAIN, levels and the other controls that make the amp louder gradually: a full sweep takes at least
  2 seconds. Switching an effect or a type sets VOLUME to 0 for a moment and raises it again.
- Panic sets VOLUME to 0 at once.
- The amp's MASTER knob limits the speaker and the PHONES jack, but not LINE OUT or USB audio. If you use those, turn
  on the ceiling in Settings, which keeps the guarded controls below a share of their travel.
- Switching to a channel loads its stored volume at once, as the amp's own channel buttons do.

Turn MASTER to minimum before connecting, and raise it while you play. Tantō comes without warranty; see the license.
The [design](docs/superpowers/specs/2026-10-01-tanto-design.md) gives the rules in full (section 5), and the
[hardware checklist](docs/hardware-checklist.md) shows what was checked on the real amp.

## Build from source

You need Xcode 26 or later.

```bash
swift build && swift test
scripts/build-app.sh
open build/Tanto.app --args -simulated YES
```

`scripts/build-app.sh` builds `build/Tanto.app`, and with `--dmg` also the disk image of a release. `-simulated YES`
runs the app against a simulated amp instead of the real one. `tools/gen_parameter_map.py` generates the parameter
table, `Sources/KatanaKit/Resources/parameters.json`, from an installed BOSS TONE STUDIO.

## Credits and trademarks

BOSS, KATANA and BOSS TONE STUDIO are trademarks of Roland Corporation. Tantō is an independent project, not affiliated
with or endorsed by Roland. Its parameter table is derived from the files of BOSS TONE STUDIO for KATANA MkII 2.1.0.

## License

[MIT](LICENSE)
