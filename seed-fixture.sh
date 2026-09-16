#!/bin/bash
# Writes a fixed conversation into the simulator's app container so the UI tests
# have something to look at. Kept out of the app itself: a test seam in production
# code is a demo conversation waiting to ship to somebody.
set -euo pipefail
DEV="${1:?Geraete-UDID fehlt}"
CONT=$(xcrun simctl get_app_container "$DEV" dev.eigenhand.perbu data)
DIR="$CONT/Library/Application Support/PerBu"
mkdir -p "$DIR"
python3 - "$DIR" <<'PY'
import json, sys, uuid, pathlib
d = pathlib.Path(sys.argv[1])
T  = lambda s: {"text": {"_0": s}}
TU = lambda i, n, inp: {"toolUse": {"id": i, "name": n, "input": inp}}
TH = lambda s: {"thinking": {"_0": s}}
TR = lambda i, c, e: {"toolResult": {"toolUseID": i, "content": c, "isError": e}}
now = "2026-09-09T11:%02d:00Z"
ids = [f"call_{n}" for n in range(4)]
msgs = [
 {"id": str(uuid.uuid4()), "role": "user", "createdAt": now % 0, "tokens": 18,
  "blocks": [T("Was ist der aktuelle Stand bei Swift 6 Strict Concurrency?")]},
 {"id": str(uuid.uuid4()), "role": "assistant", "createdAt": now % 1, "tokens": 210,
  "blocks": [TH("Die Frage zielt auf den heutigen Stand, nicht auf die Ankuendigung. "
                "Ich suche parallel nach dem Leitfaden und nach Erfahrungsberichten."),
             TU(ids[0], "web_search", {"query": "Swift 6 strict concurrency Stand 2026"}),
             TU(ids[1], "web_search", {"query": "Swift 6 Sendable Migration Erfahrungen"}),
             TU(ids[2], "web_search", {"query": "SwiftUI Swift 6 language mode Probleme"}),
             TU(ids[3], "fetch_page", {"url": "https://www.swift.org/documentation/concurrency/"})]},
 {"id": str(uuid.uuid4()), "role": "user", "createdAt": now % 2, "tokens": 900,
  "blocks": [TR(ids[0], "[1] Swift 6 Migrationsleitfaden — swift.org\nhttps://www.swift.org/migration/\nDer Sprachmodus 6 aktiviert vollstaendige Datenrennsicherheit.\n\n"
                        "[2] Strict Concurrency in der Praxis — donnywals.com\nhttps://www.donnywals.com/swift-concurrency/\nErfahrungsbericht einer groesseren Umstellung.", False),
             TR(ids[1], "[1] Sendable und was es kostet — swiftbysundell.com\nhttps://www.swiftbysundell.com/articles/sendable/\nWann eine Annotation noetig ist.\n\n"
                        "[2] Datenrennen finden — hackingwithswift.com\nhttps://www.hackingwithswift.com/concurrency/\nUeberblick ueber die Diagnosen.", False),
             TR(ids[2], "HTTP 429", True),
             TR(ids[3], "Der Migrationsleitfaden beschreibt zwei Stufen.", False)]},
 {"id": str(uuid.uuid4()), "role": "assistant", "createdAt": now % 3, "tokens": 340,
  "producedBy": "z-ai/glm-5.3-flash",
  "blocks": [TH("Zwei Quellen reichen. Die dritte Suche lief in ein Ratenlimit, das "
                "erwaehne ich, damit klar ist, worauf die Antwort steht."),
             T("Kurz: Der **Sprachmodus 6** ist stabil, die Umstellung bleibt aber Arbeit.\n\n"
               "```swift\nfunc harvest(_ json: JSONValue) -> [SearchResult] {\n"
               "    additionalResultPaths.flatMap { collect(at: $0, in: json) }\n}\n```\n\n"
               "Eine der drei Suchen lief in ein Ratenlimit.")]},
 # Second turn, deliberately after the first: a user message with text begins a new
 # turn, and placed in the middle it cuts the first answer off from its tool results
 # — sources included. The long question exercises the expanding.
 {"id": str(uuid.uuid4()), "role": "user", "createdAt": now % 4, "tokens": 120,
  "blocks": [T("Kannst du mir das **kurz einordnen**? Hier ist, was ich gefunden habe:\n"
               "- **Sprachmodus 6**: seit einem Jahr stabil, die Umstellung bleibt Arbeit.\n"
               "- *Sendable*: die Annotation kostet mehr, als die Einfuehrungen zugeben.\n"
               "- `@MainActor`: verschiebt das Problem, loest es aber nicht immer.\n"
               "Und was heisst Datenrennsicherheit in dem Zusammenhang eigentlich genau?")]},
 {"id": str(uuid.uuid4()), "role": "assistant", "createdAt": now % 5, "tokens": 60,
  "blocks": [T("**Datenrennsicherheit** heisst: der Compiler beweist, dass zwei "
               "Aufgaben nicht gleichzeitig auf denselben Zustand schreiben.")]},
]
import datetime
# Stamped to now, so that launching restores the conversation instead of opening a
# new chat — otherwise the test result hangs on the time of day the run happens.
fresh = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
conv = {"id": str(uuid.uuid4()), "title": "Swift 6 Strict Concurrency", "messages": msgs,
        "createdAt": now % 0, "updatedAt": fresh, "lastReportedInputTokens": 28400,
        "compactionCount": 0, "titledAtMessageCount": 2}
(d / "conversations.json").write_text(json.dumps([conv], indent=2))
llm = str(uuid.uuid4())
(d / "settings.json").write_text(json.dumps({
    "llms": [{"id": llm, "name": "TensorX", "wireFormat": "openai",
              "baseURL": "https://api.tensorx.ai", "path": "/v1/chat/completions",
              "model": "z-ai/glm-5.3-flash", "contextWindow": 128000,
              "maxOutputTokens": 8192, "supportsVision": True, "keychainAccount": "seed"}],
    "activeLLMID": llm, "recipes": [], "searchEnabled": True, "showThinking": True},
    indent=2))
PY
echo "Test data in $DIR"
