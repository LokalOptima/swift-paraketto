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
CONTENTS      := $(BUNDLE)/Contents
VAD_PACKAGE   := Resources/VadHead.mlpackage
VAD_COMPILED  := .build/VadHead.mlmodelc
APP_ICON      := .build/Paraketto.icns
ICON_SOURCE   := Resources/paraketto.png
# Signing. macOS ties the Accessibility grant to the app's signature. With the "Paraketto Dev"
# self-signed certificate in the login keychain (see docs/internals.md) every build carries the same
# signature and the grant survives; without it codesign falls back to ad-hoc ("-"), whose
# signature changes on every build. The certificate is selected by the SHA-1 hash that
# `security find-identity` prints, so a certificate imported twice is not "ambiguous" to codesign.
# Override with SIGN_IDENTITY=<hash or name>; the bundle target then checks the signature
# against SIGN_NAME, so set that too for a differently named certificate.
SIGN_NAME     ?= Paraketto Dev
SIGN_IDENTITY ?= $(or $(shell security find-identity -p codesigning 2>/dev/null | grep -F '"$(SIGN_NAME)"' | head -1 | awk '{print $$2}'),-)
SIGN_IDENTITY := $(SIGN_IDENTITY)

.PHONY: all build bundle xcode-bundle icons run trust vad clean

all: bundle

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
	@echo "signed ad-hoc: no $(SIGN_NAME) certificate found, the Accessibility grant will not survive rebuilds"
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

run: bundle
ifeq ($(INSTALL_APP),1)
	open "$(INSTALL_DIR)/$(BUNDLE)"
else
	open $(BUNDLE)
endif

# Drops the stale Accessibility entry left by a previous (ad-hoc) build and opens the
# Accessibility pane so the running build can be granted again.
trust:
	tccutil reset Accessibility $(BUNDLE_ID)
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

clean:
	rm -rf $(BUNDLE) .build
