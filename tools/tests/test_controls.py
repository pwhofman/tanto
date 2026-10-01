import json
import re

import pytest

from gen_parameter_map import (
    COMMAND_BUTTONS,
    DEFAULT_HTML,
    Layout,
    ParameterRow,
    annotate,
    blocks_for,
    build_table,
    display_format,
    kind_of,
    section_of,
)

LAYOUT = """
<div id="booster-frame">
  <div id="booster-type-select-box" class="elf-select-box-control" description="booster-type-label"><p>---</p>
    <div id="booster-type-select-box-box"><a href="#" class="elf-select-box-option-control" msg="">CLEAN BOOST</a><a
      href="#" class="elf-select-box-option-control" msg="">MID BOOST</a></div></div>
  <div id="booster-type-label"><p msg="">BOOSTER TYPE</p></div>
  <div id="eq-low-cut-stringer" class="elf-stringer-control" format=""><div style="display:none;"><p msg="">FLAT</p><p
    msg="">20.0<br>Hz</p></div><p msg="">FLAT</p></div>
  <div id="eq-level-stringer" class="elf-stringer-control" format="((value>0)? '+':'') + value + 'dB'"><p>0dB</p></div>
  <div id="panel-booster-spinner" class="elf-spinner-control"><input type="text" min="-1" max="100"
    format="(value === -1)? 'OFF':value"></div>
</div>
<div id="modfx-content-frame">
  <div id="twah-panel"><div id="modfx-twah-peak-dial" description="modfx-twah-peak-label"></div></div>
  <div id="awah-panel"><div id="modfx-autowah-peak-dial"></div></div>
</div>
<div id="modfx-twah-peak-label"><p msg="">PEAK</p></div>
<div id="amp-cab-resonance-select-box" class="elf-select-box-control"></div>
<div id="amp-cab-resonance-label"><p msg="">CAB<br>RESONANCE</p></div>
"""


def row(prm: str, minimum: int = 0, maximum: int = 100, encoding: str = "int1x7") -> ParameterRow:
    return {
        "prm": prm,
        "name": "",
        "block": "Patch_0",
        "offset": 0,
        "encoding": encoding,
        "minimum": minimum,
        "maximum": maximum,
        "rawOffset": 0,
        "initial": 0,
        "guarded": False,
        "louder": None,
        "written": False,
        "control": None,
        "page": None,
        "position": None,
        "panel": None,
        "kind": "numeric",
        "section": None,
        "label": "",
        "options": None,
        "valueLabels": None,
        "format": None,
        "visibleWhen": None,
    }


def test_section_of() -> None:
    assert section_of("booster-drive-dial", "Patch_0") == "booster"
    assert section_of("panel-amp-gain-knob", "Status") == "amp"
    assert section_of("panel-eq-bass-knob", "Status") == "amp"
    assert section_of("panel-presence-knob", "Status") == "amp"
    assert section_of("panel-booster-knob", "Status") == "booster"
    assert section_of("modfx-mod-type-select-box", "Fx(1)") == "mod"
    assert section_of("modfx-twah-peak-dial", "Fx(2)") == "fx"
    assert section_of("delay-delay2-type-select-box", "Delay(2)") == "delay2"
    assert section_of("eq-peq-level-dial", "Patch_0") == "eq1"
    assert section_of("sr-send-level-dial", "Patch_1") == "sendreturn"
    assert section_of("asgn-knob-booster-select-box", "KnobAsgn") is None
    with pytest.raises(ValueError, match="unknown control"):
        section_of("mystery-dial", "Patch_0")


def test_blocks_for_shared_layouts() -> None:
    assert blocks_for("modfx-mod-sw-btn", "Fx(1)") == ["Fx(1)"]
    assert blocks_for("modfx-fx-sw-btn", "Fx(1)") == ["Fx(2)"]
    assert blocks_for("modfx-twah-peak-dial", "Fx(1)") == ["Fx(1)", "Fx(2)"]
    assert blocks_for("delay-delay1-type-select-box", "Delay(1)") == ["Delay(1)"]
    assert blocks_for("delay-delay2-type-select-box", "Delay(1)") == ["Delay(2)"]
    assert blocks_for("delay-tap-time-knob", "Delay(1)") == ["Delay(1)"]
    assert blocks_for("delay-pan-time-dial", "Delay(1)") == ["Delay(1)", "Delay(2)"]
    assert blocks_for("booster-drive-dial", "Patch_0") == ["Patch_0"]


