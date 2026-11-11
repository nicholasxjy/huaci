import AppKit
import Testing
@testable import HuaciCore

@MainActor
struct SystemPasteboardTests {
    @Test func clearThenWriteIsOnePasteboardVersion() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let before = board.changeCount
        board.clearContents()
        let item = NSPasteboardItem()
        #expect(item.setString("selection", forType: .string))
        #expect(board.writeObjects([item]))

        #expect(board.changeCount == before + 1)
        #expect(board.string(forType: .string) == "selection")
    }

    @Test func restoreRoundTripsAllTypesAndItems() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = SystemPasteboard(pasteboard: board)
        let snapshot = PasteboardSnapshot(items: [
            [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("first".utf8)),
             .init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1 first}".utf8))],
            [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("second".utf8))],
        ])

        #expect(adapter.restore(snapshot))
        let restored = try #require(adapter.snapshot())
        #expect(restored.items.count == snapshot.items.count)
        for (expected, actual) in zip(snapshot.items, restored.items) {
            for entry in expected { #expect(actual.contains(entry)) }
        }
        #expect(adapter.readString() == "first\nsecond")
        #expect(adapter.restore(PasteboardSnapshot(items: [])))
        #expect(adapter.snapshot() == PasteboardSnapshot(items: []))
    }
}
