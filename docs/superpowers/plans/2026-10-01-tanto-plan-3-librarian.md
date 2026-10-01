# Tanto Plan 3: Librarian

**Goal:** switch, save, rename, back up and restore channels from Tanto, with the checks of spec section 5.4. This is
proven against the simulated amp and in hardware check 3.

**Spec:** `docs/superpowers/specs/2026-10-01-tanto-design.md`, sections 5.4, 6, 7 and 8. Builds on plans 2a to 2c.

**How:** a brief plan with a check per task, as `CLAUDE.md` asks for multi-step work. Implementation happens directly in
the repository, test first where there is logic, with one commit per task. Nothing is sent to the real amp before task 7.

**Not in 3:** `.tsl` files, system settings and assignments, saving to PANEL (the amp saves to channels 1–8 only).

## What Tone Studio 2.1.0 does

From its JavaScript, so that Tanto sends the same messages:

- **Select:** a DT1 of `00 nn` to `7F 00 01 00` (`patch_controller.js`, `updateCurrentPatch`). It waits for nothing.
- **Save:** the WRITE dialog writes the name to the live patch (`60 00 00 00`), then sends `00 nn` to `7F 00 01 04`. It
  waits for the amp to send a DT1 to that same address, then selects channel n. When the amp reports a save made on the
  amp itself, Tone Studio reads the names again 500 ms later (`midi_observe_controller.js`).
- **Backup and restore** (`backup/all_data.js`): these read and write the stored channels directly at `10 0n 00 00`, block
  by block, in DT1s of at most 128 bytes, without pauses. At the end, a restore selects the channel saved in the backup.
  A stored channel has the live patch's layout: in `address_map.js`, `UserPatch(1)`–`(9)` and `Temporary` share `Patch`.
- **Not known yet:** whether the amp sends the channel number and its patch dump after a select that Tanto sends, what its
  save confirmation contains, and how it takes direct writes to a stored channel. Hardware check 3 answers these.

## Decisions for the user's review

1. **Reads when needed, no background cache.** Spec 7 reads all stored channels in the background after connecting.
   Instead:
   - Tanto reads the target channel right before a switch (about 0.5 s), so the ceiling check never uses old data.
   - It reads all channels when backing up.
   - The names are read when connecting, as now, and a channel's name again when the amp reports a save to it.
2. **Renaming** writes the 16 name bytes into the stored channel at `10 0n 00 00`, the way Tone Studio's restore writes
   stored channels. For the current channel it also writes the live name, so that the window and the amp agree. Tone
   Studio renames through WRITE, which also stores the live sound and could overwrite the channel's own.
3. **The backup file drops `revision`.** The amp does not answer the revision read (hardware check 1). The parameter
   table's block names and lengths describe the layout instead.
4. **Restore writes channels 1–8 and selects no channel afterwards**, as spec 5.4 says. Tone Studio restores PANEL too and
   then selects the saved channel.
5. **Saving** waits until the guard has finished its ramps, so that the channel stores what the window shows. After the
   amp confirms the save, Tanto selects that channel, as Tone Studio does. The sound does not change: the channel now
   holds the live sound.

## Tasks

### 1. Session and simulated amp: channel commands

- `select(_ slot:)`:
  - raises the generation and marks the copy of the live patch invalid at once, so `SafetyGuard` drops its work and no
    write decided before goes out;
  - sends the select;
  - reads back the channel number and the live patch, whether or not the amp also sends its dump.
- `savePatch(to slot:)` sends the WRITE command and waits up to 15 s for the amp's confirmation (spec 8).
- `writeStored(_:at:)` writes into a stored channel. It is limited to channels 1–8, to bytes inside the patch, and to 128
  bytes per message.
- A WRITE that the amp reports on its own becomes `LiveUpdate.patchSaved(slot)`.
- `SimulatedAmp`:
  - a select loads the stored channel and sends the channel number and the dump, as a channel button does;
  - a WRITE copies the live patch into the channel and sends the confirmation;
  - direct writes to stored channels are stored.

