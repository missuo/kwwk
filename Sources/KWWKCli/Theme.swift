import Foundation
import NIOConcurrencyHelpers

/// Build/version surface for the CLI, rendered on the TUI welcome card.
/// Maintained by hand — no release tooling touches this file — so bump it
/// alongside each tag. (`--help` does not print a version.)
enum KWWKBuild {
    static let version = "0.1.130"
}

/// Truecolor palette + text styling for the redesigned TUI chrome. The
/// legacy `Style` enum (256-color badges) is still used by the transcript
/// renderer; `Theme` layers a calmer, omp-inspired look on top — rounded
/// boxes, a cyan→violet accent gradient, and muted borders — using 24-bit
/// SGR so the colors stay consistent across terminal palettes.
enum Theme {
    static let reset = "\u{1B}[0m"

    typealias RGB = (r: Int, g: Int, b: Int)

    /// One palette per terminal background. Same green family in both; the
    /// light one darkens foregrounds for contrast on white and swaps the dark
    /// fills (user bar, selected chip) for pale tints.
    struct Palette: Sendable {
        let accent: RGB      // headers, prompt glyph (emerald)
        let accentDim: RGB   // forest
        let gradFrom: RGB    // logo gradient start (teal-green)
        let gradTo: RGB      // logo gradient end (lime)
        let border: RGB      // box rules
        let muted: RGB       // secondary text
        let faint: RGB       // tertiary / hints
        let text: RGB        // primary text
        let success: RGB
        let warn: RGB
        let userBarBg: RGB   // user message bar background
        let chipBg: RGB      // selected-chip fill
        let chipFg: RGB      // selected-chip label
        let code: RGB        // markdown inline code and code blocks
        let link: RGB        // markdown link text

        static let dark = Palette(
            accent: (80, 210, 140),
            accentDim: (58, 150, 104),
            gradFrom: (72, 196, 150),
            gradTo: (158, 230, 130),
            border: (64, 92, 76),
            muted: (140, 168, 148),
            faint: (92, 116, 100),
            text: (216, 224, 218),
            success: (110, 210, 140),
            warn: (232, 178, 96),
            userBarBg: (26, 44, 34),
            chipBg: (34, 72, 52),
            chipFg: (245, 250, 246),
            code: (222, 178, 120),
            link: (110, 180, 230)
        )

        static let light = Palette(
            accent: (18, 138, 78),
            accentDim: (28, 112, 72),
            gradFrom: (22, 150, 106),
            gradTo: (96, 168, 48),
            border: (176, 196, 184),
            muted: (86, 110, 96),
            faint: (132, 152, 140),
            text: (30, 38, 34),
            success: (24, 140, 76),
            warn: (176, 106, 16),
            userBarBg: (226, 241, 231),
            chipBg: (204, 232, 214),
            chipFg: (18, 64, 40),
            code: (168, 84, 20),
            link: (24, 100, 180)
        )
    }

    private static let appearanceBox = NIOLockedValueBox(TerminalAppearance.dark)

    /// The terminal background the palette is drawn for. Set once at TUI
    /// start from `TerminalAppearance.detect()`; dark until then.
    static var appearance: TerminalAppearance {
        get { appearanceBox.withLockedValue { $0 } }
        set { appearanceBox.withLockedValue { $0 = newValue } }
    }

    static var palette: Palette { appearance == .light ? .light : .dark }

    static var accent: RGB { palette.accent }
    static var accentDim: RGB { palette.accentDim }
    static var gradFrom: RGB { palette.gradFrom }
    static var gradTo: RGB { palette.gradTo }
    static var border: RGB { palette.border }
    static var muted: RGB { palette.muted }
    static var faint: RGB { palette.faint }
    static var text: RGB { palette.text }
    static var success: RGB { palette.success }
    static var warn: RGB { palette.warn }
    static var userBarBg: RGB { palette.userBarBg }
    static var code: RGB { palette.code }
    static var link: RGB { palette.link }

    static func fg(_ c: (r: Int, g: Int, b: Int)) -> String {
        "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m"
    }

    static func paint(_ s: String, _ c: (r: Int, g: Int, b: Int), bold: Bool = false) -> String {
        (bold ? "\u{1B}[1m" : "") + fg(c) + s + reset
    }

    static func bg(_ c: (r: Int, g: Int, b: Int)) -> String {
        "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m"
    }

    /// omp-style full-width user-message bar: a tinted background row with an
    /// accent `❯` glyph and the user's text in primary color. Multi-line text
    /// is returned as one bar per line. Committed to scrollback as a block.
    ///
    /// The bar is filled to the right edge with erase-to-end-of-line (which
    /// paints the current background), not trailing spaces: spaces become
    /// real cells that wrap into a ragged second row when the window is
    /// narrowed later. Text wider than `width - 1` is truncated.
    static func userBar(_ text: String, width: Int) -> [String] {
        let inner = max(0, width - 1)            // leave the last column clear
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { i, raw in
            let glyph = i == 0 ? "❯ " : "  "
            let visText = ANSI.visibleWidth(raw) + 2
            let clipped = visText > inner ? ANSI.truncate(raw, to: max(0, inner - 2)) : raw
            return bg(userBarBg) + "\u{1B}[1m" + fg(accent) + glyph
                + "\u{1B}[22m" + fg(Theme.text) + clipped + "\u{1B}[K" + reset
        }
    }

