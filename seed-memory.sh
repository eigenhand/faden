#!/bin/bash
# Creates a memory store with deliberately mixed provenance: vectors from the
# configured model, from a different model, and some with no stamp at all from
# before the marking existed. That lets the test check the classification against
# the one case that matters day to day — somebody changes the embedding model.
set -euo pipefail
DEV="${1:?Geraete-UDID fehlt}"
CONT=$(xcrun simctl get_app_container "$DEV" dev.eigenhand.perbu data)
DIR="$CONT/Library/Application Support/PerBu"
mkdir -p "$DIR"
python3 - "$DIR" <<'PY'
import json, sys, uuid, pathlib, datetime
d = pathlib.Path(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
QWEN = "qwen/qwen3-embedding-8b"

def node(name, stamp, vec=True, dim=8):
    n = {"id": str(uuid.uuid4()), "name": name, "type": "Sache",
         "nodeDescription": f"Beschreibung zu {name}", "createdAt": now,
         "updatedAt": now, "version": 1, "mentions": 1}
    if vec:
        n["embedding"] = [round(0.1 * (i + 1), 3) for i in range(dim)]
        if stamp:
            n["embeddingStamp"] = {"model": stamp, "dimension": dim}
    return n

nodes = ([node(f"Ding {i}", QWEN) for i in range(6)]
       + [node(f"Alt {i}", "text-embedding-3-small") for i in range(3)]
       + [node(f"Namenlos {i}", None) for i in range(2)]
       + [node(f"Neu {i}", None, vec=False) for i in range(2)])
edges = [{"id": str(uuid.uuid4()), "sourceID": nodes[0]["id"], "targetID": nodes[1]["id"],
          "relationship": "haengt_zusammen_mit", "edgeDescription": "Ding 0 hängt mit Ding 1 zusammen.",
          "createdAt": now, "mentions": 1, "weight": 1.0,
          "embedding": [0.1] * 8, "embeddingStamp": {"model": QWEN, "dimension": 8}}]
(d / "memory.json").write_text(json.dumps({"nodes": nodes, "edges": edges}, indent=2))

# Attach the memory block to the existing settings rather than replacing them —
# the other script's model fixture has to stay where it is.
sp = d / "settings.json"
settings = json.loads(sp.read_text()) if sp.exists() else {}
settings["memory"] = {"enabled": True, "embeddingBaseURL": "https://api.tensorx.ai",
                      "embeddingPath": "/v1/embeddings", "embeddingModel": QWEN,
                      "embeddingKeychainAccount": "perbu.embedding.key", "automatic": True,
                      "topK": 6, "wideSearchTopK": 40, "neighborhoodDepth": 1,
                      "distancePenalty": 6.5, "minimumSimilarity": 0.25}
sp.write_text(json.dumps(settings, indent=2))
print("erwartet: 7 nutzbar, 5 fremd, 2 offen")
PY
