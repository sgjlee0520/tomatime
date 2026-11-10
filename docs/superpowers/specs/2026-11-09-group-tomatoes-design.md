# Tomatime Groups: design

2026-11-09. A paid feature for the existing Tomatime Mac app (menu-bar tomato focus timer, `main.swift`).
Planned to ship as version 1.2, after 1.1 (custom tomato, 10-minute break, iCloud self-sync) is out.

Marking: **(user)** = the owner decided it. **(played back)** = I proposed it, described it back, and
the owner didn't object. **(my call)** = my default; the owner hasn't weighed in.

## Why

The owner studies with a partner and with study groups and wants to focus *together*: see who is
focusing right now, start tomatoes at the same second, take breaks together, and compare minutes.
Today Tomatime only syncs one person's own Macs (iCloud key-value store), which can't reach another
person's Apple ID.

## Goals

1. **Groups of 2–6 people; a person can be in any number of groups** (user). Example: "Us" (a couple)
   and "Physics 115" (a study group of 4).
2. **Live status of every member** (user): focusing (tier, minutes left), on a break (minutes left), or
   idle (today's tomato minutes). Solo tomatoes show too, not just group ones (played back).
3. **Start together** with a 10-second full-screen countdown on every member's Mac (user).
4. **Break together**: a group break is 10 minutes, then another countdown, then the next group
   tomato (user).
5. **Group calendar and weekly ranking** (user) in the Tomato Calendar window.
6. **Paid, one-time** (user): Group Pass $2.99, Personal Pass $0.99.

## Non-goals (v1)

- A Windows or web version. It comes later, so **group sync must not depend on anything Apple-only**
  (user: "small online service seems fine"; Firebase is my call).
- Chat, messages, reactions, scheduled group tomatoes ("group tomato at 8 PM") (my call).
- Passwords or email sign-up. The only sign-in is one-click **Sign in with Apple** (user), so all of one
  person's Macs are one member.
- Subscriptions (user: one-time). iPhone app. Free trial (my call).

## Anti-goals: failure even if it works

- **Nothing starts on your Mac unless you chose it**: you click Join, or you turned on auto-join for that
  group (user).
- **The countdown must not hide your work**: the workspace stays visible (user).
- **Solo Tomatime must not get worse**: everything that works today works with no purchase, no network
  and no group. Free users see a "Groups" menu item and nothing pushy (my call).
- No server bills that grow faster than one-time revenue (writes only on state changes, see Backend).

## The experience

### Creating and joining (played back)

- Menu → **Groups ▸ New Group…** → type a group name → get an **invite code** (e.g. `TOMA-4K7Q`) to text
  to people. Also **Join with Code…** in the same submenu.
- First time in any group: **Sign in with Apple** (one click, no password) and type a **display name**
  once (shown to the others; changeable later).
- **One person = one Apple ID, across all their Macs** (user). The owner's Mac mini and MacBook are
  one member: one seat, one status, one set of minutes. Each Mac publishes its own minutes under the
  member, and the group sums them, so nothing counts twice (my call; the iCloud self-sync tally must
  not be re-published).
- Invites and countdowns appear on every awake Mac of yours; joining on one closes the countdown on
  the others. With auto-join, only the Mac you're using starts the tomato (my call; the builder
  picks how "using" is detected, e.g. recent keyboard/mouse input).

### Who can create and join (user + my call)

- **Group Pass, $2.99, one-time, forever** (user): create any number of groups; each holds up to 6
  people, and members join that group free.
- **Personal Pass, $0.99, one-time, forever** (user): join any number of groups.
- A group works if **its creator has a Group Pass, or every member has a Personal Pass** (my call).
  So a Personal Pass holder may create a group, but everyone in it then needs a pass.
- Joining a group you can't enter shows why and offers the 99¢ pass (my call).
- A Group Pass also counts as a Personal Pass for joining other groups (my call).
- A group unlocked by its creator's Group Pass **stays unlocked** for good, even if the creator leaves
  or is refunded: the unlock is stamped when the group is made (my call: simpler and kinder).
