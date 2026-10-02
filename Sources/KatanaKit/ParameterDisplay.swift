extension Parameter {
    /// The text Tone Studio shows for a value: the option label, the value label, the display format, or the number.
    ///
    /// - Parameter value: A displayed value.
    /// - Returns: E.g. `CLEAN BOOST`, `ON`, `+1.5dB`, `320ms` or `OFF`.
    public func displayText(for value: Int) -> String {
        if let option = options?.first(where: { $0.value == value }) {
            return option.label
        }
        if let valueLabels, valueLabels.indices.contains(value - minimum) {
            return valueLabels[value - minimum]
        }
        let sign = value > 0 ? "+" : value < 0 ? "-" : ""
        switch format {
        case nil:
            return "\(value)"
        case .signed:
            return "\(sign)\(abs(value))"
        case .signedDecibels:
            return "\(sign)\(abs(value))dB"
        case .signedHalfDecibels:
            return "\(sign)\(abs(value) / 2).\(abs(value) % 2 == 0 ? 0 : 5)dB"
        case .milliseconds:
            return "\(value)ms"
        case .plusOne:
            return "\(value + 1)"
        case .tenthsOfSeconds:
            return "\(value / 10).\(value % 10)s"
        case .offBelowZero:
            return value < 0 ? "OFF" : "\(value)"
        case .percent:
            return "\(value)%"
        }
    }

    /// The value that a typed text means, as Tone Studio's number pad takes one: a number in the displayed unit, with or
    /// without the unit, or a value's name; a number for named values picks the nearest one, e.g. `1250` or `1.25k` for
    /// `1.25 kHz`. The value is kept within the parameter's range.
    ///
    /// - Parameter text: E.g. `320`, `320ms`, `+1.5dB`, `off` or `flat`.
    /// - Returns: The value, or `nil` if the text means none.
    public func value(forText text: String) -> Int? {
        let typed = Self.squeezed(text)
        guard !typed.isEmpty else { return nil }
        if let option = options?.first(where: { Self.squeezed($0.label) == typed }) {
            return option.value
        }
        if let valueLabels {
            if let index = valueLabels.firstIndex(where: { Self.squeezed($0) == typed }) {
                return minimum + index
            }
            guard let number = Self.number(in: typed) else { return nil }
            let numbered = valueLabels.indices.compactMap { index in
                Self.number(in: valueLabels[index]).map { (index, $0) }
            }
            return numbered.min { abs($0.1 - number) < abs($1.1 - number) }.map { minimum + $0.0 }
        }
        if format == .offBelowZero, typed == "off" {
            return minimum
        }
        guard let number = Self.number(in: typed) else { return nil }
        let value =
            switch format {
            case .signedHalfDecibels: number * 2
            case .tenthsOfSeconds: number * 10
            case .plusOne: number - 1
            default: number
            }
        return min(max(Int(value.rounded()), minimum), maximum)
    }

    private static func squeezed(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    // The number a text starts with, with k for thousands: -1.5 in `-1.5db`, 1250 in `1.25khz`; `nil` without one.
    private static func number(in text: String) -> Double? {
        let text = squeezed(text)
        var digits = ""
        for character in text {
            if character.isNumber || character == "." || (digits.isEmpty && (character == "-" || character == "+")) {
                digits.append(character)
            } else {
                break
            }
        }
        guard let number = Double(digits) else { return nil }
        return text.dropFirst(digits.count).hasPrefix("k") ? number * 1_000 : number
    }

    /// Whether the parameter is shown, given the live values of the parameters its visibility depends on.
    ///
    /// - Parameter value: The displayed value of the parameter at an offset, or `nil` if unknown.
    /// - Returns: `true` if every condition of `visibleWhen` holds; an unknown value fails its condition.
    public func isVisible(_ value: (Int) -> Int?) -> Bool {
        Self.hold(visibleWhen, value)
    }

    /// Where Tone Studio puts the parameter on its page for the current types.
    ///
    /// - Parameter value: The displayed value of the parameter at an offset, or `nil` if unknown.
    /// - Returns: The first of `placements` whose conditions hold, otherwise `position`.
    public func position(_ value: (Int) -> Int?) -> Position? {
        guard let placement = placements?.first(where: { Self.hold($0.visibleWhen, value) }) else { return position }
        return Position(x: placement.x, y: placement.y)
    }

    // Whether every condition holds; an unknown value fails its condition.
    private static func hold(_ conditions: [Condition]?, _ value: (Int) -> Int?) -> Bool {
        (conditions ?? []).allSatisfy { condition in
            value(condition.offset).map(condition.values.contains) ?? false
        }
    }
}
