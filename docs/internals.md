# Paraketto internals

How Paraketto behaves and why, for anyone changing it. The [README](../README.md) is the short version.

Minimal dictation for macOS. Tap Right Option, speak, tap it again: the text is
pasted into whatever app has focus. Multilingual
[Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) runs on the Apple
Neural Engine with Core ML. Audio and transcripts stay on the Mac.

- Menu bar only. While the Dictionary window is open it also appears in Cmd-Tab, and in the Dock because macOS ties the two together
- Shortcut: tap `Right ⌥` to start and stop a recording, `Esc` discards it. A tap is a press and release under 0.6 s with no other modifier held and no key press or mouse click in between, so Option+letter typing is unaffected. Click the shortcut beside the status in the menu, then tap another modifier key or press a key combination. The button shows a grey `…` with a blue outline while waiting, previews the keys you press, and marks invalid shortcuts red. A valid shortcut is saved, the outline briefly flashes green, then returns to grey. Esc or clicking away cancels an unfinished change and restores the previous shortcut
- Transcription runs while you speak: every pause of 0.8 s ends a segment and it is transcribed right away, so when you pause before stopping the text is already there
- Floating pill while recording: a level meter on a -65 to -25 dBFS scale with 30 ms attack / 160 ms release smoothing; brief peaks are retained between display updates. Errors in the pill are kept short; the details are in `~/Library/Logs/Paraketto.log`
- Text is pasted only if the app that had focus when you started still has it; otherwise it is only copied, and the pill says so. Dictating with Paraketto itself in front only copies the text
- **Dictionary** (right-click the menu-bar icon, or choose Dictionary in its menu): explicit, case-sensitive replacements with multiple spellings per target, applied to each transcript before it is pasted. Search ignores case and accents, including stroked letters such as `ł` and `ø`
- **Transcripts folder** (the button beside +): every transcript is also a plain text file in `~/Library/Application Support/Paraketto/transcripts/`, named by date and time and holding the text as it was pasted or copied. Paraketto never changes or removes these files. The recording is deleted once it is transcribed
- Drop audio files onto the Dictionary window to transcribe them locally, including WAV, M4A and AAC files supported by macOS. The pill shows a progress bar for the whole batch in place of the meter, and each transcript gets its file as it is done. When the batch ends, or is cancelled, the clipboard holds all of them, separated by blank lines, and the pill says Copied. Files that fail, or hold no speech, are listed in the window, and the pill says Import failed if none worked
- **Esc**: discards a dictation or cancels an import, from any app with Accessibility. A text field holding text, such as the search, takes it first, as do a popover and the menu
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
cannot leave a seemingly ready model. Existing compatible FluidAudio caches are reused.
The app loads the stock 15 s encoder and separate decoder and joint models.

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
successful build.

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

Preparation is specific to this Mac, the model paths and the compute configuration. It is not a
portable cache bundled for other machines; macOS can also invalidate it after an OS update or purge it
to reclaim space. A first load may need preparation again in those cases.

### Releases

Other people download `Paraketto.zip` from a GitHub release instead of building. They need Apple
Silicon and macOS 14+, grant Microphone and Accessibility access, and download their own model on
first use. The zip contains no recordings or transcripts.

For the first release, use the version already in `Info.plist`. For updates, raise
`CFBundleShortVersionString` and `CFBundleVersion`. Commit, push to `master`, and run `make release`.
It refuses a commit that isn't pushed and a version that already exists, then
pushes the tag `v<version>`. The tag starts `.github/workflows/release.yml`, which runs `make dist` on
a GitHub macOS runner and publishes the release with the zip. Installation instructions are in
the README; `.github/RELEASE_NOTES.md` provides the same instructions for a release description.
The workflow checks that the tag's version matches `Info.plist`.
If a build fails transiently, rerun it from Actions. If it needs a code change, fix it and release
a new version. To test a change to the workflow without publishing, start it from the
repository's Actions tab (**Release → Run workflow**), which builds and signs but doesn't publish.

`make dist` builds the zip in `.build/dist` from a copy of the last commit, so uncommitted work stays
out and this checkout's build and `/Applications` are left alone. It packs with `ditto`, as
[Apple describes](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution),
then unzips the result and checks its signature, microphone entitlement, usage text and architecture.
Run it locally to check a release before tagging. Locally it signs ad hoc; `DIST_SIGN_NAME` names a
certificate instead, and the build then fails if the zip isn't signed by it.