def test_kind_of() -> None:
    assert kind_of(row("PRM_PATCH_NAME0", 32, 125, "ascii16"), set()) == "text"
    assert kind_of(row("PRM_ODDS_SOLO_SW", 0, 1), {"dial"}) == "switch"
    assert kind_of(row("PRM_ODDS_TYPE", 0, 25), {"select-box"}) == "picker"
    assert kind_of(row("PRM_LED_STATE_BOOST", 0, 3), {"toggle-button"}) == "picker"
    assert kind_of(row("PRM_KNOB_POS_TYPE", 0, 4), {"knob"}) == "picker"
    assert kind_of(row("PRM_KNOB_POS_GAIN"), {"knob", "spinner"}) == "numeric"
    assert kind_of(row("PRM_PEDAL_FX_WAH_PEDAL_POSITION"), {"dial"}) == "numeric"


def test_display_format() -> None:
    assert display_format("((value>0)? '+':'') + value + 'dB'") == "signedDecibels"
    assert display_format("((value>0)?'+':'')+value") == "signed"
    assert display_format("((value>0)?'+':'')+(value/2)+((value&amp;1)?'':'.0')+'<br>dB'") == "signedHalfDecibels"
    assert display_format("value + '<br>ms'") == "milliseconds"
    assert display_format("(value === -1)? 'OFF':value") == "offBelowZero"
    with pytest.raises(ValueError, match="unknown display format"):
        display_format("value * 3")


def test_layout_parsing() -> None:
    layout = Layout.parse(LAYOUT)
    assert layout.options("booster-type-select-box") == ["CLEAN BOOST", "MID BOOST"]
    assert layout.label_of("booster-type-select-box") == "BOOSTER TYPE"
    assert layout.label_of("modfx-twah-peak-dial") == "PEAK"
    assert layout.label_of("amp-cab-resonance-select-box") == "CAB RESONANCE"
    assert layout.value_labels("eq-low-cut-stringer") == ["FLAT", "20.0 Hz"]
    assert layout.value_labels("eq-level-stringer") is None
    assert layout.format_expression("eq-level-stringer") == "((value>0)? '+':'') + value + 'dB'"
    assert layout.format_expression("panel-booster-spinner") == "(value === -1)? 'OFF':value"
    assert layout.children("modfx-content-frame") == ["twah-panel", "awah-panel"]
    assert layout.parent("modfx-twah-peak-dial") == "twah-panel"
    assert layout.control_class("booster-type-select-box") == "select-box"


