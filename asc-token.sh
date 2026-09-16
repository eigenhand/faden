#!/bin/bash
# Relative to its own location and not to a path on one particular machine: the
# script gets called from assign-build.sh and release.sh, and a
# geklontes Repo liegt woanders.
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./.release.env
KEY_ID="${ASC_KEY_ID:?ASC_KEY_ID fehlt — in .release.env eintragen}"
python3 - "$KEY_ID" "$ASC_ISSUER_ID" <<'PY'
import base64, json, subprocess, sys, time, os
key_id, issuer = sys.argv[1], sys.argv[2]
p8 = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
h = b64u(json.dumps({"alg":"ES256","kid":key_id,"typ":"JWT"},separators=(",",":")).encode())
p = b64u(json.dumps({"iss":issuer,"exp":int(time.time())+1200,"aud":"appstoreconnect-v1"},separators=(",",":")).encode())
si = h + b"." + p
der = subprocess.run(["openssl","dgst","-sha256","-sign",p8], input=si, capture_output=True).stdout
def unwrap(d):
    i = 2 if d[1] < 0x80 else 2 + (d[1] & 0x7F)
    out = []
    for _ in range(2):
        ln = d[i+1]; out.append(d[i+2:i+2+ln].lstrip(b"\x00").rjust(32, b"\x00")); i += 2 + ln
    return out[0] + out[1]
print((si + b"." + b64u(unwrap(der))).decode())
PY
