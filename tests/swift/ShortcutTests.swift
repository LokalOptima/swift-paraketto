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

    func testModifierTapFiresWhenNothingElseHappens() throws {
        var taps = 0
        let tap = ModifierTap(.rightOption, inputCount: { 0 }) { taps += 1 }
        tap.flagsChanged(try flags(code: 61, modifiers: .option))
        XCTAssertEqual(taps, 0)
        tap.flagsChanged(try flags(code: 61))
        XCTAssertEqual(taps, 1)
    }

    /// Without Accessibility the typed key is never delivered; only the system's input count moves.
    func testModifierTapIgnoresInputWhileHeld() throws {
        var inputCount: UInt32 = 7
        var taps = 0
        let tap = ModifierTap(.rightOption, inputCount: { inputCount }) { taps += 1 }
        tap.flagsChanged(try flags(code: 61, modifiers: .option))
        inputCount += 1
        tap.flagsChanged(try flags(code: 61))
        XCTAssertEqual(taps, 0)

        tap.flagsChanged(try flags(code: 61, modifiers: .option))
        tap.flagsChanged(try flags(code: 61))
        XCTAssertEqual(taps, 1)
    }

    func testModifierTapIgnoresAnotherModifierJoining() throws {
        var taps = 0
        let tap = ModifierTap(.rightOption, inputCount: { 0 }) { taps += 1 }
        tap.flagsChanged(try flags(code: 61, modifiers: .option))
        tap.flagsChanged(try flags(code: 56, modifiers: [.option, .shift]))
        tap.flagsChanged(try flags(code: 56, modifiers: .option))
        tap.flagsChanged(try flags(code: 61))
        XCTAssertEqual(taps, 0)
    }

    private func flags(code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: code))
    }

    private func event(code: UInt16, characters: String,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
}
