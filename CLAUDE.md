# Tanto

A macOS editor and librarian for the BOSS Katana-100 MkII. Design: `docs/superpowers/specs/2026-10-01-tanto-design.md`.
Plans: `docs/superpowers/plans/`. Hardware checks: `docs/hardware-checklist.md`.

## The amp must never get loud

- Develop and test against `SimulatedAmp`. Announce every interaction with the real amp to the user first.
- Anything beyond reads and the editor-mode flag needs the user's explicit OK in chat at that moment, with the amp's
  MASTER knob at minimum. First write tests are silent (renaming) or lower the volume.
- Do not loosen the volume guards of the design spec (section 5) unless the user asks.

## Commands

- Build and test: `swift build`, `swift test`.
- Format: `swift format --in-place --recursive Sources Tests Package.swift`; check with
  `swift format lint --recursive Sources Tests Package.swift`.
- Probe: `swift run TantoProbe` lists MIDI endpoints and sends nothing; `--connect` talks to the amp (hardware check 1).
- Parameter table: `uv run --directory tools python gen_parameter_map.py` regenerates
  `Sources/KatanaKit/Resources/parameters.json` from the installed Tone Studio. Checks: `uv run --directory tools pytest`,
  `uv run --directory tools ruff check`, `uv run --directory tools ty check`.

## Layout

- `Sources/KatanaKit`: protocol, state and safety logic. App and probe targets stay thin.
- `tools/gen_parameter_map.py` is Python on purpose: it holds the guard rule, and the user reads Python.
