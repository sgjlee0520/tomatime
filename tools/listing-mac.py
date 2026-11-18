"""Mac 1.2.3 store text + review notes (answers the 1.0 rejection, 4.3(a)). Usage: python3 tools/listing-mac.py [--push]"""
import sys

from asc import api

MAC_VERSION = "8f14a321-c665-47f2-939f-c2773c55af23"
LOC = "12808a24-f8ed-4b0a-8412-55e594fe0d48"      # en-US
REVIEW = "b165c54b-b4d7-4d4e-aa28-e1d4ee1217a1"

PROMO = ("Focus together. Start tomatoes at the same second as your study group, see who's focusing right now, "
         "and keep one timer on your Mac, iPhone and Apple Watch.")

KEYWORDS = "pomodoro,study group,friends,focus,timer,menubar,apple watch,productivity,deep work,habit"

DESC = """Tomatime is a tomato focus timer for studying and working with other people. It lives in your Mac's menu bar, and your iPhone and Apple Watch follow the same timer.

FOCUS TOGETHER: GROUPS
• Make a group for your study partner or your class (up to 6 people) and send the invite code. Join as many groups as you like.
• See every member live: focusing (which tomato, minutes left), on a break, or how many minutes they did today.
• Start a group tomato of any length: every member's Mac shows a 10-second countdown, and everyone who joins starts at the same second.
• Take the 10-minute group break together; the next group tomato starts with another countdown.
• Want a longer one? Anyone in a group tomato can change its length for everyone, or pick a different tomato for the next round.
• Nothing starts on your Mac unless you click Join, or turn on auto-join for that group.
• The menu bar shows how many friends are focusing right now.

ONE TIMER ON MAC, IPHONE AND APPLE WATCH
Sign in with Apple and start, pause or stop on any device: the others follow. The countdown stays on your iPhone Lock Screen and in the Apple Watch Smart Stack.

EXAM MODE
Tomatoes and breaks back to back, alone or with your group: 25, 60, 45 and 45 minutes of focus with 8, 10 and 20 minute breaks in between, then a walk. Breaks start by themselves. Or type your own plan.

TOMATO CALENDAR
Every focused minute lands on a calendar, and your own Macs add up through iCloud. Each group has its own tab with everyone's minutes and this week's ranking. Click a day to see each person's time.

PICK A TOMATO
• Green 20 · Red 25 · Golden 45 · Diamond 60 minutes, or type your own length, up to 8 hours
• When time's up, a pulsing red screen covers every display. Pick a 5 or 10 minute break, a break that starts the next tomato by itself, or 1 more minute.

Also: live countdown in the menu bar, optional Open at Login, a steady break screen with Reduce Motion.

Groups and syncing use Sign in with Apple; you can delete your account in the app. Without signing in, Tomatime works offline and nothing leaves your Mac. No ads, no tracking."""

NOTES = """Regarding the 4.3(a) rejection of 1.0: this is version 1.2.3, and it is not a plain timer. Its main features are Groups (several people start a tomato at the same second, see each other's live status, take breaks together, and compare minutes in a weekly ranking) and one shared timer across Mac, iPhone and Apple Watch. The iPhone and Apple Watch app is this same app record (6832374095), approved on the App Store as 1.2. All code and artwork are our own (the source is public on GitHub at sgjlee0520/tomatime).

Tomatime is a menu-bar app with no Dock icon. After launch, click the tomato and countdown in the menu bar (top right).

Timer: pick a tomato (Green, 20 min, is the shortest) and click Start. At 0:00 a red screen covers all displays with break choices.

Groups (Groups submenu):
1. Groups > New Group... > Sign in with Apple, type a display name and a group name. You get an invite code; a second Apple ID can enter it under Groups > Join with Code... (up to 6 people).
2. The group shows in the menu with each member's live status. "Start group tomato" > pick a tomato: a 10-second countdown shows on every member's Mac; people click Join and start together. After it, the group can take a 10-minute group break, then the next round starts with another countdown.
3. While a group tomato runs, its line in the group's menu can change its length for everyone in it. The red screen after it offers the group break, with the same tomato next or another one.
4. Exam mode (in the menu, and under "Start group tomato") runs a plan of tomatoes and breaks back to back; "Exam mode > Change the Plan..." edits it.
5. Tomato Calendar... shows each day's minutes; each group has a tab with everyone's minutes and this week's ranking.

Sync: sign in with the same Apple ID in Tomatime on iPhone; start, pause or stop on one device and the others follow.

Account deletion: Groups > Delete My Groups Account... deletes the account and its data and revokes Sign in with Apple, all in the app. Groups are free; there are no in-app purchases in this version.

Our server is Google Firebase (Auth + Firestore). It stores the display name, groups, timer status and minutes."""

for name, text, limit in (("promo", PROMO, 170), ("keywords", KEYWORDS, 100), ("description", DESC, 4000), ("notes", NOTES, 4000)):
    print(f"{name}: {len(text)}/{limit}")
    assert len(text) <= limit, name

if "--push" in sys.argv:
    api("PATCH", f"/v1/appStoreVersions/{MAC_VERSION}", {"data": {"type": "appStoreVersions", "id": MAC_VERSION,
        "attributes": {"versionString": "1.2.3"}}})
    api("PATCH", f"/v1/appStoreVersionLocalizations/{LOC}", {"data": {"type": "appStoreVersionLocalizations", "id": LOC,
        "attributes": {"description": DESC, "keywords": KEYWORDS, "promotionalText": PROMO}}})
    api("PATCH", f"/v1/appStoreReviewDetails/{REVIEW}", {"data": {"type": "appStoreReviewDetails", "id": REVIEW,
        "attributes": {"notes": NOTES}}})
    print("pushed")
