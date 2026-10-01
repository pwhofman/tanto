# Hardware checklist

Checks that need the real amp, run together with the user. The rules are in the design spec, section 5.7: the amp must
never get loud, and anything beyond reads needs the user's OK in chat with MASTER at minimum.

## Check 1: reads and the editor-mode flag

Run at the end of plan 1. The probe sends an identity request and reads (RQ1), and switches the editor-communication
flag (`7F 00 00 01`) on and off, as Tone Studio does on every connect. None of this changes the sound.

Before starting:

- Amp on and connected over USB; BOSS TONE STUDIO and other MIDI apps closed.
- MASTER at minimum.

Steps:

1. `swift run TantoProbe` lists the MIDI endpoints and sends nothing. Record their names below.
2. `swift run TantoProbe --connect --listen 60 --log check1.probe-log.txt` connects, prints the channel names and the
   live patch, then listens for 60 seconds.
3. While it listens, on the amp, with a few seconds between actions:
   1. turn GAIN a little, then VOLUME a little;
   2. switch to another channel and back;
   3. press the BOOSTER button to change its colour, then change it back.

   Do not press WRITE: saving on the amp belongs to check 3, after a backup. Knob turns change only the live sound;
   switching to another channel and back restores the stored one.
4. Switch the amp to PANEL, run `swift run TantoProbe --connect` again, and compare GAIN, VOLUME, BASS, MIDDLE, TREBLE
   and PRESENCE with the knob positions; a knob at 12 o'clock is about 50.
5. Record the results below. The log file stays local: `*.probe-log.txt` is in `.gitignore`.

### Results, 2026-10-01

Katana-100 MkII, POWER CONTROL at 0.5 W, MASTER at minimum.

| Item | Result |
|---|---|
| MIDI sources and destinations | Two of each: `KATANA` and `KATANA KATANA DAW CTRL`. Tanto uses `KATANA`, like Tone Studio. |
| Identity reply | `F0 7E 00 06 02 41 33 03 00 00 06 00 00 00 F7`: device ID `00`, not Tone Studio's default `10`; model code `06`, the Katana-100 MkII. The amp ignores messages for another device ID. |
| Editor communication level and revision | Level 8, as Tone Studio requires. The amp does not answer a revision read (`7F 00 00 03`); Tone Studio skips that read for the MkII. |
| Channel names match the amp | PANEL and A1 `KATANA Mk2`, A2 `Mayer High Gain`, A3 `Mayer Rhythm`, A4 `Mayer Lead`, B1 `Page`, B2 `Acoustic`, B3 `Green Day`, B4 `Mayer Solo`. The current channel read as 6 (B2) and the live patch as `Acoustic`, which confirms the slot numbering. The amp has no name display; the user recognised the names from Tone Studio. |
| PANEL values match the knobs | Not run: the knob turns below tie the GAIN and VOLUME knobs to their addresses directly. |
| Amp VOLUME is `PRM_PREAMP_A_LEVEL` at `60 00 00 28` | Yes. Turning VOLUME sends DT1 `60 00 00 28`. |
| Messages when turning a knob | Two DT1s per step: the patch parameter, then the knob position in the Status block. GAIN: `60 00 00 22` and `60 00 06 51`; VOLUME: `60 00 00 28` and `60 00 06 52`. VOLUME jumped from the stored 88 to the knob position, 28; for GAIN the two values differ (69 against 61). The MOD knob changed the MOD effect's pitch (`60 00 01 4C`, pitch shifter). |
| Messages when switching channels | DT1 `00 01 00 00` with the new number in two bytes (`00 07` = B3), followed by the whole new live patch from `60 00 00 00` to `60 00 0F 47`: eight DT1s of 241 bytes and one of 4, skipping unused memory. No Program Change. |
| Messages when changing the booster colour | DT1 `60 00 06 39` (`PRM_FXBOX_SEL_BOOST`) with the new colour, then `60 00 00 11` (`PRM_ODDS_TYPE`) with that colour's booster type, plus the knob position and LED in the Status block (`60 00 06 57`, `60 00 06 5D`). No other booster parameter was resent. Turning the BOOSTER knob switched the booster on (`60 00 00 10` = 1) and changed DRIVE (`60 00 00 12`). |

Further findings:

- Stored patches can exceed the ceiling: B2 `Acoustic` has amp VOLUME 88, above the 50 % ceiling of 50. Plan 2 has to
  settle how channel switching works with such patches.
- The check needed three fixes: using the main port, addressing the amp by the device ID from its identity reply, and
  following Tone Studio's connect sequence without the revision read.

## Check 2: first writes

Run at the end of plan 2a. Every write goes through `SafetyGuard`, one step per run of the probe; the probe refuses to
write without `--master-at-minimum`. Each step is announced in chat and needs the user's OK.

Before starting:

- Amp on and connected over USB; BOSS TONE STUDIO and other MIDI apps closed.
- POWER CONTROL at 0.5 W and MASTER at minimum.
- Note the current channel: at the end, switching to another channel and back restores its stored sound, because no
  step saves anything.

Steps, silent:

1. `swift run TantoProbe --connect --check2 rename --master-at-minimum --log check2.probe-log.txt` writes the name
   `TANTO TEST` into the live patch, reads it back, and restores the original name.
