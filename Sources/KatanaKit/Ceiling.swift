/// The safety ceiling of design spec section 5.2.
public enum Ceiling {
    /// Whether a ceiling percentage is allowed: 0–100 in steps of 5.
    ///
    /// - Parameter percent: The percentage.
    /// - Returns: `true` if allowed.
    public static func isValid(percent: Int) -> Bool {
        (0...100).contains(percent) && percent % 5 == 0
    }

    /// The highest value Tanto may raise a guarded parameter to: `minimum + ⌊percent · (maximum − minimum) / 100⌋`.
    ///
    /// - Parameters:
    ///   - parameter: Any parameter.
    ///   - percent: The ceiling percentage.
    /// - Returns: The ceiling, or `nil` for unguarded parameters.
    public static func value(of parameter: Parameter, percent: Int) -> Int? {
        guard parameter.guarded else { return nil }
        return parameter.minimum + percent * (parameter.maximum - parameter.minimum) / 100
    }
}