- Standard **Restore Purchases** item (App Store requirement).
- **Until the Paid Apps agreement is active, groups are free for everyone** (user, 2026-11-10). Groups
  created then stay unlocked for good (the stamped-unlock rule above); the passes ship in a later version.

### Owner (my call)

- The creator is the group's owner: can **remove a member** and **make a new invite code** (the old
  code stops working). This guards against a leaked code letting strangers fill the 6 seats.
- If the owner leaves, the longest-standing member becomes the owner.

### Menu (user picked layout B: one line per group)

```
🍅 45 tomato minutes today
Tomato Calendar…
─────────────
👥 Us              1 focusing ▸
👥 Physics 115     2 focusing ▸     →  🍅 Mina   Golden · 31 min
Groups ▸                               🍅 Alex   Golden · 31 min
─────────────                          ☕ Jun    break · 4 min
Pause / Reset / tiers / Custom …       ─────────
                                       Start group tomato
                                       Auto-join          ✓
                                       Copy invite code
```

- **Groups ▸**: New Group…, Join with Code…, Restore Purchases, and per group: rename, leave (my call).
- The menu-bar item shows a small **number of friends focusing right now** next to the timer
  (played back). Counts each person once even if they share several groups with you (my call).
  **Groups ▸ Show Friends Focusing in Menu Bar** turns the number off, for when you want to focus on
  yourself (user, 2026-11-10); on by default, per Mac.

### Starting a group tomato (user, screens approved in mockups)

1. In a group's submenu, **Start group tomato**. The length is the starter's current tier or custom
   length (my call), never over 60 minutes (existing rule).
2. Every member's Mac shows the **countdown** for 10 seconds, on every screen (my call: like the break
   overlay):
   - Workspace stays visible under a **light dark tint** (about 18% black) (user).
   - A **giant white number**, about 70% of the screen height, that **fades out while growing** each
     second (user picked style "B"). Reduce Motion: fade only, no growth (my call).
   - A **dark bar at the bottom** (user): "Songgun started a 🍅 Red tomato · 25 min", **Join ⏎**,
     **Skip**, and who has joined so far ("Mina ✓ Alex ✓ Jun …").
3. **Invite mode** (default): your tomato starts at 0 only if you clicked Join or pressed Return. Do
   nothing and the screen disappears at 0; you stay solo (user).
4. **Auto-join** (a switch per group, off by default): no Join button; the bar says "Auto-join is on",
   with **Skip this one (esc)**. At 0 your tomato starts (user).
5. The starter sees the same countdown with **Cancel** instead of Join (played back).
6. At 0, everyone who joined starts at the same second and ends at the same second (user).
   Implementation note: the session stores an absolute start time; every Mac counts down to it, so a
   late-arriving invite shows only the seconds left (played back).
7. Already in a solo tomato when an invite arrives: the invite still shows; joining ends the solo
   tomato, and the minutes already done still count (played back).
8. Asleep or arrived after 0: the group's submenu shows **"Group tomato in progress — Join (18 min
   left)"**, which joins for the remaining time (played back).

### Pausing or leaving during a group tomato

- **Pause takes only you out** (user): you become a paused solo tomato with the time left; everyone
  else keeps going. Nobody can pause or stop the tomato for the whole group.
- Reset, picking a tier, or Custom tomato during a group tomato also take you out (my call).
- Leaving early: the minutes you focused still count.

### Group break (user)

- When a group tomato ends, everyone in it gets the existing red screen. Its default button (Return)
  becomes **"10 min break, then next group tomato"** (user: 10, not 5).
- Everyone who picks it gets a 10-minute break, then the 10-second countdown again, then the next
  group tomato together, same length (played back).
- The other buttons work as today and take you out of the group rhythm, back to solo (my call).
- The rhythm continues until nobody picks the group button (my call).

### Also in 1.2, solo and group (user, 2026-11-10)

