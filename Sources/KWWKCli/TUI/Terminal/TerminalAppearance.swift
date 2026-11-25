import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether the terminal draws on a dark or a light background, so `Theme`
/// can pick a palette that reads on it.
enum TerminalAppearance: String, Sendable {
    case dark
    case light

    /// Environment override: `KWWK_THEME=light` / `KWWK_THEME=dark`.
    static let overrideEnvironmentKey = "KWWK_THEME"

    /// Resolve the appearance: the `KWWK_THEME` override, then the
    /// terminal's own answer to an OSC 11 background-color query, then
    /// `COLORFGBG`, else dark (the palette kwwk was designed on).
    ///
    /// Must run before the TUI puts stdin in raw mode and starts reading it,
    /// or the terminal's reply would arrive as keystrokes.
    static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalAppearance {
        if let forced = environment[overrideEnvironmentKey].flatMap({ TerminalAppearance(rawValue: $0.lowercased()) }) {
            return forced
        }
        if let reply = queryBackgroundColor(), let fromTerminal = parseOSC11Reply(reply) {
            return fromTerminal
        }
        if let colorfgbg = environment["COLORFGBG"], let fromEnv = parseCOLORFGBG(colorfgbg) {
            return fromEnv
        }
        return .dark
    }

    // MARK: - Parsing

    /// Parse a reply to `OSC 11 ; ?` — `ESC ] 11 ; rgb:RRRR/GGGG/BBBB` (1–4
    /// hex digits per channel) terminated by BEL or ST — into an appearance
    /// by the background's relative luminance.
    static func parseOSC11Reply(_ reply: String) -> TerminalAppearance? {
        guard let range = reply.range(of: "]11;rgb:") else { return nil }
        let body = reply[range.upperBound...].prefix { $0.isHexDigit || $0 == "/" }
        let channels = body.split(separator: "/").prefix(3).compactMap { component -> Double? in
            guard (1...4).contains(component.count), let value = UInt32(component, radix: 16) else { return nil }
            let maximum = Double((1 << (4 * component.count)) - 1)
            return Double(value) / maximum
        }
        guard channels.count == 3 else { return nil }
        // Rec. 709 relative luminance on the (approximately linearised) channels.
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(channels[0]) + 0.7152 * linear(channels[1]) + 0.0722 * linear(channels[2])
        return luminance > 0.4 ? .light : .dark
    }

    /// `COLORFGBG` is `fg;bg` (sometimes `fg;default;bg`) in ANSI color
    /// numbers; a background of 7 (white) or 9–15 (bright colors) is light.
    static func parseCOLORFGBG(_ value: String) -> TerminalAppearance? {
        guard let last = value.split(separator: ";").last, let bg = Int(last) else { return nil }
        return bg == 7 || (9...15).contains(bg) ? .light : .dark
    }

    // MARK: - Query

    /// Ask the terminal for its background color. Sends OSC 11 followed by a
    /// primary device-attributes request (DA1): every terminal answers DA1,
    /// so its reply ends the wait at once on terminals that ignore OSC 11
    /// instead of running out the timeout. Returns whatever came back, or
    /// nil when stdin/stdout is not a terminal.
    static func queryBackgroundColor(timeout: TimeInterval = 0.25) -> String? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return nil }
        var saved = termios()
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return nil }
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved) }

        let query = "\u{1B}]11;?\u{1B}\\\u{1B}[c"
        _ = query.withCString { write(STDOUT_FILENO, $0, strlen($0)) }

        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&fds, 1, remaining) > 0 else { break }
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            guard n > 0 else { break }
            reply.append(contentsOf: buffer[0..<n])
            if endsWithDeviceAttributes(reply) { break }
        }
        return reply.isEmpty ? nil : String(decoding: reply, as: UTF8.self)
    }

    /// Whether `bytes` holds a complete DA1 reply (`ESC [ ? … c`).
    static func endsWithDeviceAttributes(_ bytes: [UInt8]) -> Bool {
        guard let csi = bytes.lastIndexOfSequence([0x1B, 0x5B, 0x3F]) else { return false }
        return bytes[csi...].contains(UInt8(ascii: "c"))
    }
}

private extension Array where Element == UInt8 {
    func lastIndexOfSequence(_ needle: [UInt8]) -> Int? {
        guard count >= needle.count else { return nil }
        for start in stride(from: count - needle.count, through: 0, by: -1)
        where Array(self[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }
}
