import Foundation
import Testing
@testable import HuaciCore

struct ShortcutTests {
    @Test func defaultIsControlOptionT() {
        let shortcut = Shortcut.defaultShortcut
        #expect(shortcut.displayString == "⌃⌥T")
        #expect(shortcut.carbonModifiers == 0x1800)
        #expect(shortcut.isValid)
    }

    @Test func requiresANonShiftModifier() {
        #expect(!Shortcut(keyCode: 17, modifiers: []).isValid)
        #expect(!Shortcut(keyCode: 17, modifiers: [.shift]).isValid)
        #expect(Shortcut(keyCode: 17, modifiers: [.shift, .command]).isValid)
        #expect(!Shortcut(keyCode: 999, modifiers: [.command]).isValid)
    }

    @Test func roundTripsThroughJSON() throws {
        let shortcut = Shortcut(keyCode: 2, modifiers: [.command, .shift])
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        #expect(decoded == shortcut)
        #expect(decoded.displayString == "⇧⌘D")
    }
}
