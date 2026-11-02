import AppKit
import XCTest
@testable import ParakettoKit

@MainActor
final class ShortcutTests: XCTestCase {
    func testInvalidKeyStillHasAReadablePreview() throws {
        let key = try event(code: 0, characters: "a")
        XCTAssertEqual(Chord.label(for: key), "A")
        XCTAssertNil(Chord.from(key))
    }

    func testModifierCanBeAddedWhileAKeyIsHeld() throws {
        let keyFirst = try event(code: 44, characters: "/")
        let modifierFirst = try event(code: 44, characters: "/", modifiers: .option)
        let chord = try XCTUnwrap(Chord.from(keyFirst, modifiers: .option))
        XCTAssertEqual(chord, Chord.from(modifierFirst))
        XCTAssertEqual(chord.label, "⌥/")
        XCTAssertEqual(Chord.label(for: keyFirst, modifiers: .option), chord.label)
        XCTAssertNil(Chord.from(keyFirst))
    }

    func testFunctionKeysAndNamedKeysKeepTheirLabels() throws {
        let functionKey = try event(code: 100, characters: "")
        XCTAssertEqual(Chord.from(functionKey)?.label, "F8")
        let space = try event(code: 49, characters: " ")
        XCTAssertEqual(Chord.label(for: space), "Space")
        XCTAssertNil(Chord.from(space))
        XCTAssertEqual(Chord.from(space, modifiers: [.control, .shift])?.label, "⌃⇧Space")
    }

    private func event(code: UInt16, characters: String,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
}
