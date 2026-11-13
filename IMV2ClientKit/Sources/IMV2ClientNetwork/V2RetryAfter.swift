import Foundation

/// A server lower bound, never an instruction to replay a request.
public enum V2RetryAfter {
    public static func delay(from value: String?, now: Date = Date()) -> TimeInterval {
        date(from: value, now: now).map { max(0, $0.timeIntervalSince(now)) } ?? 1
    }
    public static func date(from value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 128 else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let seconds = UInt64(value), seconds <= 315_576_000 else { return nil }
            return now.addingTimeInterval(Double(seconds))
        }
        // HTTP IMF-fixdate, plus the two obsolete forms accepted by HTTP recipients.
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'", "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'", "EEE MMM d HH':'mm':'ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value), date >= now,
               date.timeIntervalSince(now) <= 315_576_000 { return date }
        }
        return nil
    }
}
