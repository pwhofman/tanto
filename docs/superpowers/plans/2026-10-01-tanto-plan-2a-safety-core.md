# Tanto Plan 2a: Safety Core

**Goal:** KatanaKit can write to the amp, and every write goes through `SafetyGuard`. This is proven by tests against the
simulated amp and by hardware check 2, run through the probe.

**Spec:** `docs/superpowers/specs/2026-10-01-tanto-design.md`, sections 3.5 and 5. Tanto writes exactly what Tone Studio
writes: the amp through the front-panel registers, effects through their detail parameters.

**How:** a brief plan with a check per task, as `CLAUDE.md` asks for multi-step work. Implementation happens directly in
the repository, test first, with one commit per task. Nothing is sent to the real amp before task 8.

**Not in 2a:** the SwiftUI app and the `.app` build (plan 2b), the librarian (plan 3).

## Tasks

### 1. Generator: map Tone Studio's controls to parameters

`tools/gen_parameter_map.py` also reads `export/item.json` and `export/layout.div` and adds, per parameter:

- `written`: a v1 control of Tone Studio writes it. The assignment pages are excluded, and so are display-only "watcher"
  controls.
- `kind`:
  - `text` for the name;
  - `switch` for two-valued parameters;
  - `picker` for select boxes, buttons, and ids containing TYPE, MODE, SELECT, POSITION or CHAIN;
  - `numeric` otherwise.
- `section`, `label`, `options` (picker values with labels, in menu order), `valueLabels` (labelled sliders), `format`
  (one of the nine display formats found in `layout.div`; an unknown format stops the generator) and `visibleWhen`
  (type parameter and type values).
- The MOD/FX layout applies to `Fx(1)` and `Fx(2)`, the DELAY layout to `Delay(1)` and `Delay(2)`.
- Guard rule: as before, plus the seven front-panel knobs, giving 217 guarded parameters.

**Check:** pytest against snippets and against the installed Tone Studio, with pinned counts and spot checks. These
cover: VOLUME knob written and guarded; amp parameters and FOOT VOLUME guarded but not written; AMP TYPE knob a picker;
booster SOLO SW a switch; T.WAH controls visible for MOD type 0 only. Also ruff and ty, and a per-section summary of the
regenerated table, reviewed by hand.

### 2. Parameter map v2 (Swift)

`ParameterMap` decodes the new fields. The parameter-level `written` replaces the block-level `editable`.

**Check:** `swift test` pins the same facts as task 1 on the Swift side.

### 3. Live mirror

`AmpSession` keeps a copy of the live patch. It applies every change the amp reports, including the channel number and
the full patch the amp sends after a channel switch, and publishes the result. The simulated amp learns what hardware
check 1 showed:

- a channel switch sends the channel number, then the patch in 241-byte messages;
- a write to the VOLUME knob register sets the amp volume one to one.

**Check:** tests for single changes, channel-switch dumps and malformed messages.

### 4. Write path

`AmpSession` gets a write method that only KatanaKit can call. It is not public, so the app can only write through
`SafetyGuard`. The method refuses parameters that are not `written`, out-of-range values and malformed encodings, and has
a priority lane that keeps the 20 ms spacing.

**Check:** tests prove that `60 00 00 28` (amp volume) and FOOT VOLUME are refused, that out-of-range values are
refused, and that priority messages go first while the spacing is kept.

### 5. `SafetyGuard`

An actor implementing spec section 5:

- the ceiling, with a settable fraction defaulting to 50 %;
- refusal of rises above the ceiling;
- decreases at once through the priority lane;
- ramps of one raw unit at least `2 s / (max − min)` apart;
- the soft switch for switches and pickers, refused while the VOLUME knob is above the ceiling;
- Panic, which clears the queue, cancels ramps and sends the VOLUME knob = 0 first;
- coalescing of quick successive requests;
- the channel check (stored values above the ceiling).

**Check:**

- one test per rule;
- a randomised test of thousands of random actions against the simulated amp, checked against invariants on the
  recorded messages:
  - no guarded value rises above its ceiling or faster than allowed;
  - nothing unwritten is written;
  - Panic's VOLUME = 0 is the next message after Panic;
  - soft switches have the dip, change, ramp shape.

### 6. Independent review

A separate review agent checks the guard and the write path against spec section 5. Every finding is fixed with a test.

**Check:** the review report, the fixes, and `swift test` passing.

### 7. Probe steps for hardware check 2

`TantoProbe --check2 STEP` runs one step per invocation through `SafetyGuard`, logging every message:

- `rename`: write a test name into the live patch, then read it back;
- `restore-name`: put the original name back;
- `lower`: lower the VOLUME knob by 10;
- `panic`;
- `ramp`: raise the VOLUME knob by 10, ramped and within the ceiling.

**Check:** the offline paths (usage, amp off) behave like plan 1's.

### 8. Hardware check 2, together with the user

POWER CONTROL at 0.5 W and MASTER at minimum. Every step is announced in chat and needs the user's OK. The audible part
(ramp and Panic) happens at a MASTER level the user chooses. Afterwards the user switches channel and back, which
restores the stored sound.

**Check:** results recorded in `docs/hardware-checklist.md` and committed.
