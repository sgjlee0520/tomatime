# Tomatime Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paid group tomatoes: groups of 2–6 see each other live, start together after a 10-second
countdown, break together, and compare minutes; unlocked by a $2.99 Group Pass or a 99¢ Personal Pass.

**Architecture:** Pure, Foundation-only rules in `Groups/GroupRules.swift` (all the decisions, checked by
a plain `swiftc` check program). Firebase (Auth with Sign in with Apple, Firestore realtime listeners) in
`Groups/GroupStore.swift`, guarded by Firestore security rules tested in the local emulator. AppKit UI
(countdown overlay, menu, calendar tab) hooks into the existing `App` class in `main.swift`. StoreKit 2
for the two one-time passes.

**Tech Stack:** Swift 5 / AppKit, macOS 14+, XcodeGen, firebase-ios-sdk (SPM, `from: "13.0.0"`:
FirebaseAuth, FirebaseFirestore), StoreKit 2, AuthenticationServices; Node 26 + `firebase-tools` +
`@firebase/rules-unit-testing` 6 for rules tests; Java (Homebrew `openjdk@21`) for the emulator.

**Spec:** `docs/superpowers/specs/2026-11-09-group-tomatoes-design.md`

## Global Constraints

- Groups have 2–6 people (`maxGroupSize = 6`); a person may be in any number of groups.
- One person = one Apple ID (Firebase uid) across all their Macs.
- Countdown: 10 s (`countdownSeconds = 10`); group break: 10 min (`groupBreakMinutes = 10`).
- Focus never over 60 minutes (existing `maxFocusMinutes`).
- Product IDs: `com.sgjlee.tomatime.grouppass` ($2.99, non-consumable, "Group Pass"),
  `com.sgjlee.tomatime.personalpass` ($0.99, non-consumable, "Personal Pass").
- A group is joinable if it was created by a Group Pass holder (`unlocked`, stamped at creation, never
  revoked) or the joiner has a pass (Group Pass counts as a Personal Pass).
- **Groups are free until the Paid Apps agreement is active** (user, 2026-11-10): `let groupsFree = true` in
  `GroupRules.swift`; everyone counts as a Group Pass holder, so groups are created `unlocked` and no Buy/Restore
  items show. Task 5 is deferred; it flips `groupsFree` to false and wires StoreKit in.
- Nothing starts on a Mac unless its user clicked Join or turned on auto-join for that group.
- Solo Tomatime keeps working with no purchase, no network, no sign-in.
- Store-signed builds only get Apple capabilities (iCloud KVS, Sign in with Apple); ad-hoc builds
  (`tools/run-local.sh`) must still build and run solo.
- Profiles are renamed only together with `tools/release.sh` and `tools/ExportOptions.plist`.
- The repo is public (MIT): no secrets in git. `GoogleService-Info.plist` is client config (fine to
  ship) but stays out of git anyway (`.gitignore`), like `asc.env`.
- Work on branch `groups`, created from `main` after the 1.1 work is committed.

## Review Focus

1. **Invite arrives late** (Mac woke up, slow network): no countdown for a start time already past;
   the group shows "Group tomato in progress — Join (N min left)". Pinned by `sessionPhase` tests (Task 1).
2. **Two of my Macs awake**: both show the countdown; joining on one closes it on the other; auto-join
   starts only on the Mac used in the last 120 s. Pinned by `shouldAutoJoin` tests (Task 1) and the
   own-member-doc listener (Task 7).
3. **Typed invite codes** with lowercase, spaces, or no `TOMA-` prefix still join. Pinned by
   `normalizeCode` tests (Task 1).
4. **7th person / no pass**: clear message ("This group is full." / pass offer), never a silent failure.
   Pinned by `joinVerdict` tests (Task 1) and rules tests (Task 2).
5. **Offline or signed out**: every group action fails with an alert, and the solo timer and local tally
   are untouched. Pinned by the Task 4 smoke run with the emulator stopped, plus the Task 9 checklist.

---

### Task 1: Group rules (pure logic) and the check program

