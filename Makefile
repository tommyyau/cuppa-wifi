.PHONY: check release-check parity-audit native-test js-test swift-test webview-smoke local-model-smoke swift-build ui-previews app-icon app clean
.DEFAULT_GOAL := check

native-test:
	swift build --package-path macos/CuppaAutologinApp --product CuppaFixtureServer
	CUPPA_FIXTURE_SERVER="$$(swift build --package-path macos/CuppaAutologinApp --show-bin-path)/CuppaFixtureServer" swift test --package-path macos/CuppaAutologinApp

parity-audit:
	node scripts/verify-parity.mjs
	node scripts/verify-native-tests.mjs

swift-test:
	bash macos/run_swift_tests.sh

webview-smoke:
	bash macos/run_webview_smoke_test.sh

local-model-smoke:
	WIFI_PORTAL_SMOKE_MODEL_ONLY=1 bash macos/run_webview_smoke_test.sh

js-test:
	@if command -v node >/dev/null 2>&1; then \
		node --test macos/Resources/__tests__/autofill.test.js; \
	else \
		echo "Node.js is required for JavaScript portal tests; install it before running make check." >&2; \
		exit 1; \
	fi

swift-build:
	swift build -c debug --package-path macos/CuppaAutologinApp

ui-previews:
	bash macos/render_ui_previews.sh

app-icon:
	bash macos/generate_app_icon.sh

check: parity-audit native-test js-test swift-test swift-build
	plutil -lint macos/Info.plist
	bash -n macos/build_app.sh macos/generate_app_icon.sh macos/render_ui_previews.sh macos/run_webview_smoke_test.sh macos/test_install_intervals.sh
	bash macos/test_install_intervals.sh

release-check: check webview-smoke

app: release-check
	bash macos/build_app.sh

# Reproducible outputs only. Never remove saved data or private captures.
clean:
	rm -rf macos/CuppaAutologinApp/.build dist
