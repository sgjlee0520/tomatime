"""iPhone + Apple Watch App Store listing (version 1.2): text, review notes and screenshots from
store/screenshots-ios (tools/screenshots.sh). Usage: python3 tools/listing-ios.py"""
import glob
import hashlib
import os

import requests

from asc import api

VERSION = "13ea182e-b383-4d6b-96e2-4585bcace42d"   # iOS 1.2
LOC = "c0ae36a9-14fa-40b7-b5d7-12afa85becce"       # its en-US
SHOTS = os.path.join(os.path.dirname(__file__), "..", "store", "screenshots-ios")

DESCRIPTION = """Tomatime keeps your focus sessions honest, on your iPhone and Apple Watch.

Pick a tomato:
• Green tomato: 20 minutes
• Red tomato: 25 minutes
• Golden tomato: 45 minutes
• Diamond tomato: 60 minutes

Watch it count down as big numbers, or as a red clock that empties as time runs out. The countdown stays on your Lock Screen and in the Apple Watch Smart Stack, and the watch-face complication keeps it in sight even when the screen is dimmed.

When a tomato ends, take a 5, 10 or 15 minute break, or set your own: drag around the clock on iPhone, or turn the Digital Crown on Apple Watch.

On Apple Watch, swipe between the red clock, the buttons and the time. Tap to pause or resume, and feel it on your wrist.

Have Tomatime on your Mac too? Sign in with Apple and your Mac, iPhone and Apple Watch follow one timer: start, pause or stop on any of them and the others follow.

No ads. No tracking. Without signing in, everything stays on your device."""

PROMO = "Pick a tomato, focus, then actually take the break. Your iPhone, Apple Watch and Mac follow one timer."
KEYWORDS = "pomodoro,study,focus,timer,apple watch,productivity,concentration,break,countdown,deep work,habit"

NOTES = """No account is needed. Pick a tomato size (Green 20 min is the shortest) and tap Start. The countdown shows in the app and as a Live Activity on the Lock Screen (and in the Apple Watch Smart Stack). When it ends you get a notification, and the app offers 5 / 10 / 15 minute breaks or Custom (drag around the circle).

The Apple Watch app is included: pick a tomato from the list; while it runs, swipe between the red clock, Pause/Stop and the time. Tapping the clock pauses or resumes.

Sign in with Apple is optional. It syncs this timer with the same person's Tomatime for Mac and Apple Watch through our server (Google Firebase); push notifications update the Lock Screen countdown. Account > Delete Account... (shown when signed in) deletes the account and its data and revokes Sign in with Apple, all inside the app.

The bottom switch picks how the countdown looks: Numbers or Red clock."""

api("PATCH", f"/v1/appStoreVersionLocalizations/{LOC}", {"data": {"type": "appStoreVersionLocalizations", "id": LOC,
    "attributes": {"description": DESCRIPTION, "promotionalText": PROMO, "keywords": KEYWORDS}}})
review = api("GET", f"/v1/appStoreVersions/{VERSION}/appStoreReviewDetail")["data"]
api("PATCH", f"/v1/appStoreReviewDetails/{review['id']}", {"data": {"type": "appStoreReviewDetails", "id": review["id"],
    "attributes": {"notes": NOTES, "demoAccountRequired": False}}})
print("text + review notes set")

def upload(display_type, pattern):
    sets = api("GET", f"/v1/appStoreVersionLocalizations/{LOC}/appScreenshotSets")["data"]
    s = next((x for x in sets if x["attributes"]["screenshotDisplayType"] == display_type), None) or api(
        "POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": LOC}}}}})["data"]
    for old in api("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots")["data"]:
        api("DELETE", f"/v1/appScreenshots/{old['id']}")
    for path in sorted(glob.glob(os.path.join(SHOTS, pattern))):
        data = open(path, "rb").read()
        shot = api("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": s["id"]}}}}})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            requests.request(op["method"], op["url"], data=data[op["offset"]:op["offset"] + op["length"]],
                             headers={h["name"]: h["value"] for h in op["requestHeaders"]}).raise_for_status()
        api("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        print(display_type, "uploaded", os.path.basename(path))

upload("APP_IPHONE_67", "iphone-*.png")
upload("APP_WATCH_ULTRA", "watch-*.png")
