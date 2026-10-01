# Tanto Plan 1: Foundation and Read-Only Probe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build KatanaKit's tested protocol core and the read-only `TantoProbe` command, then run hardware check 1 on the real amp.

**Architecture:** One Swift package. The library `KatanaKit` holds the Roland SysEx protocol, the parameter table, a simulated amp and a paced `AmpSession` that can only read and switch the editor-mode flag; Swift Testing exercises it against the simulated amp. The executable `TantoProbe` runs hardware check 1. A Python generator in `tools/` extracts the parameter table, including the guard rule, from Tone Studio's `address_map.js`. Writing parameters is deliberately absent; it arrives in plan 2 together with `SafetyGuard`.

**Tech Stack:** Swift 6.4 (Xcode), SwiftPM, Swift Testing, CoreMIDI (Universal MIDI Packet API), Synchronization; Python 3.12+ with uv, pytest, ruff and ty for the generator.

---

## Before you start

- Spec: `docs/superpowers/specs/2026-10-01-tanto-design.md`, especially sections 3 (protocol facts), 4 (architecture) and 5
  (safety).
- Prerequisites: Xcode selected (`xcode-select -p` prints `/Applications/Xcode.app/Contents/Developer`); uv installed;
  BOSS TONE STUDIO for KATANA MkII 2.1.0 installed under `/Applications/BOSS/KATANA MkII/`, because the generator reads
  its `address_map.js`.
- **Safety: tasks 1–11 never talk to the amp.** Task 12 is done together with the user, who switches the amp on with
  MASTER at minimum. Do not send anything to the real amp outside task 12.
- Domain basics:
  - The amp is a memory map addressed with four 7-bit bytes; `60 00 00 28` is amp VOLUME in the live patch. `Address`
    stores an address as a linear integer with 7 bits per byte, so offsets can be added.
  - RQ1 requests bytes and the amp answers with a DT1; a DT1 from Tanto sets bytes. Both end with a Roland checksum.
  - The live patch starts at `60 00 00 00`, stored patch n at `10 0n 00 00` (0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4).
  - The address map uses only one-byte (`int1x7`) and two-byte (`int2x7`) values plus the 16-character patch name, so
    only those encodings are implemented.
- Run every command from the repository root. Commit after each task on `main`; the user pushes.
- Before each Swift commit, run `swift format --in-place --recursive Sources Tests Package.swift`.

## Not in this plan

`SafetyGuard`, parameter writes, the SwiftUI app, `build-app.sh`, plug/unplug handling and the librarian. Plans 2 (safety
and live editor) and 3 (librarian) are written after task 12, because they depend on what the amp reports in hardware
check 1.

## Files

| File | Responsibility |
|---|---|
| `tools/pyproject.toml` | uv project for the generator; ruff, ty and pytest settings |
| `tools/gen_parameter_map.py` | Extracts the patch layout and guard flags from Tone Studio's `address_map.js` |
| `tools/tests/test_gen_parameter_map.py` | Generator tests |
| `Sources/KatanaKit/Resources/parameters.json` | Generated table, committed |
| `Package.swift`, `.swift-format` | Package definition, formatter settings |
| `Sources/KatanaKit/Address.swift` | 7-bit addresses and the well-known addresses |
| `Sources/KatanaKit/SysEx.swift` | Identity, RQ1 and DT1 messages; checksum; parsing of incoming messages |
| `Sources/KatanaKit/ValueEncoding.swift` | Value encodings and the patch name |
| `Sources/KatanaKit/ParameterMap.swift` | Table model and lookups |
| `Sources/KatanaKit/UMP.swift` | MIDI 1.0 messages in Universal MIDI Packets |
| `Sources/KatanaKit/MIDITransport.swift` | Transport protocol |
| `Sources/KatanaKit/SimulatedAmp.swift` | In-memory amp for tests and development |
| `Sources/KatanaKit/LoggingTransport.swift` | Transport wrapper that reports every message |
| `Sources/KatanaKit/AmpSession.swift` | Connect sequence, paced reads with timeout and retry, change notifications |
| `Sources/KatanaKit/CoreMIDITransport.swift` | The real MIDI connection |
| `Sources/TantoProbe/main.swift` | Read-only hardware-check command |
| `Tests/KatanaKitTests/*Tests.swift` | One test file per KatanaKit component |
| `docs/hardware-checklist.md` | Procedures and results of the hardware checks |
| `CLAUDE.md` | Commands and safety rules for future sessions |

---

### Task 1: Parameter-table generator

The generator turns Tone Studio's `address_map.js` into `parameters.json`. It also applies the guard rule of spec
section 5.2, which marks the 210 parameters that can raise loudness.

**Files:**
- Create: `tools/pyproject.toml`
- Create: `tools/tests/test_gen_parameter_map.py`
- Create: `tools/gen_parameter_map.py`
- Create (generated): `Sources/KatanaKit/Resources/parameters.json`

- [ ] **Step 1: Create the uv project**

`tools/pyproject.toml`:

```toml
[project]
name = "tanto-tools"
version = "0.1.0"
description = "Developer tools for Tanto"
requires-python = ">=3.12"
dependencies = []

[tool.ruff]
line-length = 120
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "D"]

[tool.ruff.lint.pydocstyle]
convention = "google"

[tool.ruff.lint.per-file-ignores]
"tests/*" = ["D"]

[tool.pytest.ini_options]
pythonpath = ["."]
testpaths = ["tests"]

[dependency-groups]
dev = [
    "pytest>=9.1.1",
    "ruff>=0.16.9",
    "ty>=0.0.84",
]
```

- [ ] **Step 2: Write the failing tests**

`tools/tests/test_gen_parameter_map.py`:

```python
import json

import pytest

from gen_parameter_map import DEFAULT_SOURCE, Entry, build_table, is_guarded, linear, parse_size, render

SNIPPET = """
var prm_prop_patch_name = [
    { addr:0x00000000, size:16, ofs:0, init:'KATANA Mk2      ', min:32, max:125, name:'PATCH NAME' }, // PRM_PATCH_NAME0
];
var prm_prop_patch_0 = [
    { addr:0x00000000, size:INTEGER1x7, ofs:0, init:0, min:0, max:1, name:'SW' }, // PRM_ODDS_SW
    { addr:0x00000002, size:INTEGER1x7, ofs:0, init:50, min:0, max:120, name:'DRIVE' }, // PRM_ODDS_DRIVE
    { addr:0x00000003, size:INTEGER1x7, ofs:20, init:0, min:-20, max:20, name:'LOW GAIN' }, // PRM_EQ_LOW_GAIN
    { addr:0x00000004, size:(PADDING | 0x4), ofs:0, init:0, min:0, max:0, name:'' }, // (padding)
    { addr:0x0000007f, size:INTEGER2x7, ofs:0, init:400, min:1, max:2000, name:'TIME' }, // PRM_DLY_TIME
];
var prm_prop_status = [
    { addr:0x00000000, size:INTEGER1x7, ofs:0, init:50, min:0, max:100, name:'VOLUME' }, // PRM_KNOB_POS_VOLUME
];
var Patch = [
    { addr: 0x00000000, size: 0, child: prm_prop_patch_name, name: 'PatchName' },
    { addr: 0x00000010, size: 0, child: prm_prop_patch_0, name: 'Patch_0' },
    { addr: 0x00000650, size: 0, child: prm_prop_status, name: 'Status' },
];
"""


def entry(prm: str, name: str = "", minimum: int = 0, maximum: int = 100, encoding: str = "int1x7") -> Entry:
    return Entry(
        addr=0,
        byte_count=1,
        encoding=encoding,
        raw_offset=0,
        initial=0,
        minimum=minimum,
        maximum=maximum,
        name=name,
        prm=prm,
    )


def test_linear_matches_tone_studio_nibble() -> None:
    assert linear(0x60000000) == 0x60 << 21
    assert linear(0x00000152) == 128 + 0x52
    assert linear(0x00000561) == 737


def test_parse_size() -> None:
    assert parse_size("INTEGER1x7        ") == (1, "int1x7")
    assert parse_size("INTEGER2x7") == (2, "int2x7")
    assert parse_size("16                ") == (16, "ascii16")
    assert parse_size("(PADDING | 0x22)  ") == (0x22, None)
    with pytest.raises(ValueError, match="unsupported"):
        parse_size("INTEGER4x4")


def test_guard_rule() -> None:
    assert is_guarded(entry("PRM_PREAMP_A_LEVEL", "LEVEL"))
    assert is_guarded(entry("PRM_EQ_GEQ_BAND1", "31Hz", -24, 24))
    assert is_guarded(entry("PRM_FX1_DC30_ECHO_INTENSITY", "ECHO INTENSISTY"))
    assert is_guarded(entry("PRM_FX1_TWAH_PEAK", "PEAK"))
    assert not is_guarded(entry("PRM_PREAMP_A_BASS", "BASS"))
    assert not is_guarded(entry("PRM_FX1_DC30_CHORUS_INTENSITY", "CHORUS INTENSITY"))
    assert not is_guarded(entry("PRM_FXBOX_ASGN_BOOSTER_G", "BOOSTER GRN", 0, 25))
    assert not is_guarded(entry("PRM_CABINET_RESONANCE", "CABINET RESONANCE", 0, 2))
    assert not is_guarded(entry("PRM_ODDS_SW", "SW", 0, 1))
    assert not is_guarded(entry("PRM_DLY_LEVEL_TYPE", "TYPE", 0, 10))
    assert not is_guarded(entry("PRM_PATCH_NAME0", "PATCH NAME", 32, 125, "ascii16"))


def test_build_table_from_snippet() -> None:
    table = build_table(SNIPPET)
    assert table["blocks"] == [
        {"name": "PatchName", "offset": 0, "size": 16, "editable": True},
        {"name": "Patch_0", "offset": 16, "size": 129, "editable": True},
        {"name": "Status", "offset": 848, "size": 1, "editable": False},
    ]
    by_id = {p["prm"]: p for p in table["parameters"]}
    assert set(by_id) == {
        "PRM_PATCH_NAME0",
        "PRM_ODDS_SW",
        "PRM_ODDS_DRIVE",
        "PRM_EQ_LOW_GAIN",
        "PRM_DLY_TIME",
        "PRM_KNOB_POS_VOLUME",
    }
    assert by_id["PRM_PATCH_NAME0"]["initial"] is None
    assert by_id["PRM_ODDS_DRIVE"] == {
        "prm": "PRM_ODDS_DRIVE",
        "name": "DRIVE",
        "block": "Patch_0",
        "offset": 18,
        "encoding": "int1x7",
        "minimum": 0,
        "maximum": 120,
        "rawOffset": 0,
        "initial": 50,
        "guarded": True,
    }
    assert by_id["PRM_EQ_LOW_GAIN"]["rawOffset"] == 20
    assert by_id["PRM_DLY_TIME"]["offset"] == 16 + 127
    # Rows in blocks that v1 does not edit are never guarded.
    assert by_id["PRM_KNOB_POS_VOLUME"]["guarded"] is False


def test_render_is_valid_json_with_one_row_per_line() -> None:
    table = build_table(SNIPPET)
    text = render(table)
    assert json.loads(text) == table
    # Header and footer lines plus one line per block and per parameter.
    assert len(text.splitlines()) == 3 + len(table["blocks"]) + 2 + len(table["parameters"]) + 2


@pytest.mark.skipif(not DEFAULT_SOURCE.exists(), reason="Tone Studio is not installed")
def test_real_address_map() -> None:
    table = build_table(DEFAULT_SOURCE.read_text(encoding="utf-8"))
    assert len(table["blocks"]) == 31
    assert len(table["parameters"]) == 1465
    assert sum(1 for p in table["parameters"] if p["guarded"]) == 210
    by_key = {(p["block"], p["prm"]): p for p in table["parameters"]}
    assert by_key[("Patch_0", "PRM_PREAMP_A_LEVEL")]["offset"] == 0x28
    assert by_key[("Patch_1", "PRM_FOOT_VOLUME_VOL_LEVEL")]["offset"] == 737
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `uv run --directory tools pytest -q`
Expected: a collection error, `ModuleNotFoundError: No module named 'gen_parameter_map'`. The first run also creates
`tools/.venv` and `tools/uv.lock`.

- [ ] **Step 4: Write the generator**

`tools/gen_parameter_map.py`:

```python
"""Generate Tanto's parameter table from BOSS TONE STUDIO for KATANA MkII.

Reads ``js/config/address_map.js`` from an installed Tone Studio 2.1.0 and writes
``Sources/KatanaKit/Resources/parameters.json``. Only facts are taken over: addresses, encodings, ranges and names.
"""

