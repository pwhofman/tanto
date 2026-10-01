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

| Item                                                                   | Result |
|------------------------------------------------------------------------|--------|
| MIDI sources and destinations                                          |        |
| Identity reply                                                         |        |
| Editor communication level and revision                                |        |
| Channel names match the amp                                            |        |
| PANEL values match the knobs (GAIN, VOLUME, BASS, MIDDLE, TREBLE, PRESENCE) |   |
| Amp VOLUME is `PRM_PREAMP_A_LEVEL` at `60 00 00 28`                    |        |
| Messages when turning a knob                                           |        |
| Messages when switching channels                                       |        |
| Messages when changing the booster colour                              |        |

## Check 2: first writes

Specified in plan 2: renaming the live patch, lowering amp VOLUME, Panic and one ramped increase, with MASTER at
minimum; then listening to the ramp and to Panic at a MASTER level the user chooses.

## Check 3: librarian

Specified in plan 3: after a verified backup, saving on the amp (WRITE) to see its notification, saving the live sound
to a channel the user chooses, renaming it, and restoring the backup.
