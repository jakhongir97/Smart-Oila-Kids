# Android to iOS Parity Backlog
Date: 2026-03-09

## Current Estimate
- Weighted product parity: about 84%
- Literal Android capability parity: about 71%

## Scope Note
- These percentages are weighted by product impact, not raw source-file count.
- The iOS app already covers most user-visible child flows.
- The remaining gap is concentrated in Android-only OS powers and a few still-feasible hardening items.

## P0: Raise Real Product Parity Next
1. Real-device validation of Screen Time enforcement
   - Verify global lock, per-app lock, daily limits, and schedules on physical iPhones.
   - Confirm entitlement behavior, foreground/background transitions, and recovery alerts.

2. Real-device validation of media command execution
   - Validate microphone recording, live audio, camera recording, live video, and ReplayKit display recording on-device.
   - Capture exact failure modes for permission denial, foreground exit, low-power mode, and reconnect.

3. Parent/backend readback for new child telemetry
   - Surface `device_control` and `media_control` events back into parent-facing history/dashboard flows.
   - Today the child emits these events; parity is incomplete until the parent/backend actually reads and displays them.

4. Settings protection on iOS
   - Add a child-side protection gate for sensitive settings areas using LocalAuthentication and/or an app PIN.
   - This is the closest practical substitute for Android lock-settings protection.

5. App-control onboarding hardening
   - When a parent lock exists for an app not selected in Screen Time, guide the child directly into restoring enforceability.
   - Reduce the gap between "remote lock exists" and "iOS can actually enforce it".

## P1: High-Value Improvements
1. Media command acknowledgements
   - Add clearer upstream success/failure state for recording and streaming commands so backend state converges faster.

2. Lock/media diagnostics polish
   - Expose last command outcome, permission blockers, and current enforcement source more clearly in normal settings UI.

3. Reinstall/device-transfer recovery
   - Harden selection sync, remote lock restore, and usage state restore after reinstall or device switch.

4. Parent-visible app-control mismatch reporting
   - Show parent-side warnings when iOS cannot enforce a remote app lock because the app is not selected in Screen Time.

## P2: Optional If Time Allows
1. Better child-facing service inspection
   - Expand current diagnostics into a more Android-like "service health" surface.

2. More complete media history controls
   - Add richer filtering, retry state, and upload-state drill-down for the child settings panel.

## Do Not Chase As 1:1 App Store iOS Parity
- Boot receiver / auto-start after reboot
- Device admin
- System overlay blocking activities
- QUERY_ALL_PACKAGES style full installed-app inventory
- Android-style unrestricted foreground-app monitoring
- Accessibility interception
- Call history collection

## Recommendation
- The fastest path from 84% to the practical ceiling on iOS is:
  1. real-device validation,
  2. parent/backend readback,
  3. settings protection,
  4. app-control onboarding hardening.
- Do not spend delivery time trying to clone Android boot/device-admin/overlay behavior 1:1 on standard iOS.
