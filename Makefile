define n


endef

.EXPORT_ALL_VARIABLES:

DISABLE_NOTARIZATION := ${DISABLE_NOTARIZATION}
DISABLE_PACKING := ${DISABLE_PACKING}
ENV=Release
CHANNEL=
DSA=0

ifeq (beta, $(CHANNEL))
FULL_VERSION:=$(VERSION)b$V
else ifeq (beta, $(CHANNEL))
FULL_VERSION:=$(VERSION)a$V
else
FULL_VERSION:=$(VERSION)
endif

RELEASE_NOTES_FILES := $(wildcard ReleaseNotes/*.md)
TEMPLATE_FILES := $(wildcard Lunar/Templates/*.stencil)
GENERATED_FILES=$(patsubst Lunar/Templates/%.stencil,Lunar/Generated/%.generated.swift,$(TEMPLATE_FILES))

.git/hooks/pre-commit: pre-commit.sh
	@ln -fs "${PWD}/pre-commit.sh" "${PWD}/.git/hooks/pre-commit"; \
	chmod +x "${PWD}/.git/hooks/pre-commit"
install-hooks: .git/hooks/pre-commit

/usr/local/bin/%:
ifeq (, $(shell which brew))
	$(error No brew in PATH, aborting...:$n)
else
	brew install $*
endif

install-swiftformat: /usr/local/bin/swiftformat
install-sourcery: /usr/local/bin/sourcery
install-git-secret: /usr/local/bin/git-secret

install-deps: install-swiftformat install-sourcery install-git-secret

codegen: $(GENERATED_FILES)

CHANGELOG.md: $(RELEASE_NOTES_FILES)
	tail -n +1 `ls -r ReleaseNotes/*.md` | sed -E 's/==> ReleaseNotes\/(.+)\.md <==/# \1/g' > CHANGELOG.md

changelog: CHANGELOG.md
dev: install-deps install-hooks codegen

.PHONY: release upload build sentry pkg dmg pack appcast
upload:
	rsync -avzP Releases/*.delta darkwoods:/static/Lunar/deltas/ || true
	rsync -avzP Releases/*.dmg darkwoods:/static/Lunar/releases/
	rsync -avzP Releases/*.html darkwoods:/static/Lunar/ReleaseNotes/
	rsync -avzP ReleaseNotes/*.css darkwoods:/static/Lunar/ReleaseNotes/
	fish -c 'upload -d Lunar Releases/appcast2.xml'
	cfcli -d lunar.fyi purge

release: changelog
	echo "$(VERSION)" > /tmp/release_file_$(VERSION).md
	echo "" >> /tmp/release_file_$(VERSION).md
	echo "" >> /tmp/release_file_$(VERSION).md
	cat ReleaseNotes/$(VERSION).md >> /tmp/release_file_$(VERSION).md
	gh release create v$(VERSION) -F /tmp/release_file_$(VERSION).md "Releases/Lunar-$(VERSION).dmg#Lunar.dmg"

sentry: export DWARF_DSYM_FOLDER_PATH="$(shell xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -showBuildSettings -json 2>/dev/null | jq -r .[0].buildSettings.DWARF_DSYM_FOLDER_PATH)"
sentry:
	./bin/sentry.sh

print-%  : ; @echo $* = $($*)

dmg: SHELL=/usr/local/bin/fish
dmg:
	env CODESIGNING_FOLDER_PATH=(xcdir -s 'Lunar $(ENV)' -c $(ENV))/Lunar.app ./bin/make-installer dmg

pack: SHELL=/usr/local/bin/fish
pack: export SPARKLE_BIN_DIR="$(shell dirname $$(dirname $$(dirname $$(xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -showBuildSettings -json 2>/dev/null | jq -r .[0].buildSettings.BUILT_PRODUCTS_DIR))))/SourcePackages/artifacts/sparkle/bin"
pack:
	env CODESIGNING_FOLDER_PATH=(xcdir -s 'Lunar $(ENV)' -c $(ENV))/Lunar.app PROJECT_DIR=$$PWD ./bin/pack

appcast: export SPARKLE_BIN_DIR="$(shell dirname $$(dirname $$(dirname $$(xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -showBuildSettings -json 2>/dev/null | jq -r .[0].buildSettings.BUILT_PRODUCTS_DIR))))/SourcePackages/artifacts/sparkle/bin"
appcast: VERSION=$(shell xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -workspace Lunar.xcworkspace -showBuildSettings -json 2>/dev/null | jq -r .[0].buildSettings.MARKETING_VERSION)
appcast: Releases/Lunar-$(FULL_VERSION).html
ifneq (, $(CHANNEL))
	"$(SPARKLE_BIN_DIR)/generate_appcast" --major-version "4.0.0" --link "https://lunar.fyi/" --full-release-notes-url "https://lunar.fyi/changelog" --channel "$(CHANNEL)" --release-notes-url-prefix https://files.lunar.fyi/ReleaseNotes/ --download-url-prefix https://files.lunar.fyi/releases/ -o Releases/appcast2.xml Releases
else
	"$(SPARKLE_BIN_DIR)/generate_appcast" --major-version "4.0.0" --link "https://lunar.fyi/" --full-release-notes-url "https://lunar.fyi/changelog" --release-notes-url-prefix https://files.lunar.fyi/ReleaseNotes/ --download-url-prefix https://files.lunar.fyi/releases/ -o Releases/appcast2.xml Releases
endif

setversion: OLD_VERSION=$(shell xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -workspace Lunar.xcworkspace -showBuildSettings -json 2>/dev/null | jq -r .[0].buildSettings.MARKETING_VERSION)
setversion:
ifneq (, $(FULL_VERSION))
	rg -l 'VERSION = "?$(OLD_VERSION)"?' && sed -E -i .bkp 's/VERSION = "?$(OLD_VERSION)"?/VERSION = $(FULL_VERSION)/g' $$(rg -l 'VERSION = "?$(OLD_VERSION)"?')
endif

clean:
	xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -workspace Lunar.xcworkspace ONLY_ACTIVE_ARCH=NO clean

build: BEAUTIFY=1
build: ONLY_ACTIVE_ARCH=NO
build: setversion
ifneq ($(BEAUTIFY),0)
	xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -workspace Lunar.xcworkspace ONLY_ACTIVE_ARCH=$(ONLY_ACTIVE_ARCH) | tee /tmp/lunar-$(ENV)-build.log | xcbeautify
else
	xcodebuild -scheme "Lunar $(ENV)" -configuration $(ENV) -workspace Lunar.xcworkspace ONLY_ACTIVE_ARCH=$(ONLY_ACTIVE_ARCH) | tee /tmp/lunar-$(ENV)-build.log
endif
ifneq ($(DISABLE_PACKING),1)
	make pack VERSION=$(VERSION) CHANNEL=$(CHANNEL) V=$V
endif
ifneq ($(DISABLE_SENTRY),1)
	make sentry VERSION=$(VERSION) CHANNEL=$(CHANNEL) V=$V
endif

Releases/Lunar-%.html: ReleaseNotes/$(VERSION)*.md
	@echo Compiling $^ to $@
	pandoc -f gfm -o $@ --standalone --metadata title="Lunar $(FULL_VERSION) - Release Notes" --css https://files.lunar.fyi/ReleaseNotes/style.css $^
