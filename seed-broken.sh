#!/bin/bash
# Creates a conversation whose history holds an orphaned tool pair: the model asked
# for two searches, wrote an answer with sources, and then a call stands there with
# no result — the state an abort used to leave the history in. Both wire formats
# demand the pairing; without it the provider refuses *every* further request in
# this conversation, because the whole history goes along every time.
#
# For reproducing by hand, not for an automatic test: checked directly against the
# provider, TensorX accepts exactly this history with HTTP 200 and therefore does
# not enforce the pairing. Anthropic does. The script is the quick way to set up the
# same situation on a device when an endpoint behaves differently.
set -euo pipefail
DEV="${1:?Geraete-UDID fehlt}"
CONT=$(xcrun simctl get_app_container "$DEV" dev.eigenhand.perbu data)
DIR="$CONT/Library/Application Support/PerBu"
mkdir -p "$DIR"
python3 - "$DIR" <<'PY'
import json, sys, uuid, pathlib, datetime
d = pathlib.Path(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
stamp = lambda m: (now - datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
T  = lambda s: {"text": {"_0": s}}
TU = lambda i, n, inp: {"toolUse": {"id": i, "name": n, "input": inp}}
TR = lambda i, c, e: {"toolResult": {"toolUseID": i, "content": c, "isError": e}}

msgs = [
 {"id": str(uuid.uuid4()), "role": "user", "createdAt": stamp(9), "tokens": 14,
  "blocks": [T("Was ist beim Nachtzug nach Wien zu beachten?")]},
 # First round: call and result paired — that part is fine.
 {"id": str(uuid.uuid4()), "role": "assistant", "createdAt": stamp(8), "tokens": 80,
  "blocks": [T("Ich sehe kurz nach."), TU("call_ok", "web_search", {"query": "Nightjet Wien"})]},
 {"id": str(uuid.uuid4()), "role": "user", "createdAt": stamp(7), "tokens": 300,
  "blocks": [TR("call_ok", "[1] Nightjet — oebb.at\nhttps://www.oebb.at/nightjet\nTaeglich ab Muenchen.", False)]},
 {"id": str(uuid.uuid4()), "role": "assistant", "createdAt": stamp(6), "tokens": 120,
  "producedBy": "z-ai/glm-5.3-flash",
  "blocks": [T("Der **Nightjet** fährt täglich. Reservierung ist Pflicht.")]},
 # Zweite Runde: Aufruf ohne Ergebnis. Genau hier bricht es.
 {"id": str(uuid.uuid4()), "role": "assistant", "createdAt": stamp(5), "tokens": 40,
  "producedBy": "z-ai/glm-5.3-flash",
  "blocks": [T("Ich prüfe noch die Preise."),
             TU("call_orphaned", "web_search", {"query": "Nightjet Preise Liegewagen"})]},
]
conv = {"id": str(uuid.uuid4()), "title": "Nachtzug nach Wien", "messages": msgs,
        "createdAt": stamp(9),
        "updatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lastReportedInputTokens": 3200, "compactionCount": 0, "titledAtMessageCount": 2}
(d / "conversations.json").write_text(json.dumps([conv], indent=2))
print("Created a conversation with an orphaned tool call (call_orphaned)")
PY
