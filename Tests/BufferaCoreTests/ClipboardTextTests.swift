import Foundation
import BufferaCore

extension HistoryStoreTests {
    func testSharedTextDecoderPreservesFullPlainTextAndPrefersItOverRTF() throws {
        let full = String(repeating: "Русский English 😀\n", count: 20_000) + "\u{0000}tail"
        let plain = Representation(type: "public.utf8-plain-text", data: Data(full.utf8))
        let rtf = Representation(type: "public.rtf", data: Data(#"{\rtf1\ansi alternative}"#.utf8))
        try checkEqual(ClipboardText.decode([rtf, plain]), full)
        try checkEqual(ClipboardText.decode([plain]), full)
        try checkEqual(ClipboardText.decode([]), nil)
        try checkEqual(ClipboardText.decode([Representation(type: "custom", data: Data("opaque".utf8))]), nil)
    }

    func testSharedTextDecoderFallsBackToRTFAndPreservesItemBoundaries() throws {
        let rtf = Representation(type: "public.rtf", data: Data(#"{\rtf1\ansi plain \b bold\b0}"#.utf8))
        try checkEqual(ClipboardText.decode([rtf]), "plain bold")
        let invalid = Representation(type: "public.utf8-plain-text", data: Data([0xff, 0xfe]))
        let empty = Representation(type: "public.utf8-plain-text", data: Data())
        try checkEqual(ClipboardText.decode([invalid, rtf]), "plain bold")
        try checkEqual(ClipboardText.decode([empty, rtf]), "plain bold")
        try checkEqual(ClipboardText.decode([invalid]), nil)
        let payload = ClipPayload(items: [
            [Representation(type: "public.utf8-plain-text", data: Data("first\npart".utf8))],
            [rtf]
        ])
        try checkEqual(payload.items.map(ClipboardText.decode), ["first\npart", "plain bold"])
    }
}
