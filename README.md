# swift-paraketto

I like [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) models, but all local dictations apps I've tried are overwhelming. So I made a simple one for myself 🤷‍♂️

# tl;dr
Tap shortcut (default: `Right ⌥`), speak, tap it again: the text is copied to your clipboard and pasted into whatever app has focus. 

Multilingual [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) runs on the Apple Neural Engine with Core ML (the model downloads on first use, about 613 MB).

Extra features:
- drag and drop audio files to transcribe them
- custom replacements ("gee tub" : "github")

To set it up just use `make run`. Requires macOS 14+, Apple Silicon, and Xcode 16 or later.
