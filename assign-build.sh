#!/bin/bash
# Wartet, bis App Store Connect einen Build verarbeitet hat, und legt ihn dann in
# die interne Tester-Gruppe. Ohne diesen Schritt liegt ein Build zwar hochgeladen,
# aber sichtbar ist er fuer niemanden.
#
# Aufruf:  ./assign-build.sh <CFBundleVersion>
set -euo pipefail
cd "$(dirname "$0")"
[ -f .release.env ] && . ./.release.env
: "${ASC_ISSUER_ID:?Issuer ID fehlt (.release.env)}"

APP_ID="6810163455"
WANTED="${1:?Build-Nummer angeben}"

token() { ./asc-token.sh; }

echo "    warte auf Verarbeitung von $WANTED …"
BUILD_ID=""
for i in $(seq 1 60); do
  T=$(token)
  read -r STATE ID <<<"$(curl -s -H "Authorization: Bearer $T" \
    "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$APP_ID&limit=5&sort=-uploadedDate" \
    | python3 -c "
import json,sys
for b in json.load(sys.stdin).get('data',[]):
    if b['attributes'].get('version')=='$WANTED':
        print(b['attributes'].get('processingState'), b['id']); break
else: print('PENDING none')
")"
  case "$STATE" in
    VALID)   BUILD_ID="$ID"; echo "    verarbeitet nach ~$((i*30))s"; break ;;
    INVALID) echo "    Apple hat den Build abgelehnt."; exit 1 ;;
  esac
  sleep 30
done
[ -n "$BUILD_ID" ] || { echo "    Zeitüberschreitung beim Warten."; exit 1; }

T=$(token)
GROUP=$(curl -s -H "Authorization: Bearer $T" \
  "https://api.appstoreconnect.apple.com/v1/betaGroups?filter%5Bapp%5D=$APP_ID&limit=10" \
  | python3 -c "
import json,sys
for g in json.load(sys.stdin).get('data',[]):
    if g['attributes'].get('isInternalGroup'): print(g['id']); break
")
[ -n "$GROUP" ] || { echo "    Keine interne Gruppe gefunden."; exit 1; }

CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  "https://api.appstoreconnect.apple.com/v1/betaGroups/$GROUP/relationships/builds" \
  -d "{\"data\":[{\"type\":\"builds\",\"id\":\"$BUILD_ID\"}]}")
[ "$CODE" = "204" ] || { echo "    Zuweisung fehlgeschlagen (HTTP $CODE)"; exit 1; }

sleep 2
T=$(token)
curl -s -H "Authorization: Bearer $T" \
  "https://api.appstoreconnect.apple.com/v1/builds/$BUILD_ID/buildBetaDetail" \
  | python3 -c "
import json,sys
a=json.load(sys.stdin).get('data',{}).get('attributes',{})
print('    Build $WANTED ist', a.get('internalBuildState'))
"
