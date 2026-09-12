#!/bin/bash
# Legt ein Gespräch an, dessen Historie ein verwaistes Werkzeugpaar enthält: das
# Modell hat zwei Suchen angefordert, eine Antwort mit Quellen geschrieben, und dann
# steht ein Aufruf ohne Ergebnis da — der Zustand, in dem ein Abbruch die Historie
# hinterließ. Beide Formate verlangen die Paarung; ohne sie lehnt der Anbieter *jede*
# weitere Anfrage in diesem Gespräch ab, weil die ganze Historie jedes Mal mitgeht.
#
# Zum Nachstellen von Hand, nicht fuer einen automatischen Test: direkt gegen den
# Anbieter geprueft nimmt TensorX genau diese Historie mit HTTP 200 an, erzwingt die
# Paarung also nicht. Anthropic tut es. Das Skript ist der schnelle Weg, dieselbe
# Lage auf einem Geraet herzustellen, wenn ein Endpoint sich anders verhaelt.
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
 # Erste Runde: Aufruf und Ergebnis paaren — das ist in Ordnung.
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
             TU("call_verwaist", "web_search", {"query": "Nightjet Preise Liegewagen"})]},
]
conv = {"id": str(uuid.uuid4()), "title": "Nachtzug nach Wien", "messages": msgs,
        "createdAt": stamp(9),
        "updatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lastReportedInputTokens": 3200, "compactionCount": 0, "titledAtMessageCount": 2}
(d / "conversations.json").write_text(json.dumps([conv], indent=2))
print("Gespräch mit verwaistem Werkzeugaufruf angelegt (call_verwaist)")
PY
