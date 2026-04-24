.PHONY: test-client build-app test-server test-all

test-client:
	cd IMClientKit && swift test --no-parallel

build-app:
	xcodebuild \
		-project IMApp/IMApp.xcodeproj \
		-scheme IMApp \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
		build-for-testing

test-server:
	cd IMServer && swift test --no-parallel

test-all: test-client build-app test-server
