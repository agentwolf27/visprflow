PROJECT   := Visprflow.xcodeproj
SCHEME    := Visprflow
DERIVED   := build
APP       := $(DERIVED)/Build/Products/Debug/Visprflow.app
XCB       := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath $(DERIVED)

.PHONY: gen build test verify-stt run clean logs

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

## Build and launch the app (it lives in the menu bar)
run: build
	open "$(APP)"

## Stream the app's logs
logs:
	log stream --predicate 'subsystem == "com.vish.visprflow"' --level debug --style compact

clean:
	rm -rf $(DERIVED) $(PROJECT)
