// The invite-attribution subsystem (`InviteLinkBuilder`, `InviteAttributionStore`,
// `InviteAttributionContext`) was removed in the 2026-08-05 audit. It had no share entry point, no
// reader of the captured context, and its link host (`smart-oila.uz`) no longer resolves, so the
// only thing it did was persist a blob of query parameters nothing ever read.
//
// This file is intentionally empty: it is still listed in `SmartOilaKids.xcodeproj/project.pbxproj`
// (2 build-file refs, 1 file ref, 1 group child), which is outside the audit group that emptied it.
// Delete the file together with those project entries.
