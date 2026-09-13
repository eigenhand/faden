#!/bin/bash
# Builds PerBu and uploads it to TestFlight.
#
# Prerequisites (one-off, in App Store Connect / the Developer Portal):
#   1. Bundle-ID dev.eigenhand.perbu registriert
#   2. App-Eintrag angelegt (Name, Primärsprache, SKU)
#   3. API-Key mit der Rolle "App Manager" — liegt bereits unter
#      ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#
# Aufruf:  ASC_ISSUER_ID=<issuer-uuid> ./release.sh
set -euo pipefail

# Lokale Konfiguration, falls vorhanden (steht in .gitignore).
[ -f .release.env ] && . ./.release.env

# Keine Vorgabe: eine fest eingebaute Key ID ist ein Detail ueber ein fremdes
# Konto, und ein Fork wuerde still damit signieren wollen.
KEY_ID="${ASC_KEY_ID:?ASC_KEY_ID fehlt. In .release.env eintragen; die ID ist Teil des Dateinamens unter ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8}"
: "${ASC_ISSUER_ID:?Issuer ID fehlt. Entweder in .release.env eintragen oder ASC_ISSUER_ID=... voranstellen. Zu finden in App Store Connect > Users and Access > Integrations > App Store Connect API, ueber der Key-Liste.}"

ARCHIVE="build/PerBu.xcarchive"
EXPORT="build/export"

# App Store Connect lehnt Uploads ab, die mit einer Xcode-Beta gebaut wurden
# (Fehler 90534). Ist die aktive Auswahl eine Beta und daneben ein regulaeres
# Xcode installiert, wird fuer diesen Build auf das regulaere umgeschaltet —
# nur fuer dieses Skript, die globale Auswahl bleibt unberuehrt.
if xcode-select -p | grep -qi "beta" && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "==> Baue mit $(defaults read /Applications/Xcode.app/Contents/Info.plist CFBundleShortVersionString) statt der Beta"
fi

# Schluessel fuer den Testflight-Build einsetzen.
#
# Sie landen im Binary und sind fuer jeden lesbar, der es hat — das ist die bewusste
# Abwaegung fuer einen Build an namentlich bekannte Tester, damit die die App
# benutzen koennen statt ein Einrichtungsformular. Genommen wird bevorzugt ein
# eigener Beta-Schluessel aus .release.env; TensorX weist Kosten und Token pro
# Schluessel aus, so bleibt der Verbrauch der Testrunde getrennt und widerrufbar.
BUNDLED="PerBu/App/BundledSetup.swift"

restore_bundled() {
  python3 - "$BUNDLED" <<'RESET'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r'^    static let apiKey = .*$', '    static let apiKey = ""', s, flags=re.M)
s = re.sub(r'^    static let searchKey = .*$', '    static let searchKey = ""', s, flags=re.M)
p.write_text(s)
RESET
}
trap restore_bundled EXIT

BETA_MODEL_KEY="${BETA_MODEL_KEY:-}"
BETA_SEARCH_KEY="${BETA_SEARCH_KEY:-}"
if [ -f test.env ]; then
  [ -z "$BETA_MODEL_KEY" ]  && BETA_MODEL_KEY=$(grep -E "^MODEL_API_KEY="  test.env | cut -d= -f2- || true)
  [ -z "$BETA_SEARCH_KEY" ] && BETA_SEARCH_KEY=$(grep -E "^SEARCH_API_KEY=" test.env | cut -d= -f2- || true)
fi

if [ -n "$BETA_MODEL_KEY" ]; then
  MODEL_KEY="$BETA_MODEL_KEY" SEARCH_KEY="$BETA_SEARCH_KEY" python3 - "$BUNDLED" <<'INJECT'
import json, os, pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
def lit(v): return json.dumps(v or "")
s = re.sub(r'^    static let apiKey = .*$',
           '    static let apiKey = ' + lit(os.environ.get("MODEL_KEY")), s, flags=re.M)
s = re.sub(r'^    static let searchKey = .*$',
           '    static let searchKey = ' + lit(os.environ.get("SEARCH_KEY")), s, flags=re.M)
p.write_text(s)
INJECT
  echo "==> Modell-Schluessel eingesetzt (${#BETA_MODEL_KEY} Zeichen)"
  if [ -n "$BETA_SEARCH_KEY" ]; then
    echo "    Such-Schluessel eingesetzt (${#BETA_SEARCH_KEY} Zeichen)"
  else
    echo "    Kein Such-Schluessel — die Websuche bleibt in diesem Build unkonfiguriert."
  fi
else
  echo "==> Kein Beta-Schluessel gefunden — Build ohne Selbsteinrichtung (reines BYOK)."
fi

echo "==> Projekt erzeugen"
xcodegen generate

echo "==> Build-Nummer hochzählen"
BUILD=$(date +%Y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" PerBu/Info.plist 2>/dev/null || true

echo "==> Archivieren"
xcodebuild -project PerBu.xcodeproj -scheme PerBu \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath build/dd \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive

echo "==> Netz pruefen"
curl -s -o /dev/null --max-time 15 https://appstoreconnect.apple.com || {
  echo "    App Store Connect ist nicht erreichbar — spaeter erneut versuchen."
  exit 1
}

echo "==> Exportieren"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

# Ab hier ohne DEVELOPER_DIR-Override: Der Umweg auf das regulaere Xcode gilt nur
# fuer den Build (Apple lehnt Beta-Builds ab). Dessen altool bricht dagegen mit
# "Defaults.properties couldn't be opened" ab, waehrend das der Beta laeuft — also
# bekommt jedes Werkzeug das Xcode, mit dem es funktioniert.
unset DEVELOPER_DIR

echo "==> Vorab pruefen"
xcrun altool --validate-app -f "$EXPORT/PerBu.ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Zu TestFlight hochladen"
xcrun altool --upload-app -f "$EXPORT/PerBu.ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Warte auf Apples Verarbeitung und weise der internen Gruppe zu"
./assign-build.sh "$BUILD" || {
  echo "    (Zuweisung nicht abgeschlossen — in App Store Connect nachsehen)"
}

echo "==> Fertig."
