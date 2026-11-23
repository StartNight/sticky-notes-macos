import Foundation

extension Date {
    var noteListFormatted: String {
        noteListFormatted(relativeTo: Date(), calendar: .current)
    }

    func noteListFormatted(relativeTo referenceDate: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(self, inSameDayAs: referenceDate) {
            return self.formatted(date: .omitted, time: .shortened)
        }
        let startOfSelf = calendar.startOfDay(for: self)
        let startOfRef = calendar.startOfDay(for: referenceDate)
        let dayDiff = calendar.dateComponents([.day], from: startOfSelf, to: startOfRef).day
        if dayDiff == 1 {
            return String(localized: "Yesterday")
        }
        if let dayDiff, (2..<7).contains(dayDiff) {
            return self.formatted(.dateTime.weekday(.wide))
        }
        return self.formatted(date: .abbreviated, time: .omitted)
    }
}
