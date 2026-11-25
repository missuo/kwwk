import Foundation
import Testing
import KWWKAI
import KWWKAgent
@testable import KWWKCli

@Suite("Markdown prose rendering and transcript gutter")
struct MarkdownProseTests {
    private func plain(_ lines: [String]) -> [String] { lines.map(ANSI.stripEscapes) }

    @Test("plain prose passes through unchanged")
    func plainPassthrough() {
        var md = MarkdownProse()
        #expect(md.render("just a sentence.", width: 80) == ["just a sentence."])
        #expect(md.render("", width: 80) == [""])
    }

    @Test("headings, emphasis, code and links lose their markers")
    func inlineAndHeadings() {
        var md = MarkdownProse()
        #expect(plain(md.render("### 基本信息", width: 80)) == ["基本信息"])
        #expect(md.render("### 基本信息", width: 80)[0].contains("\u{1B}[1m"))
        let line = md.render("**bold** and *it* with `code` and ~~gone~~", width: 80)
        #expect(plain(line) == ["bold and it with code and gone"])
        #expect(line[0].contains("\u{1B}[1mbold\u{1B}[22m"))
        #expect(line[0].contains("\u{1B}[3mit\u{1B}[23m"))
        #expect(plain(md.render("see [the docs](https://example.com/x)", width: 80)) == ["see the docs (https://example.com/x)"])
        #expect(plain(md.render("[missuo.me](https://missuo.me/)", width: 80)) == ["missuo.me"])
        // Markers inside code spans and snake_case identifiers stay literal.
        #expect(plain(md.render("`**not bold**` and my_var_name", width: 80)) == ["**not bold** and my_var_name"])
        #expect(plain(md.render(#"a \*literal\* star"#, width: 80)) == ["a *literal* star"])
    }

    @Test("lists get bullets and hanging indents")
    func lists() {
        var md = MarkdownProse()
        #expect(plain(md.render("- **作者**：全栈工程师", width: 80)) == ["• 作者：全栈工程师"])
        #expect(plain(md.render("  * nested", width: 80)) == ["  ◦ nested"])
        #expect(plain(md.render("3. third", width: 80)) == ["3. third"])
        #expect(plain(md.render("- [x] done", width: 80)) == ["☑ done"])
        let wrapped = plain(md.render("- one two three four five six", width: 12))
        #expect(wrapped == ["• one two", "  three four", "  five six"])
    }

    @Test("fences hold state across lines and leave code untouched")
    func fences() {
        var md = MarkdownProse()
        #expect(plain(md.render("```swift", width: 40)) == ["── swift"])
        #expect(md.inFence)
        #expect(plain(md.render("let **x** = 1", width: 40)) == ["let **x** = 1"])
        // The streaming preview must not flip the fence state.
        _ = md.preview("```", width: 40)
        #expect(md.inFence)
        _ = md.render("```", width: 40)
        #expect(!md.inFence)
        #expect(plain(md.render("**back**", width: 40)) == ["back"])
    }

    @Test("rules, quotes and table rows")
    func blocks() {
        var md = MarkdownProse()
        #expect(plain(md.render("---", width: 10)) == [String(repeating: "─", count: 10)])
        #expect(plain(md.render("> quoted *text*", width: 40)) == ["│ quoted text"])
        #expect(plain(md.render("| a | **b** |", width: 40)) == ["a │ b"])
        #expect(plain(md.render("|---|:--:|", width: 40)).first?.allSatisfy { $0 == "─" } == true)
    }

    @Test("word wrap breaks Latin at spaces and CJK anywhere, never past the width")
    func wordWrap() {
        let latin = MarkdownProse.wordWrap("alpha beta gamma delta", width: 11)
        #expect(latin == ["alpha beta", "gamma delta"])
        let cjk = MarkdownProse.wordWrap("全栈工程师，出生于中国浙江 University of Pittsburgh 计算机科学硕士", width: 16)
        #expect(cjk.allSatisfy { ANSI.visibleWidth($0) <= 16 })
        #expect(cjk.joined().replacingOccurrences(of: " ", with: "")
            == "全栈工程师，出生于中国浙江UniversityofPittsburgh计算机科学硕士")
        // CJK fills the row instead of leaving a gap before a long run.
        #expect(ANSI.visibleWidth(cjk[0]) >= 15)
        // Styles are closed at a break and replayed on the next row.
        let styled = MarkdownProse.wordWrap("\u{1B}[1mone two three\u{1B}[22m", width: 8)
        #expect(styled.count == 2)
        #expect(styled[0].hasSuffix(ANSI.resetSequence))
        #expect(styled[1].hasPrefix("\u{1B}[1m"))
    }

    @Test("the gutter indents every row and re-wraps rows that no longer fit")
    func gutter() {
        let out = TranscriptRenderer.applyGutter(["", "short", String(repeating: "x", count: 30), "a\tb"], width: 20)
        #expect(out[0] == "")
        #expect(out[1] == "  short")
        #expect(out.dropFirst(2).dropLast().allSatisfy { $0.hasPrefix("  ") && ANSI.visibleWidth($0) <= 19 })
        #expect(out.last == "  a    b")
    }

    @MainActor
    @Test("streamed assistant markdown is committed styled, one logical line at a time")
    func rendererStreamsMarkdown() {
        let renderer = TranscriptRenderer()
        renderer.displayWidth = 80
        let partial = AssistantMessage(content: [.text(TextContent(text: ""))], api: "a", provider: "p", model: "m")
        renderer.apply(.messageStart(message: .assistant(partial)))
        var text = ""
        for chunk in ["### Title\n- **one**", "\n```\nlet **x**\n```\n", "done"] {
            text += chunk
            var snapshot = partial
            snapshot.content = [.text(TextContent(text: text))]
            renderer.apply(.messageUpdate(message: snapshot, assistantMessageEvent: .textDelta(contentIndex: 0, delta: chunk, partial: snapshot)))
        }
        var final = partial
        final.content = [.text(TextContent(text: text))]
        renderer.apply(.messageEnd(message: .assistant(final)))
        let lines = plain(renderer.drainGutteredCommits())
        #expect(lines == ["", "  Title", "  • one", "  ──", "  let **x**", "  ────────────────────────", "  done"])
    }
}