from __future__ import annotations

import argparse
import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

logger = logging.getLogger(__name__)

DEFAULT_SOURCE = Path(
    "/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app"
    "/Contents/Resources/html/js/config/address_map.js"
)
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "Sources/KatanaKit/Resources/parameters.json"

_PROP_ARRAY = re.compile(r"var (prm_prop_\w+)\s*=\s*\[(.*?)\];", re.S)
_ENTRY = re.compile(
    r"\{\s*addr:(0x[0-9a-fA-F]+),\s*size:([^,]+),\s*ofs:(-?\d+)\s*,\s*init:('[^']*'|-?\d+)\s*,"
    r"\s*min:(-?\d+)\s*,\s*max:(-?\d+)\s*,\s*name:'([^']*)'\s*\},?[ \t]*(?://[ \t]*(PRM_\w+))?"
)
_PATCH_BLOCKS = re.compile(r"var Patch = \[(.*?)\];", re.S)
_BLOCK = re.compile(r"addr:\s*(0x[0-9A-Fa-f]+),\s*size:\s*0,\s*child:\s*(\w+),\s*name:\s*'([^']*)'")
_PADDING = re.compile(r"\(PADDING \| (0x[0-9a-fA-F]+)\)")
_GUARD = re.compile(r"LEVEL|VOLUME|GAIN|DRIVE|FEEDBACK|RESONANCE|SUSTAIN|DIRECT|GEQ_BAND|REGEN|ECHO_INTENSITY|PEAK")
_NOT_GUARDED = re.compile(r"FXBOX_|CABINET_RESONANCE")
_NOT_EDITABLE = re.compile(r"Status|Asgn")


class BlockRow(TypedDict):
    """A block of the patch layout; offsets and sizes are linear byte counts."""

    name: str
    offset: int
    size: int
    editable: bool


class ParameterRow(TypedDict):
    """A parameter of the patch layout; ``offset`` is linear and relative to the patch base."""

    prm: str
    name: str
    block: str
    offset: int
    encoding: str
    minimum: int
    maximum: int
    rawOffset: int
    initial: int | None
    guarded: bool


class Table(TypedDict):
    """The generated parameter table."""

    source: str
    blocks: list[BlockRow]
    parameters: list[ParameterRow]


@dataclass(frozen=True)
class Entry:
    """One row of an address-map property array.

    Attributes:
        addr: Address relative to the block, in packed form (four 7-bit bytes).
        byte_count: Number of bytes the row occupies.
        encoding: ``int1x7``, ``int2x7`` or ``ascii16``; ``None`` for padding.
        raw_offset: Tone Studio's ``ofs``; the raw value is the displayed value plus this offset.
        initial: Default displayed value; ``None`` for text.
        minimum: Smallest displayed value.
        maximum: Largest displayed value.
        name: Tone Studio's parameter name, possibly empty.
        prm: Tone Studio's internal id (``PRM_...``), possibly empty.
    """

    addr: int
    byte_count: int
    encoding: str | None
    raw_offset: int
    initial: int | None
    minimum: int
    maximum: int
    name: str
    prm: str


def linear(packed: int) -> int:
    """Converts a packed address to a linear integer, as Tone Studio's ``nibble()`` does.

    Args:
        packed: Address with four 7-bit bytes packed into one integer, e.g. ``0x60000028``.

    Returns:
        The address with 7 bits per byte, e.g. ``0x0C000028``.
    """
    return ((packed & 0x7F000000) >> 3) | ((packed & 0x7F0000) >> 2) | ((packed & 0x7F00) >> 1) | (packed & 0x7F)


def parse_size(size: str) -> tuple[int, str | None]:
    """Interprets the ``size`` field of an address-map row.

    Args:
        size: The field as written in ``address_map.js``, e.g. ``INTEGER1x7`` or ``(PADDING | 0x8)``.

    Returns:
        The number of bytes and the encoding name, or ``None`` as encoding for padding.

    Raises:
        ValueError: If the field uses an encoding Tanto does not support.
    """
    size = size.strip()
    if size == "INTEGER1x7":
        return 1, "int1x7"
    if size == "INTEGER2x7":
        return 2, "int2x7"
    if size == "16":
        return 16, "ascii16"
    padding = _PADDING.fullmatch(size)
    if padding is not None:
        return int(padding.group(1), 16), None
    raise ValueError(f"unsupported size field: {size!r}")


def parse_entries(array_body: str) -> list[Entry]:
    """Parses the rows of one ``prm_prop_*`` array.

    Args:
        array_body: Text between the brackets of the array.

    Returns:
        The rows in source order, padding included.
    """
    entries = []
    for addr, size, ofs, init, low, high, name, prm in _ENTRY.findall(array_body):
        byte_count, encoding = parse_size(size)
        entries.append(
            Entry(
                addr=int(addr, 16),
                byte_count=byte_count,
                encoding=encoding,
                raw_offset=int(ofs),
                initial=None if init.startswith("'") else int(init),
                minimum=int(low),
                maximum=int(high),
                name=name,
                prm=prm,
            )
        )
    return entries


def is_guarded(entry: Entry) -> bool:
    """Applies the guard rule of the design spec (section 5.2) to one row.

    Args:
        entry: The row to classify.

    Returns:
        Whether the row is a numeric parameter that can raise loudness.
    """
    numeric = (
        entry.encoding in ("int1x7", "int2x7")
        and entry.maximum - entry.minimum > 1
        and "TYPE" not in entry.prm
        and "SW" not in entry.prm.split("_")
    )
    return numeric and _GUARD.search(f"{entry.prm} {entry.name}") is not None and _NOT_GUARDED.search(entry.prm) is None


def build_table(source: str) -> Table:
    """Builds the parameter table for one patch from the text of ``address_map.js``.

    Args:
        source: Contents of ``address_map.js``.

    Returns:
        The blocks and parameters of a patch; offsets are linear and relative to the patch base.

    Raises:
        ValueError: If the patch block list is missing or refers to an unknown property array.
    """
    arrays = {name: parse_entries(body) for name, body in _PROP_ARRAY.findall(source)}
    patch = _PATCH_BLOCKS.search(source)
    if patch is None:
        raise ValueError("address map has no 'var Patch' block list")
    blocks: list[BlockRow] = []
    parameters: list[ParameterRow] = []
    for addr, child, block_name in _BLOCK.findall(patch.group(1)):
        if child not in arrays:
            raise ValueError(f"block {block_name} refers to unknown array {child}")
        entries = arrays[child]
        base = linear(int(addr, 16))
        editable = _NOT_EDITABLE.search(block_name) is None
        size = max(linear(e.addr) + e.byte_count for e in entries)
        blocks.append({"name": block_name, "offset": base, "size": size, "editable": editable})
        for e in entries:
            if e.encoding is None:
                continue
            parameters.append(
                {
                    "prm": e.prm,
                    "name": e.name,
                    "block": block_name,
                    "offset": base + linear(e.addr),
                    "encoding": e.encoding,
                    "minimum": e.minimum,
                    "maximum": e.maximum,
                    "rawOffset": e.raw_offset,
                    "initial": e.initial,
                    "guarded": editable and is_guarded(e),
                }
            )
    return {
        "source": "BOSS TONE STUDIO for KATANA MkII 2.1.0, js/config/address_map.js",
        "blocks": blocks,
        "parameters": parameters,
    }