- The red screen gets **End session** (Esc): no break, back to a fresh tomato, not started.
- **The last 60 seconds of a break that starts the next tomato** count down on screen: each number fades
  out while growing (like the group countdown); the first ones are small in the top-right corner, and each
  second they get bigger and closer to the middle, up to the group countdown's size. No tint, clicks pass
  through (my call). In a group break the group's own 10-second countdown takes over at 10 (my call).
  Plain breaks (no next tomato) have none (my call: nothing starts after them).
  The owner approved the look; **open to change after customer feedback**: 30 seconds instead of 60, or
  the whole break counting down on screen (`restCountdownSeconds` in Groups/Countdown.swift).

### Tomato Calendar (user)

- A switch at the top: **Me | Us | Physics 115** (one tab per group).
- A group tab colors each day by **everyone's tomato minutes added up**, same legend as today, plus a
  month total.
- Below: **This week, ranked**: 🥇 Mina 9h 40m, 🥈 You 8h 15m, … The owner wants the ranking in every
  group, couples included (user). Week starts per the Mac's calendar settings (my call).
- A member's minutes count in a group from the day they joined, not their history before (my call:
  privacy).
- Group minutes are ordinary focus minutes: they also count in your own "Me" tally and iCloud
  self-sync, as today (my call).

## Backend (my call, user accepted "a small online service")

- **Firebase** (Firestore + Firebase Auth with Sign in with Apple). Reasons: realtime listeners deliver the "start together"
  signal in about a second (iCloud push can arrive after a 10-second countdown is over), and Firebase
  works on Windows and the web for later.
- **What's stored**: group name, invite code, member display names, each member's current status
  (state, tier, end time), and each member's daily minutes from the day they joined. Nothing else.
  Sign in with Apple's email is not needed; request no email scope (or the private relay) (my call).
- Sign in with Apple needs its capability on the App ID and in the store profile, and the
  `com.apple.developer.applesignin` entitlement (store builds only, like the iCloud one).
- **Writes only on state changes** (start, pause, break, end, join), plus one daily-minutes update per
  session end. Other Macs compute the countdown locally from the stored end time. Small groups then cost
  about a few cents per group per year.
- **Security rules**: only members can read a group; a member writes only their own status and
  minutes; the 6-person cap is enforced in the rules, not just the app.
- Clock differences between Macs: use server time for the session start, not each Mac's clock.
- **No heartbeats / no "offline" state** (my call): status is only what was last written. A "focusing"
  status whose end time passed with no update shows as idle. Keeps writes per state change only.
- **Plan**: start on the free Spark plan; move to Blaze with a budget alert if usage nears the free
  caps (my call). The owner creates the Firebase project with their own Google account (an owner step
  at build time).

## Constraints

- macOS 14+, sandboxed Mac App Store app. Today it has **no network entitlement**; groups need
  `com.apple.security.network.client`.
- Purchases must be **App Store in-app purchases** (StoreKit 2, non-consumable). Checking a pass on the
  Mac and writing "has pass" into the group is acceptable for a 99¢ product (my call).
- **Privacy**: App Store "Data Not Collected" becomes a label listing name and usage data
  (focus minutes) linked to the user (via Sign in with Apple). The public privacy page needs the same update (user
  accepted the label change).
- Existing rules stay: focus never over 60 minutes; wall-clock timers; the red-screen layout from 1.1
  (two button rows).
- The code is in a **public MIT GitHub repo** (sgjlee0520/tomatime). Firebase client config being
  public is normal; security rules carry the protection.

## Left to the builder

Invite code format and length; data model and collection layout; the Firebase SDK route (Swift
Package vs. REST); how the countdown window takes keyboard focus (the break overlay's non-activating
panel is the model); rename and leave flows; file layout (today the whole app is one `main.swift`).

**Starting point** (my call): commit the 1.1 work (custom tomato, 10-minute break, iCloud self-sync,
build 5) on `main` first; build 1.2 on a branch from it, merging any 1.1 review fixes in.
