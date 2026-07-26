import Foundation

/// Human-readable byte sizes (e.g. "17.58 GB", "67.6 MB", "2 KB", "0 B").
/// Formatted manually instead of ByteCountFormatter (which emits "Zero KB" at 0 and
/// varies precision/units by locale).
enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        // Precision: B/KB → whole; MB → 1 decimal; GB+ → 2 decimals.
        let decimals = idx <= 1 ? 0 : (idx == 2 ? 1 : 2)
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return "\(s) \(units[idx])"
    }
}

/// Single source for "how much RAM does this Mac have" — the number every label shows.
enum SystemRAM {
    static let bytesPerGiB: Int64 = 1_073_741_824
    /// Installed physical RAM in whole GiB.
    static var installedGB: Int { Int(ProcessInfo.processInfo.physicalMemory / UInt64(bytesPerGiB)) }
}
