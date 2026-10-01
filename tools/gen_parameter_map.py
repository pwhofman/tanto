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
