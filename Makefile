APP_NAME      := Paraketto
BUNDLE_ID     := io.lfrati.paraketto
BUNDLE        := $(APP_NAME).app
CONFIG        ?= release
# Warm this Mac's Core ML caches through the signed app after bundling.
# Disable for packaging on a build machine that will not run the app.
PREPARE_MODELS ?= 1
INSTALL_APP   ?= 1
INSTALL_DIR   ?= /Applications
BINARY        := .build/$(CONFIG)/ParakettoLauncher
CLI           := .build/$(CONFIG)/paraketto-cli
CONTENTS      := $(BUNDLE)/Contents
VAD_PACKAGE   := Resources/VadHead.mlpackage
VAD_COMPILED  := .build/VadHead.mlmodelc
APP_ICON      := .build/Paraketto.icns
ICON_SOURCE   := Resources/paraketto.png
FIXTURES      := tests/fixtures/librispeech_fluidaudio.tsv
CLIPS         ?= data/librispeech/*.wav
# Signing. macOS ties the Microphone and Accessibility grants to the app's signature. With the
# "Paraketto Dev" self-signed certificate in the login keychain (see docs/internals.md) every build
# carries the same signature and the grants survive; without it codesign falls back to ad-hoc ("-"),
# whose signature changes on every build. The certificate is selected by the SHA-1 hash that
# `security find-identity` prints, so a certificate imported twice is not "ambiguous" to codesign.
# Override with SIGN_IDENTITY=<hash or name>; the bundle target then checks the signature
# against SIGN_NAME, so set that too for a differently named certificate.
SIGN_NAME     ?= Paraketto Dev
SIGN_IDENTITY ?= $(or $(shell security find-identity -p codesigning 2>/dev/null | grep -F '"$(SIGN_NAME)"' | head -1 | awk '{print $$2}'),-)
SIGN_IDENTITY := $(SIGN_IDENTITY)
DIST_DIR      := .build/dist
DIST_ZIP      := $(DIST_DIR)/$(APP_NAME).zip
# Signed ad hoc unless this names a certificate, as the GitHub release build does.
DIST_SIGN_NAME ?=
# From the last commit, which is what `dist` builds, and only worked out when a release needs it.
VERSION        = $(shell git show HEAD:Resources/Info.plist | plutil -extract CFBundleShortVersionString raw -o - -)

.PHONY: screenshots all build bundle xcode-bundle icons run prepare-models trust vad dist release cli test test-models compare longform vad-export encoder-export decoder-export clean

MODELS_DIR    := $(HOME)/Library/Application Support/Paraketto/models

all: bundle

# Always debug: preview fixtures and screenshot code are excluded from release builds.
SCREENSHOTS_DIR ?= .build/screenshots
screenshots:
	swift run -c debug paraketto-screenshots --output "$(SCREENSHOTS_DIR)" $(SCREENSHOTS_ARGS)

build:
	swift build -c $(CONFIG)

# Compiles the VAD head once; the .mlpackage in Resources is the source of truth.
vad: $(VAD_COMPILED)

$(VAD_COMPILED): $(VAD_PACKAGE)/Manifest.json $(VAD_PACKAGE)/Data/com.apple.CoreML/model.mlmodel $(VAD_PACKAGE)/Data/com.apple.CoreML/weights/weight.bin
	rm -rf $(VAD_COMPILED)
	xcrun coremlcompiler compile $(VAD_PACKAGE) .build

.build/make-icon: tools/make_icon.swift
	mkdir -p .build
	swiftc -parse-as-library tools/make_icon.swift -o .build/make-icon

# Regenerate both outputs together, including when either generated file was removed.
icons: .build/make-icon $(ICON_SOURCE)
	.build/make-icon $(ICON_SOURCE) .build/Paraketto.iconset
	iconutil -c icns .build/Paraketto.iconset -o $(APP_ICON)

bundle: build vad icons
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp $(APP_ICON) $(CONTENTS)/Resources/
	cp .build/ParakettoMenu.png $(CONTENTS)/Resources/
	cp -R $(VAD_COMPILED) $(CONTENTS)/Resources/
	cp LICENSE NOTICE $(CONTENTS)/Resources/
# The first codesign with a new key blocks on a keychain dialog until "Always Allow" is clicked.
	codesign --force --sign "$(SIGN_IDENTITY)" \
		--entitlements Resources/$(APP_NAME).entitlements \
		--options runtime $(BUNDLE)
	codesign --verify --deep --strict $(BUNDLE)
ifneq ($(SIGN_IDENTITY),-)
# An ad-hoc build would look fine but lose the Accessibility grant, so refuse to keep one.
	@codesign -dvv $(BUNDLE) 2>&1 | grep -q '^Authority=$(SIGN_NAME)$$' \
		|| { echo "error: $(BUNDLE) is not signed by $(SIGN_NAME); removing it"; rm -rf $(BUNDLE); exit 1; }
	@echo "signed with: $(SIGN_NAME) ($(SIGN_IDENTITY))"
else
	@echo "signed ad-hoc: without the $(SIGN_NAME) certificate, the Accessibility grant will not survive rebuilds"
endif
ifeq ($(PREPARE_MODELS),1)
	$(CONTENTS)/MacOS/$(APP_NAME) --prepare-models --cached-only
endif
ifeq ($(INSTALL_APP),1)
	mkdir -p "$(INSTALL_DIR)"
	/usr/bin/rsync -aE --delete "$(BUNDLE)/" "$(INSTALL_DIR)/$(BUNDLE)/"
	codesign --verify --deep --strict "$(INSTALL_DIR)/$(BUNDLE)"
endif

# Last build phase of Paraketto.xcodeproj, which sets these paths in the environment.
# A signing run cancelled by a newer build leaves a .cstemp that would fail the next signature.
xcode-bundle: vad icons
	rm -f "$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/"*.cstemp
	mkdir -p "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)"
	cp $(APP_ICON) .build/ParakettoMenu.png "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
	cp -R $(VAD_COMPILED) "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
ifneq ($(SIGN_IDENTITY),-)
# Xcode signs ad-hoc until told otherwise, which would look fine but lose the Accessibility grant.
# It signed this build already, so naming the certificate here takes effect on the next one.
	@if [ "$(CODE_SIGN_IDENTITY)" = "-" ] && [ ! -f Resources/Signing.local.xcconfig ]; then \
		echo 'CODE_SIGN_IDENTITY = $(SIGN_NAME)' > Resources/Signing.local.xcconfig; \
		echo 'warning: This build is signed ad-hoc and will lose the Accessibility grant. Build again to sign with $(SIGN_NAME).'; \
	fi
endif

# Explicitly download and prepare Ultra; bundle alone only prepares an installed model.
prepare-models: bundle
	$(CONTENTS)/MacOS/$(APP_NAME) --prepare-models

run: bundle
ifeq ($(INSTALL_APP),1)
	open "$(INSTALL_DIR)/$(BUNDLE)"
else
	open $(BUNDLE)
endif

# The download for other Macs, which GitHub builds for each release (.github/workflows/release.yml).
# Made from a copy of the last commit, so uncommitted work stays out and this checkout's build and the
# app in /Applications are left alone. It never uses the Paraketto Dev certificate. Its name stays the
# same because the README links to .../releases/latest/download/Paraketto.zip.
dist:
	rm -rf $(DIST_DIR)
	mkdir -p $(DIST_DIR)/source $(DIST_DIR)/unzipped
	git archive HEAD | tar -x -C $(DIST_DIR)/source
	$(MAKE) -C $(DIST_DIR)/source bundle CONFIG=release INSTALL_APP=0 PREPARE_MODELS=0 \
		$(if $(DIST_SIGN_NAME),SIGN_NAME="$(DIST_SIGN_NAME)",SIGN_IDENTITY=-)
	ditto -c -k --keepParent $(DIST_DIR)/source/$(BUNDLE) $(DIST_ZIP)
# Checks what people will get. macOS kills an app that uses the microphone without the entitlement or the usage text.
	ditto -x -k $(DIST_ZIP) $(DIST_DIR)/unzipped
	codesign --verify --deep --strict $(DIST_DIR)/unzipped/$(BUNDLE)
ifneq ($(DIST_SIGN_NAME),)
# Without the certificate the build falls back to ad hoc, and each update would lose its permissions.
	@codesign -dvv $(DIST_DIR)/unzipped/$(BUNDLE) 2>&1 | grep -qxF 'Authority=$(DIST_SIGN_NAME)' \
		|| { echo "error: the download is not signed by $(DIST_SIGN_NAME)"; exit 1; }
endif
	codesign -d --entitlements - --xml $(DIST_DIR)/unzipped/$(BUNDLE) | grep -q com.apple.security.device.audio-input
	/usr/libexec/PlistBuddy -c 'Print NSMicrophoneUsageDescription' $(DIST_DIR)/unzipped/$(CONTENTS)/Info.plist > /dev/null
	test "$$(lipo -archs $(DIST_DIR)/unzipped/$(CONTENTS)/MacOS/$(APP_NAME))" = arm64
	rm -rf $(DIST_DIR)/source $(DIST_DIR)/unzipped
	@echo "$(DIST_ZIP): version $(VERSION), commit $$(git rev-parse --short HEAD)"

# Pushes the tag v$(VERSION) for the last commit. GitHub then builds the download and publishes the release.
release:
	@git fetch -q origin && git merge-base --is-ancestor HEAD origin/master || { echo "error: push this commit to master first, as GitHub builds the release from it"; exit 1; }
	@if git ls-remote --exit-code --tags origin v$(VERSION) > /dev/null; then echo "error: v$(VERSION) already exists, so raise the version in Resources/Info.plist"; exit 1; fi
	git push origin HEAD:refs/tags/v$(VERSION)
	@echo "GitHub is building v$(VERSION) and publishes it when the build finishes. Follow it on the repository's Actions tab."

# Drops the stale Accessibility entry left by a previous (ad-hoc) build and opens the
# Accessibility pane so the running build can be granted again.
trust:
	tccutil reset Accessibility $(BUNDLE_ID)
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

cli: build vad

test: vad
	swift test -c $(CONFIG)

test-models: vad
	PARAKETTO_MODEL_TESTS=1 swift test -c $(CONFIG)

# Transcribes the LibriSpeech clips and checks every transcript against FluidAudio's.
compare: cli
	$(CLI) --vad $(VAD_COMPILED) --chunk-ms 100 --compare $(FIXTURES) --hypotheses .build/hypotheses.tsv $(CLIPS) | tail -2
	cd tools/export && uv run python ../../tests/score.py ../../$(FIXTURES) ../../.build/hypotheses.tsv

# Joins the clips into one to three minute files and scores the recording-time segmentation on them.
longform: cli
	cd tools/export && uv run python ../../tests/make_longform.py --clips "$(abspath $(dir $(firstword $(wildcard $(CLIPS)))))" --out ../../.build/longform
	$(CLI) --vad $(VAD_COMPILED) --chunk-ms 100 --compare .build/longform/reference.tsv --hypotheses .build/longform/hypotheses.tsv .build/longform/gap*.wav | tail -2
	cd tools/export && uv run python ../../tests/score.py ../../.build/longform/reference.tsv ../../.build/longform/hypotheses.tsv

# Re-exports the VAD head from moondream/parakeet-ultra (needs uv; fetches ~9 MB of weights).
vad-export:
	cd tools/export && uv run python export_vad_head.py --out ../../$(VAD_PACKAGE)

# Exports the encoder with 5 s, 10 s and 15 s windows (needs uv; downloads the 1.2 GB checkpoint once)
# and compiles it where the app and CLI pick it up automatically.
encoder-export:
	cd tools/export && uv run python export_encoder.py --out "$(MODELS_DIR)/parakeet-ultra-encoder/Encoder.mlpackage"
	rm -rf "$(MODELS_DIR)/parakeet-ultra-encoder/Encoder.mlmodelc"
	xcrun coremlcompiler compile "$(MODELS_DIR)/parakeet-ultra-encoder/Encoder.mlpackage" "$(MODELS_DIR)/parakeet-ultra-encoder"

# Exports the fused decoder+joint step model (needs uv; fetches ~36 MB of weights) and compiles it.
decoder-export:
	cd tools/export && uv run python export_fused_decoder.py --out "$(MODELS_DIR)/parakeet-ultra-decoder/DecoderJoint.mlpackage"
	rm -rf "$(MODELS_DIR)/parakeet-ultra-decoder/DecoderJoint.mlmodelc"
	xcrun coremlcompiler compile "$(MODELS_DIR)/parakeet-ultra-decoder/DecoderJoint.mlpackage" "$(MODELS_DIR)/parakeet-ultra-decoder"

clean:
	rm -rf $(BUNDLE) .build
