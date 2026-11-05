# Paraketto

Menu-bar dictation app for macOS: Parakeet Ultra on Core ML, with a SwiftUI and AppKit interface and no package dependencies.

`docs/internals.md` explains how the app behaves and why, including signing, dictionary rules, recognition and measurements. Read the relevant section before changing those areas, and update it when a change makes it wrong.

## Commands

- `make bundle INSTALL_APP=0`: build and sign the app in the checkout
- `make bundle`, `make run`: also replace `/Applications/Paraketto.app`
- `make trust`: re-grant Accessibility after an ad-hoc signed rebuild
- `make dist`: build the downloadable zip from the last commit, signed ad hoc, without touching the checkout's build or `/Applications`
- `make release`: push the version tag for the last pushed commit, so `.github/workflows/release.yml` builds and publishes the release
- `make test`: regression tests in release, without models or the `#if DEBUG` preview tests
- `swift test`: runs in debug, so it adds the preview tests
- `make test-models`: model tests, which need `make prepare-models` and the LibriSpeech fixture
- `make compare`, `make longform`: accuracy against reference transcripts

When the user's certificate exists, `make bundle`, `make run` and Xcode builds sign with it, which can block on a keychain dialog on their screen. To check that code compiles, use `swift build`.

This branch is `master` plus the tests and tooling. Update it with `git merge master`, and never merge it into `master`.

## Rules

- Audio and transcripts stay on the Mac, and `Log` never receives dictated text.
- The `Paraketto Dev` certificate is for the user's own rebuilds and never goes to GitHub. Releases are signed with the separate `Paraketto Release` certificate, which exists only in the repository's secrets.
- The history JSON `text` is the immutable original. Display text is derived from it and the dictionary.
- Files in `transcripts/` are permanent, and only deleting a transcript in the app removes one. An entry leaves the Transcripts view, and its recording is deleted, only once its file is saved.
- Keep `#Preview`s and their fixtures inside `#if DEBUG`. They use `PreviewFixtures`, never real history, models or hotkeys.
- In previewed files write `Button("Save") { save() }`, not `Button("Save", action: save)`. The second form silently breaks the canvas's Selectable mode.
- After a source file is added or removed outside Xcode, `Paraketto.xcodeproj` must be reopened, or the canvas reports `Cannot find … in scope`.
