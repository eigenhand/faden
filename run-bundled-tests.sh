#!/bin/bash
# Prueft den Tester-Build: Schluessel einsetzen, ueber eine leere Ablage installieren,
# die beiden Live-Tests laufen lassen, Schluessel wieder entfernen.
set -euo pipefail
DEV="${1:?Geraete-UDID fehlt}"
BUNDLED="PerBu/App/BundledSetup.swift"

restore() {
  python3 - "$BUNDLED" <<'RESET'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r'^    static let apiKey = .*$', '    static let apiKey = ""', s, flags=re.M)
s = re.sub(r'^    static let searchKey = .*$', '    static let searchKey = ""', s, flags=re.M)
p.write_text(s)
RESET
}
trap restore EXIT

MK=$(grep -E "^MODEL_API_KEY=" test.env | cut -d= -f2-)
SK=$(grep -E "^SEARCH_API_KEY=" test.env | cut -d= -f2- || true)
MODEL_KEY="$MK" SEARCH_KEY="$SK" python3 - "$BUNDLED" <<'INJECT'
import json, os, pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
lit = lambda v: json.dumps(v or "")
s = re.sub(r'^    static let apiKey = .*$', '    static let apiKey = ' + lit(os.environ.get("MODEL_KEY")), s, flags=re.M)
s = re.sub(r'^    static let searchKey = .*$', '    static let searchKey = ' + lit(os.environ.get("SEARCH_KEY")), s, flags=re.M)
p.write_text(s)
INJECT

xcodebuild build-for-testing -project PerBu.xcodeproj -scheme PerBu \
  -destination "id=$DEV" -derivedDataPath build/dd-test 2>&1 | grep -E "error:|BUILD" || true
xcrun simctl terminate "$DEV" dev.eigenhand.perbu 2>/dev/null || true
xcrun simctl uninstall "$DEV" dev.eigenhand.perbu 2>/dev/null || true
xcodebuild test-without-building -project PerBu.xcodeproj -scheme PerBu \
  -destination "id=$DEV" -derivedDataPath build/dd-test \
  -only-testing:PerBuUITests/BundledBuildTests 2>&1 | grep -E "Test Case|error:|TEST "
