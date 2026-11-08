"""Crop full-screen captures to 16:10 (2880x1800) and replace the Mac screenshots on the 1.0 listing.
Usage: python3 tools/screenshots.py shot1.png shot2.png ...   (order = order on the store page)"""
import hashlib
import os
import subprocess
import sys
import tempfile

import requests

from asc import api

VER_LOC = "a043eb99-8b65-41bc-999f-88b16da6ddfd"  # 1.0 en-US


def crop(src, dst):
    w, h = (int(subprocess.check_output(["sips", "-g", k, src]).split()[-1]) for k in ("pixelWidth", "pixelHeight"))
    cw, ch = min(w, h * 16 // 10), min(h, w * 10 // 16)  # largest centred 16:10 box
    subprocess.run(["sips", "-c", str(ch), str(cw), src, "--out", dst], check=True, capture_output=True)
    # Largest Mac App Store size we can reach without upscaling (2880x1800, else 1440x900).
    tw, th = (2880, 1800) if cw >= 2880 else (1440, 900)
    subprocess.run(["sips", "-z", str(th), str(tw), dst], check=True, capture_output=True)


sets = api("GET", f"/v1/appStoreVersionLocalizations/{VER_LOC}/appScreenshotSets")["data"]
desk = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None)
if desk is None:
    desk = api("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
        "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": VER_LOC}}}}})["data"]
for old in api("GET", f"/v1/appScreenshotSets/{desk['id']}/appScreenshots")["data"]:
    api("DELETE", f"/v1/appScreenshots/{old['id']}")

out = tempfile.mkdtemp()
for i, src in enumerate(sys.argv[1:], 1):
    path = os.path.join(out, f"tomatime-{i}.png")
    crop(src, path)
    data = open(path, "rb").read()
    shot = api("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
        "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": desk["id"]}}}}})["data"]
    for op in shot["attributes"]["uploadOperations"]:
        part = data[op["offset"]:op["offset"] + op["length"]]
        requests.request(op["method"], op["url"], data=part,
                         headers={h["name"]: h["value"] for h in op["requestHeaders"]}).raise_for_status()
    api("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print("uploaded", path)
