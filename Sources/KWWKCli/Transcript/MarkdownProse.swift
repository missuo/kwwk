import Foundation

/// Line-at-a-time Markdown styling for assistant prose in the transcript.
///
/// The transcript commits assistant text one logical line at a time as it
/// streams, so this renders a line at a time too, carrying the only
/// cross-line state Markdown needs here: whether a fenced code block is open.
/// Output rows are word-wrapped to `width` with hanging indents for list
/// items and quotes. Plain lines without Markdown come back unchanged (apart
/// from wrapping), so ordinary prose renders exactly as before.
///
/// Covered: ATX headings, bullet / ordered / task lists, block quotes,
/// fenced code, horizontal rules, table rows, and inline `code`, **bold**,
/// *italic*, ~~strike~~ and [links](url). Not a CommonMark implementation.
struct MarkdownProse {
    private(set) var inFence = false
    private var fenceMarker = ""

    /// Render one logical line (no `\n`), updating fence state.
    mutating func render(_ line: String, width: Int) -> [String] {
        let width = max(8, width)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let marker = Self.fenceMarker(trimmed), !inFence || trimmed.hasPrefix(fenceMarker) {
            if inFence {
                inFence = false
                return [Theme.faintText(String(repeating: "─", count: min(width, 24)))]
            }
            inFence = true
            fenceMarker = marker
            let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            let rule = String(repeating: "─", count: 2)
            return [Theme.faintText(language.isEmpty ? rule : "\(rule) \(language)")]
        }
        if inFence {
            let code = line.replacingOccurrences(of: "\t", with: "    ")
            return ANSI.wrap(Theme.fg(Theme.code) + code + Theme.reset, width: width)
        }
        if trimmed.isEmpty { return [""] }

        if let heading = Self.heading(trimmed) {
            let styled = "\u{1B}[1m" + Theme.fg(Theme.accent) + Self.inline(heading.text) + Theme.reset
            return Self.wordWrap(styled, width: width)
        }
        if Self.isRule(trimmed) {
            return [Theme.faintText(String(repeating: "─", count: width))]
        }
        if let quote = Self.blockQuote(line) {
            let bar = Theme.faintText("│ ")
            return Self.hanging(Theme.fg(Theme.muted) + Self.inline(quote) + Theme.reset,
                                first: bar, rest: bar, width: width)
        }
        if let item = Self.listItem(line) {
            let pad = String(repeating: " ", count: item.indent)
            let marker = Theme.fg(Theme.accentDim) + item.marker + Theme.reset + " "
            let restPad = pad + String(repeating: " ", count: ANSI.visibleWidth(item.marker) + 1)
            return Self.hanging(Self.inline(item.text), first: pad + marker, rest: restPad, width: width)
        }
        if trimmed.hasPrefix("|") {
            return Self.tableRow(trimmed, width: width)
        }
        return Self.wordWrap(Self.inline(line), width: width)
    }

    /// Render without committing fence state — for the streaming tail line
    /// that has not reached its newline yet.
    func preview(_ line: String, width: Int) -> [String] {
        var copy = self
        return copy.render(line, width: width)
    }

    mutating func reset() {
        inFence = false
        fenceMarker = ""
    }

    // MARK: - Blocks

