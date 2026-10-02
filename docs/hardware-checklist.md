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
| Colour LED order (OFF, GREEN, RED, YELLOW) matches the amp | The first attempt failed: Tanto wrote the LED register `60 00 06 5D`, which only shows the colour; Tone Studio never writes it, but presses the button with `00` to `7F 01 01 01`–`05`, and VARIATION with `7F 01 01 00` (`panelActionBtnInfo` in `js/businesslogic/bts/effect_controller.js`). With the presses (plan 2b, task 8): BOOSTER COLOR cycles GREEN, RED, YELLOW on the amp and in the window, and VARIATION toggles on and off. |
| Not connected when switched off; reconnects when switched on | Yes. |
| Audible Esc and booster switch | Esc stopped the sound; the booster switch and BOOSTER COLOR dipped briefly and came back. |
| The window's look: anything unclear or wrong | No problems reported. |

## Check 3: librarian

Before starting: POWER CONTROL at 0.5 W, MASTER at minimum, BOSS TONE STUDIO closed, `build/Tanto.app` built with
`scripts/build-app.sh`. Pick a scratch channel whose sound may be overwritten until the restore in step 9.

1. File › Back Up Channels…, and save the file. Tanto reads the file back and reports that it reads back the same.
   Nothing is written to the amp before this step has succeeded.
2. Click B2 (VOLUME 88) in the sidebar. A dialog lists the front-panel volumes above the ceiling; Cancel keeps the
   current channel. Then click a channel without such values: Tanto switches at once.
3. Save the current channel onto itself with the amp's own controls. Tanto notices the save and reads the name again.
4. Change something small in Tanto, e.g. BASS. Then choose "Save Live Sound Here…" in the scratch channel's context
   menu: the amp confirms, and Tanto selects the scratch channel.
5. Rename the scratch channel from its context menu. The sidebar shows the new name.
6. Look through the front panel and every page, and say what to change (plan 4, task 7). Then turn BASS down a few
   steps and back with the scroll wheel or the trackpad: each notch is one step, the momentum after a flick turns
   nothing, and scrolling the page past a knob leaves it alone.
7. EFFECTS page, an effect that is on: click another colour's marker. VOLUME dips, the amp changes to that colour,
   and the panel's LED and the marker follow. Tanto's first write of a colour selection (`PRM_FXBOX_SEL_*`).
8. EFFECTS page: tap DELAY's TAP twice, about half a second apart. The time under it follows the interval; the
   VOLUME does not move. Tanto's first TAP.
9. File › Restore Channels…, with the file of step 1. Tanto writes A1 to B4, reads them back and reports no
   difference. The scratch channel has its own name and sound again.
10. Read only, for the sounding simulator. Quit Tanto, then run
    `swift run TantoProbe --connect --listen 120 --log scratch/knobs.log`. While it listens, turn each effect knob on
    the amp (BOOSTER, MOD, FX, DELAY, REVERB) slowly from minimum to maximum, one at a time. The log shows which
    parameters each knob moves, so that the simulator's knobs can do the same.

Afterwards, switch to another channel and back.

### Results

