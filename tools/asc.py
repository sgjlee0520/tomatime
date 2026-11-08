"""Tiny App Store Connect API client: `from asc import api; api("GET", "/v1/apps", limit=5)`."""
import os
import time

import jwt
import requests

_cfg = dict(line.strip().split("=", 1) for line in open(os.path.expanduser("~/.appstoreconnect/asc.env")) if "=" in line)
KEY_ID, ISSUER = _cfg["ASC_KEY_ID"], _cfg["ASC_ISSUER_ID"]
KEY = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")).read()


def api(method, path, json=None, **params):
    token = jwt.encode({"iss": ISSUER, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
                       KEY, algorithm="ES256", headers={"kid": KEY_ID})
    r = requests.request(method, "https://api.appstoreconnect.apple.com" + path, json=json, params=params,
                         headers={"Authorization": f"Bearer {token}"})
    if r.status_code >= 400:
        raise SystemExit(f"{method} {path} -> {r.status_code}\n{r.text}")
    return r.json() if r.text else None
