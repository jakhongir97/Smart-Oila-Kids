# Build 21 — Location fidelity. Everything on our side.

Repo `main` @ 1199cfe. 49 proposals audited, 10 survived adversarial verification, 17 agents.
Every line number verified against the current tree. Apply top-down within each step.

---

## THE FINDING THAT COMES FIRST

**We do not yet know that the screenshot is a sampling problem.** There is a second explanation that
produces exactly the same picture, and we have no code that can detect or recover from it.

If the child's phone has **Precise Location OFF**, `accuracyAuthorization == .reducedAccuracy`, every
fix is kilometre-grade, `OilaTelemetryService.swift:1532` rejects all of them, and the only points that
survive are stale-branch fixes every 600 s. That draws long straight chords across real routes and
"1 stop in 15 hours" — the reported picture, exactly.

Verified: `requestTemporaryFullAccuracyAuthorization` is **never called in app code** (only named in a
comment at `LocationPermissionManager+Actions.swift:30`), and `NSLocationTemporaryUsageDescriptionDictionary`
is **absent from `Info.plist`** (only the three standard usage strings at lines 37–41). So the app
cannot even ask.

**Do this before writing any code:** on the complaint handset, Settings → Privacy & Security →
Location Services → Bolajon360 → is **Precise Location** on? If it is off, steps 3–7 below change
nothing on that device, and the fix is STEP 0.

---

## PART A — THE iOS WORK LIST

### STEP 0 — Precise Location: detect and recover  **NEW LOGIC**
`Info.plist` + `LocationPermissionManager`.
1. Add `NSLocationTemporaryUsageDescriptionDictionary` with a purpose key.
2. Call `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)` when
   `accuracyAuthorization == .reducedAccuracy` under Always.
3. Keep the existing child notification as the fallback.
**Fixes:** the one cause that makes every other step irrelevant on an affected handset.

### STEP 1 — Set `CLActivityType`  **TUNING — one line**
`OilaTelemetryService.swift:336`, next to `pausesLocationUpdatesAutomatically`.
```swift
locationManager.activityType = .automotiveNavigation
```
Verified absent: `grep -rn "activityType" *.swift` = **zero hits repo-wide**. It has been `.other`
for the whole life of the app — on a child in a car. `.other` tells CoreLocation nothing about what
it is duty-cycling for.
**Honest bound:** the documented effect is on the auto-pause heuristic (already disabled) and on
CoreLocation's internal duty-cycle choices. No road-matching claim. Magnitude is what PART D measures.
**Cost:** zero. **Tests:** none.

### STEP 2 — Close the accuracy-ceiling bypass  **BUG FIX**
`OilaTelemetryService.swift:1597`.
```swift
if !isMuchBetterThanLast {          // ← acceptsFix is SKIPPED when this is true
    guard Self.acceptsFix(...) else { continue }
}
```
The stale branch legitimately admits a fix up to 5000 m accurate (`:1530`), so
`lastAcceptedFix.horizontalAccuracy` can be 2500. A 900 m fix arriving 10 s later satisfies
`900 <= 2500 - 20`, sets `isMuchBetterThanLast = true`, and **skips `acceptsFix` entirely** — queued
as a confident route vertex, never seeing `maxAcceptedAccuracyM` (`:1532`).
That is the spiderweb class the hardening at `:1503-1513` was written to end, still reachable
through the front door. `ingestLocations` has **zero test coverage**, so nothing pins it.
**Fix:** let the exception waive the *displacement* rule only, never the accuracy ceiling.

### STEP 3 — Displacement ceiling: take any fix ≥60 m away, whatever the clock says  **NEW LOGIC**
`OilaTelemetryService.swift:1585-1590`. Replace the time-gate branch:
```swift
} else if elapsed < Self.minFixIntervalS {
    let previousAccuracy = lastAcceptedFix?.horizontalAccuracy ?? .greatestFiniteMagnitude
    // Displacement CEILING. Deliberately does NOT set `isMuchBetterThanLast`, so the fix
    // still has to clear `acceptsFix` below and keeps the full accuracy ceiling.
    let hasTravelledFar = elapsed >= Self.burstFloorS
        && (distance ?? 0) >= Self.maxDisplacementM
    isMuchBetterThanLast = (accuracy ?? .greatestFiniteMagnitude)
        <= previousAccuracy - Self.accuracyImprovementM
    guard isMuchBetterThanLast || hasTravelledFar else { continue }
}
```
New constants next to `:262`:
```swift
nonisolated private static let maxDisplacementM: Double = 60
nonisolated private static let burstFloorS: TimeInterval = 2   // a buffered burst is not a sprint
```
Only binds above 60/30 = 2 m/s (7.2 km/h) — a walking or stationary child is governed exactly as
before, so the anti-noise defence is untouched.