def render(table: Table) -> str:
    """Formats the table as JSON with one block or parameter per line, for readable diffs.

    Args:
        table: Output of :func:`build_table`.

    Returns:
        The JSON text, ending with a newline.
    """
    lines = ["{", f' "source": {json.dumps(table["source"])},', ' "blocks": [']
    lines.append(",\n".join(f"  {json.dumps(b)}" for b in table["blocks"]))
    lines += [" ],", ' "parameters": [']
    lines.append(",\n".join(f"  {json.dumps(p)}" for p in table["parameters"]))
    lines += [" ]", "}"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> None:
    """Command-line entry point.

    Args:
        argv: Arguments without the program name; ``None`` uses ``sys.argv``.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE, help="path to Tone Studio's address_map.js")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="where to write parameters.json")
    args = parser.parse_args(argv)
    table = build_table(args.source.read_text(encoding="utf-8"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(table), encoding="utf-8")
    guarded = sum(1 for p in table["parameters"] if p["guarded"])
    logger.info("wrote %d parameters (%d guarded) to %s", len(table["parameters"]), guarded, args.output)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    main()
```

- [ ] **Step 5: Run the tests and checks**

Run: `uv run --directory tools pytest -q`
Expected: `6 passed`.

Run: `uv run --directory tools ruff format --check && uv run --directory tools ruff check && uv run --directory tools ty check`
Expected: `2 files already formatted`, then `All checks passed!` twice.

- [ ] **Step 6: Generate the table**

Run: `uv run --directory tools python gen_parameter_map.py`
Expected: `wrote 1465 parameters (210 guarded) to /Users/paulhofman/Documents/BossAmp/tanto/Sources/KatanaKit/Resources/parameters.json`

- [ ] **Step 7: Commit**

```bash
git add tools/pyproject.toml tools/uv.lock tools/gen_parameter_map.py tools/tests/test_gen_parameter_map.py Sources/KatanaKit/Resources/parameters.json
git commit -m "Add parameter-table generator and generated table"
```

---

### Task 2: Swift package and `Address`

**Files:**
- Create: `Package.swift`
- Create: `.swift-format`
- Create: `Tests/KatanaKitTests/AddressTests.swift`
- Create: `Sources/KatanaKit/Address.swift`

- [ ] **Step 1: Create the package and formatter settings**

`Package.swift` (the `TantoProbe` target is added in task 10):

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tanto",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "KatanaKit", resources: [.copy("Resources/parameters.json")]),
        .testTarget(name: "KatanaKitTests", dependencies: ["KatanaKit"]),
    ]
)
```

`.swift-format`:

`.swift-format`:

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 4 },
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeEachArgument": false
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/KatanaKitTests/AddressTests.swift`:

```swift
import Testing

@testable import KatanaKit

@Test func packedAndLinearFormsAgree() {
    let address = Address(packed: 0x6000_0028)
    #expect(address.linear == (0x60 << 21) + 0x28)
    #expect(address.bytes == [0x60, 0x00, 0x00, 0x28])
    #expect(address.description == "60 00 00 28")
    #expect(Address(bytes: [0x60, 0x00, 0x00, 0x28]) == address)
}

@Test func advancingCarriesAcrossSevenBitBytes() {
    #expect(Address(packed: 0x6000_007F).advanced(by: 1) == Address(packed: 0x6000_0100))
    #expect(Address.temporaryPatch.advanced(by: 737).description == "60 00 05 61")
}

@Test func wellKnownAddresses() {
    #expect(Address.currentPatchNumber.description == "00 01 00 00")
    #expect(Address.userPatch(0).description == "10 00 00 00")
    #expect(Address.userPatch(8).description == "10 08 00 00")
    #expect(Address.editorCommunicationMode.description == "7F 00 00 01")
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test`
Expected: SwiftPM stops with `public headers ("include") directory path for 'KatanaKit' is invalid`. KatanaKit has no
Swift file yet, so SwiftPM takes it for a C target.

- [ ] **Step 4: Implement `Address`**

`Sources/KatanaKit/Address.swift`:

```swift
import Foundation

/// A Katana memory address: four 7-bit bytes, as sent in RQ1 and DT1 messages.
///
/// The address is stored as a linear integer with 7 bits per byte (Tone Studio's `nibble()`), so byte offsets can be
/// added directly.
public struct Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The address as one integer with 7 bits per byte.
    public let linear: Int

    /// Creates an address from its linear value.
    ///
    /// - Parameter linear: A value in `0..<2^28`.
    public init(linear: Int) {
        precondition((0..<(1 << 28)).contains(linear), "address out of range: \(linear)")
        self.linear = linear
    }

    /// Creates an address from its four bytes packed into one integer, e.g. `0x6000_0028` for `60 00 00 28`.
    ///
    /// - Parameter packed: Four bytes, each below `0x80`.
    public init(packed: UInt32) {
        precondition(packed & 0x8080_8080 == 0, "address bytes must be 7-bit")
        let value =
            ((packed & 0x7F00_0000) >> 3) | ((packed & 0x007F_0000) >> 2) | ((packed & 0x0000_7F00) >> 1)
            | (packed & 0x0000_007F)
        self.init(linear: Int(value))
    }

    /// Creates an address from four SysEx bytes, most significant first.
    ///
    /// - Parameter bytes: Exactly four bytes, each below `0x80`.
    public init(bytes: some Collection<UInt8>) {
        precondition(bytes.count == 4 && bytes.allSatisfy { $0 < 0x80 }, "an address is four 7-bit bytes")
        self.init(linear: bytes.reduce(0) { ($0 << 7) | Int($1) })
    }

    /// The four SysEx bytes, most significant first.
    public var bytes: [UInt8] {
        [21, 14, 7, 0].map { UInt8((linear >> $0) & 0x7F) }
    }

    /// The address `count` bytes further on.
    ///
    /// - Parameter count: Number of bytes to move.
    /// - Returns: The new address.
    public func advanced(by count: Int) -> Address {
        Address(linear: linear + count)
    }

    public static func < (lhs: Address, rhs: Address) -> Bool {
        lhs.linear < rhs.linear
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension Address {
    /// The selected channel, two bytes: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    public static let currentPatchNumber = Address(packed: 0x0001_0000)
    /// The live (temporary) patch.
    public static let temporaryPatch = Address(packed: 0x6000_0000)
    /// Editor communication level, one byte.
    public static let editorCommunicationLevel = Address(packed: 0x7F00_0000)
    /// Editor communication mode: 1 = on, 0 = off.
    public static let editorCommunicationMode = Address(packed: 0x7F00_0001)
    /// Editor communication revision, one byte.
    public static let editorCommunicationRevision = Address(packed: 0x7F00_0003)

    /// The base address of stored patch `slot`.
    ///
    /// - Parameter slot: 0 = PANEL, 1–4 = A1–A4, 5–8 = B1–B4.
    /// - Returns: `10 0n 00 00` for slot n.
    public static func userPatch(_ slot: Int) -> Address {
        precondition((0...8).contains(slot), "slot must be in 0...8")
        return Address(packed: 0x1000_0000 | UInt32(slot) << 16)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: `Test run with 3 tests in 0 suites passed`.

- [ ] **Step 6: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Package.swift .swift-format Sources/KatanaKit/Address.swift Tests/KatanaKitTests/AddressTests.swift
git commit -m "Add Swift package and 7-bit addresses"
```

---

### Task 3: SysEx messages

**Files:**
- Create: `Tests/KatanaKitTests/SysExTests.swift`
- Create: `Sources/KatanaKit/SysEx.swift`

The expected bytes of the editor-mode messages match the commonly published Katana "editor mode" commands and follow
from the checksum rule.

- [ ] **Step 1: Write the failing tests**

`Tests/KatanaKitTests/SysExTests.swift`:

```swift
import Testing

@testable import KatanaKit

@Test func editorModeMessagesMatchKnownBytes() {
    #expect(
        SysEx.dt1(.editorCommunicationMode, data: [1]) == [
            0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33, 0x12, 0x7F, 0x00, 0x00, 0x01, 0x01, 0x7F, 0xF7,
        ])
    #expect(
        SysEx.dt1(.editorCommunicationMode, data: [0]) == [
            0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33, 0x12, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x00, 0xF7,
        ])
}

@Test func rq1ForTheLivePatchName() {
    #expect(
        SysEx.rq1(.temporaryPatch, size: 16) == [
            0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33, 0x11, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x10, 0xF7,
        ])
}

@Test func parsesDataSet() {
    let message = SysEx.dt1(Address(packed: 0x6000_0028), data: [42])
    #expect(IncomingMessage(message) == .dataSet(Address(packed: 0x6000_0028), [42]))
}

@Test func wrongChecksumIsMalformed() {
    var message = SysEx.dt1(.temporaryPatch, data: [1, 2, 3])
    message[message.count - 2] ^= 0x01
    #expect(IncomingMessage(message) == .malformed(message))
}

@Test func recognizesTheKatanaIdentityReply() {
    let reply: [UInt8] = [0xF0, 0x7E, 0x10, 0x06, 0x02, 0x41, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7]
    #expect(IncomingMessage(reply) == .identityReply(reply))
    #expect(SysEx.isKatanaIdentityReply(reply))
    var other = reply
    other[6] = 0x34
    #expect(!SysEx.isKatanaIdentityReply(other))
}

@Test func otherMessagesAreOther() {
    #expect(IncomingMessage([0xF0, 0x43, 0x10, 0xF7]) == .other([0xF0, 0x43, 0x10, 0xF7]))
    #expect(IncomingMessage(SysEx.identityRequest) == .other(SysEx.identityRequest))
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'SysEx' in scope`.

- [ ] **Step 3: Implement the messages**

`Sources/KatanaKit/SysEx.swift`:

```swift
/// Roland SysEx messages for the Katana MkII: device ID `10`, model ID `00 00 00 33`.
public enum SysEx {
    /// Universal identity request, addressed to any device.
    public static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]

    static let header: [UInt8] = [0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x33]
    static let rq1Command: UInt8 = 0x11
    static let dt1Command: UInt8 = 0x12

    /// The Roland checksum: the byte that makes the sum of `bytes` and the checksum a multiple of 128.
    ///
    /// - Parameter bytes: Address bytes followed by size or data bytes.
    /// - Returns: The checksum byte.
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return UInt8((128 - sum % 128) % 128)
    }

    /// A data request (RQ1).
    ///
    /// - Parameters:
    ///   - address: First address to read.
    ///   - size: Number of bytes to read.
    /// - Returns: The complete message.
    public static func rq1(_ address: Address, size: Int) -> [UInt8] {
        let body = address.bytes + Address(linear: size).bytes
        return header + [rq1Command] + body + [checksum(body), 0xF7]
    }

    /// A data set (DT1).
    ///
    /// - Parameters:
    ///   - address: First address to write.
    ///   - data: Bytes to write, each below `0x80`.
    /// - Returns: The complete message.
    public static func dt1(_ address: Address, data: [UInt8]) -> [UInt8] {
        precondition(!data.isEmpty && data.allSatisfy { $0 < 0x80 }, "DT1 data must be non-empty 7-bit bytes")
        let body = address.bytes + data
        return header + [dt1Command] + body + [checksum(body), 0xF7]
    }

    /// Whether `message` is a Katana MkII identity reply, by Tone Studio's check: bytes 0–1 are `F0 7E` and bytes 3–7
    /// are `06 02 41 33 03`.
    ///
    /// - Parameter message: A complete SysEx message.
    /// - Returns: `true` for a Katana MkII.
    public static func isKatanaIdentityReply(_ message: [UInt8]) -> Bool {
        message.count >= 8 && message[0...1] == [0xF0, 0x7E] && message[3...7] == [0x06, 0x02, 0x41, 0x33, 0x03]
    }
}

/// A SysEx message received from the amp.
public enum IncomingMessage: Equatable, Sendable {
    /// A reply to the identity request.
    case identityReply([UInt8])
    /// A DT1 from the Katana with a valid checksum: start address and data.
    case dataSet(Address, [UInt8])
    /// A message with the Katana's DT1 header but a wrong length, byte value or checksum.
    case malformed([UInt8])
    /// Anything else.
    case other([UInt8])

    /// Classifies one complete SysEx message.
    ///
    /// - Parameter message: Bytes from `F0` to `F7`.
    public init(_ message: [UInt8]) {
        if message.count >= 6, message[0] == 0xF0, message[1] == 0x7E, message[3] == 0x06, message[4] == 0x02 {
            self = .identityReply(message)
            return
        }
        let prefix = SysEx.header + [SysEx.dt1Command]
        guard message.starts(with: prefix) else {
            self = .other(message)
            return
        }
        // Prefix, four address bytes, at least one data byte, checksum and F7.
        guard message.count >= prefix.count + 7, message.last == 0xF7 else {
            self = .malformed(message)
            return
        }
        let body = Array(message[prefix.count..<(message.count - 2)])
        guard body.allSatisfy({ $0 < 0x80 }), SysEx.checksum(body) == message[message.count - 2] else {
            self = .malformed(message)
            return
        }
        self = .dataSet(Address(bytes: body.prefix(4)), Array(body.dropFirst(4)))
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: `Test run with 9 tests in 0 suites passed`.

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/SysEx.swift Tests/KatanaKitTests/SysExTests.swift
git commit -m "Add Roland SysEx messages and parsing"
```

---

### Task 4: Value encodings

**Files:**
- Create: `Tests/KatanaKitTests/ValueEncodingTests.swift`
- Create: `Sources/KatanaKit/ValueEncoding.swift`

Two-byte values are big-endian with 7 bits per byte, as in Tone Studio's `js/common/parameter.js`.

- [ ] **Step 1: Write the failing tests**

`Tests/KatanaKitTests/ValueEncodingTests.swift`:

```swift
import Testing

@testable import KatanaKit

@Test func oneByteValues() {
    #expect(ValueEncoding.int1x7.encode(100) == [100])
    #expect(ValueEncoding.int1x7.decode([100]) == 100)
}

@Test func twoByteValuesAreBigEndian() {
    #expect(ValueEncoding.int2x7.encode(400) == [0x03, 0x10])
    #expect(ValueEncoding.int2x7.decode([0x03, 0x10]) == 400)
}

@Test func patchNamesLoseTrailingSpaces() {
    #expect(PatchName.decode(Array("KATANA Mk2      ".utf8)) == "KATANA Mk2")
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'ValueEncoding' in scope`.

- [ ] **Step 3: Implement the encodings**

`Sources/KatanaKit/ValueEncoding.swift`:

```swift
/// How a parameter value is stored in the amp's memory.
public enum ValueEncoding: String, Codable, Sendable {
    /// One byte of 7 bits (Tone Studio's `INTEGER1x7`).
    case int1x7
    /// Two bytes of 7 bits, most significant first (`INTEGER2x7`).
    case int2x7
    /// Sixteen ASCII characters: the patch name.
    case ascii16

    /// Number of bytes a value occupies.
    public var byteCount: Int {
        switch self {
        case .int1x7: 1
        case .int2x7: 2
        case .ascii16: 16
        }
    }

    /// Decodes a raw numeric value.
    ///
    /// - Parameter bytes: Exactly `byteCount` bytes of a numeric encoding.
    /// - Returns: The raw value, before the parameter's `rawOffset` is subtracted.
    public func decode(_ bytes: some Collection<UInt8>) -> Int {
        precondition(self != .ascii16 && bytes.count == byteCount, "decode needs \(byteCount) bytes of a number")
        return bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    /// Encodes a raw numeric value.
    ///
    /// - Parameter raw: `0..<128` for `int1x7`, `0..<16384` for `int2x7`.
    /// - Returns: The bytes to store.
    public func encode(_ raw: Int) -> [UInt8] {
        switch self {
        case .int1x7:
            precondition((0..<128).contains(raw), "int1x7 value out of range: \(raw)")
            return [UInt8(raw)]
        case .int2x7:
            precondition((0..<16384).contains(raw), "int2x7 value out of range: \(raw)")
            return [UInt8(raw >> 7), UInt8(raw & 0x7F)]
        case .ascii16:
            preconditionFailure("ascii16 is not a number")
        }
    }
}

/// The 16-character patch name.
public enum PatchName {
    /// Decodes a stored name.
    ///
    /// - Parameter bytes: The 16 name bytes.
    /// - Returns: The name without trailing spaces.
    public static func decode(_ bytes: some Collection<UInt8>) -> String {
        var name = String(decoding: bytes.map { $0 & 0x7F }, as: UTF8.self)
        while name.last == " " {
            name.removeLast()
        }
        return name
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: `Test run with 12 tests in 0 suites passed`.

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/ValueEncoding.swift Tests/KatanaKitTests/ValueEncodingTests.swift
git commit -m "Add value encodings and patch names"
```

---

### Task 5: Parameter map

The tests pin the numbers from the spec: 210 guarded parameters, and Panic's two parameters at `60 00 00 28` and
`60 00 05 61`.

**Files:**
- Create: `Tests/KatanaKitTests/ParameterMapTests.swift`
- Create: `Sources/KatanaKit/ParameterMap.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/KatanaKitTests/ParameterMapTests.swift`:

```swift
import Testing

@testable import KatanaKit

@Test func bundledTableMatchesToneStudio() throws {
    let map = try ParameterMap.bundled()
    #expect(map.table.blocks.count == 31)
    #expect(map.table.parameters.count == 1465)
    #expect(map.patchSize == 1986)
}

@Test func guardedParametersMatchTheSpec() throws {
    let map = try ParameterMap.bundled()
    let editable = Set(map.table.blocks.filter(\.editable).map(\.name))
    let guarded = map.table.parameters.filter(\.guarded)
    #expect(guarded.count == 210)
    #expect(guarded.allSatisfy { editable.contains($0.block) })
}

@Test func panicParametersSitWhereTheSpecSays() throws {
    let map = try ParameterMap.bundled()
    let volume = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL"))
    let footVolume = try #require(map.parameter(block: "Patch_1", prm: "PRM_FOOT_VOLUME_VOL_LEVEL"))
    #expect(Address.temporaryPatch.advanced(by: volume.offset).description == "60 00 00 28")
    #expect(Address.temporaryPatch.advanced(by: footVolume.offset).description == "60 00 05 61")
    #expect(volume.guarded && footVolume.guarded)
}

@Test func parametersLieInsideTheirBlocksWithoutOverlap() throws {
    let map = try ParameterMap.bundled()
    let blocks = Dictionary(uniqueKeysWithValues: map.table.blocks.map { ($0.name, $0) })
    for parameter in map.table.parameters {
        let block = try #require(blocks[parameter.block])
        #expect(parameter.offset >= block.offset)
        #expect(parameter.offset + parameter.encoding.byteCount <= block.offset + block.size)
    }
    let sorted = map.table.parameters.sorted { $0.offset < $1.offset }
    for (first, second) in zip(sorted, sorted.dropFirst()) {
        #expect(first.offset + first.encoding.byteCount <= second.offset, "\(first.prm) overlaps \(second.prm)")
    }
}

@Test func valuesSubtractTheRawOffset() throws {
    let map = try ParameterMap.bundled()
    let lowGain = try #require(map.parameter(block: "Patch_0", prm: "PRM_EQ_LOW_GAIN"))
    #expect(lowGain.rawOffset == 20)
    #expect(map.values(in: [23], at: lowGain.offset) == [ParameterValue(parameter: lowGain, value: 3)])
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'ParameterMap' in scope`.

- [ ] **Step 3: Implement the map**

`Sources/KatanaKit/ParameterMap.swift`:

```swift
import Foundation

/// One block of the patch layout.
public struct ParameterBlock: Codable, Sendable, Hashable {
    /// Tone Studio's block name, e.g. `Patch_0` or `Fx(1)`.
    public let name: String
    /// Linear offset from the patch base.
    public let offset: Int
    /// Size in bytes.
    public let size: Int
    /// Whether v1 edits this block; status and controller-assignment blocks are read-only.
    public let editable: Bool
}

/// One parameter of the patch layout.
public struct Parameter: Codable, Sendable, Hashable {
    /// Tone Studio's internal id, e.g. `PRM_PREAMP_A_LEVEL`; empty for unnamed entries.
    public let prm: String
    /// Tone Studio's name, possibly empty.
    public let name: String
    /// Name of the block that contains the parameter.
    public let block: String
    /// Linear offset from the patch base.
    public let offset: Int
    /// How the value is stored.
    public let encoding: ValueEncoding
    /// Smallest displayed value.
    public let minimum: Int
    /// Largest displayed value.
    public let maximum: Int
    /// The stored (raw) value is the displayed value plus this offset.
    public let rawOffset: Int
    /// Tone Studio's default displayed value; `nil` for the patch name.
    public let initial: Int?
    /// Whether the parameter can raise loudness and falls under the safety ceiling (design spec, section 5.2).
    public let guarded: Bool

    /// Converts a raw value to the displayed value.
    ///
    /// - Parameter raw: Value as stored in the amp.
    /// - Returns: `raw - rawOffset`.
    public func value(fromRaw raw: Int) -> Int {
        raw - rawOffset
    }
}

/// The patch layout generated from Tone Studio by `tools/gen_parameter_map.py`.
public struct ParameterTable: Codable, Sendable, Hashable {
    /// Where the data came from.
    public let source: String
    /// Blocks in increasing offset order.
    public let blocks: [ParameterBlock]
    /// Parameters in increasing offset order.
    public let parameters: [Parameter]
}

/// A parameter together with a displayed value.
public struct ParameterValue: Equatable, Sendable {
    /// The parameter.
    public let parameter: Parameter
    /// The displayed value.
    public let value: Int
}

/// Lookups in a `ParameterTable`.
public struct ParameterMap: Sendable {
    /// The underlying table.
    public let table: ParameterTable
    private let byOffset: [Int: Parameter]

    /// Creates a map over `table`.
    ///
    /// - Parameter table: The patch layout.
    public init(_ table: ParameterTable) {
        self.table = table
        byOffset = Dictionary(table.parameters.map { ($0.offset, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Loads the table bundled with KatanaKit.
    ///
    /// - Returns: The map.
    /// - Throws: `CocoaError` if the resource is missing, `DecodingError` if it is invalid.
    public static func bundled() throws -> ParameterMap {
        guard let url = Bundle.module.url(forResource: "parameters", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ParameterMap(try JSONDecoder().decode(ParameterTable.self, from: Data(contentsOf: url)))
    }

    /// Size of a patch in bytes, up to the end of its last block.
    public var patchSize: Int {
        table.blocks.map { $0.offset + $0.size }.max() ?? 0
    }

    /// The parameter that starts at `offset`.
    ///
    /// - Parameter offset: Linear offset from the patch base.
    /// - Returns: The parameter, or `nil` if none starts there.
    public func parameter(atOffset offset: Int) -> Parameter? {
        byOffset[offset]
    }

    /// The parameter with Tone Studio id `prm` in `block`.
    ///
    /// - Parameters:
    ///   - block: Block name, e.g. `Patch_0`.
    ///   - prm: Tone Studio id, e.g. `PRM_PREAMP_A_LEVEL`.
    /// - Returns: The parameter, or `nil` if there is none.
    public func parameter(block: String, prm: String) -> Parameter? {
        table.parameters.first { $0.block == block && $0.prm == prm }
    }

    /// Decodes the numeric parameters that lie completely inside `data`.
    ///
    /// - Parameters:
    ///   - data: Bytes read from a patch.
    ///   - offset: Linear offset of the first byte from the patch base.
    /// - Returns: Each parameter with its displayed value, in offset order.
    public func values(in data: [UInt8], at offset: Int) -> [ParameterValue] {
        table.parameters.compactMap { parameter in
            let start = parameter.offset - offset
            guard parameter.encoding != .ascii16, start >= 0, start + parameter.encoding.byteCount <= data.count else {
                return nil
            }
            let raw = parameter.encoding.decode(data[start..<(start + parameter.encoding.byteCount)])
            return ParameterValue(parameter: parameter, value: parameter.value(fromRaw: raw))
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: `Test run with 17 tests in 0 suites passed`.

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/ParameterMap.swift Tests/KatanaKitTests/ParameterMapTests.swift
git commit -m "Add parameter map over the generated table"
```

---

### Task 6: Universal MIDI Packets

CoreMIDI's current API carries MIDI 1.0 messages as Universal MIDI Packets. SysEx travels in 64-bit SysEx7 packets of up
to six bytes; channel messages such as Program Change travel in 32-bit packets. The amp may announce a channel switch
with a Program Change, so the decoder keeps channel messages too.

**Files:**
- Create: `Tests/KatanaKitTests/UMPTests.swift`
- Create: `Sources/KatanaKit/UMP.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/KatanaKitTests/UMPTests.swift`:

```swift
import Testing

@testable import KatanaKit

@Test(arguments: [0, 1, 5, 6, 7, 12, 13, 150])
func sysExSurvivesARoundTrip(length: Int) {
    let message: [UInt8] = [0xF0] + (0..<length).map { UInt8($0 % 128) } + [0xF7]
    var decoder = UMPDecoder()
    #expect(decoder.decode(UMP.sysEx7Packets(for: message).flatMap { $0 }) == [message])
}

@Test func messagesMaySpanSeveralPackets() {
    let message = SysEx.dt1(.temporaryPatch, data: Array(repeating: 7, count: 40))
    let packets = UMP.sysEx7Packets(for: message)
    var decoder = UMPDecoder()
    #expect(decoder.decode(packets[0] + packets[1]) == [])
    #expect(decoder.decode(packets.dropFirst(2).flatMap { $0 }) == [message])
}

@Test func channelMessagesAreDecoded() {
    var decoder = UMPDecoder()
    #expect(decoder.decode([0x20C0_0500]) == [[0xC0, 0x05]])  // Program Change 5 on channel 1
    #expect(decoder.decode([0x2090_3C64]) == [[0x90, 0x3C, 0x64]])  // Note On
}

@Test func otherMessageTypesAreSkippedBetweenSysExPackets() {
    let message = SysEx.dt1(.temporaryPatch, data: [1, 2, 3])
    var words = UMP.sysEx7Packets(for: message).flatMap { $0 }
    words.insert(0x10F8_0000, at: 2)  // System Real Time: timing clock, one word
    var decoder = UMPDecoder()
    #expect(decoder.decode(words) == [message])
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'UMPDecoder' in scope`.

- [ ] **Step 3: Implement packing and decoding**

`Sources/KatanaKit/UMP.swift`:

```swift
/// MIDI 1.0 messages in Universal MIDI Packets (UMP), the format of CoreMIDI's current API.
///
/// A SysEx message travels as 64-bit SysEx7 packets (UMP message type 3), each carrying up to six data bytes without
/// the `F0` and `F7` framing. Channel messages such as Program Change travel as 32-bit packets (message type 2).
public enum UMP {
    /// Splits a SysEx message into SysEx7 packets.
    ///
    /// - Parameters:
    ///   - message: A complete message from `F0` to `F7`.
    ///   - group: UMP group, 0–15.
    /// - Returns: Packets of two 32-bit words each.
    public static func sysEx7Packets(for message: [UInt8], group: UInt8 = 0) -> [[UInt32]] {
        precondition(message.first == 0xF0 && message.last == 0xF7, "a SysEx message runs from F0 to F7")
        let payload = Array(message.dropFirst().dropLast())
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        return chunks.enumerated().map { index, chunk in
            let status: UInt32 =
                if chunks.count == 1 { 0 }  // complete in one packet
                else if index == 0 { 1 }  // start
                else if index == chunks.count - 1 { 3 }  // end
                else { 2 }  // continue
            let b = chunk + Array(repeating: 0, count: 6 - chunk.count)
            let word0 =
                (0x3 << 28) | (UInt32(group & 0xF) << 24) | (status << 20) | (UInt32(chunk.count) << 16)
                | (UInt32(b[0]) << 8) | UInt32(b[1])
            let word1 = (UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5])
            return [word0, word1]
        }
    }
}

/// Turns a stream of UMP words back into MIDI 1.0 messages: SysEx from `F0` to `F7`, and channel messages of two or
/// three bytes. Other UMP message types are skipped.
public struct UMPDecoder: Sendable {
    private var sysEx: [UInt8]?

    /// Creates a decoder with no message in progress.
    public init() {}

    /// Decodes the words of one received packet.
    ///
    /// - Parameter words: UMP words in arrival order.
    /// - Returns: The messages completed by these words.
    public mutating func decode(_ words: [UInt32]) -> [[UInt8]] {
        // Message size in words for each UMP message type (the top four bits of the first word).
        let sizes = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        var messages: [[UInt8]] = []
        var index = 0
        while index < words.count {
            let word0 = words[index]
            let type = Int(word0 >> 28)
            if type == 0x2 {
                let status = UInt8((word0 >> 16) & 0xFF)
                let data = [UInt8((word0 >> 8) & 0x7F), UInt8(word0 & 0x7F)]
                // Program Change (Cn) and Channel Pressure (Dn) carry one data byte, the others two.
                messages.append([status] + data.prefix(status & 0xE0 == 0xC0 ? 1 : 2))
            } else if type == 0x3, index + 1 < words.count {
                if let message = sysEx7(word0, words[index + 1]) {
                    messages.append(message)
                }
            }
            index += sizes[type]
        }
        return messages
    }

    private mutating func sysEx7(_ word0: UInt32, _ word1: UInt32) -> [UInt8]? {
        let all: [UInt8] = [
            UInt8((word0 >> 8) & 0xFF), UInt8(word0 & 0xFF), UInt8(word1 >> 24), UInt8((word1 >> 16) & 0xFF),
            UInt8((word1 >> 8) & 0xFF), UInt8(word1 & 0xFF),
        ]
        let bytes = Array(all.prefix(min(Int((word0 >> 16) & 0xF), 6)))
        switch (word0 >> 20) & 0xF {
        case 0:
            sysEx = nil
            return [0xF0] + bytes + [0xF7]
        case 1:
            sysEx = bytes
        case 2:
            sysEx?.append(contentsOf: bytes)
        case 3:
            defer { sysEx = nil }
            if let start = sysEx {
                return [0xF0] + start + bytes + [0xF7]
            }
        default:
            break
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: `Test run with 21 tests in 0 suites passed`.

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/UMP.swift Tests/KatanaKitTests/UMPTests.swift
git commit -m "Add Universal MIDI Packet encoding and decoding"
```

---

### Task 7: Transport protocol and simulated amp

**Files:**
- Create: `Sources/KatanaKit/MIDITransport.swift`
- Create: `Tests/KatanaKitTests/SimulatedAmpTests.swift`
- Create: `Sources/KatanaKit/SimulatedAmp.swift`

- [ ] **Step 1: Add the transport protocol**

`Sources/KatanaKit/MIDITransport.swift`:

```swift
/// Moves MIDI messages between Tanto and an amp.
public protocol MIDITransport: Sendable {
    /// Complete messages from the amp: SysEx from `F0` to `F7`, and channel messages of two or three bytes. Only one
    /// consumer may iterate the stream.
    var incoming: AsyncStream<[UInt8]> { get }

    /// Sends one complete SysEx message.
    ///
    /// - Parameter message: Bytes from `F0` to `F7`.
    /// - Throws: An error from the underlying MIDI system.
    func send(_ message: [UInt8]) throws
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/KatanaKitTests/SimulatedAmpTests.swift`:

```swift
import Testing

@testable import KatanaKit

@Test func answersReadsWithInitialValues() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let volume = try #require(map.parameter(block: "Patch_0", prm: "PRM_PREAMP_A_LEVEL"))
    let address = Address.temporaryPatch.advanced(by: volume.offset)
    try amp.send(SysEx.rq1(address, size: 1))
    var replies = amp.incoming.makeAsyncIterator()
    #expect(await replies.next() == SysEx.dt1(address, data: [50]))
}

@Test func storesWrites() throws {
    let amp = SimulatedAmp(map: try .bundled())
    try amp.send(SysEx.dt1(.userPatch(3), data: [0x41, 0x42]))
    #expect(amp.memory(at: .userPatch(3), count: 2) == [0x41, 0x42])
}

@Test func storedPatchesHaveNames() throws {
    let amp = SimulatedAmp(map: try .bundled())
    #expect(PatchName.decode(amp.memory(at: .userPatch(1), count: 16)) == "SIM PATCH 1")
    #expect(PatchName.decode(amp.memory(at: .temporaryPatch, count: 16)) == "SIM LIVE")
}

@Test func changesOnTheAmpAreSentAsDataSets() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let address = Address.temporaryPatch.advanced(by: 0x28)
    amp.changeOnAmp([42], at: address)
    var messages = amp.incoming.makeAsyncIterator()
    #expect(await messages.next() == SysEx.dt1(address, data: [42]))
    #expect(amp.memory(at: address, count: 1) == [42])
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'SimulatedAmp' in scope`.

- [ ] **Step 4: Implement the simulated amp**

`Sources/KatanaKit/SimulatedAmp.swift`:

```swift
import Foundation
import Synchronization

/// An in-memory Katana MkII for tests and for development while the amp is off.
///
/// It answers identity requests and RQ1 reads from its memory, stores DT1 writes, and records every message it
/// receives with its arrival time.
public final class SimulatedAmp: MIDITransport {
    /// A message the simulated amp received.
    public struct Received: Sendable {
        /// The message.
        public let message: [UInt8]
        /// When it arrived.
        public let time: ContinuousClock.Instant
    }

    /// The default reply to an identity request; passes Tone Studio's Katana MkII check.
    public static let katanaIdentityReply: [UInt8] = [
        0xF0, 0x7E, 0x10, 0x06, 0x02, 0x41, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF7,
    ]

    public let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let state: Mutex<State>

    private struct State {
        var memory: [Int: UInt8]
        var received: [Received] = []
        var answersReads = true
        let identityReply: [UInt8]
    }

    /// Creates a simulated amp whose nine stored patches and live patch hold the table's initial values.
    ///
    /// Stored patches are named `SIM PATCH 0` to `SIM PATCH 8`, the live patch `SIM LIVE`. The current channel is A1,
    /// the editor communication level 8 and the revision 1.
    ///
    /// - Parameters:
    ///   - map: Layout used to fill the patches.
    ///   - identityReply: Reply to identity requests.
    public init(map: ParameterMap, identityReply: [UInt8] = SimulatedAmp.katanaIdentityReply) {
        (incoming, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        var memory: [Int: UInt8] = [:]
        let patches =
            (0...8).map { (Address.userPatch($0), "SIM PATCH \($0)") } + [(Address.temporaryPatch, "SIM LIVE")]
        for (base, name) in patches {
            for parameter in map.table.parameters {
                let bytes =
                    if let initial = parameter.initial {
                        parameter.encoding.encode(initial + parameter.rawOffset)
                    } else {
                        Array(name.padding(toLength: 16, withPad: " ", startingAt: 0).utf8)
                    }
                for (index, byte) in bytes.enumerated() {
                    memory[base.linear + parameter.offset + index] = byte
                }
            }
        }
        memory[Address.currentPatchNumber.linear] = 0
        memory[Address.currentPatchNumber.linear + 1] = 1
        memory[Address.editorCommunicationLevel.linear] = 8
        memory[Address.editorCommunicationRevision.linear] = 1
        state = Mutex(State(memory: memory, identityReply: identityReply))
    }

    /// Handles a message from Tanto as the amp would.
    ///
    /// - Parameter message: A complete SysEx message.
    public func send(_ message: [UInt8]) throws {
        let now = ContinuousClock.now
        let reply: [UInt8]? = state.withLock { state in
            state.received.append(Received(message: message, time: now))
            if message == SysEx.identityRequest {
                return state.identityReply
            }
            if let (address, size) = Self.parseRQ1(message) {
                guard state.answersReads else { return nil }
                let data = (0..<size).map { state.memory[address.linear + $0] ?? 0 }
                return SysEx.dt1(address, data: data)
            }
            if case .dataSet(let address, let data) = IncomingMessage(message) {
                for (index, byte) in data.enumerated() {
                    state.memory[address.linear + index] = byte
                }
            }
            return nil
        }
        if let reply {
            continuation.yield(reply)
        }
    }

    /// Every message received so far, oldest first.
    public var received: [Received] {
        state.withLock { $0.received }
    }

    /// Reads simulated memory; unset bytes read as 0.
    ///
    /// - Parameters:
    ///   - address: First address.
    ///   - count: Number of bytes.
    /// - Returns: The bytes.
    public func memory(at address: Address, count: Int) -> [UInt8] {
        state.withLock { state in (0..<count).map { state.memory[address.linear + $0] ?? 0 } }
    }

    /// Simulates a change made on the amp itself: stores `bytes` and sends them to Tanto as a DT1.
    ///
    /// - Parameters:
    ///   - bytes: New memory content, each byte below `0x80`.
    ///   - address: Where the change starts.
    public func changeOnAmp(_ bytes: [UInt8], at address: Address) {
        state.withLock { state in
            for (index, byte) in bytes.enumerated() {
                state.memory[address.linear + index] = byte
            }
        }
        continuation.yield(SysEx.dt1(address, data: bytes))
    }

    /// Stops or resumes answering RQ1 reads, to test timeouts.
    ///
    /// - Parameter answers: Whether reads get a reply.
    public func setAnswersReads(_ answers: Bool) {
        state.withLock { $0.answersReads = answers }
    }

    static func parseRQ1(_ message: [UInt8]) -> (Address, Int)? {
        let prefix = SysEx.header + [SysEx.rq1Command]
        guard message.count == prefix.count + 10, message.starts(with: prefix), message.last == 0xF7 else {
            return nil
        }
        let body = Array(message[prefix.count..<(prefix.count + 8)])
        guard body.allSatisfy({ $0 < 0x80 }), SysEx.checksum(body) == message[prefix.count + 8] else { return nil }
        return (Address(bytes: body.prefix(4)), Address(bytes: body.suffix(4)).linear)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: `Test run with 25 tests in 0 suites passed`.

- [ ] **Step 6: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/MIDITransport.swift Sources/KatanaKit/SimulatedAmp.swift Tests/KatanaKitTests/SimulatedAmpTests.swift
git commit -m "Add transport protocol and simulated amp"
```

---

### Task 8: Logging transport

**Files:**
- Create: `Tests/KatanaKitTests/LoggingTransportTests.swift`
- Create: `Sources/KatanaKit/LoggingTransport.swift`

- [ ] **Step 1: Write the failing test**

`Tests/KatanaKitTests/LoggingTransportTests.swift`:

```swift
import Synchronization
import Testing

@testable import KatanaKit

@Test func logsBothDirections() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let log = Mutex<[(LoggingTransport.Direction, [UInt8])]>([])
    let transport = LoggingTransport(wrapping: amp) { direction, message in
        log.withLock { $0.append((direction, message)) }
    }
    try transport.send(SysEx.identityRequest)
    var replies = transport.incoming.makeAsyncIterator()
    #expect(await replies.next() == SimulatedAmp.katanaIdentityReply)
    let entries = log.withLock { $0 }
    #expect(entries.map { $0.0 } == [.sent, .received])
    #expect(entries.map { $0.1 } == [SysEx.identityRequest, SimulatedAmp.katanaIdentityReply])
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'LoggingTransport' in scope`.

- [ ] **Step 3: Implement the wrapper**

`Sources/KatanaKit/LoggingTransport.swift`:

```swift
/// Wraps a transport and reports every message in both directions, e.g. to write a transcript.
public final class LoggingTransport: MIDITransport {
    /// Direction of a logged message.
    public enum Direction: Sendable {
        /// From Tanto to the amp.
        case sent
        /// From the amp to Tanto.
        case received
    }

    public let incoming: AsyncStream<[UInt8]>
    private let base: any MIDITransport
    private let log: @Sendable (Direction, [UInt8]) -> Void
    private let forwarder: Task<Void, Never>

    /// Wraps `base`.
    ///
    /// - Parameters:
    ///   - base: The transport that does the work.
    ///   - log: Called for every message; must be safe to call from any thread.
    public init(wrapping base: any MIDITransport, log: @escaping @Sendable (Direction, [UInt8]) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        incoming = stream
        self.base = base
        self.log = log
        forwarder = Task {
            for await message in base.incoming {
                log(.received, message)
                continuation.yield(message)
            }
            continuation.finish()
        }
    }

    deinit {
        forwarder.cancel()
    }

    public func send(_ message: [UInt8]) throws {
        log(.sent, message)
        try base.send(message)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: `Test run with 26 tests in 0 suites passed`.

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/LoggingTransport.swift Tests/KatanaKitTests/LoggingTransportTests.swift
git commit -m "Add logging transport"
```

---

### Task 9: Amp session

`AmpSession` is an actor. A first-come, first-served lock keeps one message in flight, every message waits until 20 ms
after the previous one, and a read gets one retry after a 3 s timeout. It offers no way to write parameters: the only
DT1 it sends is the editor-mode flag. The last test checks exactly that over the probe's whole sequence.

**Files:**
- Create: `Tests/KatanaKitTests/AmpSessionTests.swift`
- Create: `Sources/KatanaKit/AmpSession.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/KatanaKitTests/AmpSessionTests.swift`:

```swift
import Testing

@testable import KatanaKit

private let quickTimeout = SessionTiming(spacing: .milliseconds(20), readTimeout: .milliseconds(100))

@Test func connectSendsToneStudiosSequence() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let info = try await AmpSession(transport: amp).connect()
    #expect(info.identityReply == SimulatedAmp.katanaIdentityReply)
    #expect(info.communicationLevel == 8)
    #expect(info.communicationRevision == 1)
    #expect(
        amp.received.map(\.message) == [
            SysEx.identityRequest,
            SysEx.rq1(.editorCommunicationLevel, size: 1),
            SysEx.dt1(.editorCommunicationMode, data: [1]),
            SysEx.rq1(.editorCommunicationRevision, size: 1),
        ])
}

@Test func connectRejectsOtherDevices() async throws {
    var reply = SimulatedAmp.katanaIdentityReply
    reply[6] = 0x34
    let amp = SimulatedAmp(map: try .bundled(), identityReply: reply)
    await #expect(throws: AmpError.notAKatana(reply)) {
        try await AmpSession(transport: amp).connect()
    }
    #expect(amp.received.map(\.message) == [SysEx.identityRequest])
}

@Test func readsAreSplitIntoRequestsOf128Bytes() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let start = Address.temporaryPatch.advanced(by: 128)
    let data = try await AmpSession(transport: amp).read(start, size: 300)
    #expect(data == amp.memory(at: start, count: 300))
    #expect(
        amp.received.map(\.message) == [
            SysEx.rq1(start, size: 128),
            SysEx.rq1(start.advanced(by: 128), size: 128),
            SysEx.rq1(start.advanced(by: 256), size: 44),
        ])
}

@Test func messagesAreAtLeast20MillisecondsApart() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    _ = try await session.read(.temporaryPatch, size: 300)
    let times = amp.received.map(\.time)
    #expect(times.count == 7)
    for (earlier, later) in zip(times, times.dropFirst()) {
        #expect(later - earlier >= .milliseconds(20))
    }
}

@Test func readsGiveUpAfterOneRetry() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    amp.setAnswersReads(false)
    let session = AmpSession(transport: amp, timing: quickTimeout)
    await #expect(throws: AmpError.timeout(.temporaryPatch)) {
        try await session.read(.temporaryPatch, size: 16)
    }
    #expect(amp.received.map(\.message) == Array(repeating: SysEx.rq1(.temporaryPatch, size: 16), count: 2))
}

@Test func changesMadeOnTheAmpAreReported() async throws {
    let amp = SimulatedAmp(map: try .bundled())
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    let volume = Address.temporaryPatch.advanced(by: 0x28)
    amp.changeOnAmp([42], at: volume)
    var changes = session.changes.makeAsyncIterator()
    #expect(await changes.next() == AmpChange(address: volume, data: [42]))
}

// The probe's whole sequence: the only DT1 messages are editor mode on and off.
@Test func connectingAndReadingWritesNothingButTheEditorModeFlag() async throws {
    let map = try ParameterMap.bundled()
    let amp = SimulatedAmp(map: map)
    let session = AmpSession(transport: amp)
    _ = try await session.connect()
    _ = try await session.read(.currentPatchNumber, size: 2)
    for slot in 0...8 {
        _ = try await session.read(.userPatch(slot), size: 16)
    }
    for block in map.table.blocks {
        _ = try await session.read(.temporaryPatch.advanced(by: block.offset), size: block.size)
    }
    try await session.disconnect()
    let writes = amp.received.compactMap { received -> [UInt8]? in
        if case .dataSet = IncomingMessage(received.message) { received.message } else { nil }
    }
    #expect(
        writes == [SysEx.dt1(.editorCommunicationMode, data: [1]), SysEx.dt1(.editorCommunicationMode, data: [0])])
    #expect(amp.received.last?.message == SysEx.dt1(.editorCommunicationMode, data: [0]))
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test`
Expected: compile errors such as `cannot find 'AmpSession' in scope`.

- [ ] **Step 3: Implement the session**

`Sources/KatanaKit/AmpSession.swift`:

```swift
import os

/// Errors from talking to the amp.
public enum AmpError: Error, Equatable, Sendable {
    /// The identity reply does not come from a Katana MkII.
    case notAKatana([UInt8])
    /// No identity reply arrived, also not after one retry.
    case noIdentityReply
    /// No reply arrived for a read at this address, also not after one retry.
    case timeout(Address)
}

/// What the amp reported while connecting.
public struct ConnectionInfo: Equatable, Sendable {
    /// The identity reply, from `F0` to `F7`.
    public let identityReply: [UInt8]
    /// Editor communication level (Tone Studio's own level is 8).
    public let communicationLevel: UInt8
    /// Editor communication revision.
    public let communicationRevision: UInt8
}

/// A DT1 from the amp that is not a reply to a read, i.e. a change made on the amp itself.
public struct AmpChange: Equatable, Sendable {
    /// Where the change starts.
    public let address: Address
    /// The new bytes.
    public let data: [UInt8]
}

/// Timing of the conversation with the amp.
public struct SessionTiming: Sendable {
    /// Minimum time between two outgoing messages.
    public var spacing: Duration
    /// How long to wait for a reply before retrying once.
    public var readTimeout: Duration

    /// Creates a timing.
    ///
    /// - Parameters:
    ///   - spacing: Minimum time between two outgoing messages.
    ///   - readTimeout: How long to wait for a reply before retrying once.
    public init(spacing: Duration, readTimeout: Duration) {
        self.spacing = spacing
        self.readTimeout = readTimeout
    }

    /// Tone Studio's 20 ms spacing with a 3 s read timeout (design spec, sections 3.3 and 8).
    public static let katana = SessionTiming(spacing: .milliseconds(20), readTimeout: .seconds(3))
}

/// A conversation with the amp over a `MIDITransport`.
///
/// Messages go out one at a time and at least `timing.spacing` apart. This version reads and switches the
/// editor-communication mode; it has no way to write parameters.
public actor AmpSession {
    /// Largest number of bytes one RQ1 asks for (Tone Studio's `SYSEX_MAXLEN`).
    public static let maxReadSize = 128

    /// Changes made on the amp itself, reported while connected.
    public nonisolated let changes: AsyncStream<AmpChange>
    private let changesContinuation: AsyncStream<AmpChange>.Continuation
    private let transport: any MIDITransport
    private let timing: SessionTiming
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "io.github.pwhofman.tanto", category: "midi")
    private var lastSend: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pending: Pending?
    private var requestCount = 0
    private var listener: Task<Void, Never>?

    private enum Expected: Equatable {
        case identityReply
        case data(Address, Int)
    }

    private struct Pending {
        let id: Int
        let expected: Expected
        let continuation: CheckedContinuation<[UInt8], any Error>
        let timeout: Task<Void, Never>
    }

    private struct NoReply: Error {}

    /// Creates a session; nothing is sent until `connect()` or `read(_:size:)` is called.
    ///
    /// - Parameters:
    ///   - transport: Connection to the amp.
    ///   - timing: Message spacing and read timeout.
    public init(transport: any MIDITransport, timing: SessionTiming = .katana) {
        self.transport = transport
        self.timing = timing
        (changes, changesContinuation) = AsyncStream.makeStream(of: AmpChange.self)
    }

    deinit {
        listener?.cancel()
        changesContinuation.finish()
    }

    /// Runs Tone Studio's connect sequence: identity request, editor communication level, editor mode on, revision.
    ///
    /// - Returns: What the amp reported.
    /// - Throws: `AmpError` if the amp does not answer or is not a Katana MkII.
    public func connect() async throws -> ConnectionInfo {
        startListening()
        let identity = try await request(SysEx.identityRequest, expecting: .identityReply)
        guard SysEx.isKatanaIdentityReply(identity) else { throw AmpError.notAKatana(identity) }
        let level = try await read(.editorCommunicationLevel, size: 1)[0]
        try await sendCommand(SysEx.dt1(.editorCommunicationMode, data: [1]))
        let revision = try await read(.editorCommunicationRevision, size: 1)[0]
        return ConnectionInfo(identityReply: identity, communicationLevel: level, communicationRevision: revision)
    }

    /// Switches editor mode off.
    ///
    /// - Throws: An error from the transport.
    public func disconnect() async throws {
        try await sendCommand(SysEx.dt1(.editorCommunicationMode, data: [0]))
    }

    /// Reads `size` bytes starting at `address`, in requests of at most `maxReadSize` bytes.
    ///
    /// - Parameters:
    ///   - address: First address.
    ///   - size: Number of bytes, at least 1.
    /// - Returns: The bytes.
    /// - Throws: `AmpError.timeout` if a request gets no reply, also not after one retry.
    public func read(_ address: Address, size: Int) async throws -> [UInt8] {
        precondition(size > 0, "read at least one byte")
        startListening()
        var data: [UInt8] = []
        while data.count < size {
            let start = address.advanced(by: data.count)
            let count = min(Self.maxReadSize, size - data.count)
            data += try await request(SysEx.rq1(start, size: count), expecting: .data(start, count))
        }
        return data
    }

    private func startListening() {
        guard listener == nil else { return }
        let incoming = transport.incoming
        listener = Task { [weak self] in
            for await message in incoming {
                await self?.handle(message)
            }
        }
    }

    private func handle(_ message: [UInt8]) {
        switch IncomingMessage(message) {
        case .identityReply(let reply):
            if let pending, pending.expected == .identityReply {
                resolve(pending, with: reply)
            }
        case .dataSet(let address, let data):
            if let pending, pending.expected == .data(address, data.count) {
                resolve(pending, with: data)
            } else {
                changesContinuation.yield(AmpChange(address: address, data: data))
            }
        case .malformed(let bytes):
            logger.error("dropped malformed message of \(bytes.count) bytes")
        case .other(let bytes):
            logger.debug("ignored message starting with \(bytes.first ?? 0, format: .hex)")
        }
    }

    private func resolve(_ pending: Pending, with data: [UInt8]) {
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume(returning: data)
    }

    private func request(_ message: [UInt8], expecting expected: Expected) async throws -> [UInt8] {
        do {
            return try await requestOnce(message, expecting: expected)
        } catch is NoReply {
            logger.notice("no reply, retrying once")
        }
        do {
            return try await requestOnce(message, expecting: expected)
        } catch is NoReply {
            switch expected {
            case .identityReply: throw AmpError.noIdentityReply
            case .data(let address, _): throw AmpError.timeout(address)
            }
        }
    }

    private func requestOnce(_ message: [UInt8], expecting expected: Expected) async throws -> [UInt8] {
        await acquire()
        defer { release() }
        try await waitForSlot()
        requestCount += 1
        let id = requestCount
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [clock, readTimeout = timing.readTimeout] in
                try? await clock.sleep(for: readTimeout)
                self.expire(id)
            }
            pending = Pending(id: id, expected: expected, continuation: continuation, timeout: timeout)
            do {
                try transport.send(message)
                lastSend = clock.now
            } catch {
                pending = nil
                timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func expire(_ id: Int) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume(throwing: NoReply())
    }

    private func sendCommand(_ message: [UInt8]) async throws {
        await acquire()
        defer { release() }
        try await waitForSlot()
        try transport.send(message)
        lastSend = clock.now
    }

    private func waitForSlot() async throws {
        if let lastSend {
            try await clock.sleep(until: lastSend.advanced(by: timing.spacing))
        }
    }

    // A first-come, first-served lock: one message is in flight at a time.
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: `Test run with 33 tests in 0 suites passed`, after about 1.5 s; the longest test reads a whole patch.

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Sources/KatanaKit/AmpSession.swift Tests/KatanaKitTests/AmpSessionTests.swift
git commit -m "Add amp session with paced reads and connect sequence"
```

---

### Task 10: CoreMIDI transport and probe

`CoreMIDITransport` needs the real amp, so it has no unit tests. Its packet handling is covered by task 6, and task 12
exercises it on the amp. The probe's offline behaviour is checked here; it sends nothing without `--connect`.

**Files:**
- Create: `Sources/KatanaKit/CoreMIDITransport.swift`
- Create: `Sources/TantoProbe/main.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Implement the transport**

`Sources/KatanaKit/CoreMIDITransport.swift`:

```swift
import CoreMIDI
import Foundation
import Synchronization

/// A MIDI endpoint as CoreMIDI reports it.
public struct MIDIEndpoint: Sendable, Hashable {
    /// Display name, e.g. `KATANA`.
    public let name: String
    let ref: MIDIEndpointRef
}

/// Errors from CoreMIDI.
public enum CoreMIDIError: Error, Equatable, CustomStringConvertible {
    /// A CoreMIDI call failed.
    case call(String, OSStatus)
    /// No source or no destination has "KATANA" in its name.
    case katanaNotFound
    /// More than one source or destination has "KATANA" in its name.
    case ambiguous(sources: [String], destinations: [String])

    public var description: String {
        switch self {
        case .call(let name, let status): "\(name) failed with OSStatus \(status)"
        case .katanaNotFound:
            "no MIDI source and destination named KATANA; is the amp on and the BOSS driver installed?"
        case .ambiguous(let sources, let destinations):
            "several KATANA endpoints, sources \(sources), destinations \(destinations)"
        }
    }
}

/// The amp's MIDI connection through CoreMIDI, using MIDI 1.0 Universal MIDI Packets.
public final class CoreMIDITransport: MIDITransport {
    public let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let client: MIDIClientRef
    private let inputPort: MIDIPortRef
    private let outputPort: MIDIPortRef
    private let destination: MIDIEndpointRef

    /// All MIDI sources (messages flow from them to Tanto).
    public static func sources() -> [MIDIEndpoint] {
        (0..<MIDIGetNumberOfSources()).map { endpoint(MIDIGetSource($0)) }
    }

    /// All MIDI destinations (messages flow from Tanto to them).
    public static func destinations() -> [MIDIEndpoint] {
        (0..<MIDIGetNumberOfDestinations()).map { endpoint(MIDIGetDestination($0)) }
    }

    /// Connects to the only source and destination whose names contain "KATANA".
    ///
    /// - Returns: The transport.
    /// - Throws: `CoreMIDIError` if there is no such pair, more than one, or CoreMIDI fails.
    public static func katana() throws -> CoreMIDITransport {
        let sources = sources().filter { $0.name.localizedCaseInsensitiveContains("KATANA") }
        let destinations = destinations().filter { $0.name.localizedCaseInsensitiveContains("KATANA") }
        guard !sources.isEmpty, !destinations.isEmpty else { throw CoreMIDIError.katanaNotFound }
        guard sources.count == 1, destinations.count == 1 else {
            throw CoreMIDIError.ambiguous(sources: sources.map(\.name), destinations: destinations.map(\.name))
        }
        return try CoreMIDITransport(source: sources[0], destination: destinations[0])
    }

    /// Opens a connection.
    ///
    /// - Parameters:
    ///   - source: Where messages from the amp come from.
    ///   - destination: Where messages to the amp go.
    /// - Throws: `CoreMIDIError.call` if CoreMIDI fails.
    public init(source: MIDIEndpoint, destination: MIDIEndpoint) throws {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        incoming = stream
        self.continuation = continuation
        self.destination = destination.ref
        var client = MIDIClientRef()
        try Self.check("MIDIClientCreateWithBlock", MIDIClientCreateWithBlock("Tanto" as CFString, &client, nil))
        self.client = client
        var outputPort = MIDIPortRef()
        try Self.check("MIDIOutputPortCreate", MIDIOutputPortCreate(client, "Tanto out" as CFString, &outputPort))
        self.outputPort = outputPort
        let decoder = Mutex(UMPDecoder())
        var inputPort = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(client, "Tanto in" as CFString, ._1_0, &inputPort) { list, _ in
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
            for packet in list.unsafeSequence() {
                let base = UnsafeRawPointer(packet).advanced(by: wordsOffset)
                let words = (0..<Int(packet.pointee.wordCount)).map {
                    base.load(fromByteOffset: $0 * MemoryLayout<UInt32>.size, as: UInt32.self)
                }
                for message in decoder.withLock({ $0.decode(words) }) {
                    continuation.yield(message)
                }
            }
        }
        try Self.check("MIDIInputPortCreateWithProtocol", status)
        self.inputPort = inputPort
        try Self.check("MIDIPortConnectSource", MIDIPortConnectSource(inputPort, source.ref, nil))
    }

    deinit {
        continuation.finish()
        MIDIPortDispose(inputPort)
        MIDIPortDispose(outputPort)
        MIDIClientDispose(client)
    }

    public func send(_ message: [UInt8]) throws {
        // A Katana message is at most about 150 bytes, far below this buffer's capacity.
        let size = 65_536
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        for words in UMP.sysEx7Packets(for: message) {
            packet = words.withUnsafeBufferPointer {
                MIDIEventListAdd(list, size, packet, 0, words.count, $0.baseAddress!)
            }
        }
        try Self.check("MIDISendEventList", MIDISendEventList(outputPort, destination, list))
    }

    private static func endpoint(_ ref: MIDIEndpointRef) -> MIDIEndpoint {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        return MIDIEndpoint(name: status == noErr ? (name?.takeRetainedValue() as String?) ?? "" : "", ref: ref)
    }

    private static func check(_ call: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CoreMIDIError.call(call, status) }
    }
}
```

- [ ] **Step 2: Add the probe target to `Package.swift`**

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tanto",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "KatanaKit", resources: [.copy("Resources/parameters.json")]),
        .testTarget(name: "KatanaKitTests", dependencies: ["KatanaKit"]),
        .executableTarget(name: "TantoProbe", dependencies: ["KatanaKit"]),
    ]
)
```

- [ ] **Step 3: Write the probe**

`Sources/TantoProbe/main.swift`:

```swift
// Hardware check 1 (docs/hardware-checklist.md): lists MIDI endpoints and, with --connect, reads from the amp.
// AmpSession has no way to write parameters; the only DT1 messages are editor mode on and off.

import Foundation
import KatanaKit
import Synchronization

let usage = """
    usage: swift run TantoProbe [--connect [--listen SECONDS] [--log FILE]]

      (no options)   list MIDI sources and destinations; sends nothing
      --connect      identity request, editor mode on, read the current channel, the channel names and the live
                     patch, editor mode off
      --listen N     before disconnecting, print what the amp sends for N seconds
      --log FILE     write every message sent and received to FILE
    """

struct Options {
    var connect = false
    var listenSeconds = 0
    var logPath: String?

    init?(_ arguments: [String]) {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--connect":
                connect = true
            case "--listen":
                guard let value = remaining.popFirst().flatMap({ Int($0) }), value > 0 else { return nil }
                listenSeconds = value
            case "--log":
                guard let value = remaining.popFirst() else { return nil }
                logPath = value
            default:
                return nil
            }
        }
        if !connect && (listenSeconds > 0 || logPath != nil) { return nil }
    }
}

/// Appends one line per message to a file; safe to call from any thread.
final class Transcript: Sendable {
    private let file: Mutex<FileHandle>
    private let start = ContinuousClock.now

    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        file = Mutex(try FileHandle(forWritingTo: URL(filePath: path)))
    }

    func write(_ direction: LoggingTransport.Direction, _ message: [UInt8]) {
        let milliseconds = (ContinuousClock.now - start) / .milliseconds(1)
        let line = String(format: "%10.1f ms ", milliseconds) + (direction == .sent ? "> " : "< ") + hex(message)
        file.withLock { $0.write(Data((line + "\n").utf8)) }
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func channelName(_ slot: Int) -> String {
    slot == 0 ? "PANEL" : "\(slot <= 4 ? "A" : "B")\((slot - 1) % 4 + 1)"
}

func describe(_ change: AmpChange, map: ParameterMap) -> String {
    let offset = change.address.linear - Address.temporaryPatch.linear
    let values = map.values(in: change.data, at: offset)
    guard (0..<map.patchSize).contains(offset), !values.isEmpty else {
        return "DT1   \(change.address)  \(hex(change.data))"
    }
    return values.map { "DT1   \(change.address)  \($0.parameter.block) \($0.parameter.name) = \($0.value)" }
        .joined(separator: "\n")
}

func run(_ options: Options) async throws {
    print("MIDI sources:      \(CoreMIDITransport.sources().map(\.name))")
    print("MIDI destinations: \(CoreMIDITransport.destinations().map(\.name))")
    guard options.connect else { return }

    let map = try ParameterMap.bundled()
    let transcript = try options.logPath.map(Transcript.init(path:))
    let transport = LoggingTransport(wrapping: try CoreMIDITransport.katana()) { direction, message in
        transcript?.write(direction, message)
        if direction == .received, message.first != 0xF0 {
            print("MIDI  \(hex(message))")  // channel messages, e.g. a Program Change on a channel switch
        }
    }
    let session = AmpSession(transport: transport)
    let info = try await session.connect()
    print("identity reply:    \(hex(info.identityReply))")
    print("editor level \(info.communicationLevel), revision \(info.communicationRevision); editor mode is on")
    do {
        let current = ValueEncoding.int2x7.decode(try await session.read(.currentPatchNumber, size: 2))
        print("current channel:   \(current) (\(channelName(current)))")
        for slot in 0...8 {
            let name = PatchName.decode(try await session.read(.userPatch(slot), size: 16))
            print("  slot \(slot) \(channelName(slot).padding(toLength: 5, withPad: " ", startingAt: 0)) \(name)")
        }
        var live: [ParameterValue] = []
        for block in map.table.blocks {
            let data = try await session.read(.temporaryPatch.advanced(by: block.offset), size: block.size)
            live += map.values(in: data, at: block.offset)
        }
        print("live patch: \(PatchName.decode(try await session.read(.temporaryPatch, size: 16)))")
        for value in live where value.parameter.block == "Patch_0" && !value.parameter.name.isEmpty {
            let address = Address.temporaryPatch.advanced(by: value.parameter.offset)
            let prm = value.parameter.prm.padding(toLength: 28, withPad: " ", startingAt: 0)
            print("  \(address)  \(prm) \(value.value)")
        }
        if options.listenSeconds > 0 {
            print("listening for \(options.listenSeconds) s: turn knobs, switch channels, change a colour")
            let listener = Task {
                for await change in session.changes {
                    print(describe(change, map: map))
                }
            }
            try await Task.sleep(for: .seconds(options.listenSeconds))
            listener.cancel()
        }
    } catch {
        try? await session.disconnect()
        throw error
    }
    try await session.disconnect()
    print("editor mode is off")
}

guard let options = Options(Array(CommandLine.arguments.dropFirst())) else {
    print(usage)
    exit(2)
}
do {
    try await run(options)
} catch {
    print("error: \(error)")
    exit(1)
}
```

- [ ] **Step 4: Build and check the offline paths**

Run: `swift build`
Expected: `Build complete!` without warnings.

Run: `swift run TantoProbe`
Expected, with the amp off:
```
MIDI sources:      []
MIDI destinations: []
```

Run: `swift run TantoProbe --listen 5`
Expected: the usage text; exit status 2, because `--listen` needs `--connect`.

Run: `swift run TantoProbe --connect`
Expected, with the amp off: `error: no MIDI source and destination named KATANA; is the amp on and the BOSS driver installed?`

- [ ] **Step 5: Format and commit**

```bash
swift format --in-place --recursive Sources Tests Package.swift
git add Package.swift Sources/KatanaKit/CoreMIDITransport.swift Sources/TantoProbe/main.swift
git commit -m "Add CoreMIDI transport and read-only probe"
```

---

### Task 11: Checklist, CLAUDE.md and full check

**Files:**
- Create: `docs/hardware-checklist.md`
- Create: `CLAUDE.md`

- [ ] **Step 1: Write the hardware checklist**

`docs/hardware-checklist.md`:

````markdown
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
````

- [ ] **Step 2: Write `CLAUDE.md`**

`CLAUDE.md`:

````markdown
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
````

- [ ] **Step 3: Run everything**

Run: `swift test`
Expected: `Test run with 33 tests in 0 suites passed`.

Run: `swift format lint --recursive Sources Tests Package.swift`
Expected: no output.

Run: `uv run --directory tools pytest -q && uv run --directory tools ruff check && uv run --directory tools ty check`
Expected: `6 passed`, then `All checks passed!` twice.

Run: `git status --short`
Expected: only `CLAUDE.md` and `docs/hardware-checklist.md` as new files.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/hardware-checklist.md
git commit -m "Add hardware checklist and CLAUDE.md"
```

- [ ] **Step 5: Ask the user to push**

Claude's sandboxed shell cannot authenticate to GitHub. Ask the user to run `git push -u origin main`.

---

### Task 12: Hardware check 1, together with the user

Follow `docs/hardware-checklist.md`, check 1. Every step is announced to the user before it runs.

- [ ] **Step 1: Prepare**

Ask the user to switch the amp on, connect USB, set MASTER to minimum and close BOSS TONE STUDIO. Wait for their
confirmation in chat.

- [ ] **Step 2: List endpoints (sends nothing)**

Run: `swift run TantoProbe`
Expected: at least one source and one destination with KATANA in the name. If several match, stop and report: the
transport refuses to guess.

- [ ] **Step 3: Read and listen**

Tell the user what will happen and which actions to do on the amp (checklist step 3), then run:
`swift run TantoProbe --connect --listen 60 --log check1.probe-log.txt`
Expected: identity reply, editor level and revision, nine channel names, the live patch's booster, amp and EQ values,
then the messages caused by the user's actions, and `editor mode is off`.

- [ ] **Step 4: Compare PANEL values with the knobs**

Ask the user to switch the amp to PANEL, then run `swift run TantoProbe --connect` and compare the values together.

- [ ] **Step 5: Record and commit the results**

Fill in the results table in `docs/hardware-checklist.md`, then:

```bash
git add docs/hardware-checklist.md
git commit -m "Record hardware check 1 results"
```

- [ ] **Step 6: Hand over**

Report the results to the user. Plans 2 and 3 are written next, using these results.
