# Tanto: Katana MkII editor for macOS — design

Date: 2026-10-01. Status: approved in brainstorming, awaiting spec review.

## 1. Goal

A macOS app that replaces BOSS TONE STUDIO for KATANA MkII (v2.1.0, Intel-only) for a Katana-100 MkII connected over
USB. It starts like any other Mac app (double-click `Tanto.app`). The first version favours function over looks: native
sliders, toggles and pop-up menus.

Hard requirement: the app must never cause a sudden loud sound. Section 5 defines how.

## 2. Scope

v1:

- Live editing of the current sound.
- Patch librarian: channel list, channel switching, saving the live sound to a channel, renaming, backup and restore.

Later milestones, each with its own spec: `.tsl` tone files; global settings and controller assignments (knob,
expression pedal, GA-FC, footswitch functions); visual design.

Not planned: BOSS Tone Central/Exchange browsing, firmware updates, audio over USB.

## 3. Verified facts

### 3.1 Machine

Apple Silicon Mac, macOS 27.0.1, Swift 6.4 from the Command Line Tools (includes Swift Testing). Xcode is being installed.

### 3.2 USB and driver

- The amp enumerates as `KATANA` (vendor BOSS, VID `0x0582`, PID `0x01D8`), device class `0xFF`, four interfaces.
  Interfaces 0–2 carry audio and are served by `/Library/Audio/Plug-Ins/HAL/RDUSB01D8Audio.driver`. Interface 3 carries
  MIDI and is claimed by MIDIServer through `/Library/Audio/MIDI Drivers/RDUSB01D8Midi.plugin` (v1.0.4, universal
  arm64/x86_64).
- The Boss driver is a prerequisite. With it, the amp is an ordinary CoreMIDI device with two ports, `KATANA` and
  `KATANA KATANA DAW CTRL` (for controlling recording software). Tone Studio and Tanto use `KATANA`.

### 3.3 Protocol

Sources in Tone Studio's `Contents/Resources/html/js/`: `config/product_setting.js`, `businesslogic/bts/address_const.js`,
`businesslogic/bts/midi_connect_controller.js`, `utilities/converter.js`, `utilities/constant.js`.

- Roland SysEx with model ID `00 00 00 33` and the device ID from the amp's identity reply. Tone Studio's default
  is `10`; the user's amp answers as `00` and ignores messages for other device IDs.
  - RQ1 (read): `F0 41 10 00 00 00 33 11 a3 a2 a1 a0 s3 s2 s1 s0 cs F7`
  - DT1 (write): `F0 41 10 00 00 00 33 12 a3 a2 a1 a0 d… cs F7`
  - `cs = (128 − (sum of address and size/data bytes) mod 128) mod 128`
- Identity request: `F0 7E 7F 06 01 F7`. Tone Studio accepts a reply whose bytes 0–1 are `F0 7E` and bytes 3–7 are
  `06 02 41 33 03`.
- Tone Studio leaves 20 ms between outgoing messages, splits reads into chunks of at most 128 data bytes
  (`SYSEX_MAXLEN`) and times out reads after 15 s. Tanto uses the same 128-byte limit for writes.
- Tone Studio's connect sequence: identity request, after which it uses the device ID from the reply; RQ1
  `7F 00 00 00` (editor communication level, 1 byte), which must be 8 or Tone Studio disconnects; DT1 `7F 00 00 01` =
  `01` (editor communication mode on). It reads a revision at `7F 00 00 03` only when its settings define
  `communicationRevision`, which the KATANA MkII build does not, and the amp does not answer that read. On disconnect
  it sends DT1 `7F 00 00 01` = `00`.
