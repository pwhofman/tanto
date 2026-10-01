# Tanto Plan 2c: Fixes from the Safety Review

**Goal:** close what the independent review of plan 2a (task 6) found, before any hardware check writes more than a name.
The review found 4 critical, 6 major and 9 minor problems; it reproduced most of them with tests against
`SimulatedAmp`.

**Spec:** `docs/superpowers/specs/2026-10-01-tanto-design.md`, section 5. The fixes keep its rules; tasks 5 and 6 refine
the wording where the review showed gaps.

**How:** the review's tests come into the repository as failing regression tests, one per finding, and each task makes
its tests pass. One commit per task. Nothing is sent to the real amp.

## Principles

1. Panic is absolute. VOLUME 0 goes out before any queued message, a read that waits for its reply does not hold it up,
   and nothing decided before Panic is sent after it.
2. Writes are conditional. Each write carries the channel generation, the Panic epoch and the amp's report count for its
   parameter, and for a switch change also VOLUME's. The session checks them on its own actor right before sending and
   drops a write whose basis has changed.
3. A channel change makes the copy of the live patch invalid until the amp's dump has covered it, and ends all of the
   guard's work.
4. No guessing about crossed messages. When an amp report may have crossed a write of Tanto's, the guard waits until the
   parameter is quiet and reads it from the amp. Only if the amp then holds Tanto's value and the user's knob is lower
   does the guard write the knob's value, which is lower than Tanto's own last write.

## Tasks

### 1. Review tests

`Tests/KatanaKitTests/SafetyReviewTests.swift` with the review's scenarios, named after the findings, and the rig that
replays a channel switch with the timing of hardware check 1.

**Check:** the tests compile and fail for the reasons the review gives.

### 2. Session: send lane, conditional writes, Panic, channel generation

- The send slot is held only while a message goes out; a read waits for its reply outside it, one read at a time (M2).
- Three lanes: Panic, high (decreases), normal.
- `panic(volumeKnob:)` raises the Panic epoch and sends VOLUME 0 first; during connecting it is sent right after editor
  mode is switched on (M4).
- Conditional writes (principle 2).
- A channel change from the amp raises the generation and makes the copy invalid until every byte has been reported
  (C1).
- `readLivePatch` applies each block as its reply arrives and keeps bytes Tanto wrote after the request (C3).
- Reports count every byte of a parameter (m7) and keep their arrival time; connecting starts from a clean copy (m3).

**Check:** C3 and M2 tests; unit tests for each rule.

### 3. Guard: requests, Panic and stopping

- A request makes one call to the session, then changes the guard's state without suspending; a request that Panic
  overtook is refused (M1, M5, m8).
- Panic clears everything and treats VOLUME as 0 until its write is out, so no switch restores the old level (M3).
- A failed VOLUME write clears the pending restore and switches (m1).
- `stop()` ends a guard for good (M4).
- The initializer checks the table: VOLUME guarded, every guarded parameter with a range. The ramp duration and the
  session spacing come from the spec; tests set them through internal initializers (m4).

**Check:** M1, M3, M5, m1 tests.

### 4. Guard: channel changes and crossed messages

- A new generation resets the guard; requests are refused while the copy is invalid (C1).
- A request counts as a decrease only below everything the amp may hold: the copy and an unresolved write of Tanto's
  (C2).
- Principle 4 replaces today's immediate corrective write (C4).

**Check:** C1, C2 and C4 tests; the randomized test also turns knobs and switches channels on the amp, and checks at
the amp that no write raises a guarded value by more than one step or above its ceiling.

### 5. App

- `EditorModel` stops the old guard before it drops it, and Panic works while connecting (M4).
- A slider ignores its drag after Panic until the drag ends (M1).

**Check:** M4 and M1 tests through `EditorModel`.

### 6. Spec and checklist

- Section 5: the four principles; the remaining window of one message around a channel change made on the amp.
- Hardware check 2 asks whether the amp echoes Tanto's writes to `60 00 06 52` (m9).
- `Parameter.written` documents that renaming writes the name (m5).

**Check:** read through by the user.

### 7. Effect knobs and the limiter (decided by the user)

- M6: moving an effect knob across −1, its effect on or off, uses the soft switch of section 5.3. Switching on sets the
  knob to 0; a higher request then ramps from there.
- m6: rises of LIMITER THRESHOLD and falls of LIMITER RATIO are ramped like guarded increases, without a ceiling, because
  the limiter's LEVEL is already guarded. The table gets a field for the direction in which a parameter gets louder.
  TREMOLO DEPTH stays unguarded: lowering it fills in the dips but does not raise the peaks. The slicer has no depth
  parameter.
- m2: Panic stays as it is; section 5.5 says what it does not cover.

**Check:** tests for both directions of the effect-knob switch and for the limiter's ramps; generator tests for the new
field.