2. `swift run TantoProbe --connect --check2 lower --master-at-minimum` lowers the VOLUME knob by 10. The amp volume
   read back afterwards should equal the knob value.
3. `swift run TantoProbe --connect --check2 panic --master-at-minimum` sets the VOLUME knob to 0; the amp volume should
   follow to 0.
4. `swift run TantoProbe --connect --check2 ramp --master-at-minimum --log check2-ramp.probe-log.txt` raises the
   VOLUME knob by up to 10, at most to the ceiling. The log should show one step per message, at least 20 ms apart.

In steps 1–4 the probe prints every message the amp sends by itself as an `amp` line. There should be none: if the amp
echoes Tanto's writes, each echo looks like a knob turn to the guard (plan 2c, m9), and a ramp stops after one step.
Stop and report if `amp` lines appear.

Steps, audible, only with the user's OK and at a MASTER level the user chooses:

5. Repeat step 4 while playing: the volume rises gradually.
6. Repeat step 3 while playing: the sound stops.

Afterwards, switch to another channel and back.

### Results

Silent steps on 2026-10-01: Katana-100 MkII, POWER CONTROL at 0.5 W, MASTER at minimum. The live channel started with
VOLUME 88, above the ceiling.

| Item | Result |
|---|---|
| Rename and restore | `TANTO TEST` read back from the amp, then the original name `Acoustic` restored. |
| Lower: VOLUME knob and amp volume after | 88 → 78; the amp volume followed to 78. |
| Panic: VOLUME knob and amp volume after | 78 → 0; the amp volume followed to 0. |
| Ramp: steps and spacing in the log | 0 → 10 in ten steps of 1, 21.8–32.7 ms apart; no message closer than 20.5 ms to the one before. |
| No `amp` lines in steps 1–4 (the amp does not echo Tanto's writes) | The amp does not echo writes to `60 00 06 52`. After each one it reports the amp volume it derives from it, `60 00 00 28` (`PRM_PREAMP_A_LEVEL`), which Tanto does not write, so the guard does not take it for a knob turn and ramps go on. |
| Audible ramp | At a MASTER level the user chose: a smooth swell, no jump. VOLUME 10 → 20 in ten steps, 22–29 ms apart, 238 ms in all. |
| Audible Panic | The sound stopped. VOLUME 20 → 0. |
| Colour LED order (OFF, GREEN, RED, YELLOW) matches the amp | Moved to check 2b: it needs the app's colour menus. |

Afterwards MASTER went back to minimum, and switching to another channel and back restored the stored sound.

## Check 2b: the app

Before starting: POWER CONTROL at 0.5 W, MASTER at minimum, BOSS TONE STUDIO closed. Build the app with
`scripts/build-app.sh`.

Steps, silent:

1. Switch the amp off and open `build/Tanto.app`. The toolbar shows "Not connected".
2. Switch the amp on. Tanto connects by itself, shows the channel in the toolbar and the live patch in the window, and
   the values match the amp's knobs. A value above its ceiling shows in orange.
3. Lower VOLUME with its slider to about 30. The slider ends at the ceiling, so it cannot raise VOLUME above it.
4. Press Esc: VOLUME goes to 0 in the window and on the amp.
5. Raise VOLUME to about 20, then switch the booster on and off with its SW switch: each time VOLUME dips to 0 and
   comes back.
6. Turn the booster on (its SW switch, or its knob above OFF), then press BOOSTER COLOR a few times: each press dips
   VOLUME, and the colour moves on, GREEN, RED, YELLOW, on the amp's LED and in the window alike. Press VARIATION twice:
   its LED goes on and off again.
7. Switch the amp off: the toolbar shows "Not connected". Switch it on again: Tanto reconnects.

Steps, audible, only with the user's OK and at a MASTER level the user chooses: repeat steps 4 and 5 while playing.

Afterwards, turn MASTER to minimum, then switch to another channel and back.

### Results

| Item | Result |
|---|---|
| Not connected while the amp is off | Yes. |
| Connects by itself; channel, values and warnings shown | Yes; VOLUME 88 in orange. |
| VOLUME lowered with the slider; the slider ends at the ceiling | Yes; the slider stops at 50. |
| Esc sets VOLUME to 0 | Yes. |
| Booster on and off: VOLUME dips and comes back | Yes. |
| Colour LED order (OFF, GREEN, RED, YELLOW) matches the amp | Failed: every choice went back to GREEN and the amp did not change. Tanto wrote the LED register `60 00 06 5D`, which only shows the colour; Tone Studio never writes it. Its colour buttons send a button press, `00` to `7F 01 01 01`–`05`, and VARIATION one to `7F 01 01 00` (`panelActionBtnInfo` in `js/businesslogic/bts/effect_controller.js`). |
| Not connected when switched off; reconnects when switched on | Yes. |
| Audible Esc and booster switch | |
| The window's look: anything unclear or wrong | |

## Check 3: librarian

Specified in plan 3: after a verified backup, saving on the amp (WRITE) to see its notification, saving the live sound
to a channel the user chooses, renaming it, and restoring the backup.
