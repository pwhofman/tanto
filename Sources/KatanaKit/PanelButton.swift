/// A front-panel button that Tone Studio presses instead of writing: VARIATION and the five colour buttons.
///
/// A press is a DT1 of `00` to `7F 01 01 0n`. The amp then does what its own button does, e.g. it moves on to the next
/// colour, and reports the result; the button's LED in the Status block shows it (design spec, section 3.5).
public enum PanelButton: Int, CaseIterable, Sendable {
    /// The VARIATION button of the amp section.
    case variation
    /// The BOOSTER colour button.
    case booster
    /// The MOD colour button.
    case mod
    /// The FX colour button.
    case fx
    /// The DELAY colour button.
    case delay
    /// The REVERB colour button.
    case reverb

    /// Where a press goes: `7F 01 01 00` for VARIATION to `7F 01 01 05` for REVERB.
    public var address: Address {
        Address(packed: 0x7F01_0100 | UInt32(rawValue))
    }

    /// Tone Studio's id of the LED that shows the button's state, in the Status block.
    public var led: String {
        [
            "PRM_LED_STATE_VARI", "PRM_LED_STATE_BOOST", "PRM_LED_STATE_MOD", "PRM_LED_STATE_FX", "PRM_LED_STATE_DELAY",
            "PRM_LED_STATE_REVERB",
        ][rawValue]
    }

    /// The editor section of the button, as in the parameter table.
    public var section: String {
        ["amp", "booster", "mod", "fx", "delay", "reverb"][rawValue]
    }

    /// The button's name on the amp.
    public var label: String {
        ["VARIATION", "BOOSTER COLOR", "MOD COLOR", "FX COLOR", "DELAY COLOR", "REVERB COLOR"][rawValue]
    }
}