**Check:** unit tests for each command: the bytes sent, the generation after a select, the 15 s timeout, refused writes
outside channels 1–8, and the update for a save made on the amp.

### 2. Backup files

`ChannelBackup` (Codable) is spec 7's JSON without `revision`:

```json
{"format": 1, "model": "KATANA MkII", "created": "<ISO 8601>",
 "channels": [{"slot": 1, "name": "…", "blocks": {"Patch_0": "<hex>", …}}, …]}
```

Loading a file checks everything before anything can be written:

- the format and the model;
- slots 1–8, each exactly once;
- every block of the parameter table, at its exact length;
- the hex digits;
- the name characters.

Each failure has its own reason.

**Check:** a round-trip test, and one refusal test per check.

### 3. Librarian

`Librarian` (KatanaKit) uses the session and the guard:

- `read(slot)` reads a stored channel.
- `valuesAboveCeiling(slot)` lists the stored guarded values above the ceiling (`SafetyGuard.valuesAboveCeiling(in:)`).
- `select(slot)` switches channels.
- `save(to:)`:
  - waits for `SafetyGuard.settle()`;
  - saves with the confirmation;
  - selects the channel;
  - reads its name.

  Without a confirmation within 15 s, the error says so and the channel's name is read again (spec 8).
- `rename(slot, to:)` writes the stored name, and the live name for the current channel.
- `backup()` reads channels 1–8 into a `ChannelBackup`.
- `restore(_:)` writes channels 1–8 block by block, reads them back, and reports every difference. If the amp stops
  answering, the error names the last channel written.

**Check:** tests against `SimulatedAmp`:

- a backup, a restore and a second backup are byte for byte the same;
- a restore that fails halfway names its channel;
- a rename leaves the rest of the channel alone;
- a save stores what the guard was ramping towards.

### 4. Editor model

- `EditorModel` tracks unsaved edits: requests the guard accepted since the last channel load or save.
- Switching has two confirmations, which the window shows as dialogs, in this order:
  1. unsaved edits would be lost;
  2. stored values lie above the ceiling. This one lists them, and Cancel is the default.

  Without either, the switch happens at once.
- Save, rename, backup and restore show their results and errors as messages.
- A save that the amp reports re-reads that channel's name.

**Check:** model tests for both confirmations and their order, for a direct switch, and for the name update after a save
made on the amp.

### 5. Window

- Clicking a channel in the sidebar switches to it.
- The sidebar's context menu has "Save Live Sound Here…" and "Rename…" (channels 1–8).
- The File menu has "Back Up Channels…" and "Restore Channels…".
- Dialogs:
  - the two switch confirmations;
  - overwrite on save;
  - restore, listing the 8 names and asking for MASTER at minimum first;
  - results.

**Check:** the app builds without warnings, and a snapshot review against the simulated amp, dialogs included.

### 6. Spec and checklist

- Spec 7: the reads of decision 1 and the backup format of decision 3.
- Spec 5.1.2: direct writes to stored channels count as librarian writes.
- `docs/hardware-checklist.md` gets check 3 (task 7).

**Check:** read through by the user.

### 7. Hardware check 3, together with the user

POWER CONTROL at 0.5 W, MASTER at minimum, BOSS TONE STUDIO closed. The user picks a scratch channel whose sound may be
overwritten until the restore in step 6.

1. Back up all channels to a file. Tanto reads the file back and checks it before anything else is written.
2. Switch to B2 (VOLUME 88) from the sidebar. The dialog lists the values above the ceiling, and Cancel keeps the
   current channel. Then switch to a channel without such values: it switches at once. The log shows whether the amp
   sent its channel number and dump after the select.
3. Save the current channel onto itself on the amp. Tanto notices the save and reads the name again.
4. Change something small in Tanto, then "Save Live Sound Here…" on the scratch channel. The confirmation arrives.
5. Rename the scratch channel. The sidebar shows the new name, and after selecting the channel, so does the window.
6. Restore the backup. Tanto writes channels 1–8, reads them back and reports no difference. The scratch channel has its
   own name and sound again.

**Check:** results recorded in `docs/hardware-checklist.md` and committed.
