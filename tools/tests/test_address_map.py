import json

import pytest

from gen_parameter_map import DEFAULT_HTML, Entry, build_table, is_guarded, linear, parse_size, render

ADDRESS_MAP = DEFAULT_HTML / "js/config/address_map.js"

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
        {"name": "PatchName", "offset": 0, "size": 16},
        {"name": "Patch_0", "offset": 16, "size": 129},
        {"name": "Status", "offset": 848, "size": 1},
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
        "louder": "up",
        "written": False,
        "control": None,
        "page": None,
        "position": None,
        "placements": None,
        "panel": None,
        "kind": "numeric",
        "section": None,
        "label": "DRIVE",
        "options": None,
        "valueLabels": None,
        "format": None,
        "visibleWhen": None,
    }
    assert by_id["PRM_EQ_LOW_GAIN"]["rawOffset"] == 20
    assert by_id["PRM_DLY_TIME"]["offset"] == 16 + 127
    # In the Status block only the front-panel knobs are guarded; the general rule does not apply there.
    assert by_id["PRM_KNOB_POS_VOLUME"]["guarded"] is True
    assert by_id["PRM_ODDS_SW"]["kind"] == "switch"
    assert by_id["PRM_PATCH_NAME0"]["kind"] == "text"


def test_render_is_valid_json_with_one_row_per_line() -> None:
    table = build_table(SNIPPET)
    text = render(table)
    assert json.loads(text) == table
    # Header and footer lines plus one line per block and per parameter.
    assert len(text.splitlines()) == 3 + len(table["blocks"]) + 2 + len(table["parameters"]) + 2


@pytest.mark.skipif(not ADDRESS_MAP.exists(), reason="Tone Studio is not installed")
def test_real_address_map() -> None:
    table = build_table(ADDRESS_MAP.read_text(encoding="utf-8"))
    assert len(table["blocks"]) == 31
    assert len(table["parameters"]) == 1465
    assert sum(1 for p in table["parameters"] if p["guarded"]) == 217
    by_key = {(p["block"], p["prm"]): p for p in table["parameters"]}
    assert by_key[("Patch_0", "PRM_PREAMP_A_LEVEL")]["offset"] == 0x28
    assert by_key[("Patch_1", "PRM_FOOT_VOLUME_VOL_LEVEL")]["offset"] == 737