    static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let run = trimmed.prefix { $0 == marker.first }
            return String(run)
        }
        return nil
    }

    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes: `## Title ##`.
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes.count, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func blockQuote(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == ">" else { return nil }
        var rest = trimmed.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    struct ListItem {
        var indent: Int
        var marker: String
        var text: String
    }

    static func listItem(_ line: String) -> ListItem? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let body = expanded.dropFirst(indent)
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            var text = String(body.dropFirst(2))
            var marker = indent >= 2 ? "◦" : "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
            return ListItem(indent: indent, marker: marker, text: text)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = body.dropFirst(digits.count)
            if let punct = afterDigits.first, punct == "." || punct == ")", afterDigits.dropFirst().first == " " {
                return ListItem(indent: indent, marker: "\(digits)\(punct)", text: String(afterDigits.dropFirst(2)))
            }
        }
        return nil
    }

    static func tableRow(_ trimmed: String, width: Int) -> [String] {
        let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-:".contains($0) }
        }
        if isSeparator {
            return [Theme.faintText(String(repeating: "─", count: min(width, max(3, ANSI.visibleWidth(trimmed)))))]
        }
        let sep = Theme.faintText(" │ ")
        return wordWrap(cells.map(inline).joined(separator: sep), width: width)
    }

    /// Wrap `body` to `width`, the first row behind `first` and the rest
    /// behind `rest` (both already styled; widths measured visibly).
    static func hanging(_ body: String, first: String, rest: String, width: Int) -> [String] {
        let firstWidth = ANSI.visibleWidth(first)
        let restWidth = ANSI.visibleWidth(rest)
        let inner = max(4, width - max(firstWidth, restWidth))
        return wordWrap(body, width: inner).enumerated().map { index, row in
            (index == 0 ? first : rest) + row
        }
    }

    // MARK: - Inline

    /// Style inline spans. Code spans are lifted out first so nothing inside
    /// them is read as Markdown; every style closes with its own off-code so
    /// styles nest and survive `wordWrap`'s replay at a row break.
    static func inline(_ raw: String) -> String {
        var codeSpans: [String] = []
        var text = replace(raw, #"(`+)(.+?)\1"#) { groups in
            codeSpans.append(groups[2])
            return "\u{0}\(codeSpans.count - 1)\u{0}"
        }
        // Backslash escapes keep their character literal.
        var escapes: [String] = []
        text = replace(text, #"\\([\\`*_{}\[\]()#+\-.!~|>])"#) { groups in
            escapes.append(groups[1])
            return "\u{1}\(escapes.count - 1)\u{1}"
        }
        text = replace(text, #"!?\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { groups in
            let label = groups[1], url = groups[2]
            let shown = "\u{1B}[4m" + fg(Theme.link) + label + "\u{1B}[39m\u{1B}[24m"
            let bareURL = url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            if label == url || label == bareURL || "https://\(label)/" == url || "https://\(label)" == url {
                return shown
            }
            return shown + Theme.fg(Theme.faint) + " (\(url))" + "\u{1B}[39m"
        }
        text = replace(text, #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { "\u{1B}[1m" + $0[1] + "\u{1B}[22m" }
        text = replace(text, #"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#) { "\u{1B}[1m" + $0[1] + "\u{1B}[22m" }
        text = replace(text, #"~~(?=\S)(.+?)(?<=\S)~~"#) { "\u{1B}[9m" + $0[1] + "\u{1B}[29m" }
        text = replace(text, #"(?<![*\w])\*(?=[^\s*])([^*]+?)(?<=\S)\*(?![*\w])"#) { "\u{1B}[3m" + $0[1] + "\u{1B}[23m" }
        text = replace(text, #"(?<![\w_])_(?=[^\s_])([^_]+?)(?<=\S)_(?![\w_])"#) { "\u{1B}[3m" + $0[1] + "\u{1B}[23m" }

        text = replace(text, "\u{1}(\\d+)\u{1}") { escapes[Int($0[1]) ?? 0] }
        text = replace(text, "\u{0}(\\d+)\u{0}") { groups in
            let code = codeSpans[Int(groups[1]) ?? 0].trimmingCharacters(in: .whitespaces)
            return fg(Theme.code) + code + "\u{1B}[39m"
        }
        return text
    }

    private static func fg(_ c: Theme.RGB) -> String { Theme.fg(c) }

    /// Regex replace with a closure over the capture groups (index 0 is the
    /// whole match; an unmatched group is "").
    static func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Wrapping

    /// Greedy word wrap of a styled string to `width` visible columns.
    ///
    /// Breaks at spaces. A word that does not fit the rest of the row moves
    /// to the next row whole — unless it holds wide (CJK) characters, which
    /// may break anywhere and so fill the current row first, or it is wider
    /// than a whole row (a URL), which is broken at the column. Active SGR
    /// state is closed at the end of each row and replayed at the start of
    /// the next, so styles neither leak nor drop at a break.
    static func wordWrap(_ s: String, width: Int) -> [String] {
        let width = max(1, width)
        if ANSI.visibleWidth(s) <= width { return [s] }

        var rows: [String] = []
        var current = ""
        var currentWidth = 0
        var activeSGR = ""

        func flush() {
            var row = current
            while row.hasSuffix(" ") { row.removeLast() }
            if !activeSGR.isEmpty { row += ANSI.resetSequence }
            rows.append(row)
            current = activeSGR
            currentWidth = 0
        }

        func append(_ piece: String) {
            current += piece
            currentWidth += ANSI.visibleWidth(piece)
            for escape in escapes(in: piece) where ANSI.isSGR(escape) {
                activeSGR = ANSI.isSGRReset(escape) ? "" : activeSGR + escape
            }
        }

        for (index, word) in s.components(separatedBy: " ").enumerated() {
            if index > 0, currentWidth > 0 {
                if currentWidth + 1 >= width { flush() } else { append(" ") }
            }
            var rest = word
            var restWidth = ANSI.visibleWidth(rest)
            if currentWidth + restWidth <= width {
                append(rest)
                continue
            }
            let breakable = restWidth > width || containsWide(rest)
            if !breakable {
                if currentWidth > 0 {
                    // Drop the space we just added before moving on.
                    if current.hasSuffix(" ") { current.removeLast(); currentWidth -= 1 }
                    flush()
                }
                append(rest)
                continue
            }
            while restWidth > 0 {
                let room = width - currentWidth
                if room <= 0 { flush(); continue }
                let (head, tail) = splitPrefix(rest, columns: room)
                if ANSI.visibleWidth(head) == 0 {
                    // Next glyph is wider than the room left on this row.
                    if currentWidth == 0 { append(tail); break }
                    flush()
                    continue
                }
                append(head)
                rest = tail
                restWidth = ANSI.visibleWidth(rest)
                if restWidth > 0 { flush() } else { append(rest) }
            }
        }
        if currentWidth > 0 || rows.isEmpty {
            var row = current
            while row.hasSuffix(" ") { row.removeLast() }
            rows.append(row)
        }
        return rows
    }

    /// Whether `s` has a wide (2-column) glyph, i.e. text that may wrap at
    /// any character.
    static func containsWide(_ s: String) -> Bool {
        s.unicodeScalars.contains { ANSI.columnWidth(of: $0.value) == 2 }
    }

    /// Split a styled string after at most `columns` visible columns,
    /// keeping escape sequences with the half they precede.
    static func splitPrefix(_ s: String, columns: Int) -> (String, String) {
        let scalars = Array(s.unicodeScalars)
        var head = String.UnicodeScalarView()
        var used = 0
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {
                let end = ANSI.skipEscape(scalars, from: i)
                head.append(contentsOf: scalars[i..<end])
                i = end
                continue
            }
            let w = ANSI.columnWidth(of: v)
            if used + w > columns { break }
            head.append(scalars[i])
            used += w
            i += 1
        }
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars[i...])
        return (String(head), String(tail))
    }

    static func escapes(in s: String) -> [String] {
        let scalars = Array(s.unicodeScalars)
        var out: [String] = []
        var i = 0
        while i < scalars.count {
            if scalars[i].value == 0x1B {
                let end = ANSI.skipEscape(scalars, from: i)
                var escape = String.UnicodeScalarView()
                escape.append(contentsOf: scalars[i..<end])
                out.append(String(escape))
                i = end
            } else {
                i += 1
            }
        }
        return out
    }
}

extension TranscriptRenderer {
    /// Indent every transcript row by `gutter` columns so the transcript lines
    /// up with the prompt box below it, re-wrapping rows that would no longer
    /// fit (the live zone draws at `width − 1`). Tabs become spaces first:
    /// a tab's width depends on its column, which the gutter shifts.
    nonisolated static func applyGutter(_ lines: [String], width: Int) -> [String] {
        let pad = String(repeating: " ", count: gutter)
        let available = max(8, width - gutter - 1)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if line.isEmpty {
                out.append("")
                continue
            }
            let expanded = line.contains("\t") ? line.replacingOccurrences(of: "\t", with: "    ") : line
            if ANSI.visibleWidth(expanded) <= available {
                out.append(pad + expanded)
            } else {
                out.append(contentsOf: ANSI.wrap(expanded, width: available).map { pad + $0 })
            }
        }
        return out
    }

    /// Columns the transcript is indented by (the prompt box's left margin).
    nonisolated static let gutter = 2
}