    /// Selected-chip style: bold near-white text on a dark forest background,
    /// padded one space each side so the label reads as a solid block (the
    /// /model provider tab bar's active tab). Adds 2 visible columns.
    static func chipText(_ s: String) -> String {
        bg(chipBg) + "\u{1B}[1m" + fg(chipFg) + " " + s + " " + reset
    }
    static var chipBg: RGB { palette.chipBg }
    static var chipFg: RGB { palette.chipFg }

    static func accentText(_ s: String, bold: Bool = true) -> String { paint(s, accent, bold: bold) }
    static func mutedText(_ s: String) -> String { paint(s, muted) }
    static func faintText(_ s: String) -> String { paint(s, faint) }
    static func bodyText(_ s: String) -> String { paint(s, text) }
    static func borderText(_ s: String) -> String { paint(s, border) }

    /// Per-character linear interpolation between two RGB stops across the
    /// visible glyphs of `s`. ANSI control bytes are skipped so a pre-styled
    /// string is left untouched. Used for the logo + wordmark.
    static func gradient(
        _ s: String,
        from: (r: Int, g: Int, b: Int) = gradFrom,
        to: (r: Int, g: Int, b: Int) = gradTo,
        bold: Bool = true
    ) -> String {
        let glyphs = Array(s)
        let n = max(1, glyphs.count - 1)
        var out = bold ? "\u{1B}[1m" : ""
        for (i, ch) in glyphs.enumerated() {
            if ch == " " { out.append(" "); continue }
            let t = Double(i) / Double(n)
            let r = Int((Double(from.r) + (Double(to.r) - Double(from.r)) * t).rounded())
            let g = Int((Double(from.g) + (Double(to.g) - Double(from.g)) * t).rounded())
            let b = Int((Double(from.b) + (Double(to.b) - Double(from.b)) * t).rounded())
            out += "\u{1B}[38;2;\(r);\(g);\(b)m\(ch)"
        }
        out += reset
        return out
    }
}

/// ANSI-aware rounded-box drawing. Every helper returns a single styled
/// line whose visible width is exactly `width` (or `≤ width` after a
/// truncate), so the retained full-screen frame can stack them without
/// jitter. Borders are drawn in `Theme.border`; callers own the interior
/// styling.
enum Box {
    static let tl = "╭", tr = "╮", bl = "╰", br = "╯"
    static let h = "─", v = "│"

    /// Pad a styled string with trailing spaces to exactly `width` visible
    /// columns (truncating if it is already wider). Trailing spaces carry no
    /// active SGR, so they are safe at any row position.
    static func pad(_ s: String, to width: Int) -> String {
        let vis = ANSI.visibleWidth(s)
        if vis >= width { return ANSI.truncate(s, to: width) }
        return s + String(repeating: " ", count: width - vis)
    }

    /// Top border with an optional inset label: `╭─ label ──────────╮`.
    static func top(width: Int, label: String? = nil) -> String {
        guard width >= 2 else { return ANSI.truncate(Theme.borderText(tl), to: width) }
        let inner = width - 2
        var mid: String
        if let label, !label.isEmpty {
            let lead = 1
            // Clamp the label to the inner span (minus the lead rule and the
            // two padding spaces) so an over-long breadcrumb can't overflow
            // the border past `width` and drop the corner.
            let tag = " " + ANSI.truncate(label, to: max(0, inner - lead - 2)) + " "
            let tagWidth = ANSI.visibleWidth(tag)
            let rest = max(0, inner - lead - tagWidth)
            mid = Theme.borderText(String(repeating: h, count: lead))
                + tag
                + Theme.borderText(String(repeating: h, count: rest))
        } else {
            mid = Theme.borderText(String(repeating: h, count: inner))
        }
        return Theme.borderText(tl) + mid + Theme.borderText(tr)
    }

    /// Bottom border with an optional right-aligned label:
    /// `╰──────────── label ─╯`.
    static func bottom(width: Int, rightLabel: String? = nil) -> String {
        guard width >= 2 else { return ANSI.truncate(Theme.borderText(bl), to: width) }
        let inner = width - 2
        var mid: String
        if let rightLabel, !rightLabel.isEmpty {
            let trail = 1
            // Clamp the label to the inner span (minus the trailing rule and
            // the two padding spaces) so an over-long label can't overflow the
            // border past `width` and drop the corner.
            let tag = " " + ANSI.truncate(rightLabel, to: max(0, inner - trail - 2)) + " "
            let tagWidth = ANSI.visibleWidth(tag)
            let rest = max(0, inner - trail - tagWidth)
            mid = Theme.borderText(String(repeating: h, count: rest))
                + tag
                + Theme.borderText(String(repeating: h, count: trail))
        } else {
            mid = Theme.borderText(String(repeating: h, count: inner))
        }
        return Theme.borderText(bl) + mid + Theme.borderText(br)
    }

    /// Interior row: `│ <content padded to inner> │`.
    static func row(_ content: String, width: Int) -> String {
        guard width >= 4 else { return ANSI.truncate(Theme.borderText(v), to: width) }
        let inner = width - 4   // leading + trailing border + one space each side
        let body = pad(content, to: inner)
        return Theme.borderText(v) + " " + body + " " + Theme.borderText(v)
    }
}
