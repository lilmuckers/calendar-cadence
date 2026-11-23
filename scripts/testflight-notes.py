#!/usr/bin/env python3
"""Set TestFlight's "What to Test" for an uploaded iPhone build, through the App Store Connect API.

Usage: scripts/testflight-notes.py <bundle-id> <version> <build-number> <notes-file>

Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the AuthKey_<id>.p8) in the environment, and openssl.
The build shows up in the API a few minutes after the upload; this waits for it (up to WAIT_MINUTES,
default 30). The notes are the iPhone section of the release's changelog (scripts/changelog.py
--only ios --format text), cut to App Store Connect's 4000-character limit.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
LOCALE = "en-US"
LIMIT = 4000


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der, size=32):
    """openssl writes ECDSA signatures as DER; JWT's ES256 wants r || s."""
    def read_int(buf, i):
        assert buf[i] == 0x02, "bad DER signature"
        n = buf[i + 1]
        value = buf[i + 2:i + 2 + n].lstrip(b"\0")
        return value.rjust(size, b"\0"), i + 2 + n
    assert der[0] == 0x30, "bad DER signature"
    i = 3 if der[1] & 0x80 else 2
    r, i = read_int(der, i)
    s, _ = read_int(der, i)
    return r + s


def token():
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(claims).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64(der_to_raw(der))}"


def call(method, path, body=None, query=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            return json.loads(res.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: {e.code} {e.read().decode(errors='replace')[:500]}")


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    bundle_id, version, build_number, notes_file = sys.argv[1:]
    notes = open(notes_file).read().strip()
    if not notes:
        notes = "Behind-the-scenes changes only."
    if len(notes) > LIMIT:
        notes = notes[:LIMIT - 1].rsplit("\n", 1)[0] + "\n…"

    apps = call("GET", "/apps", query={"filter[bundleId]": bundle_id})["data"]
    if not apps:
        raise SystemExit(f"No app with bundle ID {bundle_id} in App Store Connect")
    app = apps[0]["id"]

    deadline = time.time() + int(os.environ.get("WAIT_MINUTES", "30")) * 60
    while True:
        builds = call("GET", "/builds", query={"filter[app]": app, "filter[version]": build_number,
                                               "filter[preReleaseVersion.version]": version})["data"]
        if builds:
            build = builds[0]["id"]
            break
        if time.time() > deadline:
            raise SystemExit(f"Build {version} ({build_number}) didn't show up in App Store Connect in time")
        print(f"Waiting for build {version} ({build_number}) to show up…", flush=True)
        time.sleep(30)

    existing = [l for l in call("GET", f"/builds/{build}/betaBuildLocalizations")["data"]
                if l["attributes"].get("locale") == LOCALE]
    if existing:
        call("PATCH", f"/betaBuildLocalizations/{existing[0]['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": existing[0]["id"], "attributes": {"whatsNew": notes}}})
    else:
        call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations", "attributes": {"locale": LOCALE, "whatsNew": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
    print(f"TestFlight notes set for {version} ({build_number}):\n{notes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
