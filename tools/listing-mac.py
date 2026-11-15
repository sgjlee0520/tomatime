"""Mac 1.2 store text + review notes (answers the 1.0 rejection, 4.3(a)). Usage: python3 tools/listing-mac.py [--push]"""
import sys

from asc import api

MAC_VERSION = "8fde81e1-bdf8-4000-aa2d-888f30c3e2da"
LOC = "a043eb99-8b65-41bc-999f-88b16da6ddfd"      # en-US
REVIEW = "9c717bdc-587e-4c62-92a6-1d18a1710f1f"

PROMO = ("Focus together. Start tomatoes at the same second as your study group, see who's focusing right now, "
         "and keep one timer on your Mac, iPhone and Apple Watch.")

KEYWORDS = "pomodoro,study group,friends,focus,timer,menubar,apple watch,productivity,deep work,habit"

DESC = """Tomatime is a tomato focus timer for studying and working with other people. It lives in your Mac's menu bar, and your iPhone and Apple Watch follow the same timer.

FOCUS TOGETHER: GROUPS
• Make a group for your study partner or your class (up to 6 people) and send the invite code. Join as many groups as you like.
• See every member live: focusing (which tomato, minutes left), on a break, or how many minutes they did today.
• Start a group tomato: every member's Mac shows a 10-second countdown, and everyone who joins starts at the same second.
• Take the 10-minute group break together; the next group tomato starts with another countdown.
• Nothing starts on your Mac unless you click Join, or turn on auto-join for that group.
• The menu bar shows how many friends are focusing right now.

ONE TIMER ON MAC, IPHONE AND APPLE WATCH
Sign in with Apple and start, pause or stop on any device: the others follow. The countdown stays on your iPhone Lock Screen and in the Apple Watch Smart Stack.

TOMATO CALENDAR
Every focused minute lands on a calendar, and your own Macs add up through iCloud. Each group has its own tab with everyone's minutes and this week's ranking.

PICK A TOMATO
• Green 20 · Red 25 · Golden 45 · Diamond 60 minutes, or type your own length
• A focus session never runs past an hour
• When time's up, a pulsing red screen covers every display. Pick a 5 or 10 minute break, a break that starts the next tomato by itself, or 1 more minute.

Also: live countdown in the menu bar, optional Open at Login, a steady break screen with Reduce Motion.

Groups and syncing use Sign in with Apple; you can delete your account in the app. Without signing in, Tomatime works offline and nothing leaves your Mac. No ads, no tracking."""

NOTES = """Regarding the 4.3(a) rejection of 1.0: this is version 1.2, and it is not a plain timer. Its main features are Groups (several people start a tomato at the same second, see each other's live status, take breaks together, and compare minutes in a weekly ranking) and one shared timer across Mac, iPhone and Apple Watch. The iPhone and Apple Watch app is this same app record (6832374095), approved on the App Store as 1.2. All code and artwork are our own (the source is public on GitHub at sgjlee0520/tomatime).

Tomatime is a menu-bar app with no Dock icon. After launch, click the tomato and countdown in the menu bar (top right).

Timer: pick a tomato (Green, 20 min, is the shortest) and click Start. At 0:00 a red screen covers all displays with break choices.

Groups (Groups submenu):
1. Groups > New Group... > Sign in with Apple, type a display name and a group name. You get an invite code; a second Apple ID can enter it under Groups > Join with Code... (up to 6 people).
2. The group shows in the menu with each member's live status. "Start group tomato" shows a 10-second countdown on every member's Mac; people click Join and start together. After it, the group can take a 10-minute group break, then the next round starts with another countdown.
3. Tomato Calendar... shows each day's minutes; each group has a tab with everyone's minutes and this week's ranking.

Sync: sign in with the same Apple ID in Tomatime on iPhone; start, pause or stop on one device and the others follow.

Account deletion: Groups > Delete My Groups Account... deletes the account and its data and revokes Sign in with Apple, all in the app. Groups are free; there are no in-app purchases in this version.

Our server is Google Firebase (Auth + Firestore). It stores the display name, groups, timer status and minutes."""

for name, text, limit in (("promo", PROMO, 170), ("keywords", KEYWORDS, 100), ("description", DESC, 4000), ("notes", NOTES, 4000)):
    print(f"{name}: {len(text)}/{limit}")
    assert len(text) <= limit, name

if "--push" in sys.argv:
    api("PATCH", f"/v1/appStoreVersions/{MAC_VERSION}", {"data": {"type": "appStoreVersions", "id": MAC_VERSION,
        "attributes": {"versionString": "1.2"}}})
    api("PATCH", f"/v1/appStoreVersionLocalizations/{LOC}", {"data": {"type": "appStoreVersionLocalizations", "id": LOC,
        "attributes": {"description": DESC, "keywords": KEYWORDS, "promotionalText": PROMO}}})
    api("PATCH", f"/v1/appStoreReviewDetails/{REVIEW}", {"data": {"type": "appStoreReviewDetails", "id": REVIEW,
        "attributes": {"notes": NOTES}}})
    print("pushed")
