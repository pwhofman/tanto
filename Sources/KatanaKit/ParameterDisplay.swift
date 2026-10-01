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

    /// Whether the parameter is shown, given the live values of the parameters its visibility depends on.
    ///
    /// - Parameter value: The displayed value of the parameter at an offset, or `nil` if unknown.
    /// - Returns: `true` if every condition of `visibleWhen` holds; an unknown value fails its condition.
    public func isVisible(_ value: (Int) -> Int?) -> Bool {
        (visibleWhen ?? []).allSatisfy { condition in
            value(condition.offset).map(condition.values.contains) ?? false
        }
    }
}