**Files:**
- Create: `Groups/GroupRules.swift`, `Tests/RulesCheck.swift`, `tools/test.sh`
- Modify: `main.swift` (move `dayKey(_:)` into `GroupRules.swift`; delete it from `main.swift`)

**Interfaces — Produces** (all in `Groups/GroupRules.swift`, Foundation only):
```swift
let maxGroupSize = 6, countdownSeconds = 10, groupBreakMinutes = 10.0, activeMacSeconds = 120.0
let groupsFree = true   // until the Paid Apps agreement; Task 5 flips it
func dayKey(_ date: Date = Date()) -> String                       // moved unchanged
enum MemberState: String { case focus, rest = "break", idle }
struct MemberStatus: Equatable { var state: MemberState; var tierName: String; var minutes: Double
                                 var endsAt: Date?; var sessionID: String? }
struct Member { let uid: String; var name: String; var joinedAt: Date; var hasPass: Bool
                var status: MemberStatus; var secondsByDevice: [String: [String: Double]] } // device → dayKey → s
struct TomatoGroup { let id: String; var name: String; var ownerUID: String; var memberUIDs: [String]
                     var unlocked: Bool; var members: [Member] }
struct GroupSession { let id: String; var round: Int; var startedBy: String; var starterName: String
                      var tierName: String; var minutes: Double; var startAt: Date; var cancelled: Bool
                      var joined: [String]; var nextJoined: [String] }
enum JoinVerdict: Equatable { case ok, alreadyMember, full, needsPass }
enum SessionPhase: Equatable { case countdown(Int), running(Double), over }   // secs to start / secs left
func joinVerdict(_ g: TomatoGroup, uid: String, hasPass: Bool) -> JoinVerdict
func effectiveState(_ s: MemberStatus, now: Date) -> MemberState              // focus/break past endsAt → idle
func friendsFocusing(_ groups: [TomatoGroup], me: String, now: Date) -> Int   // unique uids, not me
func statusText(_ m: Member, now: Date) -> String
func memberSeconds(_ m: Member, day: Date) -> Double                           // 0 before joinedAt's day
func groupDayMinutes(_ g: TomatoGroup, days: [Date]) -> [Int]
func weeklyRanking(_ g: TomatoGroup, now: Date, calendar: Calendar) -> [(name: String, minutes: Int)]
func sessionPhase(_ s: GroupSession, now: Date) -> SessionPhase
func nextRoundStart(after end: Date) -> Date                                   // end + 600 s
func shouldAutoJoin(idleSeconds: Double) -> Bool                               // < activeMacSeconds
func makeInviteCode<R: RandomNumberGenerator>(using rng: inout R) -> String    // "TOMA-" + 6 chars
func normalizeCode(_ s: String) -> String?
// Firestore boundary (Dates already converted from Timestamp by GroupStore):
func member(uid: String, data: [String: Any]) -> Member?
func statusData(_ s: MemberStatus) -> [String: Any]
func session(id: String, data: [String: Any]) -> GroupSession?
```

- [ ] **Step 1: Commit 1.1 on `main`, branch off**

```bash
git add -A && git commit -m "1.1: custom tomato, 10-min break then next, iCloud self-sync (build 5)"
git switch -c groups
```

