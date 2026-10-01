# Tanto Plan 4: Tone Studio's Layout, Native Look

**Goal:** the window arranges the controls as BOSS TONE STUDIO does, so that every knob lives where a Tone Studio user
expects it, but it is built from macOS's own controls and materials and looks like a current Mac app.

**Spec:** `docs/superpowers/specs/2026-10-01-tanto-design.md`, section 6, which this plan replaces for the window. The
safety rules of section 5 stay as they are: every control still goes through `EditorModel` and `SafetyGuard`.

**How:** a brief plan with a check per task, as `CLAUDE.md` asks for multi-step work. Test first where there is logic
(the generator), snapshot reviews for the views, one commit per task. Nothing is sent to the real amp; the user looks at
the result in hardware check 3 of plan 3.

**Not in 4:** the ASSIGN page and the system settings (later milestones), Tone Studio's own colours, images and fonts.

## The user's direction

- The arrangement follows Tone Studio: where the knobs live, the front panel, the pages.
- The look is Apple's: the system's window background and sidebar material, grouped containers, SF Symbols, light and
  dark mode.
- On/off is a macOS switch. What Tone Studio shows as a knob or dial is a macOS knob (`NSSlider` in its circular style).
- The colour buttons stay as they are.

## What Tone Studio shows

From its interface in demo mode and from `export/layout.div`:

- **Channel list** on the left. This is Tanto's sidebar already.
- **Front panel** across the top, in groups:
  - AMPLIFIER: VARIATION, AMP TYPE (a knob with five positions), GAIN, VOLUME;
  - EQUALIZER: BASS, MIDDLE, TREBLE;
  - EFFECTS: BOOSTER, MOD, FX, DELAY and REVERB, each a knob with its colour button above it;
  - CAB RESONANCE (a menu), PRESENCE;
  - SOLO, a switch and its level;
  - CONTOUR, a switch and its type.
- **Pages** below the panel, chosen with tabs: EFFECTS and CHAIN; BOOSTER, MOD, FX, DELAY, DELAY2, REVERB, SOLO,
  CONTOUR; PEDAL FX, EQ, EQ2, NS, SEND/RETURN, ASSIGN.
- **A page** has a header with the block's on/off button and its type menus, then dials (64 × 64 px) at fixed positions,
  usually in one or two rows. The graphic EQs use vertical sliders.
- **In `layout.div`**, every control has its position as `left` and `top` inside its frame, and its kind as a class:
  - `knob` (the panel) and `dial` (the pages);
  - `slider` (graphic EQ);
  - `select-box`;
  - `toggle-button`, `check-box`, `radio-button`.

## Tasks

### 1. Generator: control kind and position

- `control`, from the class of the parameter's first written control:
  - `knob` for Tone Studio's knobs and dials;
  - `slider`;
  - `switch`, `menu` or `segmented`.
- `position`: the control's place on its page, adding up `left` and `top` along its frames, in Tone Studio's pixels.
- `panel`: whether the control is on the front panel (ids starting `panel-`).

**Check:** generator tests:
- BOOSTER DRIVE is a knob at (34, 65) on its page;
- the panel's GAIN is a knob on the panel;
- the graphic EQ's bands are sliders;
- every written parameter has a kind and a position.

### 2. Native controls

- A knob: `NSSlider` in its circular style, through `NSViewRepresentable`, with the label and the value below it. A
  guarded knob stops at its ceiling and says "max 50" in its caption. As with today's sliders, a drag that Panic
  interrupted sends nothing more.
- A stepped knob with tick marks for AMP TYPE.
- A vertical slider for the graphic EQ bands.
- Switches, pop-up menus and segmented controls as SwiftUI provides them.

**Check:** builds without warnings; a snapshot of every kind against the simulated amp.

### 3. Front panel

The panel's groups in Tone Studio's order, each in a grouped container, always visible above the pages. The colour
buttons sit above their knobs.

**Check:** a snapshot review against the simulated amp.

### 4. Pages

- A segmented control chooses the page. ASSIGN is left out.
- A page shows its on/off switch and type menus in a header row.
- The other controls follow in rows by Tone Studio's `top`, ordered by its `left`, so they sit where Tone Studio has
  them while the row fits the window.
- Controls that the current effect type does not use stay hidden, as now.

**Check:** a snapshot review of every page against the simulated amp.

### 5. EFFECTS and CHAIN

- EFFECTS shows, per effect, the three colour assignments as menus next to coloured markers, as Tone Studio does.
- CHAIN shows the chain settings as menus.

**Check:** a snapshot review against the simulated amp.

### 6. Look

- The window background and the sidebar's material come from the system; the long list of sections goes.
- SF Symbols for the toolbar.
- Light and dark mode both work.
- Spec section 6 describes the new window.

**Check:** snapshots in light and dark mode, and the user reads spec section 6 through.

### 7. Review with the user

The user looks at the app during hardware check 3 of plan 3, and says what to change.

**Check:** the user's remarks recorded in `docs/hardware-checklist.md`, and changes made or planned.
