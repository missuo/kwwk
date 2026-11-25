import Foundation
import Testing
@testable import KWWKCli

@Suite("Terminal appearance detection and light palette")
struct TerminalAppearanceTests {
    @Test("OSC 11 replies classify by background luminance")
    func osc11() {
        #expect(TerminalAppearance.parseOSC11Reply("\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\") == .light)
        #expect(TerminalAppearance.parseOSC11Reply("\u{1B}]11;rgb:1e1e/1e1e/2e2e\u{07}") == .dark)
        #expect(TerminalAppearance.parseOSC11Reply("\u{1B}]11;rgb:fd/f6/e3\u{07}\u{1B}[?62;22c") == .light)
        #expect(TerminalAppearance.parseOSC11Reply("\u{1B}[?62;22c") == nil)
        #expect(TerminalAppearance.parseOSC11Reply("\u{1B}]11;rgb:zz/00/00\u{07}") == nil)
    }

    @Test("COLORFGBG names a light background by its color number")
    func colorfgbg() {
        #expect(TerminalAppearance.parseCOLORFGBG("0;15") == .light)
        #expect(TerminalAppearance.parseCOLORFGBG("0;default;7") == .light)
        #expect(TerminalAppearance.parseCOLORFGBG("15;0") == .dark)
        #expect(TerminalAppearance.parseCOLORFGBG("garbage") == nil)
    }

    @Test("KWWK_THEME overrides detection")
    func override() {
        #expect(TerminalAppearance.detect(environment: ["KWWK_THEME": "light"]) == .light)
        #expect(TerminalAppearance.detect(environment: ["KWWK_THEME": "Dark"]) == .dark)
    }

    @Test("a DA1 reply ends the wait")
    func deviceAttributes() {
        #expect(TerminalAppearance.endsWithDeviceAttributes(Array("\u{1B}]11;rgb:0/0/0\u{07}\u{1B}[?62;22c".utf8)))
        #expect(!TerminalAppearance.endsWithDeviceAttributes(Array("\u{1B}]11;rgb:0/0/0\u{07}".utf8)))
    }

    @Test("the user bar fills to the edge with erase-to-EOL and the active palette")
    func userBar() {
        let previous = Theme.appearance
        defer { Theme.appearance = previous }

        Theme.appearance = .light
        let line = Theme.userBar("hi", width: 40)[0]
        #expect(line.contains(Theme.bg(Theme.Palette.light.userBarBg)))
        #expect(line.contains("\u{1B}[K"))
        #expect(ANSI.visibleWidth(line) == 4)   // "❯ hi" — no trailing pad cells

        Theme.appearance = .dark
        #expect(Theme.userBar("hi", width: 40)[0].contains(Theme.bg(Theme.Palette.dark.userBarBg)))
    }
}