**Effect, stated honestly.** Effective spacing is `max(60, 1.5 × accuracy)` plus a ≤15 m delivery
quantum — **not** a flat 60 m. At accuracy ≤40 m: 60–75 m. At 60 m: 90–105 m. At the 100 m ceiling:
150–165 m. In central Tashkent the 40–80 m band is common, so quote **60–165 m**, and worst-case
90° corner error **21–58 m**, not the best case.

Today at a realistic central-Tashkent 25–30 km/h the spacing is 167–250 m, so a 750 m detour taken in
~90 s already gets 3–4 interior points. **The screenshot shows zero.** Density alone does not explain
that — which is why STEP 0 and STEP 2 come first.

### STEP 4 — Raise the offline queue. **SAME COMMIT AS STEP 3.**
`:231` `maxQueuedFixes = 400` → `1200`. At the new cadence 400 slots hold ~32 min of driving, then
`suffix(maxQueuedFixes)` (`:1620`, `:1108`, `:1118`) **silently discards the oldest** — the start of
the offline stretch. A new failure of exactly the class we are fixing.
No backend change: `items <= 500` is enforced by `locationUploadChunk = 250` at the slice `:1093`,
not by `maxQueuedFixes`. The comment at `:228-230` implying otherwise is wrong — fix it too.
Also false after this lands: `:216-217`, `:227`, `:329`.

### STEP 5 — Stop the O(n) outbox rewrite scaling with the new cadence  **NEW LOGIC**
`persistPendingFixes()` (`:748-754`) JSON-encodes the **whole** array on every accepted fix (`:1621`).
~2/min today while driving, ~12/min after step 3. Online the queue is ~7 items (trivial); offline
with a 1200-entry queue it rewrites 1200 objects twelve times a minute. Move to an append-only
journal, or throttle the full rewrite.

### STEP 6 — Vertex on every real turn  **NEW LOGIC — only after 0–4 are measured**
`course` is **never read anywhere in the repo** (verified). Add a pure static
`isSignificantHeadingChange(...)` gated on `speed >= 4.0` (14.4 km/h), `courseAccuracy <= 10`,
`accuracy <= 30`, delta `>= 25°` using the `(course - previous + 540) % 360 - 180` form so 359°→5°
reads as 6°. OR it into the STEP 3 guard.
**Required companion:** `:333` `distanceFilter = 15` → `5`, or CoreLocation never delivers the fixes
this step exists to accept (a 25° chord at a 15 m turning radius is 6.5 m, suppressed at the OS layer).
**Do NOT add `course` to `OilaLocationFix`** — it is an all-`let` struct with 4 construction sites, and
a non-defaulted property makes the persisted backlog fail to decode on upgrade, silently dropping
every queued offline fix at `restorePendingFixes` (`:757`).
Persist the previous course under its own defaults key.
**Cost is not free:** at `distanceFilter = 5` the accepted rate roughly triples again on top of
step 3. Ship step 5 in the same commit.

### STEP 7 — Make CLVisit points reach the wire  **NEW LOGIC — the "1 stop in 15 hours" complaint**
`didVisit` exists (`:1432`) but **no visit survives while the process is alive**: gate 1 at `:1451`
(`timestamp <= lastAcceptedFixAt`) always returns, because a departure is reported minutes after it
happened while `startUpdatingLocation()` has been accepting newer fixes throughout. The doc comment
at `:1422-1431` claims otherwise. Zero test coverage.
**Prerequisite, read-only, not a backend request:** post one backdated point to staging and read back
`/location/history` and `/location/latest`. If either orders by insertion rather than `ts`, a
backdated departure draws a spike across the city — emit only the arrival endpoint in that case.
Keep the accuracy ceiling on visits. Insert sorted, do not append. Persist the dedup key.

### DELIBERATELY NOT DOING
- **Speed-tiered `minFixIntervalS`.** Route shape is governed by spacing, not time. Step 3 fixes
  spacing at every speed without reading a new field, and the tier doubles the walking-case data bill.
- **Lowering `minDisplacementM` below 15.** `max(15, 1.5×accuracy)` is the entire defence against a
  stationary child drawing a fake walk. Pinned by `SmartOilaKidsCoreUnitTests.swift:4077-4098`.

---

## PART B — THE BACKEND ASK

