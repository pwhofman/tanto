# Tanto Plan 2b: Editor App

**Goal:** a double-clickable `Tanto.app` that connects to the amp by itself, shows the live patch section by section with
plain controls, and changes the sound only through `SafetyGuard`.

**Spec:** `docs/superpowers/specs/2026-10-01-tanto-design.md`, sections 4 to 6 and 8 to 10. Builds on plan 2a.

**How:** a brief plan with a check per task. Implementation happens directly in the repository, test first where there is
logic, with one commit per task. The real amp is only used in task 7.

**Not in 2b:** switching, saving, renaming and backing up channels (plan 3). The sidebar shows the channel names and the
current channel only.

## Tasks

### 1. Display text and visibility

`Parameter` gains `displayText(for:)` and `isVisible(in:)`.

- `displayText(for:)` uses, in this order: the option label, the value label, the display format, the plain number.
  Formats: `+3`, `+3dB`, `+1.5dB`, `320ms`, the value plus one, `2.5s`, `OFF` below zero, `50%`.
- `isVisible(in:)` holds when every `visibleWhen` condition holds for the given live values.

**Check:** tests with real parameters: a GEQ band shows `+1.5dB` and `-12.0dB`, the booster knob `OFF` at −1, booster
type 1 `CLEAN BOOST`, T.WAH PEAK is visible for MOD type 0 and hidden for type 1.

### 2. Editor model

A main-actor `@Observable` model between the views and KatanaKit:

- connection state (not connected, connecting, connected, failed with a reason);
- the live values, kept current from `AmpSession.updates`;
- the channel names and the current channel;
- the sections with their visible parameters;
- per control the last refusal message from `SafetyGuard`;
- the ceiling percentage.

Requests go to `SafetyGuard` and never directly to the session.

**Check:** tests against the simulated amp: a slider request updates the value; a refusal shows a message and the
control returns to the amp's value; Panic sets VOLUME to 0; a change reported by the amp shows up; hidden parameters
appear when the effect type changes.

### 3. Connection handling

- The model connects when a `KATANA` MIDI port appears, using CoreMIDI's setup notifications, and drops back to
  "not connected" when it disappears.
- After connecting, it reads the current channel, the channel names and the live patch, then switches editor mode off on
  quit.
- Reconnecting runs the same read-only sequence (spec, section 8).

**Check:** the logic is tested with a fake port watcher. Plugging and unplugging is checked on the real amp in task 7.

### 4. The window

SwiftUI, one window:

- a toolbar with the connection state, the current channel and a red Panic button (Esc);
- a sidebar with PANEL, A1–A4 and B1–B4 and their names;
- the editor: the patch name, then one section per editor section in the spec's order. Numeric parameters are sliders
  with their display text; switches are toggles; pickers are pop-up menus.
  - A guarded slider ends at the higher of its ceiling and its current value, and its label shows the ceiling.
  - A value above the ceiling is shown in orange.
  - A refusal appears under the control.

**Check:** the app builds without warnings; a screenshot review against the simulated amp, which the app can use through
a launch argument for development.

### 5. Settings

A Settings window (⌘,) with the ceiling percentage from 0 to 100 % in steps of 5. Raising it asks for confirmation;
lowering it does not.

**Check:** tests on the model: raising asks for confirmation, lowering does not, invalid values are impossible.

### 6. The app bundle

`scripts/build-app.sh` builds a release binary with SwiftPM and assembles `build/Tanto.app`:

- `Info.plist`;
- the parameter table in `Contents/Resources`, loaded with `ParameterMap(contentsOf:)` because SwiftPM's resource
  bundle is not found inside a hand-made app;
- a simple `.icns` icon made with `iconutil`;
- an ad-hoc signature.

`scripts/build-app.sh --install` also copies the app to `/Applications`, after showing what it replaces.

**Check:** the script runs clean, `codesign --verify` passes, and the app starts with a double click and shows "not
connected" while the amp is off.

### 7. Hardware check 2b, together with the user

POWER CONTROL at 0.5 W and MASTER at minimum.

1. Start the app, then switch the amp on: it connects by itself and shows the live patch, matching the knobs.
2. Lower VOLUME with the slider, try to raise it above the ceiling (refused), press Esc (Panic).
3. Switch an effect on and off: VOLUME dips and comes back.
4. Switch the amp off: the app shows "not connected".
5. Switch the amp on again: it reconnects.

The audible part, at a MASTER level the user chooses, repeats steps 2 and 3. Afterwards, switch channel and back.

**Check:** results recorded in `docs/hardware-checklist.md` and committed.

### 8. Panel buttons, after check 2b

Check 2b showed that Tone Studio presses the VARIATION and colour buttons instead of writing their LEDs (spec 3.5). The
user chose to add the presses, soft-switched like every other switch.

- `PanelButton`: the six buttons, their addresses `7F 01 01 00` to `05` and their LEDs.
- `AmpSession.press(_:)` sends `00` to the button's address, paced and with a basis like a write.
- `SafetyGuard.press(_:)`: VOLUME dips to 0, the press goes out, VOLUME comes back. The press is dropped if VOLUME or the
  button's LED changed on the amp meanwhile, and refused while VOLUME is above the ceiling.
- The window shows a VARIATION button in the Amp section and a colour button in each effect section, with the LED state
  the amp reports.
- `SimulatedAmp` moves an effect that is on to its next colour and toggles VARIATION.

**Check:** tests for the press message, the soft switch, its refusal, the simulated amp and the model; the randomized
test presses buttons and checks that every press goes out at VOLUME 0. On the amp: step 6 of check 2b.