@pytest.mark.skipif(not DEFAULT_HTML.exists(), reason="Tone Studio is not installed")
def test_real_controls() -> None:
    table = annotate(
        build_table((DEFAULT_HTML / "js/config/address_map.js").read_text(encoding="utf-8")),
        json.loads((DEFAULT_HTML / "export/item.json").read_text(encoding="utf-8")),
        (DEFAULT_HTML / "export/layout.div").read_text(encoding="utf-8", errors="replace"),
    )
    by_key = {(p["block"], p["prm"]): p for p in table["parameters"]}
    by_offset = {p["offset"]: p for p in table["parameters"]}
    parameters = table["parameters"]
    assert sum(1 for p in parameters if p["guarded"]) == 217
    assert all(p["section"] is not None for p in parameters if p["written"])
    assert not any(p["written"] for p in parameters if "Asgn" in p["block"])

    volume_knob = by_key[("Status", "PRM_KNOB_POS_VOLUME")]
    assert volume_knob["offset"] == 850  # 60 00 06 52
    assert (volume_knob["written"], volume_knob["guarded"], volume_knob["section"]) == (True, True, "amp")
    for block, prm in [
        ("Patch_0", "PRM_PREAMP_A_LEVEL"),
        ("Patch_0", "PRM_PREAMP_A_GAIN"),
        ("Patch_0", "PRM_PREAMP_A_SOLO_LEVEL"),
        ("Patch_1", "PRM_FOOT_VOLUME_VOL_LEVEL"),
    ]:
        assert (by_key[(block, prm)]["guarded"], by_key[(block, prm)]["written"]) == (True, False), prm

    amp_type = by_key[("Status", "PRM_KNOB_POS_TYPE")]
    assert amp_type["kind"] == "picker"
    assert [o["label"] for o in amp_type["options"] or []] == ["ACOUSTIC", "CLEAN", "CRUNCH", "LEAD", "BROWN"]
    led = by_key[("Status", "PRM_LED_STATE_BOOST")]
    assert (led["kind"], [o["label"] for o in led["options"] or []]) == ("picker", ["OFF", "GREEN", "RED", "YELLOW"])
    assert by_key[("Patch_0", "PRM_ODDS_SOLO_SW")]["kind"] == "switch"
    assert (by_key[("Patch_0", "PRM_ODDS_TYPE")]["options"] or [])[0] == {"value": 1, "label": "CLEAN BOOST"}
    assert (by_key[("Patch_1", "PRM_REVERB_TYPE")]["options"] or [])[0] == {"value": 4, "label": "PLATE"}

    # Changes in the louder direction are ramped (spec 5.2): guarded parameters upwards, and without a ceiling the
    # limiter's threshold upwards and its ratio downwards.
    assert all(p["louder"] == "up" for p in parameters if p["guarded"])
    for block in ("Fx(1)", "Fx(2)"):
        threshold = by_key[(block, "PRM_FX1_LIMITER_THRESHOLD")]
        ratio = by_key[(block, "PRM_FX1_LIMITER_RATIO")]
        assert (threshold["guarded"], threshold["louder"]) == (False, "up")
        assert (ratio["guarded"], ratio["louder"]) == (False, "down")
    assert by_key[("Fx(1)", "PRM_FX1_TREMOLO_DEPTH")]["louder"] is None
    assert sum(1 for p in parameters if p["louder"]) == 217 + 4

    # The panel's VARIATION and colour buttons send a button press instead of writing the LED they show.
    controller = (DEFAULT_HTML / "js/businesslogic/bts/effect_controller.js").read_text(encoding="utf-8")
    assert set(re.findall(r"'([\w-]+)':\s*\{\s*addr:\s*0x7F0101", controller)) == COMMAND_BUTTONS
    for led in ("VARI", "BOOST", "MOD", "FX", "DELAY", "REVERB"):
        assert not by_key[("Status", f"PRM_LED_STATE_{led}")]["written"], led
    assert sum(1 for p in parameters if p["written"]) == 616

    # How Tone Studio shows a control and where: on its page, measured from the page's top left, and on the front panel.
    drive = by_key[("Patch_0", "PRM_ODDS_DRIVE")]
    assert (drive["control"], drive["page"], drive["position"], drive["panel"]) == (
        "knob",
        "booster",
        {"x": 34, "y": 101},
        None,
    )
    gain = by_key[("Status", "PRM_KNOB_POS_GAIN")]
    assert (gain["control"], gain["page"], gain["position"], gain["panel"]) == ("knob", None, None, {"x": 124, "y": 88})
    # The EFFECTS page has a column per effect for the effect's colour assignments.
    green = by_key[("Patch_2", "PRM_FXBOX_ASGN_BOOSTER_G")]
    assert (green["section"], green["page"], green["position"]) == ("booster", "effects-booster", {"x": 20, "y": 56})
    # DELAY TIME is the TIME dial of the DELAY page; on the EFFECTS page only a hidden knob behind TAP holds it.
    for offset in (642, 674):
        assert (by_offset[offset]["page"], by_offset[offset]["position"]) == ("delay", {"x": 34, "y": 101})
    assert all((p["page"] is None) == (p["position"] is None) for p in parameters)
    assert by_key[("Patch_0", "PRM_ODDS_TYPE")]["control"] == "menu"
    assert by_key[("Patch_0", "PRM_ODDS_SW")]["control"] == "switch"
    assert by_key[("Fx(1)", "PRM_FX1_GEQ_BAND1")]["control"] == "slider"
    written = [p for p in parameters if p["written"] and p["kind"] != "text"]
    assert all(p["control"] in ("knob", "slider", "switch", "menu", "segmented") for p in written)
    assert all(p["position"] is not None or p["panel"] is not None for p in written)
    # MOD and FX share a layout, so their controls sit at the same places.
    assert by_offset[134]["position"] == by_offset[390]["position"]
    assert by_offset[134]["page"] == by_offset[390]["page"] == "modfx"

    # T.WAH PEAK shows for MOD/FX type 0 only, in both the MOD (Fx(1)) and the FX (Fx(2)) block.
    assert by_offset[134]["visibleWhen"] == [{"offset": 129, "values": [0]}]
    assert (by_offset[390]["visibleWhen"], by_offset[390]["section"]) == ([{"offset": 385, "values": [0]}], "fx")
    # Without an `order`, a value shows the page of the same number: the PEDAL FX type, the EQ type, and CONTOUR's
    # selection inside its on/off switch.
    assert [by_offset[o]["visibleWhen"] for o in (723, 728, 732)] == [
        [{"offset": 721, "values": [v]}] for v in (0, 1, 2)
    ]
    assert [by_offset[o]["visibleWhen"] for o in (67, 77)] == [[{"offset": 65, "values": [v]}] for v in (0, 1)]
    assert by_offset[1976]["visibleWhen"] == [{"offset": 791, "values": [1]}, {"offset": 790, "values": [1]}]

    # A menu of two values has its options too, and so do radio buttons: the CHAIN patterns.
    assert by_offset[65]["options"] == [{"value": 0, "label": "PARAMETRIC EQ"}, {"value": 1, "label": "GE-10"}]
    chains = ["CHAIN1", "CHAIN2-1", "CHAIN3-1", "CHAIN4-1", "CHAIN2-2", "CHAIN3-2", "CHAIN4-2"]
    assert by_key[("Patch_2", "PRM_CHAIN_PTN")]["options"] == [{"value": v, "label": c} for v, c in enumerate(chains)]
    # CONTOUR's hidden radio button on its page has no options to give.
    assert by_key[("Patch_1", "PRM_CONTOUR_SELECT")]["options"] is None
    # The label under a control wins over the one its description names, which is wrong for the EQs' HIGH-MID GAIN.
    # Two solo controls with generated ids have their labels beside them.
    assert by_offset[73]["label"] == "HIGH-MID GAIN"
    assert (by_offset[1936]["label"], by_offset[1937]["label"]) == ("POSITION", "SOLO EQ")