```
1. PATCH /api/v1/device/fcm-token
   UpdateFcmTokenDto += one optional field:

     @IsOptional() @IsString() @Length(1, 4096)
     locationPushToken?: string;        // upsert onto the device row

2. Send the push DIRECT to APNs (FCM cannot send this type):

     apns-push-type: location
     apns-topic:     uz.smartoila.kids.location-query
     apns-priority:  10
     auth:           existing .p8 (certificates not supported)
     send to:        locationPushToken  — NOT fcmToken, NOT the APNs token

Trigger: parent taps "check in now", or a sweep over children
whose last fix is stale. Never a poll.

No new endpoint. No new response field. No change to
/device/location/batch, /device/status, or history.
```

`uz.smartoila.kids.location-query` is derived from the **app** bundle id (`project.yml:38`).
It is **not** the extension's id `uz.smartoila.kids.location-push` — one copy-paste away, fails silently.

**Not a backend blocker, ours:** the entitlements (`com.apple.developer.location.push` +
`keychain-access-groups`) are absent from `SmartOilaKids.entitlements`; the extension is built but
**never embedded** (`PBXCopyFilesBuildPhase` at `project.pbxproj:146-147` is empty, app target
`dependencies = ()` at `:724-725`); `AppRuntime.locationPushEnabled` is off. That is an App-ID and
signing cycle on our side, not one field on theirs.

---

## PART C — WHAT WE GIVE UP

1. **`accuracy` never reaches the parent web.** We send it on every point; history/latest drop it, so
   the web draws a 5 m point and a 100 m point as equally confident vertices. **No client fix exists.**
   This is the only change that would repair the map families see *today*, on rows already stored.
2. **The parent is never told why a phone went quiet.** The client sends `diagnostics`, eats one 400
   per launch, latches it off (`OilaDeviceAPI.swift:981, 1008, 1020`) and resends without it.
3. **"Precise location off" stays invisible to the parent** even after that — `locationPrecise` is
   measured but not in `emittableKeys`.
4. **A force-quit phone reports only via SLC, region and visits.** Location push stays inert.
5. **No road snapping, ever.** We bet entirely on density: a 60 m chord between two real road points
   is visually indistinguishable from the road. It will still cut a hairpin taken in under 4 s.
6. **We cannot see whether the history endpoint caps or downsamples.** The PART D drive is how we
   find out — one drive instead of one request to another team.
7. **We cannot send a "stop" event.** All we can do is feed denser points and real visit centroids.
8. **Relaunch-region blind spots get ~2.3× more frequent.** Accepted, not fixed.

---

## PART D — THE MEASUREMENT

Two handsets, same car, same seat, one trip, both Always **+ Precise**, both cellular, both ≥80%.
- **A: build 20** (control). **B: build 21 with steps 0–4 only** — steps 5–7 make it unattributable.

**Temporary log in B**, at the **top** of the loop right after `let distance = …` (`:1563`), NOT after
the append at `:1613` — both rejection paths exit before that, so a phone whose fixes are all being
rejected produces an empty log and the drive proves nothing:
```swift
os_log("fix acc=%.1f spd=%.1f spdAcc=%.1f crs=%.1f crsAcc=%.1f dist=%.1f gate=%{public}s",
       location.horizontalAccuracy, location.speed, location.speedAccuracy,
       location.course, location.courseAccuracy, distance ?? -1, gateOutcome)
```

Drive the exact complaint route including the Furqat → Zargar → finish detour. 30–45 min. Note start
and end to the second. Then, from a laptop with the parent token, read-only:
```
curl -s -H "Authorization: Bearer $PARENT" \
  "$BASE/api/v1/parent/children/$CHILD/location/history?from=$START&to=$END" > a.json
```

| # | Number | Pass |
|---|--------|------|
| 1 | Points B / points A | **≥ 2.5** (4.0 only above ~48 km/h with accuracy ≤40 m) |
| 2 | Median consecutive spacing, B | **≤ 80 m** — the real criterion, speed-independent |
| 3 | 90th-percentile spacing, B | ≤ 150 m |
| 4 | Largest gap, B, and whether a tunnel explains it | ≤ 250 m outside tunnels |
| 5 | Interior points inside the detour, A and B | B ≥ 8 |
| 6 | Battery % drop, A and B | within 1 point |
| 7 | Location payload = points × ~130 B | not the Settings figure — `lockTimer` + `flushTimer` + `statusTimer` already spend ~250 requests/h before a single location byte |
| 8 | From the log: % of moving fixes with `spdAcc ≥ 0 && spd ≥ 4`, median `crsAcc` among those | ≥60% → build step 6; below that, do not build it |

**If #1 comes back near 1.0 while the device log shows 60–75 m spacing**, the client worked and the
history endpoint is capping or downsampling. That is the only moment to go back to the backend, and
the ask becomes a different one.
