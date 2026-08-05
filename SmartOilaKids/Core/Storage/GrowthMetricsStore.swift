// `GrowthMetricsStore` / `GrowthMetricsSnapshot` / `GrowthEvent` were removed in the 2026-08-05
// audit. The only writer was the (now deleted) invite-attribution capture, and nothing ever read a
// snapshot or observed `growthMetricsDidChange` — the counters were written to UserDefaults and
// never surfaced anywhere. The rename/delete events it declared were never emitted at all.
//
// This file is intentionally empty: it is still listed in `SmartOilaKids.xcodeproj/project.pbxproj`
// (2 build-file refs, 1 file ref, 1 group child), which is outside the audit group that emptied it.
// Delete the file together with those project entries.
