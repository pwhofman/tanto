"""Generate Tanto's parameter table from BOSS TONE STUDIO for KATANA MkII.

Reads three files of an installed Tone Studio 2.1.0 and writes ``Sources/KatanaKit/Resources/parameters.json``:

- ``js/config/address_map.js``: address, encoding, range and name of every parameter;
- ``export/item.json``: which on-screen control edits which parameter;
- ``export/layout.div``: labels, option lists and display formats of those controls.

Only facts are taken over, not Roland's code. Tanto writes exactly the parameters that a Tone Studio control writes
(design spec, section 3.5) and guards those that can raise loudness (section 5.2).
"""

from __future__ import annotations

import argparse
import html
import json
import logging
import re
from collections import defaultdict
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import TypedDict

logger = logging.getLogger(__name__)

DEFAULT_HTML = Path("/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app/Contents/Resources/html")
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
# The general guard rule skips the panel status and the controller assignments; the front-panel knobs are listed below.
_RULE_EXCLUDED_BLOCKS = re.compile(r"Status|Asgn")
# Front-panel knobs that raise loudness. Tone Studio edits the amp through these (spec, sections 3.5 and 5.2).
_FRONT_PANEL_KNOBS = frozenset(
    {
        "PRM_KNOB_POS_GAIN",
        "PRM_KNOB_POS_VOLUME",
        "PRM_KNOB_POS_BOOST",
        "PRM_KNOB_POS_MOD",
        "PRM_KNOB_POS_FX",
        "PRM_KNOB_POS_DELAY",
        "PRM_KNOB_POS_REVERB",
    }
)
# Unguarded parameters that get louder in one direction; Tanto ramps changes in that direction, without a ceiling,
# because the limiter's LEVEL is guarded already. A higher threshold or a lower ratio lets more of the signal through.
_RAMPED = {"PRM_FX1_LIMITER_THRESHOLD": "up", "PRM_FX1_LIMITER_RATIO": "down"}
# Option labels that Tone Studio draws as pictures. The amp types follow `panelAmpTypeInfo` in
# js/businesslogic/bts/effect_controller.js; the colours follow the GRN, RED, YLW order of the colour assignments, with
# 0 for an unlit LED.
_COLOURS = ["OFF", "GREEN", "RED", "YELLOW"]
_PICTURE_OPTIONS = {
    "PRM_KNOB_POS_TYPE": ["ACOUSTIC", "CLEAN", "CRUNCH", "LEAD", "BROWN"],
    "PRM_LED_STATE_BOOST": _COLOURS,
    "PRM_LED_STATE_MOD": _COLOURS,
    "PRM_LED_STATE_FX": _COLOURS,
    "PRM_LED_STATE_DELAY": _COLOURS,
    "PRM_LED_STATE_REVERB": _COLOURS,
}
# Tone Studio's display formats without whitespace, mapped to the names of Tanto's formatters.
_FORMATS = {
    "((value>0)?'+':'')+value": "signed",
    "(value>0?'+':'')+value": "signed",
    "((value>0)?'+':'')+value+'dB'": "signedDecibels",
    "((value>0)?'+':'')+value+'<br>dB'": "signedDecibels",
    "((value>0)?'+':'')+(value/2)+((value&1)?'':'.0')+'<br>dB'": "signedHalfDecibels",
    "((value>0)?'+':'')+(value/2)+(((value/2)%1)?'':'.0')+'<br>dB'": "signedHalfDecibels",
    "value+'<br>ms'": "milliseconds",
    "value+'ms'": "milliseconds",
    "value+1": "plusOne",
    "(value/10)+((value%10)?'':'.0')+'s'": "tenthsOfSeconds",
    "(value<0)?'OFF':value": "offBelowZero",
    "(value===-1)?'OFF':value": "offBelowZero",
    "value+'%'": "percent",
}
_PICKER_CLASSES = frozenset({"select-box", "toggle-button", "radio-button", "check-box"})
# Controls that only display a value, or duplicate another control; they do not make a parameter written.
_DISPLAY_ONLY = re.compile(r"-(watcher|dummy)$")
# Panel buttons that send a button press, a DT1 of 00 to 7F 01 01 0n, instead of writing the parameter they show, which
# for the VARIATION and colour buttons is their LED (`panelActionBtnInfo` in js/businesslogic/bts/effect_controller.js).
COMMAND_BUTTONS = frozenset(
    {
        "panel-amp-type-vari-btn",
        "panel-booster-btn",
        "panel-mod-btn",
        "panel-fx-btn",
        "panel-delay-btn",
        "panel-reverb-btn",
        "delay-tap-btn",
        "delay2-tap-btn",
    }
)
# Two solo controls with generated ids, and the labels that Tone Studio puts beside them without naming them.
_GENERATED_ID_LABELS = {
    "id_l4nnsh87_pw3sspdwt": "id_l4nnsl0a_dn7z9rjcj",
    "id_l4nnsnoh_pnm8d5436": "id_l4nnt69v_6jywbgm6r",
}
# The root of a page in `layout.div`: the front panel (`editor-panel-page`) or a block's, e.g. `editor-booster-page`.
_PAGE_ROOT = re.compile(r"editor-[\w-]+-page")
_PANEL_ROOT = "editor-panel-page"
# How Tanto shows a control, from the classes of Tone Studio's controls in order of preference.
_CONTROL_CLASSES = (
    ("knob", frozenset({"knob", "dial"})),
    ("slider", frozenset({"slider"})),
    ("menu", frozenset({"select-box"})),
    ("segmented", frozenset({"radio-button"})),
)
_VOID_TAGS = frozenset({"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "wbr"})


class BlockRow(TypedDict):
    """A block of the patch layout; offsets and sizes are linear byte counts."""

    name: str
    offset: int
    size: int


class OptionRow(TypedDict):
    """One choice of a picker."""

    value: int
    label: str


class PositionRow(TypedDict):
    """Where a control sits: its offset from the top left of its page, in Tone Studio's pixels."""

    x: int
    y: int


class ConditionRow(TypedDict):
    """A parameter is shown only while the parameter at ``offset`` has one of ``values``."""

    offset: int
    values: list[int]


class PlacementRow(TypedDict):
    """Where a parameter sits on its page while ``visibleWhen`` holds (``None``: always), in Tone Studio's pixels."""

    x: int
    y: int
    visibleWhen: list[ConditionRow] | None


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
    louder: str | None
    written: bool
    control: str | None
    page: str | None
    position: PositionRow | None
    placements: list[PlacementRow] | None
    panel: PositionRow | None
    kind: str
    section: str | None
    label: str
    options: list[OptionRow] | None
    valueLabels: list[str] | None
    format: str | None
    visibleWhen: list[ConditionRow] | None


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
    """Applies the general guard rule of the design spec (section 5.2) to one row.

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


def kind_of(row: ParameterRow, control_classes: set[str]) -> str:
    """Decides how a parameter is edited.

    The kind follows from the parameter, not from how Tone Studio draws it: two-valued parameters are switches and
    ``*_TYPE`` parameters are pickers even when Tone Studio shows them as dials. Switches and pickers get the soft
    switch of spec section 5.3.

    Args:
        row: The parameter.
        control_classes: Classes of Tone Studio's controls for it, e.g. ``{"dial"}`` for ``elf-dial-control``.

    Returns:
        ``text``, ``switch``, ``picker`` or ``numeric``.
    """
    if row["encoding"] == "ascii16":
        return "text"
    if row["maximum"] - row["minimum"] == 1:
        return "switch"
    if control_classes & _PICKER_CLASSES or row["prm"].endswith("_TYPE"):
        return "picker"
    return "numeric"


def display_format(expression: str) -> str:
    """Maps one of Tone Studio's display-format expressions to the name of a Tanto formatter.

    Args:
        expression: The JavaScript expression of a stringer or spinner, possibly with HTML entities.

    Returns:
        The formatter name, e.g. ``signedDecibels``.

    Raises:
        ValueError: If the expression is not one of the known formats.
    """
    key = re.sub(r"\s+", "", html.unescape(expression))
    if key not in _FORMATS:
        raise ValueError(f"unknown display format: {expression!r}")
    return _FORMATS[key]


def section_of(control_id: str, block: str) -> str | None:
    """Names the editor section of a Tone Studio control.

    Args:
        control_id: Control id from ``item.json``, e.g. ``booster-drive-dial``.
        block: The block the control edits; it separates MOD from FX and DELAY from DELAY 2.

    Returns:
        The section, or ``None`` for controller assignments, which v1 does not edit.

    Raises:
        ValueError: If the control belongs to no known section.
    """
    prefix = control_id.split("-")[0]
    if prefix == "asgn":
        return None
    if prefix == "panel":
        part = control_id.split("-")[1]
        return "amp" if part in ("amp", "eq", "presence", "cab") else part
    if prefix == "modfx":
        return "fx" if block == "Fx(2)" else "mod"
    if prefix == "delay":
        return "delay2" if block == "Delay(2)" else "delay"
    if prefix.startswith("id_"):
        # Two controls with generated ids edit the solo settings in Patch_Mk2V2.
        if block == "Patch_Mk2V2":
            return "solo"
    sections = {"eq": "eq1", "sr": "sendreturn"}
    if prefix in ("booster", "mod", "fx", "delay2", "reverb", "eq", "eq2", "pedalfx", "ns", "sr", "solo", "contour"):
        return sections.get(prefix, prefix)
    if prefix == "chain":
        return "chain"
    raise ValueError(f"unknown control section: {control_id}")


def blocks_for(control_id: str, block: str) -> list[str]:
    """Lists the blocks a control edits.

    Tone Studio shares one layout between MOD and FX and one between DELAY and DELAY 2; its controls name the first
    block, and Tone Studio swaps in the second at runtime.

    Args:
        control_id: Control id from ``item.json``.
        block: The block named by the control.

    Returns:
        The blocks the control edits.
    """
    if block == "Fx(1)":
        if control_id.startswith("modfx-mod-"):
            return ["Fx(1)"]
        if control_id.startswith("modfx-fx-"):
            return ["Fx(2)"]
        return ["Fx(1)", "Fx(2)"]
    if block == "Delay(1)":
        if control_id.startswith("delay-delay1-") or control_id == "delay-tap-time-knob":
            return ["Delay(1)"]
        if control_id.startswith("delay-delay2-"):
            return ["Delay(2)"]
        return ["Delay(1)", "Delay(2)"]
    return [block]


class Layout(HTMLParser):
    """The parts of ``layout.div`` the generator needs: element tree, labels, options, value labels and formats."""

    def __init__(self) -> None:
        """Creates an empty layout; use :meth:`parse`."""
        super().__init__(convert_charrefs=True)
        self._stack: list[tuple[str, str | None]] = []
        self._parent: dict[str, str | None] = {}
        self._children: dict[str | None, list[str]] = defaultdict(list)
        self._attributes: dict[str, dict[str, str]] = {}
        self._text: dict[str, str] = defaultdict(str)
        self._options: dict[str, list[str]] = defaultdict(list)
        self._hidden: dict[str, list[str]] = {}
        self._input_formats: dict[str, str] = {}
        self._option_owner: str | None = None
        self._hidden_owner: str | None = None
        self._hidden_depth = 0
        self._in_hidden_p = False

    @classmethod
    def parse(cls, text: str) -> Layout:
        """Parses the contents of ``layout.div``.

        Args:
            text: The HTML text.

        Returns:
            The parsed layout.
        """
        layout = cls()
        layout.feed(text)
        layout.close()
        return layout

    def _owner(self) -> str | None:
        return next((ident for _, ident in reversed(self._stack) if ident), None)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """Records element ids, options, hidden value lists and spinner formats."""
        attributes = {name: value or "" for name, value in attrs}
        owner = self._owner()
        if tag == "input" and owner is not None and attributes.get("format"):
            self._input_formats[owner] = attributes["format"]
        if tag == "br":
            if self._in_hidden_p and self._hidden_owner is not None:
                self._hidden[self._hidden_owner][-1] += " "
            elif self._option_owner is not None:
                self._options[self._option_owner][-1] += " "
            elif owner is not None:
                self._text[owner] += " "
            return
        if tag in _VOID_TAGS:
            return
        ident = attributes.get("id")
        if ident:
            self._parent[ident] = owner
            self._children[owner].append(ident)
            self._attributes[ident] = attributes
        # A select box's options are links in its popup, a radio button group's are labels in the group.
        option_class = {"a": "elf-select-box-option-control", "label": "elf-radio-button-item"}.get(tag)
        if option_class and option_class in attributes.get("class", "").split() and owner is not None:
            self._option_owner = owner
            self._options[owner].append("")
        if tag == "div" and not ident and "display:none" in attributes.get("style", "").replace(" ", ""):
            if owner is not None and self._hidden_owner is None:
                self._hidden_owner = owner
                self._hidden[owner] = []
                self._hidden_depth = len(self._stack)
        if tag == "p" and self._hidden_owner is not None:
            self._in_hidden_p = True
            self._hidden[self._hidden_owner].append("")
        self._stack.append((tag, ident))

    def handle_endtag(self, tag: str) -> None:
        """Closes the innermost open element with this tag."""
        if tag in _VOID_TAGS:
            return
        if tag in ("a", "label"):
            self._option_owner = None
        if tag == "p":
            self._in_hidden_p = False
        while self._stack:
            open_tag, _ = self._stack.pop()
            if self._hidden_owner is not None and len(self._stack) == self._hidden_depth:
                self._hidden_owner = None
            if open_tag == tag:
                break

    def handle_data(self, data: str) -> None:
        """Collects option labels, hidden value labels and element text."""
        if self._option_owner is not None:
            self._options[self._option_owner][-1] += data
            return
        if self._in_hidden_p and self._hidden_owner is not None:
            self._hidden[self._hidden_owner][-1] += data
            return
        owner = self._owner()
        if owner is not None:
            self._text[owner] += data

    def parent(self, ident: str) -> str | None:
        """The nearest ancestor with an id.

        Args:
            ident: An element id.

        Returns:
            The ancestor's id, or ``None`` at the top.
        """
        return self._parent.get(ident)

    def children(self, ident: str) -> list[str]:
        """The descendants with ids whose nearest ancestor with an id is ``ident``, in document order.

        Args:
            ident: An element id.

        Returns:
            Their ids.
        """
        return list(self._children.get(ident, []))

    def control_class(self, ident: str) -> str | None:
        """The control class of an element: ``dial`` for ``elf-dial-control``.

        Args:
            ident: An element id.

        Returns:
            The class, or ``None`` if the element is not a control.
        """
        for token in self._attributes.get(ident, {}).get("class", "").split():
            if token.startswith("elf-") and token.endswith("-control"):
                return token[len("elf-") : -len("-control")]
        return None

    def options(self, control_id: str) -> list[str]:
        """The option labels of a select box or of a group of radio buttons, in order.

        Args:
            control_id: The control's id.

        Returns:
            The labels; empty for other elements.
        """
        labels = self._options.get(f"{control_id}-box") or self._options.get(control_id, [])
        return [label.strip() for label in labels]

    def label_of(self, control_id: str) -> str | None:
        """The text of a control's label element.

        The label named after the control, which Tone Studio puts under it, wins over the one that the ``description``
        attribute names: some descriptions name a neighbour's label.

        Args:
            control_id: The control's id.

        Returns:
            The label, or ``None`` if there is none.
        """
        candidates = [
            re.sub(r"-(dial|knob|slider|spinner|select-box|btn|sw|selector)(-\d+)?$", r"-label\2", control_id),
            self._attributes.get(control_id, {}).get("description", ""),
            _GENERATED_ID_LABELS.get(control_id, ""),
        ]
        for candidate in candidates:
            # A control's own text is its value.
            if candidate == control_id:
                continue
            text = re.sub(r"\s+", " ", self._text.get(candidate, "")).strip()
            if text:
                return text
        return None

    def value_labels(self, ident: str) -> list[str] | None:
        """The hidden list of value labels inside a stringer, e.g. ``["OFF", "ON"]``.

        Args:
            ident: The stringer's id.

        Returns:
            The labels, or ``None`` if the stringer has none.
        """
        labels = self._hidden.get(ident)
        return [re.sub(r"\s+", " ", label).strip() for label in labels] if labels else None

    def position(self, ident: str) -> tuple[str, int, int] | None:
        """Where an element sits: its page and its offset from the page's top left.

        The offset adds up the ``left`` and ``top`` of the element's style and those of its frames, up to the page's
        root element.

        Args:
            ident: An element id.

        Returns:
            The page root's id and the offset in Tone Studio's pixels, or ``None`` if the element is on no page.
        """
        x = y = 0.0
        current: str | None = ident
        while current is not None and _PAGE_ROOT.fullmatch(current) is None:
            style = self._attributes.get(current, {}).get("style", "")
            for name, value in re.findall(r"(left|top):\s*(-?[\d.]+)px", style):
                if name == "left":
                    x += float(value)
                else:
                    y += float(value)
            current = self.parent(current)
        if current is None:
            return None
        return current, round(x), round(y)

    def format_expression(self, ident: str) -> str | None:
        """The display-format expression of a stringer, or of a spinner's input field.

        Args:
            ident: The stringer's or spinner's id.

        Returns:
            The expression, or ``None`` if it is missing or empty.
        """
        expression = self._attributes.get(ident, {}).get("format") or self._input_formats.get(ident)
        return expression or None


def build_table(source: str) -> Table:
    """Builds the parameter table for one patch from the text of ``address_map.js``.

    Control-related fields get their defaults; :func:`annotate` fills them in.

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
        rule_applies = _RULE_EXCLUDED_BLOCKS.search(block_name) is None
        size = max(linear(e.addr) + e.byte_count for e in entries)
        blocks.append({"name": block_name, "offset": base, "size": size})
        for e in entries:
            if e.encoding is None:
                continue
            guarded = e.prm in _FRONT_PANEL_KNOBS or (rule_applies and is_guarded(e))
            row: ParameterRow = {
                "prm": e.prm,
                "name": e.name,
                "block": block_name,
                "offset": base + linear(e.addr),
                "encoding": e.encoding,
                "minimum": e.minimum,
                "maximum": e.maximum,
                "rawOffset": e.raw_offset,
                "initial": e.initial,
                "guarded": guarded,
                "louder": "up" if guarded else _RAMPED.get(e.prm),
                "written": False,
                "control": None,
                "page": None,
                "position": None,
                "placements": None,
                "panel": None,
                "kind": "numeric",
                "section": None,
                "label": e.name,
                "options": None,
                "valueLabels": None,
                "format": None,
                "visibleWhen": None,
            }
            row["kind"] = kind_of(row, set())
            parameters.append(row)
    return {
        "source": "BOSS TONE STUDIO for KATANA MkII 2.1.0: address_map.js, item.json, layout.div",
        "blocks": blocks,
        "parameters": parameters,
    }


@dataclass(frozen=True)
class _Control:
    """One Tone Studio control, resolved to the patch."""

    ident: str
    section: str
    control_class: str | None
    written: bool
    label: str | None
    options: list[OptionRow] | None
    value_labels: list[str] | None
    format: str | None
    conditions: tuple[tuple[int, tuple[int, ...]], ...]
    position: tuple[str, int, int] | None


def control_of(row: ParameterRow, control_classes: set[str]) -> str | None:
    """Decides how Tanto shows a parameter, following how Tone Studio draws it.

    Args:
        row: The parameter, with its kind decided.
        control_classes: Classes of Tone Studio's written controls for it.

    Returns:
        ``knob``, ``slider``, ``menu``, ``segmented`` or ``switch``; ``None`` for the patch name.
    """
    if row["kind"] == "text":
        return None
    for control, classes in _CONTROL_CLASSES:
        if control_classes & classes:
            return control
    if row["kind"] == "switch":
        return "switch"
    if control_classes & {"toggle-button", "check-box"}:
        return "segmented"
    return "menu" if row["kind"] == "picker" else "knob"


def _place(controls: list[_Control], control: str | None, on_panel: bool) -> tuple[str, PositionRow] | None:
    """Finds where a parameter is shown, on the front panel or on a page.

    The control of the class that decided ``control`` wins over spinners and other companions. A control on a block's
    own page wins over one on the EFFECTS page, where DELAY TIME has only a hidden knob behind the TAP button.

    Returns:
        The page, e.g. ``booster`` or ``effects-booster``, and the control's position on it; ``None`` if no control is
        placed.
    """
    preferred = next((classes for kind, classes in _CONTROL_CLASSES if kind == control), frozenset())
    placed: list[tuple[bool, bool, str, int, int]] = []
    for c in controls:
        if not c.written or c.position is None:
            continue
        root, x, y = c.position
        if (root == _PANEL_ROOT) == on_panel:
            placed.append((c.control_class not in preferred, root.startswith("editor-effects-"), root, x, y))
    if not placed:
        return None
    _, _, root, x, y = min(placed, key=lambda p: p[:2])
    return root.removeprefix("editor-").removesuffix("-page"), PositionRow(x=x, y=y)


def _placements(row: ParameterRow, controls: list[_Control], root: str) -> list[PlacementRow] | None:
    """Where a parameter sits on its page for each type, if Tone Studio puts it in different places for different types.

    Returns:
        A placement per position, with the types it holds for; ``None`` if the parameter stays in one place.
    """
    alternatives: dict[tuple[int, int], list[tuple[tuple[int, tuple[int, ...]], ...]]] = {}
    for c in controls:
        if c.written and c.position is not None and c.position[0] == root:
            alternatives.setdefault((c.position[1], c.position[2]), []).append(c.conditions)
    if len(alternatives) < 2:
        return None
    return [
        PlacementRow(
            x=x, y=y, visibleWhen=None if any(not a for a in conditions) else _union_conditions(row, conditions)
        )
        for (x, y), conditions in alternatives.items()
    ]


def _string(item: dict[str, object], key: str) -> str | None:
    value = item.get(key)
    return value if isinstance(value, str) else None


def _integers(item: dict[str, object], key: str) -> list[int] | None:
    value = item.get(key)
    if isinstance(value, list) and all(isinstance(v, int) for v in value):
        return [v for v in value if isinstance(v, int)]
    return None


def _conditions(
    control_id: str,
    block: str,
    layout: Layout,
    switchers: dict[str, tuple[str, int, list[int] | None]],
    blocks: dict[str, int],
) -> tuple[tuple[int, tuple[int, ...]], ...]:
    """Collects, from the innermost outwards, every type switch that has to match for a control to show."""
    conditions = []
    ident: str | None = control_id
    while ident is not None:
        frame = layout.parent(ident)
        if frame is not None and frame in switchers:
            type_block, type_offset, order = switchers[frame]
            panel = layout.children(frame).index(ident)
            # Without an order, a value shows the page of the same number.
            values = tuple(value for value, child in enumerate(order) if child == panel) if order else (panel,)
            # Shared layouts: the type parameter lives in the block the control edits.
            target = block if type_block in ("Fx(1)", "Delay(1)") and block in ("Fx(2)", "Delay(2)") else type_block
            conditions.append((blocks[target] + type_offset, values))
        ident = frame
    return tuple(conditions)


def annotate(table: Table, items: dict[str, dict[str, object]], layout_text: str) -> Table:
    """Adds what Tone Studio's controls say about each parameter.

    Args:
        table: Output of :func:`build_table`.
        items: Contents of ``item.json``.
        layout_text: Contents of ``layout.div``.

    Returns:
        A new table with ``written``, ``kind``, ``section``, ``label``, ``options``, ``valueLabels``, ``format`` and
        ``visibleWhen`` filled in from the controls.

    Raises:
        ValueError: If the controls of a parameter disagree, an option list does not fit its parameter, or two items
            switch a frame differently.
    """
    layout = Layout.parse(layout_text)
    blocks = {b["name"]: b["offset"] for b in table["blocks"]}
    switchers: dict[str, tuple[str, int, list[int] | None]] = {}
    for item in items.values():
        frame, pid, order = _string(item, "frame"), _string(item, "pid"), _integers(item, "order")
        if frame and pid and pid.startswith("Temporary%"):
            _, type_block, type_offset = pid.split("%")
            switcher = (type_block, int(type_offset), order)
            # The type menus of MOD and FX, and of DELAY and DELAY 2, switch one shared frame alike.
            if switchers.get(frame, switcher) != switcher:
                raise ValueError(f"items switch {frame} differently")
            switchers[frame] = switcher

    controls: dict[int, list[_Control]] = defaultdict(list)
    for control_id, item in items.items():
        pid = _string(item, "pid")
        if pid is None or not pid.startswith("Temporary%"):
            continue
        _, pid_block, pid_offset = pid.split("%")
        if section_of(control_id, pid_block) is None:
            continue
        stringer = _string(item, "stringer")
        expression = layout.format_expression(stringer) if stringer else layout.format_expression(control_id)
        value_labels = layout.value_labels(stringer) if stringer else None
        options = None
        if layout.control_class(control_id) in ("select-box", "radio-button"):
            labels = layout.options(control_id)
            values = _integers(item, "list_order") or list(range(len(labels)))
            options = [OptionRow(value=v, label=label) for v, label in zip(values, labels, strict=True)]
        for block in blocks_for(control_id, pid_block):
            section = section_of(control_id, block)
            assert section is not None
            controls[blocks[block] + int(pid_offset)].append(
                _Control(
                    ident=control_id,
                    section=section,
                    control_class=layout.control_class(control_id),
                    written=_DISPLAY_ONLY.search(control_id) is None and control_id not in COMMAND_BUTTONS,
                    label=layout.label_of(control_id),
                    options=options,
                    value_labels=value_labels,
                    format=display_format(expression) if expression else None,
                    conditions=_conditions(control_id, block, layout, switchers, blocks),
                    position=layout.position(control_id),
                )
            )

    parameters = [_merge(row, controls.get(row["offset"], [])) for row in table["parameters"]]
    return {"source": table["source"], "blocks": table["blocks"], "parameters": parameters}


def _merge(row: ParameterRow, controls: list[_Control]) -> ParameterRow:
    """Combines a parameter with the controls that edit it."""
    merged = ParameterRow(**row)
    if not controls:
        return merged
    sections = {c.section for c in controls}
    if len(sections) != 1:
        raise ValueError(f"{row['prm']} at {row['offset']} has controls in several sections: {sorted(sections)}")
    merged["section"] = sections.pop()
    merged["written"] = any(c.written for c in controls)
    merged["label"] = next((c.label for c in controls if c.label), row["name"])
    merged["kind"] = kind_of(row, {c.control_class for c in controls if c.control_class})
    merged["control"] = control_of(merged, {c.control_class for c in controls if c.written and c.control_class})
    page = _place(controls, merged["control"], on_panel=False)
    merged["page"], merged["position"] = page if page else (None, None)
    merged["placements"] = _placements(row, controls, f"editor-{page[0]}-page") if page else None
    panel = _place(controls, merged["control"], on_panel=True)
    merged["panel"] = panel[1] if panel else None
    # The guard rule also reads Tone Studio's label (spec 5.2); it is the only name of some entries.
    if (
        merged["kind"] == "numeric"
        and _RULE_EXCLUDED_BLOCKS.search(row["block"]) is None
        and _GUARD.search(merged["label"].upper().replace(" ", "_")) is not None
        and _NOT_GUARDED.search(row["prm"]) is None
    ):
        merged["guarded"] = True
        merged["louder"] = "up"
    merged["format"] = next((c.format for c in controls if c.format), None)
    merged["valueLabels"] = next((c.value_labels for c in controls if c.value_labels), None)
    count = row["maximum"] - row["minimum"] + 1
    if merged["valueLabels"] is not None and len(merged["valueLabels"]) != count:
        raise ValueError(f"{row['prm']}: {len(merged['valueLabels'])} value labels for {count} values")
    # Menus of two values count as switches but have options too.
    if merged["kind"] == "picker" or merged["control"] == "menu":
        merged["options"] = next((c.options for c in controls if c.written and c.options), None)
        if merged["options"] is None and row["prm"] in _PICTURE_OPTIONS:
            labels = _PICTURE_OPTIONS[row["prm"]]
            merged["options"] = [OptionRow(value=row["minimum"] + i, label=label) for i, label in enumerate(labels)]
        for option in merged["options"] or []:
            if not row["minimum"] <= option["value"] <= row["maximum"]:
                raise ValueError(f"{row['prm']}: option {option} outside {row['minimum']}..{row['maximum']}")
    # A parameter is always visible if one of its controls is; otherwise the conditions must agree.
    if any(not c.conditions for c in controls):
        merged["visibleWhen"] = None
    else:
        merged["visibleWhen"] = _union_conditions(row, [c.conditions for c in controls])
    return merged


def _union_conditions(
    row: ParameterRow, alternatives: list[tuple[tuple[int, tuple[int, ...]], ...]]
) -> list[ConditionRow]:
    """Joins the conditions of several controls; they may differ only in the values of their innermost type switch."""
    outer = {alternative[1:] for alternative in alternatives}
    inner_offsets = {alternative[0][0] for alternative in alternatives}
    if len(outer) != 1 or len(inner_offsets) != 1:
        raise ValueError(f"{row['prm']} at {row['offset']} has controls with unrelated visibility conditions")
    values = sorted({value for alternative in alternatives for value in alternative[0][1]})
    conditions = [ConditionRow(offset=inner_offsets.pop(), values=values)]
    conditions += [ConditionRow(offset=offset, values=list(vals)) for offset, vals in outer.pop()]
    return conditions


def render(table: Table) -> str:
    """Formats the table as JSON with one block or parameter per line, for readable diffs.

    Args:
        table: Output of :func:`annotate`.

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
    parser.add_argument("--html", type=Path, default=DEFAULT_HTML, help="Tone Studio's Resources/html directory")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="where to write parameters.json")
    args = parser.parse_args(argv)
    table = annotate(
        build_table((args.html / "js/config/address_map.js").read_text(encoding="utf-8")),
        json.loads((args.html / "export/item.json").read_text(encoding="utf-8")),
        (args.html / "export/layout.div").read_text(encoding="utf-8", errors="replace"),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(table), encoding="utf-8")
    parameters = table["parameters"]
    logger.info(
        "wrote %d parameters (%d written, %d guarded) to %s",
        len(parameters),
        sum(1 for p in parameters if p["written"]),
        sum(1 for p in parameters if p["guarded"]),
        args.output,
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    main()
