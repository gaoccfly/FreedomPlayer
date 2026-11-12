import SwiftUI

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0A0A0E)
    static let panel = Color(hex: 0x14141B)
    static let card = Color(hex: 0x1B1B24)
    static let accent = Color(hex: 0xFF7A1F)
    static let textDim = Color(hex: 0x9A9AA8)
}

func timeString(_ t: Double) -> String {
    guard t.isFinite, t > 0 else { return "00:00" }
    let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%02d:%02d", m, sec)
}