- Addresses are four 7-bit bytes. Offsets are added in linear space, `linear = a3·2²¹ + a2·2¹⁴ + a1·2⁷ + a0`
  (Tone Studio's `nibble()`), and converted back afterwards.
- Value encodings, big-endian: `INTEGER1x7` one byte; `INTEGER2x7` two bytes of 7 bits; `INTEGER2x4` two bytes of 4 bits;
  `INTEGER4x4` four bytes of 4 bits. The address map uses only `INTEGER1x7`, `INTEGER2x7` and the 16-byte patch name.
  Displayed value = raw value − `ofs`.

### 3.4 Memory map

| Address       | Content                                                                    | v1                      |
|---------------|----------------------------------------------------------------------------|-------------------------|
| `00 00 00 00` | System: global EQ, line out, USB levels, cab EQ, power adjust              | not touched             |
| `00 01 00 00` | Current patch number, `INTEGER2x7`, 0–8                                     | read                    |
| `00 02 00 00` | MIDI settings                                                              | not touched             |
| `10 0n 00 00` | Stored patch n, n = 0…8: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4                | read; write n = 1…8     |
| `60 00 00 00` | Live (temporary) patch                                                     | read and write          |
| `7F 00 01 00` | Patch select, DT1 `00 nn`                                                  | write                   |
| `7F 00 01 04` | Patch write (store the live patch in n), DT1 `00 nn`; the amp answers with a DT1 on the same address | write |

PANEL is read and shown but never written, as in Tone Studio (`businesslogic/ktn/model_info.js`, `transferablePatch`).

Patch layout, as offsets from the patch base: name `00 00` (16 ASCII characters); `Patch_0` `00 10` (booster, amp,
EQ 1); `Eq(2)` `00 60`; `Fx(1)` `01 00` (MOD); `Fx(2)` `03 00` (FX); `Delay(1)` `05 00`; `Delay(2)` `05 20`; `Patch_1`
`05 40` (reverb, pedal FX, foot volume, send/return, noise suppressor, solo, contour); `Patch_2` `06 20` (chain, block
positions, variation colours, cabinet resonance); `Status` `06 50`; controller assignments `07 00`–`0F 08`;
`Patch_Mk2V2` `0F 10` (solo EQ and solo delay); `Contour(1)`–`Contour(3)` `0F 30`, `0F 38`, `0F 40`.

### 3.5 Parameter data

Tone Studio 2.1.0 ships its parameter definitions as plain files under `Contents/Resources/html/`:

- `js/config/address_map.js`: address, encoding, offset, range, name and internal id (`PRM_…`) of every parameter.
- `export/item.json`: for each UI control, the parameter it edits (e.g. `Temporary%Delay(1)%2`) and its value formatter.
- `export/layout.div`: option labels (e.g. the booster types CLEAN BOOST, TREBLE BOOST, MID BOOST, …) and display
  formats.

A generator run by the developer (`tools/gen_parameter_map.py`, run with `uv`) turns these into Tanto's parameter table,
`Sources/KatanaKit/Resources/parameters.json`, which is committed. The app never reads Tone Studio's files at runtime.
Only facts are taken over (addresses, ranges, labels), not Roland's code. KatanaFxFloorBoard
(sourceforge.net/projects/fxfloorboard) is a fallback reference for unclear labels.

Tanto writes exactly the addresses that Tone Studio's controls write, and nothing else (decided after hardware check 1).
Tone Studio edits the amp section only through a virtual front panel: it writes the knob positions of the Status block
(`60 00 06 50` to `60 00 06 61`). These are AMP TYPE (five positions), GAIN, VOLUME, BASS, MIDDLE, TREBLE and PRESENCE,
and the BOOSTER, MOD, FX, DELAY and REVERB knobs, where −1 means the effect is off. The amp derives its amp parameters
from these, as when the real knobs are turned. The VARIATION and colour buttons are pressed instead: a DT1 of `00` to
`7F 01 01 00` (VARIATION) or `7F 01 01 01` to `05` (BOOSTER to REVERB) does what pressing the real button does. Their
LEDs in the Status block, where 0 means off and 1–3 are the colours, only show the result; writing them changes nothing
(hardware check 2b). VOLUME, BASS, MIDDLE, TREBLE and PRESENCE map one to one; GAIN goes through the amp's own
curve (knob 34 gave gain 47 in hardware check 1). After a channel is loaded the Status block holds the saved positions
(B2: VOLUME 88), and turning a real knob overwrites them.

Tone Studio never writes the amp parameters themselves (`PRM_PREAMP_A_*`) or FOOT VOLUME. Tanto reads them but does not
write them. The effects' detail pages write the effect parameters directly. About 50 entries in `address_map.js` have no
name; Tanto writes them only where a Tone Studio control does.

## 4. Architecture

One Swift package with two parts:

- `KatanaKit`: library without UI. All protocol, state and safety logic, unit-tested with Swift Testing (`swift test`).
- `Tanto`: SwiftUI app, a thin layer over `KatanaKit`.

| Component           | Responsibility                                                                                     |
|---------------------|----------------------------------------------------------------------------------------------------|
| `SysEx`             | Encodes and decodes identity, RQ1 and DT1 messages; checksum; 7-bit address arithmetic; value encodings. |
| `ParameterMap`      | Loads `parameters.json`: section, block, address, encoding, range, offset, label, option labels, formatter, kind (numeric, switch, picker, text) and the `guarded` flag. |
| `MIDITransport`     | Protocol with two implementations. `CoreMIDITransport` finds the amp's endpoints, sends, receives SysEx and channel messages (e.g. Program Change), and reports plug/unplug. `SimulatedAmp` is an in-memory amp with the same memory map: it answers RQ1 and DT1, sends change notifications and records every message it receives. |
| `AmpSession` (actor) | Connect and disconnect, outgoing queue (at least 20 ms between messages, priority lane for decreases and Panic), read timeouts, mirror of the amp's memory, change stream for the UI. |
| `SafetyGuard`       | The only path from a user action to a parameter write (section 5).                                 |
| `Librarian`         | Channel names, cache of stored patches, select, save, rename, backup, restore.                      |

Swift 6 language mode with strict concurrency. UI state is an `@Observable` model on the main actor, fed by
`AmpSession`'s change stream.

Data flow:

- Connect: identity request, editor mode on, then reads of the current patch number, the live patch and, in the
  background, the 9 stored patches. Apart from the editor-mode flag, connecting only reads.
- Edit: control → `SafetyGuard` → queue → DT1 to `60 00 …` → mirror.
- Amp to app: with editor mode on, the amp sends DT1 messages for changes made on the amp. The mirror and the UI follow;
  no write is triggered, apart from the correction of 5.8. On a channel change the amp sends its channel number and then
  the whole new patch; the mirror is valid again once that dump has covered it (5.8).
- Quit or disconnect: editor mode off.

## 5. Safety

### 5.1 Always on

1. No automatic writes. Launch, connect and reconnect only read, apart from the editor-mode flag and a Panic pressed
   meanwhile. Messages from the amp never trigger a write, except the correction of 5.8, which only lowers a value
   that Tanto itself wrote.
2. Every outgoing DT1 is one of: a parameter write that `SafetyGuard` produced from a user action; a whitelisted command
   (`7F 00 00 01` editor mode, `7F 00 01 00` patch select, `7F 00 01 04` patch write); a press of the VARIATION or a
   colour button (`7F 01 01 00` to `05`, 3.5), which `SafetyGuard` soft-switches (5.3); a librarian write after
   confirmation: a save, or a rename or restore that writes stored channels 1–8 at `10 0n 00 00` directly.
3. Validation before sending: the address belongs to `ParameterMap`, the value is within range, the encoding and the
   checksum are correct. Anything else is refused and logged. The UI has no way to send raw SysEx.
4. At most one message per 20 ms. A slider drag sends only its latest value, and after Panic it sends nothing until
   it ends.

### 5.2 Guarded parameters

A parameter is guarded if it can raise loudness: the GAIN and VOLUME knobs and the five effect knobs of the front panel,
and every numeric parameter whose internal id or Tone Studio label contains LEVEL, VOLUME, GAIN, DRIVE, FEEDBACK,
RESONANCE, SUSTAIN, DIRECT, REGEN, ECHO INTENSITY or PEAK, or that is a graphic-EQ band. Selectors whose names match
(`FXBOX_*` variation settings, CABINET RESONANCE) are pickers and follow 5.3. Tone controls (the BASS, MIDDLE, TREBLE and
PRESENCE knobs, booster TONE and BOTTOM), times, rates and depths are not guarded. Appendix A lists the guarded
parameters. The rule also marks amp parameters and FOOT VOLUME, which Tanto does not write (3.5); for those it serves
only the channel check of 5.4 and the warnings.

Two unguarded parameters of the MOD and FX limiter get louder in one direction: a higher THRESHOLD and a lower RATIO let
more of the signal through. Changes in that direction are ramped like guarded increases, without a ceiling, because the
limiter's LEVEL is guarded. The table marks the direction in which each parameter gets louder (`louder`). TREMOLO DEPTH
stays unguarded: lowering it fills in the dips of the tremolo without raising its peaks.

- Ceiling: `ceiling = min + ⌊f · (max − min)⌋` with f = 50 % by default. f is set in Settings from 0 % to 100 % in 5 %
  steps; raising it asks for confirmation. At 50 %: VOLUME and GAIN knobs 50, effect knobs 49, delay EFFECT LEVEL 60,
  EQ gains and levels 0 dB.
- A requested value above the ceiling and above the current value is refused with a message at the control, and the
  control returns to the amp's value. Values are never clipped silently.
- A value that is already above the ceiling (set on the amp, or stored in a patch) is shown with a warning. It can be
  lowered but not raised.
- Increases are ramped in steps of one raw unit, at least `2 s / (max − min)` apart, so a full sweep takes at least 2 s.
  The 20 ms pacing can only make a ramp slower.
- Decreases take the next message slot through the priority lane, ahead of queued increases, and cancel any ramp of the
  same parameter. The 20 ms spacing applies to every message, including priority ones.
- Moving an effect knob (BOOSTER, MOD, FX, DELAY, REVERB) between −1 and 0 or more switches its effect on or off, as
  hardware check 1 showed for the booster. This uses the soft switch of 5.3: switching on sets the knob to 0, and a
  higher request then ramps from there.

### 5.3 Switches and pickers

Switches and pickers in the sound path (block on/off, the AMP TYPE knob, the VARIATION and colour buttons, effect types,
colour assignments, chain, block positions, contour, cabinet resonance), and effect knobs moved across −1, use a soft
switch:

1. If the VOLUME knob is above the ceiling, the change is refused with the message "Lower VOLUME below the ceiling
   first".
2. The VOLUME knob is set to 0 at once.
3. The change is sent.
4. The VOLUME knob ramps back to its previous value under the rules of 5.2.

Patch-name edits are not soft-switched.

### 5.4 Channels and memory

- Switching channels from the app uses Tone Studio's select command (3.3), after up to two questions:
  1. If the live patch has unsaved edits made in the app, a dialog asks before discarding them.
  2. Tanto reads the target channel from the amp. If a front-panel volume stored there lies above its ceiling, a dialog
     lists those values and asks first, with Cancel as the default button. The front-panel volumes are the VOLUME, GAIN,
     BOOSTER, MOD, FX, DELAY and REVERB knobs and the amp volume.

  Otherwise the switch happens directly, as with the amp's own channel buttons. A channel switch cannot be faded,
  because the amp loads the stored volume at once.
- Saving the live sound to channel n (1–8) asks before overwriting. It waits until the guard's ramps are done, sends
  Tone Studio's WRITE and waits for the amp's confirmation, then selects channel n as Tone Studio does. The sound does
  not change.
- Renaming writes the 16-character name field of the stored channel, and for the current channel also the live name.
  The sound does not change.
- Restore asks you to turn MASTER to minimum first, writes channels 1–8, and selects no channel afterwards.

Hardware check 1 showed that saved channels exceed the ceiling (B2 has amp VOLUME 88). The user chose to keep these
rules: a switch to such a channel asks first, and effect switches there need VOLUME at or below the ceiling. During plan
3 the user narrowed the switch question to the front-panel volumes: Tone Studio's defaults alone put 56 guarded values
above the 50 % ceiling in every channel, mostly levels of effect types the channel does not use, so a question about
all of them would come with almost every switch.

### 5.5 Panic

Toolbar button and the Esc key. Panic clears the outgoing queue, cancels all ramps and sets the VOLUME knob
(`60 00 06 52`) to 0 in the next message slot. Like turning the real VOLUME knob down, this sets the amp volume
(`60 00 00 28`) to 0, as hardware check 1 showed. The volume stays at 0 until raised by hand, which is ramped and limited
by the ceiling. Panic changes only the live patch; stored channels are untouched.

VOLUME 0 goes ahead of every queued message, also while a read waits for its reply, and nothing decided before Panic is
sent after it; requests still being decided are refused. While connecting, VOLUME 0 goes out as soon as the amp is in
editor mode. Panic sets only the VOLUME knob register: delay and reverb tails already sounding die out by themselves, and
touching the real VOLUME knob sets the register to the knob's position again.

### 5.6 Outside the app's control

The amp's MIDI map has no MASTER or POWER CONTROL parameter. Both stay hardware-only and remain the final safety limit.
Changes made with the amp's own knobs and buttons are shown in the app, with a warning when a guarded value exceeds its
ceiling.

### 5.7 Development on the real amp

- Development and automated tests use `SimulatedAmp`.
- Every interaction with the real amp is announced in chat first. Sessions that send anything beyond reads and the
  editor-mode flag need your explicit OK and MASTER at minimum.
- The first write tests are silent (renaming the live patch) or lower the volume.
- Audible checks (ramp, Panic) happen only at a MASTER level you choose.

### 5.8 Changes on the amp while Tanto writes

The amp's knobs and buttons keep working while Tanto writes, and their reports reach Tanto a little later. The
independent review of the safety core (plan 2c) showed how such a report can cross a write of Tanto's. These rules
apply:

- Every write carries what it was decided on: the channel generation, the Panic count, and the number of reports the
  amp has sent about the parameter (for a switch change also about VOLUME). The session checks them right before sending
  and drops the write if any of them changed.
- A channel change reported by the amp ends all of Tanto's work and makes the mirror invalid until the amp's dump of the
  new patch has covered it. Requests are refused meanwhile.
- A request counts as a decrease only if it lies below every value the amp may hold: the mirror, and a write of Tanto's
  that a report may have crossed. A rise starts from the lowest of these values.
- A report that arrives within 100 ms after a write of Tanto's to the same parameter, or a channel change within 100 ms
  after it, may have lost against that write on the amp. Once the parameter has been quiet for 150 ms and the mirror is
  valid, Tanto reads it back. If the amp holds Tanto's value and the amp's own value is lower (the knob's last report,
  or the stored value of the new channel), Tanto writes the amp's own value.
- What remains: a write already on its way when a channel is selected on the amp lands on the new channel. A guarded
  value is set back as above; a switch or picker change stays, and the mirror shows it after the read-back.

## 6. UI (v1)

One window:

- Toolbar: connection status, current channel, Panic.
- Sidebar: PANEL, A1–A4 and B1–B4 with their names; the current channel is highlighted; clicking a channel switches to
  it (5.4). Context menu: "Save Live Sound Here…", "Rename…". Backup and Restore are in the File menu.
- Editor: the patch name, then the sections Amp, Booster, Mod, FX, Delay, Delay 2, Reverb, EQ 1, EQ 2, Pedal FX, Noise
  Suppressor, Send/Return, Solo, Contour, Chain.
  - Amp is the front panel: AMP TYPE, VARIATION, GAIN, VOLUME, BASS, MIDDLE, TREBLE, PRESENCE and CAB RESONANCE.
  - Booster, Mod, FX, Delay and Reverb each show their panel knob and colour button, then their on/off switch and type,
    then the detail parameters of the selected type.
  - The VARIATION and colour buttons are pressed as on the amp (3.5) and show the state the amp reports: OFF or ON, and
    OFF, GREEN, RED or YELLOW.
  - Sections and the parameters per type follow Tone Studio's UI grouping; its control ids carry a section prefix such
    as `booster-` or `delay2-`. The amp reports the result of every panel change, so the display shows what the amp
    actually did.
- Controls: numeric parameters are sliders with the value in display units (formatters from `layout.div`, e.g. `+3`,
  `320 ms`); switches are toggles; pickers are pop-up menus. Guarded sliders show the ceiling.
- Settings window: the ceiling percentage.

## 7. Librarian

- Reads: the names are read when connecting. A channel is read from the amp right before a switch to it, and channels
  1–8 when backing up, so no check rests on old data. When the amp reports a save, the channel's name is read again.
  Stored channels have the live patch's layout at `10 0n 00 00`.
- Backup: channels 1–8 go into a JSON file, `<name>.tanto-backup.json`:
  `{"format": 1, "model": "KATANA MkII", "created": <ISO 8601>,
  "channels": [{"slot": 1, "name": "…", "blocks": {"Patch_0": "<hex>", …}}, …]}`. The parameter table's block names
  and lengths describe the layout; the amp does not answer the editor-revision read (hardware check 1). After saving,
  Tanto reads the file back and compares it with what it read from the amp.
- Restore: checks the format, the model, the slots, every block, its length and its bytes, and the names, before anything
  is written; shows the 8 names; asks as in 5.4; writes the blocks into the stored channels directly, as Tone Studio's
  own restore does, as paced DT1 messages of at most 128 data bytes; reads everything back and reports any difference.

## 8. Error handling

| Situation                                        | Behaviour                                                                           |
|--------------------------------------------------|-------------------------------------------------------------------------------------|
| Amp off or unplugged                             | "Not connected", controls disabled. When the amp reappears, the connect sequence runs again. |
| Identity reply does not match                    | No connection; the message names the device found.                                  |
| Editor communication level is not 8             | No connection, editor mode stays off; message.                                      |
| No reply to a read within 3 s                    | One retry, then nothing more is sent and "Connection problem" offers Reconnect.     |
| A reply after its read timed out                 | Applied as a read, not as a change made on the amp.                                 |
| No patch-write confirmation within 15 s          | Error message; the channel is re-read.                                              |
| Malformed message or bad checksum from the amp   | Dropped and logged; the affected block is re-read.                                  |
| Write refused (validation or ceiling)            | Message at the control; nothing is sent.                                            |
| Disconnect during restore                        | Error naming the last channel written; restore can be run again.                    |
| Invalid backup file                              | Refused before any write, with the reason.                                          |

Logging goes through `os.Logger` (categories `midi`, `safety`, `librarian`) and can be followed in Console.app or with
`log stream`.

## 9. Testing

Automated, with `swift test` and no amp:

- `SysEx`: encode/decode round trips; checksums against messages from Tone Studio's sources and from hardware check 1;
  7-bit address arithmetic; every value encoding.
- `ParameterMap`: no overlapping addresses; ranges consistent with encodings; the guarded set equals appendix A plus the
  reviewed additions from 3.5; the Panic address resolves to the VOLUME knob.
- `SafetyGuard`: refusal above the ceiling; ramps are monotonic and respect step size and spacing; decreases go out at
  once and cancel ramps; the soft-switch sequence, including its refusal above the ceiling; Panic clears the queue and
  goes first; connecting and incoming amp messages produce no writes; random sequences of UI actions never produce a
  write above a ceiling or a faster rise than allowed; the scenarios of the independent review (plan 2c), in which
  knob turns and channel switches on the amp cross Tanto's writes.
- Integration with `SimulatedAmp`: connect sequence, editing, channel switch with the ceiling dialog, save, rename, and a
  backup → restore round trip that must be byte-identical.

Hardware checklist, kept in `docs/hardware-checklist.md` and run together with you:

1. Reads and the editor-mode flag only, MASTER at minimum. Record the endpoint names, the identity reply and the
   editor communication level. Read the channel names and the live patch and compare them with the amp's knobs, including amp
   VOLUME at `60 00 00 28`. Log what the amp sends when you turn knobs, switch channels and change a variation colour.
   Editor mode off at the end.
2. First writes, MASTER at minimum: rename the live patch and read it back; lower amp VOLUME; Panic; one ramped increase
   within the ceiling, checked in the log. Then, at a MASTER level you choose, listen to the ramp and to Panic.
3. Librarian, after a backup has been made and verified: save on the amp (WRITE) to log its notification, save to a
   channel you choose, rename it, restore the backup.

## 10. Build and run

```
Package.swift            KatanaKit library and tests, Tanto executable
Sources/KatanaKit/
Sources/Tanto/
Tests/KatanaKitTests/
tools/                   parameter-table generator (Python, uv)
scripts/build-app.sh     builds Tanto.app
docs/
```

- `scripts/build-app.sh` builds a release binary with SwiftPM and assembles `Tanto.app`: `Info.plist`, an `.icns` icon
  made with macOS's `iconutil`, ad-hoc `codesign`. Copying it to `/Applications` is a separate, explicit step. The
  package opens in Xcode for editing and debugging.
- Deployment target macOS 27. CoreMIDI needs no sandbox or special entitlements.
- The folder is not a git repository yet; whether to create one is decided at the start of implementation.

## 11. Later milestones

- `.tsl` import and export (Tone Studio LiveSet, format revision `0002` in `product_setting.js`).
- Global settings and controller assignments. The guard then extends to system levels: global EQ level, cab EQ level,
  USB levels.
- Visual design.

## Appendix A: guarded parameters

Selected by the rule in 5.2: the seven front-panel knobs plus 210 parameters of `address_map.js`. Ceilings at the
default of 50 %. Rows marked "read only" are amp parameters that Tanto reads but never writes (3.5); they count for the
channel check of 5.4 and for warnings.

| Section           | Parameters                                                        | Range → ceiling     |
|-------------------|-------------------------------------------------------------------|---------------------|
| Front panel       | GAIN and VOLUME knobs                                             | 0–100 → 50          |
|                   | BOOSTER, MOD, FX, DELAY and REVERB knobs                          | −1…100 → 49         |
| Booster           | DRIVE                                                             | 0–120 → 60          |
|                   | EFFECT LEVEL, DIRECT MIX, SOLO LEVEL                              | 0–100 → 50          |
| Amp, read only    | GAIN                                                              | 0–120 → 60          |
|                   | VOLUME (`PREAMP_A_LEVEL`), SOLO LEVEL                             | 0–100 → 50          |
| EQ 1, EQ 2 (each) | parametric LOW, LOW-MID, HIGH-MID and HIGH GAIN; LEVEL            | −20…+20 dB → 0 dB   |
|                   | graphic 31 Hz … 16 kHz (10 bands); LEVEL                          | −24…+24 dB → 0 dB   |
| Mod, FX (73 each) | per effect type, below                                            |                     |
| Delay, Delay 2    | FEEDBACK, DIRECT MIX                                              | 0–100 → 50          |
|                   | EFFECT LEVEL                                                      | 0–120 → 60          |
| Reverb            | EFFECT LEVEL, DIRECT MIX                                          | 0–100 → 50          |
| Pedal FX          | EFFECT LEVEL and DIRECT MIX of WAH, PEDAL BEND and EVH95          | 0–100 → 50          |
| Foot Volume, read only | FOOT VOLUME                                                  | 0–100 → 50          |
| Send/Return       | SEND LEVEL, RETURN LEVEL                                          | 0–100 → 50          |
| Solo              | LEVEL; delay FEEDBACK and DIRECT LEVEL                            | 0–100 → 50          |
|                   | delay EFFECT LEVEL                                                | 0–120 → 60          |
|                   | EQ LOW, MID and HIGH GAIN; LEVEL                                  | −24…+24 dB → 0 dB   |

Mod and FX, by effect type (0–100 → 50 unless noted):

- T.WAH, AUTO WAH: PEAK, EFFECT LEVEL, DIRECT MIX
- SUB WAH, SLICER, RING MOD, PEDAL BEND, EVH WAH: EFFECT LEVEL, DIRECT MIX
- COMPRESSOR: SUSTAIN, LEVEL
- LIMITER, GUITAR SIM, SLOW GEAR, AC.PROCESSOR, TREMOLO, ROTARY, UNI-V, VIBRATO, HUMANIZER, AC.GUITAR SIM: LEVEL
- GRAPHIC EQ: 10 bands, LEVEL (−20…+20 dB → 0 dB)
- PARAMETRIC EQ: LOW, LOW-MID, HIGH-MID and HIGH GAIN, LEVEL (−20…+20 dB → 0 dB)
- WAVE SYNTH: RESONANCE, SYNTH LEVEL, DIRECT MIX
- OCTAVE: EFFECT LEVEL, DIRECT MIX
- PITCH SHIFTER: PS1 LEVEL, PS2 LEVEL, PS1 FEEDBACK, DIRECT MIX
- HARMONIST: HR1 LEVEL, HR2 LEVEL, HR1 FEEDBACK, DIRECT MIX
- PHASER, FLANGER: RESONANCE, EFFECT LEVEL, DIRECT MIX
- 2x2 CHORUS: LOW LEVEL, HIGH LEVEL, DIRECT MIX
- EVH FLANGER: REGEN.
- DC-30: INPUT VOLUME, ECHO VOLUME, ECHO INTENSITY
- HEAVY OCTAVE: 1OCT LEVEL, 2OCT LEVEL, DIRECT MIX

Effect-type names here come from the internal ids (e.g. `PRM_FX1_ADCOMP_*` is the compressor); the generator uses Tone
Studio's labels. The generator also applies the rule to unnamed entries that Tone Studio shows, using their on-screen
labels. Each Delay block has two unnamed 0–120 entries to check this way.