Releases are signed with their own self-signed certificate, `Paraketto Release`, so updates keep their
permissions. It exists only in the repository secrets `RELEASE_CERTIFICATE_P12` (the `.p12`, in
base64) and `RELEASE_CERTIFICATE_PASSWORD`. The workflow imports it into a temporary keychain, and
GitHub doesn't pass secrets to workflows run from forks. The `Paraketto Dev` certificate stays on the
development Mac. Anyone with either private key can sign an app that macOS treats as Paraketto, with
the permissions people gave it.

The release certificate expires in November 2036. To replace it, or if the secrets are lost, create a
new one with the commands under [Accessibility and rebuilds](#accessibility-and-rebuilds), using
`/CN=Paraketto Release`, `-name "Paraketto Release"` and a random password instead of `x`, and skip the
import. Then upload it, entering the password when asked:

```bash
base64 -i release.p12 | gh secret set RELEASE_CERTIFICATE_P12
gh secret set RELEASE_CERTIFICATE_PASSWORD
```

After that release, people run `tccutil reset All io.lfrati.paraketto` once and grant both permissions
again.

Releases aren't notarized, which needs a Developer ID certificate from the paid Apple Developer
Program. Browsers mark downloads with a quarantine attribute, and Gatekeeper blocks a marked app until
`xattr` removes the mark. Control-click stopped working in macOS 15, and the release notes for macOS
26 and 27 list no change to this. Apple also documents
[Open Anyway](https://support.apple.com/en-us/102445) in System Settings for apps that aren't
notarized, without saying which apps get the button. `syspolicy_check distribution` reports the
missing notarization as the release build's only problem, but the button hasn't been seen for
Paraketto, so the README gives only `xattr`. The README has people move the app to
Applications first, because Gatekeeper opens an app that hasn't been moved from a random read-only path
on its first launch.

Moving to Developer ID later means signing with it, adding `--timestamp` and notarizing the zip with
`notarytool`. The `xattr` step would then go away, and since the signature changes, people would grant
both permissions once more.

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
| `MenuContent.swift` | Ready, Needs Accessibility, Needs Microphone, Shortcut in use, Downloading, Optimizing, Loading, Recording, Transcribing, Notice, Model failed |
| `PillView.swift` | Recording (with a live meter), Transcribing, Importing, Copied, Error, All messages |
| `ShortcutRecorder.swift` | All states, Interactive |
| `DictionaryView.swift` | Dictionary, Empty dictionary, Import failed, Drop audio files, Drop while busy |
| `DictionaryEditor.swift` | Add replacement, Edit replacement, Adding to an existing target, Many spellings, Spelling already used |

`PreviewFixtures.swift` supplies disposable sample dictionary entries. Each preview has its own
temporary dictionary, transcripts folder and shortcut preferences; previews do not load recognition
models, start recording, register shortcuts, read the real dictionary or transcripts, or write to
the log. States reach the views through the debug-only `DictationController.showPreview`.
Preview declarations and fixtures are excluded from release builds.

Xcode reads the package’s file list when it opens the project. After adding or removing a source
file outside Xcode, close and reopen the project, or the canvas reports `Cannot find … in scope`.

**Run** builds and launches the real `Paraketto.app` from Xcode’s build folder, with the debugger
attached, its menu-bar icon and VAD model, and your real dictionary, transcripts, and models. Quit
any other running copy first, because both would answer the shortcut. The project signs ad-hoc, so
anyone can build it. If the `Paraketto Dev` certificate described under
[Accessibility and rebuilds](#accessibility-and-rebuilds) exists, the first Xcode build warns that it
was signed ad-hoc and writes the untracked `Resources/Signing.local.xcconfig`, and later builds sign
with the certificate. They have the same designated requirement as a `make bundle` build and keep the
Accessibility grant. Xcode signs every build, including each canvas rebuild, so if a keychain dialog
asks to let `codesign` use the key, choose **Always Allow**; **Allow** only covers that one build.

The project is only a thin app target: `Sources/ParakettoLauncher/main.swift` links the
`ParakettoKit` package library, and a final build phase runs `make xcode-bundle` to add the same
resources as `make bundle`. Use `make run` or `make bundle` to build the release app and install it
in Applications.

## Permissions

- **Microphone**: prompted on the first recording. macOS asks only once, so after a denial the pill
  reports "No mic access" and the menu offers **Grant Microphone…**, which opens System Settings.
- **Accessibility**: needed to send the Cmd+V keystroke and to see `Esc` in other apps. Prompted at
  launch, granted in System Settings → Privacy & Security → Accessibility. Without it the transcript
  is only copied to the clipboard and `Esc` can't cancel a recording, which the menu explains under
  **Grant Accessibility…**. After a grant, quit and reopen the app so event-posting permission
  takes effect. If Accessibility is granted but posting is unavailable, the menu says
  **Reopen to paste** and explains that transcripts are copied until then.
  Microphone access is checked before recording; Accessibility and event posting are checked before pasting.

The shortcut needs neither permission. Key combinations are Carbon hotkeys. A bare modifier tap relies
on macOS delivering modifier changes to global monitors without Accessibility, which Apple does not
document (checked on macOS 15.8). Other keys are withheld, so the tap reads the system's input counters
to tell a tap from Option+letter.

### Permissions and signatures

macOS remembers both grants against the app's
[designated requirement](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
With the `Paraketto Dev` certificate that is the bundle ID and the certificate's hash, so `make run`
builds count as the same app and keep their grants. The certificate doesn't need to be trusted: on
the development Mac it reports `CSSMERR_TP_NOT_TRUSTED`, and grants still survive rebuilds. If the
certificate ever changes, the switch looks on but isn't honored. Run
`tccutil reset Accessibility io.lfrati.paraketto` and grant it again.

Releases are signed with the `Paraketto Release` certificate described under [Releases](#releases),
so their requirement is the bundle ID and that certificate's hash, and updates keep their grants. An
ad-hoc signature's requirement matches only that exact build, so every update would need the grants
again.

`AXIsProcessTrusted` updates while the app runs. Posting Cmd+V is a separate privilege under the same
switch, and [Apple says](https://developer.apple.com/forums/thread/727984)
`CGPreflightPostEventAccess` doesn't update until a relaunch. The app checks both privileges before
claiming a paste was sent, and the log records both at launch and at each delivery. The first-grant
instructions explicitly include reopening the app.

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

Each replacement has one or more explicit spellings to replace and the target text to write with
them. The Dictionary window lists them with search and an add button.

The editor is a popover attached to the add button or the row's pencil, so the list stays in view.
**Replace** holds spellings as chips: a comma or Return finishes one, Delete in an empty field
reopens the last, and clicking a chip reopens it. **With** suggests
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

Replacements apply once, when a dictation or an import finishes: the pasted or copied text and the
transcript's file hold the result, and the original recognition output isn't kept. A rule change,
deleting one included, applies only to later transcripts: text already pasted into other apps and
files already saved stay as they are.
Rules live in `~/Library/Application Support/Paraketto/dictionary.json`.
Dictionary changes are saved atomically before becoming active. A failed save leaves the
previous rules active, and an unreadable dictionary is never silently overwritten.
Change detection uses the same literal Unicode spelling as matching. The matcher is rebuilt
only after rules load or a change is saved, then reused for subsequent transcripts.

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
| `MultiArray.swift` | small `MLMultiArray` helpers |

The Ultra model files are FluidInference's Core ML conversion of moondream's checkpoint, which is
based on NVIDIA's Parakeet TDT 0.6B v3 (all CC-BY-4.0, see [NOTICE](../NOTICE)): a fixed 15 s
preprocessor and int8 encoder, an LSTM decoder, and a joint network that returns token, probability
and duration bin directly.

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
The disk feeder runs outside the main actor, leaving the interface free while it reads batches.
Cancellation explicitly stops and drains that feeder before the recognizer is reused.
The WAV takes about 3.84 MB of disk per minute and is deleted once its users release it,
whether it was transcribed, cancelled or failed. Imports feed the file's samples straight to a
session, with no copy on disk. Transcript tokens still grow with recording length.
The live WAV is a temporary backlog buffer, not the old week-long recording history. Stopping
capture finalizes its header and synchronizes the file; transcription reads the published samples
through the shared file handle. The file is not moved into permanent storage.

Live and file transcription both feed batches of at most 100 ms through the same session and pause rules.
Each batch drains an autorelease pool so temporary Core ML/Foundation objects do not accumulate
during a long file import with no run-loop yield. The final batch drains one too.
VAD results for the current partial block are reused only when the sample count is unchanged,
such as when a cut or finalization consults the same audio again. New audio still triggers a new
evaluation at the normal cadence. Decoder state is not advanced after the last encoder frame,
since that state is discarded at the segment boundary.

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

### Performance review, 2026-11-06

Measured in release builds on an M1 Max with 32 GB RAM and macOS 15.8.2, using the cached stock
15 s encoder, separate decoder/joint models and bundled VAD. The fixture was 31.70 s of locally
synthesized speech and silence, producing four segments. Times are medians of three warm runs;
model loading and audio capture are excluded. The live simulation reads the temporary WAV in
100 ms batches through the transcriber actor; it does not measure microphone or UI latency.

| Measurement | Before this review | After |
|---|---:|---:|
| Disk-backed live simulation, including finish | 922 ms | 900 ms |
| Remaining recognition work at stop | 115 ms | 104 ms |
| File transcription, including audio reading | 938 ms | 885 ms |
| Process peak resident memory across repeated live/file runs | 212.5 MB | 96.4 MB |

Text, token ids, token frames and segment count matched the original implementation exactly on
this fixture. VAD evaluations fell from 113 to 112 and decoder calls from 227 to 226 per run.
The largest improvement was temporary-object lifetime, rather than fewer model calls. A separate
101 s session checked bounded audio buffering; cancellation, recognizer reuse and short silence
were also exercised. WAV finalization measured about 0.08 ms and remains synchronized.
This synthetic fixture checks path consistency and resource use, not recognition accuracy across
languages or a general speed guarantee.

### Optional model experiments

The multi-window encoder, fused decoder, export tools and historical comparisons are preserved
on `optimizations`. That branch includes `make encoder-export` and
`make decoder-export`; its copy of this document explains their setup and tradeoffs.
`master` uses one stock-model path and does not discover or load those optional exports.
The batch memory limits, VAD caching and off-main-thread live feeder apply to both branches.

### Measuring

- `xcrun xctrace record --template 'Core ML' --launch -- .build/release/paraketto-cli clip.wav`
  records every Core ML prediction and the Neural Engine's hardware intervals; export tables with
  `xcrun xctrace export --input <trace> --toc`.
- `paraketto-cli --plan` prints each model's operation count, how Core ML assigns operations to
  CPU, GPU and ANE, and which operators force the CPU.
- `PARAKEET_TIMING=1` prints mel, encoder and decode time per recording, with the number and total
  time of joint and decoder Core ML calls; `--chunk-ms N` feeds each file to a session in N ms chunks like the app
  and reports the time spent after the last chunk; `--tokens` prints each
  token with its frame; `--vad-probe` prints the VAD strip; `PARAKEET_DEBUG=1` logs every joint decision.

### Checking against FluidAudio

`make test` checks dictionary matching and selection, original preservation, file storage, audio decoding, recording downloads, paste delivery, and cache validation
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
its views: `UI` holds the views, and `Core` holds dictation control, audio, pasting, the transcripts
folder and the dictionary. `Sources/ParakettoLauncher` contains only the entry point, shared by the
SwiftPM executable and `Paraketto.xcodeproj`. Recognition is isolated in `Sources/ParakeetTDT`.
Generated bundles and caches are ignored. The source icon lives in `Resources`;
`tools/make_icon.swift` generates the app icon and template menu-bar image together.

Files dropped on the Dictionary window arrive through `FileDropArea`, an AppKit view that hosts the
window's content, not through SwiftUI's `dropDestination`. With `dropDestination`, Finder's file icon
stayed on screen for a moment after it was released over the window. AppKit removes it on release,
before the drop is handled. AppKit offers a drop only to the view under the pointer and its
ancestors, so the content has to be inside the drop view rather than beside it.

Each transcript is a text file in `~/Library/Application Support/Paraketto/transcripts/`, written
before the text is pasted. If it can't be written, a dictation is pasted anyway and the log records
the failure, while an import lists it among its errors and still copies the text.

Earlier versions also kept each transcript's original text as JSON and its recording as WAV in
`history/` for 7 days, after which the JSON moved to `history/archive/`. At launch the app gives
each transcript still in `history/` the text file it never got, if a save had failed, then moves its
JSON to `history/archive/` and deletes the recordings. A transcript whose file can't be written
keeps its JSON and recording for the next launch to try again. Nothing reads or removes
`history/archive/`.
`~/Library/Logs/Paraketto.log` is truncated on each launch and never contains transcripts.

Transcript filenames that collide get a numbered suffix. Creation refuses to overwrite an
existing path, including one created by another writer after a filename was chosen.

## Tests and tools

`master` holds only what builds and runs the app. The regression tests, the `paraketto-cli` runner,
benchmarks and the VAD exporter live on the `dev-tools` branch, which is `master` plus those files,
and this document's copy there explains them. `git switch dev-tools && git merge master` brings it up
to date. Never merge `dev-tools` into `master`.
Keep `optimizations` separate from `master` as well.
Some tests on `dev-tools` still use removed history, transcript-editing and optional-model APIs; merging
the app changes also requires adapting those tests before the full suite can run.
