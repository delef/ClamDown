/// Turns the raw CPU temperature readings into the two numbers ClamDown uses.
public enum CPUTemperatures {
    /// The average and the hottest of the plausible values, in °C. Both nil when none is plausible.
    public static func summary(_ values: [Double]) -> (average: Double?, hottest: Double?) {
        let plausible = values.filter(isPlausible)
        guard let hottest = plausible.max() else { return (nil, nil) }
        return (plausible.reduce(0, +) / Double(plausible.count), hottest)
    }

    /// Unused sensors read 0 or nonsense; real temperatures fall in this range.
    public static func isPlausible(_ celsius: Double) -> Bool { celsius > 10 && celsius < 130 }
}
