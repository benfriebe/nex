.PHONY: lint lint-fix format format-check build test check

lint:
	swiftlint lint

lint-fix:
	swiftlint lint --fix

format:
	swiftformat .

format-check:
	swiftformat --lint .

build:
	xcodegen generate --spec project.yml
	xcodebuild -scheme Nex -destination 'platform=macOS' -skipMacroValidation build

test:
	xcodebuild -scheme NexTests -destination 'platform=macOS' -skipMacroValidation test

check: format-check lint build test
