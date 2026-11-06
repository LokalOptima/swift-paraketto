Download **Paraketto.zip** from Assets below. Requires Apple Silicon and macOS 14 or later.

1. Unzip it and move **Paraketto.app** to **Applications**.
2. Run this in Terminal to unblock the self-signed app:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Paraketto.app
   ```
3. Open Paraketto and enable **Accessibility** in System Settings when prompted. Quit and reopen Paraketto after granting it. The first dictation asks for **Microphone** access.

Tap **Right Option**, speak, then tap it again to paste the text. The speech model downloads on first launch (about 613 MB). Audio and transcripts stay on your Mac.

**Updating:** quit Paraketto, replace the app with this download, and run the same `xattr` command again. Releases use the same signing certificate and bundle identifier so macOS can retain your existing permissions.