- [ ] **Step 2: Write the failing checks in `Tests/RulesCheck.swift`** (`@main struct RulesCheck`,
  `precondition` per line, prints `rules ok`). Fixed clock `t0 = Date(timeIntervalSince1970: 1_794_000_000)`.
  - `joinVerdict`: unlocked group with 2 members, new uid, no pass → `.ok`; same group locked → `.needsPass`;
    locked + pass → `.ok`; 6 members → `.full` (even with pass); uid already in `memberUIDs` → `.alreadyMember`.
  - `effectiveState`: focus with `endsAt = t0 - 1` at `t0` → `.idle`; `endsAt = t0 + 60` → `.focus`; break past end → `.idle`.
  - `friendsFocusing`: me + A focusing in group 1, A + B focusing in group 2, C focusing but expired → `2`.
  - `statusText`: focus "Golden", ends in 31 min → `"Golden · 31 min"`; break ends in 4 min → `"break · 4 min"`;
    idle with 2700 s today → `"45 min today"`.
  - `memberSeconds`: device a 600 + device b 300 on the same day → `900`; a day before `joinedAt` → `0`.
  - `weeklyRanking`: Mina 9h40m, You 8h15m, Alex 6h05m, Jun 3h50m in this week plus 5h last week for Jun
    → names in that order, Jun `230`; equal minutes → alphabetical.
  - `sessionPhase`: `startAt = t0 + 7` at `t0` → `.countdown(7)`; `t0 + 6.2` → `.countdown(7)` (ceil);
    25-min session started 7 min ago → `.running(1080)`; started 30 min ago → `.over`; `cancelled` → `.over`.
  - `nextRoundStart(after: t0)` → `t0 + 600`.
  - `shouldAutoJoin(idleSeconds: 30)` → true; `150` → false.
  - `makeInviteCode` with a seeded generator → matches `^TOMA-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$`.
  - `normalizeCode`: `" toma-4k7qm2 "` → `"TOMA-4K7QM2"`; `"4k7qm2"` → `"TOMA-4K7QM2"`; `"4K7Q"` → nil; `"TOMA-4K7QM0"` → nil (0 not in alphabet).
  - Round trip: `member(uid:data:)` of a dict built from `statusData` keeps state/tier/minutes/endsAt/sessionID.

- [ ] **Step 3: `tools/test.sh`** runs
  `swiftc -parse-as-library Groups/GroupRules.swift Tests/RulesCheck.swift -o build/rulescheck && build/rulescheck`,
  then (once Task 2 exists) the rules tests. Run `tools/test.sh` → expected: compile error (no GroupRules).

- [ ] **Step 4: Implement `Groups/GroupRules.swift`** to the signatures above; add `Groups/GroupRules.swift`
  to the app's `sources` in `project.yml`.

- [ ] **Step 5: Verify** `tools/test.sh` → `rules ok`; `tools/run-local.sh --fast` still builds and runs solo.

- [ ] **Step 6: Commit** `git commit -am "Groups: pure rules + check"` (add new files).

### Task 2: Firestore security rules + emulator tests

**Files:**
- Create: `firebase/firebase.json` (firestore rules + emulators: auth 9099, firestore 8080),
  `firebase/firestore.rules`, `firebase/package.json` (devDeps `firebase-tools@15`,
  `@firebase/rules-unit-testing@6`, `firebase@12`; script `"test": "node --test"`), `firebase/rules.test.mjs`
- Modify: `.gitignore` (+ `firebase/node_modules/`), `tools/test.sh` (append
  `cd firebase && npx firebase emulators:exec --project demo-tomatime --only firestore "npm test"`)

**Interfaces — Produces** (data model every later task uses):
- `users/{uid}`: `{ name }`
- `codes/{CODE}`: `{ groupID }`
- `groups/{gid}`: `{ name, code, ownerUID, memberUIDs: [uid], unlocked: Bool, createdAt, joinCode? }`
- `groups/{gid}/members/{uid}`: `{ name, joinedAt, hasPass, status: {state, tierName, minutes, endsAt, sessionID}, secondsByDevice: {device: {dayKey: s}} }`
- `groups/{gid}/sessions/current`: `{ id, round, startedBy, starterName, tierName, minutes, createdAt, startAt, cancelled, joined: [uid], nextJoined: [uid] }`

- [ ] **Step 1: Install** `brew install openjdk@21` (add its `bin` to PATH in `tools/test.sh`), `cd firebase && npm install`.

- [ ] **Step 2: Write failing tests** in `firebase/rules.test.mjs` (one `test()` each, `assertSucceeds`/`assertFails`):
  1. non-member can't read `groups/g1` or its members; member can.
  2. signed-in user can `get` `codes/X`, can't `list` `codes`.
  3. join = batch {group update `memberUIDs` + self, `joinCode: "TOMA-…"` ; create own member doc}:
     right code succeeds; wrong code fails; adding someone else's uid fails.
  4. join when `memberUIDs.length == 6` fails.
  5. join a locked group with member doc `hasPass: false` fails; `hasPass: true` succeeds.
  6. member writes own member doc ✓; another member's doc ✗.
  7. owner removes a member (memberUIDs minus uid + delete their doc) ✓; non-owner removing another ✗;
     anyone removing themselves (leave) ✓.
  8. owner changes `code`/`name` ✓; non-owner ✗; nobody changes `ownerUID` except to a current member when the owner leaves.
  9. member writes `sessions/current` ✓; non-member ✗.
  10. create group: creator must be `ownerUID` and only member; `unlocked: true` allowed (client-trusted, my call in spec).