| Item | Result |
|---|---|
| Backup saved and read back the same | Yes: `Katana 2026-10-02.tanto-backup.json`; all 8 channels, 31 blocks each, match the amp's replies byte for byte (passive listener). |
| B2: dialog lists the volumes above the ceiling; Cancel keeps the channel | Yes: LEVEL (solo) 88 and VOLUME 88 (ceiling 50), MOD 50, FX 62, REVERB 61 (ceiling 49). Cancel kept A1 and nothing was written. Bug: the sidebar kept B2 highlighted. |
| A channel without such values switches at once | Not at first: the amp ignores `7F 00 01 00` and stayed on B2 through about ten selects. Fixed in d29e678 to write PATCH NUM at `00 01 00 00`, as Tone Studio's channel list does; then A1 switched at once. |
| After Tanto's select: did the amp send its channel number and dump? (log) | Yes: its channel number, then the whole live patch in DT1s of 241 bytes, as after a channel button (a passive MIDI listener next to Tanto, which only receives). |
| A save made on the amp: Tanto reads the name again | Yes: the amp sent `7F 00 01 04 00 01`, then its channel number and the whole patch; Tanto read A1's name 3 s later: the amp left its first read unanswered while sending the patch, and the retry got the reply ("no reply, retrying once" in the log; the same after step 4). |
| Save Live Sound Here…: confirmed, channel selected | Yes: BASS 50 → 36 in Tanto (the amp reported its own `PRM_PREAMP_A_BASS` along the way, one to one with the knob); after Save the amp sent `7F 00 01 04 00 01`, its channel number and the whole patch; Tanto selected A1 and read the name; the live patch holds BASS 36. |
| Rename: new name in the sidebar | Yes: SCRATCH in the sidebar and as the live patch's name; the amp sent nothing back. |
| The window: remarks on the panel and the pages | Looks very good. To change: align the toolbar's green Connected label vertically with the channel (A1), and give that toolbar item a little more width. |
| Scrolling: BASS turns; momentum and page scrolls leave knobs alone | BASS turns. With an MX Master 3 and Logi Options' smooth scrolling the wheel sends fine deltas: a slight turn between notches changes BASS, and a fast turn swept 0 → 100 in 0.1 s (fine for now, says the user). Free-spin flick not tried. Scrolling the page past knobs left them alone: the amp reported no other change. |
| Colour marker: VOLUME dips, the amp changes colour, LED and marker follow | With DELAY off (knob at −1): pressing DELAY's colour button does nothing on the amp (no report), only the VOLUME dip; an effect goes on with its knob. Clicking a marker works: after the dip the amp switches DELAY's type to that colour's variation (`PRM_DLY_TYPE` 0 ↔ 7) and reports the type, not the selection; the marker follows, the LED stays off. With DELAY on (its knob turned up from OFF to 30, soft-switched: the amp reported `PRM_DLY_SW` 1 and LED 2 = red, then raised the effect level 0 → 51 and lowered feedback 35 → 31 as the knob rose): green and red markers each dip VOLUME, switch the type, and the LED follows about 1.5 s later (1 = green, 2 = red), on the amp and in Tanto. Each dip: VOLUME to 0, then back to 50 in about 1.1 s (the amp's `PRM_PREAMP_A_LEVEL` reports). |
| TAP: the time follows the taps, VOLUME stays | Yes: two taps about half a second apart gave 614 ms, about a second apart 952 ms; the amp reported each new DELAY TIME once per pair, and VOLUME did not move. |
| Restore: written, read back the same; scratch channel restored | Yes: the dialog listed the eight names; Tanto reported "Restored channels 1–8; they read back the same."; the amp's read-back matches the backup file byte for byte (passive listener); A1 is KATANA Mk2 again. |
| Effect knobs on the amp: what the amp reports for each (log) | Done with Tanto connected and the passive listener instead of the probe. For A1's selected types, fully left to fully right: BOOSTER raises `PRM_ODDS_DRIVE` 1 → 70 and lowers `PRM_ODDS_EFFECT_LEVEL` 74 → 40; MOD (2x2 CHORUS) raises LOW RATE 21 → 80 and HIGH RATE 11 → 70; FX (TREMOLO) raises RATE 31 → 90; DELAY raises EFFECT LEVEL 2 → 100 and lowers FEEDBACK 34 → 22; REVERB raises EFFECT LEVEL 0 → 100. At −1 the effect's SW and LED go to 0. The amp also reports the knob position (`PRM_KNOB_POS_*`). Then A2 and back to A1 on the amp, each with its full dump. |
| The dialogs' look: anything unclear or wrong | Fine, says the user. |

## Check 4: fast channel switching

A switch from Tanto takes the amp's channel number and dump as its read-back instead of reads that the amp leaves
unanswered while it sends them; check 3's log showed the dump ending about 0.3 s after the channel number. Silent:
nothing here needs sound.

Before starting: POWER CONTROL at 0.5 W, MASTER at minimum, BOSS TONE STUDIO closed, Tanto quit, so that the new build
can be installed with `scripts/build-app.sh --install`.

1. Open Tanto and let it connect. Click another channel in the sidebar: within about half a second the knobs and the
   name show the new channel, and "Edited" does not appear.
2. Click through four channels quickly, then run through them with the arrow keys. Tanto ends on the last channel
   chosen, and the amp's channel LEDs agree.
3. Switch with a channel button on the amp: Tanto follows, as before.
4. Read only, by Claude: Tanto's log since step 1 holds no "no dump of channel … after selecting it" and no "no reply,
   retrying once".

### Results

| Item | Result |
|---|---|
| A switch shows the new channel within about half a second, without "Edited" | |
| Quick clicks and arrow keys end on the last channel; the amp agrees | |
| A channel button on the amp: Tanto follows | |
| Log: no fallback reads, no retries | |
