# Paraketto

Menu-bar dictation app for macOS: Parakeet Ultra on Core ML, with a SwiftUI and AppKit interface and no package dependencies.

`docs/internals.md` explains how the app behaves and why, including signing, dictionary rules, recognition and measurements. Read the relevant section before changing those areas, and update it when a change makes it wrong.

## Commands

- `make bundle INSTALL_APP=0`: build and sign the app in the checkout
- `make bundle`, `make run`: also replace `/Applications/Paraketto.app`
- `make test`: regression tests in release, without models or the `#if DEBUG` preview tests
- `swift test`: runs in debug, so it adds the preview tests
- `make test-models`: model tests, which need `make prepare-models` and the LibriSpeech fixture
- `make compare`, `make longform`: accuracy against reference transcripts

`make bundle`, `make run` and Xcode builds sign with the user's key, which can block on a keychain dialog on their screen. To check that code compiles, use `swift build`.

## Rules

- Audio and transcripts stay on the Mac, and `Log` never receives dictated text.
- The history JSON `text` is the immutable original. Display text is derived from it and the dictionary.
- Keep `#Preview`s and their fixtures inside `#if DEBUG`. They use `PreviewFixtures`, never real history, models or hotkeys.
- In previewed files write `Button("Save") { save() }`, not `Button("Save", action: save)`. The second form silently breaks the canvas's Selectable mode.
- After a source file is added or removed outside Xcode, `Paraketto.xcodeproj` must be reopened, or the canvas reports `Cannot find … in scope`.
