# Paraketto internals

How Paraketto behaves and why, for anyone changing it. The [README](../README.md) is the short version.

Minimal dictation for macOS. Tap Right Option, speak, tap it again: the text is
pasted into whatever app has focus. Multilingual
[Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) runs on the Apple
Neural Engine with Core ML. Audio and transcripts stay on the Mac.

- Menu bar only. While the Transcripts window is open it also appears in Cmd-Tab, and in the Dock because macOS ties the two together
- Shortcut: tap `Right ⌥` to start and stop a recording, `Esc` discards it. A tap is a press and release under 0.6 s with no other key in between, so Option+letter typing is unaffected. Click the shortcut beside the status in the menu, then tap another modifier key or press a key combination. The button shows a grey `…` with a blue outline while waiting, previews the keys you press, and marks invalid shortcuts red. A valid shortcut is saved, the outline briefly flashes green, then returns to grey. Esc or clicking away cancels an unfinished change and restores the previous shortcut
- Transcription runs while you speak: every pause of 0.8 s ends a segment and it is transcribed right away, so when you pause before stopping the text is already there
- Floating pill while recording: a level meter on a -65 to -25 dBFS scale with 30 ms attack / 160 ms release smoothing; brief peaks are retained between display updates. Errors in the pill are kept short; the details are in `~/Library/Logs/Paraketto.log`
- Text is pasted only if the app that had focus when you started still has it; otherwise it is kept in history
- **Transcripts** (right-click the menu-bar icon, or choose Transcripts in its menu): recordings grouped by day, with playback, copy, delete, and word count stats. Entries show up to four lines; hover to reveal actions and expand longer text
- **Dictionary** (the other tab in the same window): explicit, case-sensitive replacements with multiple spellings per target. Select transcript text and right-click to add one; underlines show replacements. Changes update every stored transcript from its original
- Drop an audio file onto Transcripts to transcribe it locally, including WAV, M4A and AAC files supported by macOS
- Supports 25 European languages with automatic detection, punctuation, and capitalization
- The model downloads on first use (about 613 MB); existing compatible FluidAudio caches are reused

The transcript also stays on the clipboard after pasting. The previous clipboard contents are not
restored, since a timed restore races slow readers.

## Model setup

Parakeet Ultra is the only recognizer, shared by live dictation and audio imports.
The menu shows a byte-based download progress bar, then **Optimizing…** with a spinner
for initial preparation. Later starts show **Loading…**, followed by a green Ready label.
If setup fails, choose **Retry** in the menu.

Model files are cached at `~/Library/Application Support/Paraketto/models/parakeet-ultra/`.
Downloads are installed only after all required files arrive, so an interrupted download
cannot leave a seemingly ready model. Existing compatible FluidAudio caches and optional
locally optimized Ultra encoder and decoder exports are reused.

The command-line runner uses the same recognizer:

```bash
.build/release/paraketto-cli --vad .build/VadHead.mlmodelc recording.wav
```

## Build and run

Requires macOS 14+, Apple Silicon, and Xcode 16 or later.

```bash
make run
```

This builds with SwiftPM, compiles the VAD model, assembles `Paraketto.app`, signs it,
prepares the downloaded model for this Mac, updates `/Applications/Paraketto.app`,
and launches that installed copy. `make bundle` also updates the Applications copy on every
successful build, ready to open or compress in Finder for sharing.

Core ML's portable `.mlmodelc` files still need device-specific specialization when first
loaded. `make bundle` performs that load and warm-up through the signed app executable,
without opening windows, accessing the microphone, or registering hotkeys.
The first build can therefore spend tens of seconds preparing a model;
subsequent builds normally reuse Core ML's disk cache. Missing models are skipped.
Successful preparation is remembered for the model files and macOS version, including
preparation during builds. This is a UI hint, not a query of Core ML's private cache;
a system cache purge can still make a later **Loading** take longer.

- `make prepare-models` downloads and prepares Ultra explicitly.
- `make bundle PREPARE_MODELS=0` skips preparation, useful when packaging for another Mac.
- `make bundle INSTALL_APP=0` keeps the build in the checkout without installing it.
- `INSTALL_DIR=~/Applications` installs to your personal Applications folder instead.

Quit and reopen the app after a rebuild to run the new version. `make clean` removes local
build outputs; it does not uninstall the Applications copy or remove models and transcripts.