- [ ] **Step 3: Run** `tools/test.sh` → rules tests FAIL (rules deny everything).

- [ ] **Step 4: Write `firebase/firestore.rules`** to pass them (use `getAfter()` to check the joiner's member doc in the same batch).

- [ ] **Step 5: Verify** `tools/test.sh` → `rules ok` and all rules tests pass.

- [ ] **Step 6: Commit** `"Groups: Firestore rules + emulator tests"`.

### Task 3: Capabilities, profiles, Firebase wiring

**Files:**
- Modify: `project.yml` (package `Firebase` → products `FirebaseAuth`, `FirebaseFirestore`; sources add `Groups`;
  base entitlements add `com.apple.security.network.client: true`; resource `GoogleService-Info.plist` if present),
  `tools/Store.entitlements` (+ `com.apple.developer.applesignin: [Default]`,
  `keychain-access-groups: [$(AppIdentifierPrefix)com.sgjlee.tomatime]`, + network.client),
  `tools/release.sh` + `tools/ExportOptions.plist` (profile → `Tomatime Store 20261110`), `.gitignore` (+ `GoogleService-Info.plist`)
- Create: `tools/run-dev.sh` (like `run-local.sh` but `CODE_SIGN_IDENTITY="Apple Development"`,
  `PROVISIONING_PROFILE_SPECIFIER="Tomatime Dev 20261110"`, `CODE_SIGN_ENTITLEMENTS=tools/Store.entitlements`,
  runs from `build/dev` without copying, passes args through)

- [ ] **Step 1: Apple side via `tools/asc.py`**: add capability `APPLE_ID_AUTH` (setting
  `APPLE_ID_AUTH_APP_CONSENT` = `PRIMARY_APP_CONSENT`) to bundle `com.sgjlee.tomatime`; register this Mac
  (`Mac mini`, UDID `00006040-001E518102A3801C`, platform `MAC_OS`); create profiles `Tomatime Store 20261110`
  (MAC_APP_STORE, cert V8LB9WYJTA) and `Tomatime Dev 20261110` (MAC_APP_DEVELOPMENT, the Apple Development
  cert 79ZAP2FM6K, this Mac); install both into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.

- [ ] **Step 2: Owner steps (Firebase)** — give the user these literally, then continue when done:
  1. Run `! npx firebase-tools@15 login` and sign in with your Google account.
  2. Tell me "done"; I run `firebase projects:create`, `firebase apps:create ios --bundle-id com.sgjlee.tomatime`,
     `firebase apps:sdkconfig ios` → `GoogleService-Info.plist`, create the Firestore database (`nam5`), deploy rules.
  3. In console.firebase.google.com → your project → Authentication → Get started → Sign-in method → Apple → Enable → Save.
  4. In App Store Connect → Business: confirm the **Paid Apps** agreement is Active (needed for the passes).

- [ ] **Step 3: Configure Firebase at launch** in `applicationDidFinishLaunching`: `--emulator` →
  `FirebaseOptions(googleAppID: "1:1:ios:1", gcmSenderID: "1")`, `projectID = "demo-tomatime"`, Auth
  emulator `localhost:9099`, Firestore `localhost:8080`; otherwise configure from the plist only if it is in
  the bundle (no plist → groups hidden, solo unaffected).

- [ ] **Step 4: Verify**: `tools/run-local.sh --fast` builds and runs solo (no Apple entitlements);
  `tools/run-dev.sh` builds; `codesign -d --entitlements - build/dev/Build/Products/Release/Tomatime.app`
  shows applesignin, kvstore, keychain-access-groups, network.client; `tools/release.sh` exports a pkg.

- [ ] **Step 5: Commit** `"Groups: capabilities, profiles, Firebase wiring"`.

### Task 4: GroupStore (auth, listeners, writes) + emulator smoke

**Files:**
- Create: `Groups/GroupStore.swift`, `firebase/tools/fake-member.mjs`, `firebase/tools/smoke.mjs`

**Interfaces — Consumes:** Task 1 types and mappers, Task 2 data model.
**Produces:**
```swift
final class GroupStore {
  static let shared = GroupStore()
  private(set) var uid: String?; private(set) var myName: String?
  private(set) var groups: [TomatoGroup] = []; private(set) var sessions: [String: GroupSession] = [:] // by group id
  var onChange: (() -> Void)?                    // main thread, after any listener update
  var emulator = false
  func signIn(anchor: NSWindow) async throws     // Sign in with Apple → Firebase; emulator: anonymous
  func setName(_ name: String) async throws
  func createGroup(name: String, unlocked: Bool) async throws -> String           // invite code
  func join(code: String, hasPass: Bool) async throws -> JoinVerdict              // reads codes/, checks verdict, batch
  func leave(_ gid: String) async throws        // owner leaving hands ownerUID to longest-standing member
  func remove(_ uid: String, from gid: String) async throws
  func newCode(_ gid: String) async throws -> String
  func rename(_ gid: String, to name: String) async throws
  func publish(status: MemberStatus)            // to my member doc in every group; fire-and-forget
  func publishSeconds(device: String, local: [String: Double])   // days ≥ each group's joinedAt
  func startSession(_ gid: String, tierName: String, minutes: Double) async throws // startAt = server createdAt + 10 s
  func setJoined(_ gid: String, joined: Bool)   // arrayUnion/arrayRemove on `joined`
  func setNextJoined(_ gid: String)             // arrayUnion on `nextJoined`
  func advanceRound(_ gid: String, from round: Int, startAt: Date) // transaction; no-op if round moved on
  func cancelSession(_ gid: String)
}
```
Sign in with Apple: random nonce, SHA-256 in the request, `OAuthProvider.appleCredential(withIDToken:rawNonce:fullName:)`;
no email scope. Listeners: `groups where memberUIDs array-contains uid`, plus each group's `members` and `sessions/current`;
read timestamps with `serverTimestampBehavior: .estimate`.

- [ ] **Step 1: `firebase/tools/fake-member.mjs`** (JS SDK, emulator, anonymous auth): `join <code> <name>`,
  `status <code> focus|break|idle <tier> <minutes>`, `start <code> <tier> <minutes>`, `leave <code>`.

- [ ] **Step 2: Smoke mode**: `--emulator --smoke` signs in anonymously, sets name "Smoke", creates group
  "Smoke Group", publishes a focus status, prints `SMOKE <code>` and quits. `firebase/tools/smoke.mjs <code>`
  asserts the group doc, member doc and status exist. Run it before implementing → FAIL.

- [ ] **Step 3: Implement `Groups/GroupStore.swift`** and the `--smoke` path.

- [ ] **Step 4: Verify** inside `npx firebase emulators:exec --project demo-tomatime --only auth,firestore`:
  app smoke + `smoke.mjs` pass; `fake-member.mjs join <code> Mina` succeeds; with the emulator **stopped**,
  `--emulator --smoke` exits with an error message and no crash (Review Focus 5).

- [ ] **Step 5: Commit** `"Groups: GroupStore + emulator smoke"`.

### Task 5: Passes (StoreKit 2) + App Store products — DEFERRED until the Paid Apps agreement is active

**Files:** Create `Groups/Purchases.swift`; Modify `tools/asc.py` usage only (no repo change needed beyond a
`tools/iap.py` one-off that creates the products).

**Produces:**
```swift
@MainActor final class Purchases {
  static let shared = Purchases()
  private(set) var hasGroupPass = false; private(set) var hasPersonalPass = false
  var hasAnyPass: Bool { hasGroupPass || hasPersonalPass }
  private(set) var prices: [String: String] = [:]          // product id → displayPrice
  var onChange: (() -> Void)?
  func start()                                             // load products, currentEntitlements, Transaction.updates
  func buy(_ productID: String) async throws -> Bool
  func restore() async                                     // AppStore.sync()
}
```
`--emulator` treats both passes as owned.

- [ ] **Step 1: `tools/iap.py`** creates both non-consumables (ids, names, prices from Global Constraints),
  en-US localization ("Group Pass": "Create groups of up to 6. Members join free."; "Personal Pass": "Join any
  Tomatime group."), all territories. Run → both listed in `GET /v1/apps/6832374095/inAppPurchasesV2`.
- [ ] **Step 2: Implement `Purchases`**; call `start()` at launch.
- [ ] **Step 3: Verify** build passes; real purchase check happens in Task 9 (TestFlight sandbox).
- [ ] **Step 4: Commit** `"Groups: passes"`.

### Task 6: Countdown overlay

**Files:** Create `Groups/Countdown.swift`.

**Produces:**
```swift
enum CountdownMode { case invite, autoJoin, starter }
final class Countdown {
  init(title: String, mode: CountdownMode, startAt: Date, onJoin: @escaping () -> Void,
       onSkip: @escaping () -> Void, onCancel: @escaping () -> Void)
  func setJoinedNames(_ names: [String], waiting: [String])
  func close()
}
```
Values from the spec: one borderless non-activating panel per screen at `.screenSaver` level (like the red
overlay); tint black 18%; number white 92% opacity, ~70% of screen height, heavy weight, shadow; each second
animate opacity 1→0 and scale 0.85→1.15 over 1 s (Reduce Motion: opacity only); shows "Go" at 0 then closes;
dark bar (78% black, pill, bottom 5% of screen) with title `"\(starter) started a 🍅 \(tier) tomato · \(min) min"`
and buttons: invite `Join ⏎` (Return, default) + `Skip`; autoJoin `Skip this one  esc` and note `Auto-join is on`;
starter `Cancel`. Esc = Skip/Cancel. Joined line: `"Mina ✓ · Alex ✓ · Jun …"`. Reuse `App.button(_:_:color:)`
styling (move it to a free function if needed).

- [ ] **Step 1: `--countdown-demo`** flag shows an invite countdown starting in 10 s with fake names; stage it
  with `tools/run-local.sh --countdown-demo` and ask the user to look (manual-testing rule).
- [ ] **Step 2: Implement**; verify Return joins, Esc skips, both screens covered, workspace visible.
- [ ] **Step 3: Commit** `"Groups: countdown overlay"`.

### Task 7: Groups in the menu and group sessions

**Files:** Create `Groups/GroupsUI.swift` (`extension App`); Modify `main.swift` (call sites only).

**Consumes:** `GroupStore`, `Countdown`, Task 1 functions. Pass checks use `groupsFree` (no `Purchases` yet):
create with `unlocked: true`, join with `hasPass: true`, and hide `Buy …` / `Restore Purchases`.

Menu (layout B), inserted after "Tomato Calendar…":
- Per group: `"👥 \(name)"` with right side `"\(n) focusing"` (or `"\(count) members"` when 0), submenu:
  member lines (🍅 focus / ☕ break / 💤 idle + `statusText`), separator, `Start group tomato` or
  `Group tomato in progress — Join (\(n) min left)`, `Auto-join` (✓; UserDefaults `autoJoin.<gid>`),
  `Copy invite code`, owner-only `New invite code`, `Remove member ▸`, `Rename group…`, then `Leave group`.
- `Groups ▸`: `Sign in with Apple…` (when signed out) | `New Group…`, `Join with Code…`, `Change My Name…`,
  `Buy Group Pass — \(price)`, `Buy Personal Pass — \(price)` (hidden when owned), `Restore Purchases`.
- No plist / not configured → no group items at all.
- Status item: append the `friendsFocusing` count to the title in bold red when > 0.

Flows:
- New Group / Join: sign in if needed → name prompt first time → pass check (`joinVerdict`; Group Pass required
  to create unlocked, any pass to create locked) → alert with the code ("Invite code copied: TOMA-…").
  Messages: `.full` → "This group is full (6 people)."; `.needsPass` → offer Personal Pass; network error →
  "Couldn't reach Tomatime Groups. Check your connection." Solo state never changes on failure.
- `Start group tomato` uses my current `tier` (custom length included): `startSession(gid, tierName: tier.name,
  minutes: tier.minutes)`.
- Sessions: on a `sessions/current` change with phase `.countdown`: if I started it → starter mode; else if
  auto-join on and `shouldAutoJoin(CGEventSource idle)` → autoJoin mode; else invite mode. Join → `setJoined`.
  At `startAt`, if joined → `App.startGroupTomato(gid:, minutes:, tierName:)` (`countFocus()` first so a
  running solo tomato's minutes are kept, closes any red screen, sets `end` to session end,
  `groupID` = gid, publishes status with `sessionID`). Late arrival (`.running`) → only the submenu Join item.
- My other Mac: when my own member doc's `status.sessionID` equals the countdown's session → close it there.
- Pause / Reset / tier pick / Custom during a group tomato → clear `groupID`, `setJoined(false)`, keep
  solo behaviour (Pause leaves a paused solo tomato with the time left). Minutes already counted stay.
- Red screen in a group tomato: default button `10 min break, then next group tomato` → `setNextJoined`,
  10-min break; at `nextRoundStart − 10 s` the countdown shows in autoJoin mode for those in `nextJoined`;
  first client calls `advanceRound`. Other buttons → solo.
- Publish status on every run/stop/break/reset (only when signed in).

- [ ] **Step 1: Stage with the emulator**: `tools/run-local.sh --emulator` + `fake-member.mjs` (join, status,
  start) and ask the user to walk the list: create group, Mina joins, Mina's status shows, Mina starts → countdown,
  Join → timer starts at 0, Pause → solo paused, red screen group button → next round countdown.
- [ ] **Step 2: Implement**; `tools/test.sh` still green.
- [ ] **Step 3: Commit** `"Groups: menu + group sessions"`.

### Task 8: Group calendar and ranking; minutes publishing

**Files:** Modify `main.swift` (`CalendarView`, `stop()`/`applicationWillTerminate` call `publishSeconds`).

- Segmented control at the top: `Me` + one segment per group (hidden when not in groups).
- Group segment: squares from `groupDayMinutes`, header `"group total \(hm)"`, same legend; below the grid
  `"This week"` and `weeklyRanking` rows with 🥇🥈🥉 for the first three; `"You"` for my own uid.
- `publishSeconds(device: <the UUID in deviceKey>, local: localTally())` wherever `pushToCloud()` runs
  (never `tally()`, which already includes iCloud minutes from my other Macs).

- [ ] **Step 1: Stage** with the emulator and `fake-member.mjs` minutes; ask the user to look at the tab.
- [ ] **Step 2: Implement**; verify window grows to fit 6 rows, Me tab unchanged.
- [ ] **Step 3: Commit** `"Groups: calendar tab + weekly ranking"`.

### Task 9: Privacy, TestFlight 1.2, real-world test

**Files:** Modify `store/privacy/index.html` (adds: display name, group membership and daily tomato minutes
are stored on Google Firebase only when you use Groups; Sign in with Apple; how to leave/delete),
`project.yml` (MARKETING_VERSION "1.2", CURRENT_PROJECT_VERSION "6").

- [ ] **Step 1:** Deploy rules (`firebase deploy --only firestore:rules`), `tools/release.sh --upload`, wait for VALID.
- [ ] **Step 2: Owner checklist** (give literally): install TestFlight 1.2 (6) on both Macs; sign in; create "Us"; send the code to a second person with a Mac; run a group tomato; check
  Pause, the 10-min group break, both Macs closing the countdown, calendar tab; turn Wi-Fi off and try "Start
  group tomato" (alert, solo timer fine).
- [ ] **Step 3:** Update the privacy page in the app-privacy repo and App Privacy answers in App Store Connect
  — **ask the user before publishing either**, and before submitting 1.2 for review.
- [ ] **Step 4: Commit** `"Tomatime 1.2 (6): Groups"`; merging `groups` and pushing to GitHub waits for the user.
