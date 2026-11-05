# swift-paraketto

I like [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) models, but all local dictation apps I've tried are overwhelming. So "I" made a simple one for myself.

# tl;dr
Tap shortcut (default: `Right ⌥`), speak, tap it again: the text is copied to your clipboard and pasted into whatever app has focus.

Multilingual [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) runs on the Apple Neural Engine with Core ML (the model downloads on first use, about 613 MB).

Extra features:
- drag and drop audio files to transcribe them
- custom replacements ("gee tub" : "github")

Requires macOS 14+ and Apple Silicon.

# How to install it?

## If you trust me:
(sorry, I'm not gonna pay a monthly fee for your convenience 🤷‍♂️)

1. Download [Paraketto.zip](https://github.com/LokalOptima/swift-paraketto/releases/latest/download/Paraketto.zip), unzip it, and move `Paraketto.app` to Applications.
2. The app isn't notarized by Apple, so macOS blocks it. Unblock it in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Paraketto.app
   ```
3. Open it and allow Accessibility, which lets it paste. It asks for the microphone on your first dictation.

To update, quit the app, replace it with the new download, and run the `xattr` command from step 2 again. Your permissions carry over.

## If you don't trust me:
Just use `make run`. Requires macOS 14+, Apple Silicon, and Xcode 16 or later.

## If you don't care:
Just ask your agent.