To share a build, compress `/Applications/Paraketto.app` in Finder and send the ZIP. The recipient
needs Apple Silicon and macOS 14+, grants Microphone and Accessibility access, and downloads their
own model on first use. The bundle contains no personal recordings or transcripts. Local development
signing is not Developer ID signing or Apple notarization, so another Mac may require an
[Open Anyway exception](https://support.apple.com/en-us/102445).

Preparation is local to this Mac, model paths and compute configuration. It is not a portable
cache bundled for other machines; macOS can also invalidate it after an OS update or purge it
to reclaim space. A first load may need preparation again in those cases.

## Editing the interface in Xcode

Open `Paraketto.xcodeproj` and use the **Paraketto** scheme with **My Mac**. The same scheme
drives both the canvas and Run.

**Previews.** Open a file from `Sources/ParakettoKit/UI`, choose **Editor → Canvas**, and click
**Resume** if the preview is paused. Select a named preview in the canvas, edit the view’s
SwiftUI code, and watch the preview update. The buttons at the bottom left of the canvas decide
what a click does: in **Live** mode (play icon) it operates the view’s controls, and in
**Selectable** mode (arrow icon) it selects the element under the cursor and its code.

Selectable mode recompiles the open file with instrumentation that cannot handle a function passed
by name to a button, so in previewed files write `Button("Save") { save() }` rather than
`Button("Save", action: save)`. Xcode shows no error when this happens: clicks only outline the
whole preview, and other previews can stop selecting as well.

| File | Previews |
|---|---|
| `MenuContent.swift` | Ready, Needs Accessibility, Downloading, Optimizing, Loading, Recording, Transcribing, Notice, Model failed |
| `PillView.swift` | Recording (with a live meter), Transcribing, Copied, Kept in history, Error, All messages |
| `ShortcutRecorder.swift` | All states, Interactive |
| `TranscriptsView.swift` | Transcripts, Empty transcripts, Importing, Import failed, Importing with errors, Drop audio files, Drop while busy |
| `DictionaryView.swift` | Dictionary, Empty dictionary |
| `DictionaryEditor.swift` | Add replacement, Edit replacement, From a transcript, Adding to an existing target, Many spellings, Spelling already used |

`PreviewFixtures.swift` supplies disposable sample dictionary entries, transcripts, and silent
recordings. Each preview has separate temporary files and shortcut preferences; previews do
not load recognition models, start recording, register shortcuts, read personal history, or
write to the log. States reach the views through the debug-only `DictationController.showPreview`.
Preview declarations and fixtures are excluded from release builds.

Xcode reads the package’s file list when it opens the project. After adding or removing a source
file outside Xcode, close and reopen the project, or the canvas reports `Cannot find … in scope`.

**Run** builds and launches the real `Paraketto.app` from Xcode’s build folder, with the debugger
attached, its menu-bar icon and VAD model, and your real history, dictionary, and models. Quit
any other running copy first, because both would answer the shortcut. The project signs with the
`Paraketto Dev` certificate described under [Accessibility and rebuilds](#accessibility-and-rebuilds),
so it has the same designated requirement as a `make bundle` build and keeps its Accessibility
grant; Run needs that certificate. Xcode signs every build, including each canvas rebuild, so
if a keychain dialog asks to let `codesign` use the key, choose **Always Allow**; **Allow** only
covers that one build.

The project is only a thin app target: `Sources/ParakettoLauncher/main.swift` links the
`ParakettoKit` package library, and a final build phase runs `make xcode-bundle` to add the same
resources as `make bundle`. Use `make run` or `make bundle` to build the release app and install it
in Applications.

## Permissions

- **Microphone**: prompted on the first recording.
- **Accessibility**: needed to send the Cmd+V keystroke. Prompted at launch, granted in
  System Settings → Privacy & Security → Accessibility. Without it the transcript is only
  copied to the clipboard.

### Accessibility and rebuilds

macOS ties the Accessibility grant to the app's code signature. With ad-hoc signing every
rebuild is a different signature, so the toggle in System Settings looks on but the new build
is not trusted and text is only copied. Two ways out:

- **Per build:** `make trust` removes the stale entry and opens the Accessibility pane. Grant
  the app again.
- **Once:** create a self-signed code-signing certificate named `Paraketto Dev`. The Makefile
  picks it up automatically and the grant survives rebuilds.

  ```bash
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem \
    -subj "/CN=Paraketto Dev" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"
  openssl pkcs12 -export -legacy -out dev.p12 -inkey key.pem -in cert.pem -passout pass:x -name "Paraketto Dev"
  security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
  rm key.pem cert.pem dev.p12
  make trust   # one last re-grant for the newly signed build
  ```

  The first `codesign` with the new key may show a keychain dialog; choose "Always Allow".

## Dictionary decisions

The Transcripts and Dictionary tabs share one window. Each replacement has one or more explicit
spellings to replace and the target text to write with them, with search and an add button.
Selected transcript text can be added through **Add to dictionary…**; outer whitespace is
trimmed and selections containing replacements map back to the original recognition text.
Partial selections of a replacement cannot be added. Replacement underlines show the original
wording on hover, with actions to edit the replacement or remove that spelling globally.

The editor is a popover attached to the selected words, the add button or the row's pencil, so the
sentence or list stays in view. **Replace** holds spellings as chips: a comma or Return finishes
one, Delete in an empty field reopens the last, and clicking a chip reopens it. **With** suggests
existing targets that have a word starting with the text; Tab takes the first, and the arrow keys
and Return choose another. Typing an exact existing target adds to that replacement, whether adding
or editing. One fixed status line shows suggestions, conflicts and what a save will join, so nothing
moves while typing. Add and Save stay disabled until the entry is complete and free of conflicts.
Return finishes one thing at a time and saves once nothing is left. Clicking away saves a complete
entry and drops an incomplete one; only Cancel and Esc discard changes.

Matching is literal and case-sensitive, without Unicode, case, or whitespace normalization.
Targets are never implicit aliases. At each position the longest eligible alias wins;
replacement output is never matched again. Conflicting aliases are rejected, not overwritten.
There is no fuzzy matching, filler removal, or per-occurrence disable switch.

An alias must start after whitespace or at the start of the transcript. It must end at whitespace,
the end of the transcript, or simple punctuation (`. , ; ' " ? ! )` and the closing quotes `’ ”`)
that itself ends the word, leaving that punctuation untouched. So `gee tub?!` matches, while `don`
does not match inside `don't`, nor `3` inside `3.5`. Internal punctuation must still match literally.
Emails, URLs, and paths are protected. Protection deliberately favors skipping ambiguous
address-like tokens over modifying them; for example, `word.example` is protected even if it
was intended as prose with a missing space.

The existing history JSON `text` remains the immutable original recognition output, and WAV
files are unchanged. Display text and replacement ranges are derived in memory from a single
current dictionary snapshot. Every successful rule change synchronously reprocesses all
transcripts from their originals, including on launch. Copy and new dictation delivery use
the processed text; text already pasted into other apps is not changed. Removing or editing
a rule is the way to undo replacements globally; there is no separate Show original control.
Rules live in `~/Library/Application Support/Paraketto/dictionary.json`.
Dictionary changes are saved atomically before becoming active. A failed save leaves the
previous rules active, and an unreadable dictionary is never silently overwritten.

## Speech recognition

`Sources/ParakeetTDT` is a self-contained Core ML runner for Parakeet Ultra,
with no package dependencies:

| File | Role |
|---|---|
| `ModelStore.swift` | finds or downloads Ultra's Core ML assets |
| `ModelFileDownload.swift` | cancellable file transfers with live byte progress and temporary-file cleanup |
| `ParakeetModels.swift` | loads the four Core ML models (preprocessor on CPU; other models allow CPU and ANE), the VAD head and the vocabulary |
| `ParakeetTranscriber.swift` | streaming sessions and mel → encoder → decode; about 1 s of context at pauses, 2 s of overlap on each side of cuts through speech |
| `TdtDecoder.swift` | greedy Token-and-Duration Transducer loop with the 2-layer LSTM state |
| `VoiceActivity.swift` | places cuts at pauses found by the model's own VAD head |
| `EncoderSet.swift` | picks the shortest encoder window that holds a segment |
| `MultiArray.swift` | small `MLMultiArray` helpers |

The Ultra model files are FluidAudio's Core ML conversion (Apache 2.0) of moondream's checkpoint
(CC-BY-4.0): a fixed 15 s preprocessor and int8 encoder, an LSTM decoder, and a joint network
that returns token, probability and duration bin directly.

### Voice-activity head

Parakeet Ultra's weights carry a small VAD head on the encoder's subsampler, which moondream's
engine uses to cut long audio at pauses. FluidAudio's export leaves it out, so
`tools/export/export_vad_head.py` exports subsampler plus head to `Resources/VadHead.mlpackage`
(8.7 MB), fetching only the 9 MB of needed tensors from the safetensors file. The wiring
(SiLU after `proj` and `ctx`, no residual) follows parakeet.cpp's published analysis, since
moondream does not document the head; it gives one speech probability per 80 ms frame.

The bundled export includes its own subsampler, so pause detection runs independently
of the recognition encoder.

A `Session` segments the recording while it is still going. Every 0.24 s it runs the VAD head
over the newest audio; a silence of 0.8 s ends the segment before it, which is then encoded and
decoded right away on the otherwise idle ANE and CPU. At stop only the audio after the last cut is
left: nothing if you paused, otherwise one short encoder pass.

Audio memory stays bounded: the recognizer discards consumed samples, retaining only the
next window's overlap and the incomplete VAD block. Capture writes a temporary Float32 WAV
as audio arrives; the transcriber reads small batches from it. Only the latest file-length
notification is queued, so inference lag accumulates on disk instead of in an audio queue.
At completion, the WAV moves into History without loading it into memory. Cancelled or
failed recordings are removed when their users release the temporary file. Transcript
tokens still grow with recording length. New recordings use about 3.84 MB of disk per minute;
existing PCM16 History recordings remain playable.

VAD blocks end on whole 80 ms frames (14.96 s per complete block), so rounding each block
does not accumulate a timestamp offset over long recordings. The encoder's maximum input remains 15 s.

Every segment is decoded with a fresh decoder, as moondream's runtime does. Carrying the LSTM state
from segment to segment looked like free language context, but over a few minutes of speech it
drifts until whole segments decode to blanks.

- **Cuts at pauses** lie in silence, so each side keeps the tokens on its side of the cut, with about
  a second of audio around it for the encoder.
- **Cuts through speech**, when 11 s pass without a 0.8 s pause, overlap: both segments encode the
  2 s on each side of the cut, their tokens there are aligned with a longest common subsequence
  (same token at nearly the same frame), and the text is joined at the matched token nearest the
  cut. If the two sides do not agree, the one that heard more of the overlap wins. This is the
  scheme NVIDIA uses for long audio with Parakeet; it replaced a one-second context plus exact
  dedupe that doubled or dropped a word at about a third of such cuts.
- **Empty windows are retried.** The model sometimes returns nothing at all for a window that
  starts mid-word (FluidAudio's own models do the same), so a window with speech that decodes
  empty is decoded again from a later start.

`tests/make_longform.py` joins the LibriSpeech clips into one to three minute files with 0.3 to 1 s
gaps, and `tests/score.py` computes word error rate the Open ASR Leaderboard way: Whisper's
EnglishTextNormalizer on both sides, then `jiwer`. `make compare` and `make longform` feed audio in
100 ms chunks like the app. The table below records earlier development measurements;
rerun those commands to measure the current build:

| Version | Long files | Short clips |
|---|---|---|
| state carried across cuts, 13 s windows | about 9% (counted before the scorer existed) | 0.20% |
| pause commits, overlap join, fresh decoder | 0.20% | 0.20% |

Those runs included model errors such as "bade fare" for "bade fair" and "Murcheston". Pause
decisions use only the audio heard so far, so feeding a whole file at once can cut differently
(0.40% on the long files).

### Faster than the stock export

Two optional exports, built locally with `uv` (they are too large for the repo) and picked up
automatically by the app and CLI from `~/Library/Application Support/Paraketto/models/`:

- `make encoder-export`: the encoder as one multi-function Core ML model with 5 s, 10 s and 15 s
  windows (605 MB, weights shared), traced from Hugging Face `transformers`' `ParakeetForTDT` and
  quantized to int8 per channel. A segment uses the shortest window that holds it, so a 4.5 s
  utterance costs a 17 ms encoder pass instead of 55 ms. Needs macOS 15 for multi-function models.
- `make decoder-export`: one Core ML model that advances the LSTM with the emitted token and
  decides the next frame, replacing two framework calls per token step with one (35 MB).

Historical measurements on the 17 LibriSpeech clips on an M1 Max, with the same transcripts
in every configuration (these timings have not been remeasured for the current build):

| Configuration | RTFx |
|---|---|
| FluidAudio models, two-call decode | 80x |
| + fused decoder step | 93x |
| + multi-window encoder | 124x |

In those measurements, time was split between the encoder on the ANE (17 to 55 ms depending on window) and
the sequential decode on the CPU: 0.73 ms per emitted token inside the fused step, bound by
streaming the fp32 LSTM and joint weights through one core (Core ML's per-call floor is 35 µs, and
smaller weights do not help because the CPU path expands them at load). A Metal decoder that ran
the greedy loop on the GPU reached 182x with identical transcripts (commit `89c4e5e`), but hand-written
kernels failed silently twice on the way there, and for dictation the 30 ms it saves on a 10 s
utterance is below perception, so it was removed in favour of the framework path.

### Measuring

- `xcrun xctrace record --template 'Core ML' --launch -- .build/release/paraketto-cli clip.wav`
  records every Core ML prediction and the Neural Engine's hardware intervals; export tables with
  `xcrun xctrace export --input <trace> --toc`.
- `paraketto-cli --plan` prints each model's operation count, how Core ML assigns operations to
  CPU, GPU and ANE, and which operators force the CPU.
- `PARAKEET_TIMING=1` prints mel, encoder and decode time per recording, with the number and total
  time of fused, joint and decoder Core ML calls; `--fused <model>` swaps in another fused step
  export for A/B timing; `--chunk-ms N` feeds each file to a session in N ms chunks like the app
  and reports the time spent after the last chunk; `--tokens` prints each
  token with its frame; `--vad-probe` prints the VAD strip; `PARAKEET_DEBUG=1` logs every joint decision.

### Checking against FluidAudio

`make test` checks dictionary matching and selection, original preservation, file storage, audio decoding, playback, paste delivery, and cache validation
without downloading recognition models. Plain `swift test` also runs the debug-only preview fixture tests. Tests that need the real models are skipped by default.
After `make prepare-models`, enable them with the LibriSpeech `1995-1826-0002.wav` fixture:

```bash
PARAKETTO_TEST_AUDIO=/path/to/1995-1826-0002.wav make test-models
```

The fixture defaults to `data/librispeech/1995-1826-0002.wav` inside this checkout. Opting into
model tests requires the models and fixture to exist; missing prerequisites fail the run.
These tests check repeated model loading, silence and quiet speech, long-recording
memory and VAD timing, file imports, and cancellation.

`tests/fixtures/librispeech_fluidaudio.tsv` holds FluidAudio's transcripts of 17 LibriSpeech
clips. `make compare` transcribes `data/librispeech/*.wav` (set `CLIPS=` to another location) and reports
differences and the real-time factor. An earlier run matched 15 of 17 transcripts. The two
differences are a British/American spelling choice
on a clip cut differently, and a trailing period that FluidAudio drops because it discards any
token whose duration runs past the end of the audio, which standard TDT decoding does not.

`paraketto-cli --tokens` prints each token with its emission frame, `--vad-probe` prints the
VAD strip, and `PARAKEET_DEBUG=1` logs every joint decision.

## Layout

The application lives in the `ParakettoKit` library in `Sources/ParakettoKit`, so Xcode can preview
its views: `UI` holds the views, and `Core` holds dictation control, audio, pasting, history and the
dictionary. `Sources/ParakettoLauncher` contains only the entry point, shared by the SwiftPM executable
and `Paraketto.xcodeproj`. Recognition is isolated in `Sources/ParakeetTDT`,
and the CLI is in `Sources/ParakettoCLI`. `tests/swift` contains regression tests; `tools/export`
contains optional model exporters and probes. Generated bundles, caches, local audio fixtures, and
build/test artifacts are ignored. The source icon lives in `Resources`; `tools/make_icon.swift`
generates the app icon and template menu-bar image together.

Transcripts and their recordings are stored under `~/Library/Application Support/Paraketto/history/`.
`~/Library/Logs/Paraketto.log` is truncated on each launch and never contains transcripts.