def test_guard_rule_also_reads_tone_studio_labels() -> None:
    address_map = """
var prm_prop_patch_delay = [
    { addr:0x00000000, size:INTEGER1x7, ofs:0, init:50, min:0, max:120, name:'' }, //
    { addr:0x00000001, size:INTEGER1x7, ofs:0, init:50, min:0, max:100, name:'' }, //
];
var Patch = [
    { addr: 0x00000500, size: 0, child: prm_prop_patch_delay, name: 'Delay(1)' },
    { addr: 0x00000520, size: 0, child: prm_prop_patch_delay, name: 'Delay(2)' },
];
"""
    items: dict[str, dict[str, object]] = {
        "delay-tap-level-dial": {"pid": "Temporary%Delay(1)%0"},
        "delay-tap-rate-dial": {"pid": "Temporary%Delay(1)%1"},
    }
    layout = """
<div id="delay-tap-level-dial" class="elf-dial-control" description="delay-tap-level-label"></div>
<div id="delay-tap-level-label"><p>EFFECT LEVEL</p></div>
<div id="delay-tap-rate-dial" class="elf-dial-control"></div>
<div id="delay-tap-rate-label"><p>RATE</p></div>
"""
    table = annotate(build_table(address_map), items, layout)
    by_offset = {p["offset"]: p for p in table["parameters"]}
    assert (by_offset[640]["guarded"], by_offset[640]["written"], by_offset[640]["section"]) == (True, True, "delay")
    assert (by_offset[672]["guarded"], by_offset[672]["section"]) == (True, "delay2")
    assert (by_offset[641]["guarded"], by_offset[641]["label"]) == (False, "RATE")
    assert (by_offset[640]["louder"], by_offset[641]["louder"]) == ("up", None)
