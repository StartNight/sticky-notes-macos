import Foundation

extension TimeInterval {
    var formattedDuration: String {
        guard isFinite, self > 0 else { return "0:00" }
        let clamped = min(self, Double(Int.max / 2))
        let totalSeconds = Int(clamped.rounded(.down))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
