PROJECT   := Visprflow.xcodeproj
SCHEME    := Visprflow
DERIVED   := build
APP       := $(DERIVED)/Build/Products/Debug/Visprflow.app
XCB       := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath $(DERIVED)

.PHONY: gen build test verify-stt run release install clean logs

## Generate Visprflow.xcodeproj from project.yml (requires: brew install xcodegen)
gen:
	xcodegen generate --quiet

## Build the Debug app
build: gen
	$(XCB) -configuration Debug build 2>&1 | grep -E 'error:|warning:|BUILD ' || true

## Run the unit tests
test: gen
	$(XCB) test 2>&1 | grep -E 'error:|Test Case .* (passed|failed)|Executed|BUILD |TEST ' || true

## Run the speech tests against audio synthesised with `say`.
## First run downloads roughly 600 MB of Core ML models.
verify-stt: gen
	TEST_RUNNER_VISPRFLOW_STT=1 $(XCB) test -only-testing:VisprflowTests/SpeechIntegrationTests 2>&1 | \
		grep -E 'STT|error:|Test Case .* (passed|failed)|Executed|TEST ' || true

## Build the optimised Release app.
## ARCHS is passed here rather than in project.yml because Swift package targets are separate
## projects and do not inherit it. Apple Silicon only: FluidAudio's Float16 paths do not
## compile for x86_64, and Parakeet needs the Neural Engine regardless.
release: gen
	$(XCB) -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build 2>&1 | grep -E 'error:|BUILD ' || true

## Build Release and install into ~/Applications.
## Do this once and launch from there: debug builds are ad-hoc signed, so macOS ties the
## Accessibility and Input Monitoring grants to the exact binary and a rebuild loses them.
install: release
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(HOME)/Applications/Visprflow.app"
	@cp -R "$(DERIVED)/Build/Products/Release/Visprflow.app" "$(HOME)/Applications/"
	@echo "Installed to ~/Applications/Visprflow.app"

## Build and launch the app (it lives in the menu bar)
run: build
	open "$(APP)"

## Stream the app's logs
logs:
	log stream --predicate 'subsystem == "com.vish.visprflow"' --level debug --style compact

clean:
	rm -rf $(DERIVED) $(PROJECT)
