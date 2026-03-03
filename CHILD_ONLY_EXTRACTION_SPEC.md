# Smart Oila Child App - Child-Only Extraction Spec

Date: February 24, 2026

## 1) Goal
Build a brand-new iOS child app with **1:1 parity** to the child experience in legacy sources and Figma, while avoiding parent-only scope.

Requested mapping format:
- `Figma node -> legacy screen -> new module/API contract`

## 2) Sources Analyzed
- Figma URL (working copy): `https://www.figma.com/design/H83caT3AdU32aKqCeFJ8Mg/Smart-Oila--Copy-?node-id=0-1&p=f&t=LcUJfEyrEcdYg8fH-0`
- Legacy projects:
  - `/Users/jakhongirnematov/Downloads/child-tracker-ios-all-sources/child-tracker-kids-v1-ios-app`
  - `/Users/jakhongirnematov/Downloads/child-tracker-ios-all-sources/child-tracker-v1`
  - `/Users/jakhongirnematov/Downloads/child-tracker-ios-all-sources/child-tracker-v2`

Figma access status:
- MCP auth is valid for `jakhongir.nematov97@gmail.com`.
- Copy file access is confirmed.
- During node discovery, MCP hit plan tool-call limit, so one row (`Settings`) remains unresolved in this pass.

## 3) Child-Only Scope (Strict)
Include:
- Session gate by DSN (registered child device state)
- Child auth/registration by parent phone + device bind
- Child main screen with SOS + toolbar to Chat, Tasks, Settings
- Geo permission onboarding full screen
- Child chat with parent (history + send + websocket receive)
- Child tasks read-only list
- Settings (logout + delete local session)
- Background/location websocket sender (`location`, `system_info` events)

Scope clarification:
- Legacy child source includes explicit `SOS` action on main screen.
- Copied Figma candidate home (`183:1885`) shows tasks/messages entry but no explicit SOS CTA.
- Final implementation should follow product decision: strict legacy parity vs strict copied-Figma parity.

Exclude (parent-only and out of scope):
- Parent login/register/SMS code/profile/cards
- Parent device list, map, history location UI, geofence, app blocking UI
- Record environment/camera/live stream
- News/support/phone-blocking UI

## 4) Screen Parity Matrix (Child App)

| Flow | Figma Node | Legacy Screen (Source of Truth) | New Module | API / Socket Contract | Acceptance Criteria |
|---|---|---|---|---|---|
| App bootstrap + gate | `183:1328` (splash frame baseline) | `iOS App/App/ContentView.swift` | `App/Root/RootView` | Local storage only (`DSN`) | If `DSN` missing -> Auth. If `DSN` exists -> Main. |
| Auth (phone input + submit) | `75:40` (phone), `183:1366` (QR), `183:1446` (success), `183:1409` (error) | `iOS App/Scene/Auth/View/AuthView.swift`, `.../ViewModel/AuthViewModel.swift` | `Features/Auth` | `GET/POST` flow (see section 5) | Single phone field, submit button with loading, errors shown inline/toast, success stores `DSN` and transitions to Main. |
| Geo permission onboarding | `183:1479` | `iOS App/Scene/Permission/View/GeoPermissionView.swift`, `iOS App/Service/LocationManager.swift` | `Features/Permissions` | iOS CoreLocation only | Full-screen modal appears when location flag not granted; first tap requests permission; next tap dismisses. |
| Main (child home) | `183:1885` (candidate child home in copied file) | `iOS App/Scene/Main/View/MainView.swift`, `.../ViewModel/MainViewModel.swift` | `Features/Main` | `POST /devices/notify/member` + start geo socket manager | Home shell + entry points for tasks/messages; final UI behavior aligns with approved child flow. |
| Chat list + composer | `447:412` (chat list), `447:368` (chat detail + composer) | `iOS App/Scene/Chat/View/ChatView.swift`, `.../ViewModel/ChatViewModel.swift`, `.../Model/ChatEntity.swift` | `Features/Chat` | `GET /messages/{dsn}`, `POST /messages/`, `WS /children/device/{dsn}/chat/` | Group messages by date; parent/child bubble alignment; send text; auto-scroll to latest; realtime incoming via websocket. |
| Chat bubble/media viewer | `447:368` | `iOS App/Helpers/View/Message/View/MessageView.swift` | `Features/Chat/Components` | Uses chat payload attachments URLs | Bubble styles by `user_type`; image tap opens full-screen zoomable viewer. |
| Tasks (read-only) | `447:63` (primary), `447:246` (variant) | `iOS App/Scene/Task/View/TaskView.swift`, `.../ViewModel/TaskViewModel.swift`, `.../Model/TaskModel.swift` | `Features/Tasks` | `GET /awards/devices/{dsn}/` | Show awards, nested task names, completed state text. No create/edit/delete/toggle in child app. |
| Settings | `Node ID pending (MCP limit). User provided full frame spec: "Профиль", 412x917, purple content area, save CTA, connected devices cards.` | `iOS App/Scene/Settings/View/SettingsView.swift` | `Features/Settings` | Local storage only | Profile header ("Профиль"), editable user name field, connected devices cards (e.g., "Мама", "Папа"), save button, plus legacy actions (delete account/logout) per product decision. |

Node mapping status:
- Resolved with screenshots and metadata: auth flow, permission flow, home candidate, chat, tasks.
- Pending due Figma MCP rate limit: dedicated settings frame ID confirmation only.
- Settings visual/UX contract is captured from the user-provided Figma inspect spec.

## 5) API + WebSocket Contract (Extracted)

## 5.1 Registration / Auth (child bind)
From:
- `iOS App/Data/Constants.swift`
- `iOS App/Scene/Auth/Model/AuthRequest.swift`
- `iOS App/Service/AuthService.swift`

Legacy contract:
1. Check parent phone exists:
   - `GET /api/members/phone?phone_number=%2B{digits}`
2. Register child device:
   - `POST /upload-v2/device` with form fields:
     - `email` = `+998...`
     - `DeviceName`
     - `content` = `add-dev`
     - `client-ver`
     - `app-ver`
     - `device` = `""`
     - `client-date-time` = `dd/MM/yyyy HH:mm:ss`
3. Response parsing:
   - legacy parses DSN from plain text body tail after `:`

Implication for new app:
- Keep exact field names/casing for compatibility.
- Replace fragile string parsing with backend-confirmed structured response if available.

## 5.2 SOS
From `NetworkService.sendSOS`:
- Endpoint: `POST /api/devices/notify/member`
- Body: `device_dsn={dsn}`
- Content expectation: success toast/alert on OK.

## 5.3 Chat
From child chat model + view model:
- Fetch history: `GET /api/messages/{dsn}?page=1&limit={limit}`
- Send: `POST /api/messages/` as multipart fields:
  - `send_from_id` (child DSN)
  - `user_type` = `child`
  - `text`
  - optional repeated `attachments`
- Realtime receive socket:
  - child side listens: `/ws/.../children/device/{dsn}/chat/`
  - parent side (v1) uses `/ws/.../parent/device/{dsn}/chat/`

Payload keys to preserve:
- `user_type`, `text`, `attachments`, `time`
- group key is date (legacy uses formatted `yyyy-MM-dd`)

## 5.4 Tasks
From child task model:
- Fetch awards/tasks: `GET /api/awards/devices/{dsn}/`
- Response includes:
  - `award_id`, `name`, `image_url`, `needed_points`, `is_completed`, `collected_coins`, `tasks[]`
  - nested tasks: `task_id`, `name`, `is_finished`, `points_amount`

## 5.5 Geo + Device Status Socket
From `LocationWebSocketService.swift`:
- Socket endpoint:
  - `/ws/.../children/device/{dsn}/geo/`
- Event payloads:
  - `event=location`, data: `latitude`, `longitude`, `device_date`, `device_id`
  - `event=system_info`, data: `battery`, `connect`, `sound_mode`

## 6) Live Backend Readiness (Validated February 24, 2026)

Observed from live probes:
- `https://child-tracker.uz/upload-v2/device` is reachable (HTTP 302/200 depending method) and processes payloads.
- Posting test registration payload returns business error text (`Email not found or account is blocked`), confirming endpoint is active.
- Legacy host/port `89.111.175.220:8000` is **not reachable** from current network (connection refused).
- `https://child-tracker.uz/api/*` responds but currently returns token errors for unauthenticated calls.
- Legacy websocket paths on old host are currently not reachable via old `ws://...:8000`.

Conclusion:
- Backend exists and is alive.
- Child app can start now, but must be wired to **current production base URLs and token rules** (legacy hardcoded `http://...:8000` contracts are stale for many routes).

## 7) Cross-Project Consistency Notes (Why 3-project analysis matters)
- Child app (`kids-v1`) contains the actual child UI flow to replicate.
- Parent v1 has matching chat/tasks schemas and confirms websocket channel pair direction (`parent/device/*` vs `children/device/*`).
- Parent v2 confirms ongoing migration to tokenized API architecture, and many service modules are placeholders; child flow is not migrated there.

Practical result:
- For child new app, treat `kids-v1` as UI behavior source.
- Use parent v1/v2 only to validate DTO naming and backend evolution assumptions.

## 8) Legacy Risks to Fix in New Project (Do Not Carry Over)
- Broken symbols in kids `NetworkService.getNotificationToken`:
  - `firebaseToken`, `ChatFirebaseTokenResponse`, `Constants.POST` unresolved.
- `KidsApp` contains Firebase/AppDelegate code but app struct does not wire `UIApplicationDelegateAdaptor`.
- Hardcoded hosts/protocols (`http://...:8000`, `ws://...`) and ATS `NSAllowsArbitraryLoads=true`.
- Auth UX bug:
  - if `getUserExists` returns success with `success=false`, loading state can remain stuck.
- Phone validation inconsistency:
  - regex expects spaced Uzbek format, UI actually stores compact `+998...`.

## 9) New Project Module Blueprint (Child)

Recommended target structure:
- `App/Root` (session gate + dependency graph)
- `Core/Storage` (`DSN` persistence abstraction)
- `Core/Networking` (base URL/env config, auth header policy, request adapters)
- `Core/Socket` (chat socket + geo socket clients)
- `Features/Auth`
- `Features/Permissions`
- `Features/Main`
- `Features/Chat`
- `Features/Tasks`
- `Features/Settings`
- `Shared/UI` (button styles, app shell, error/empty components)
- `Shared/Resources` (fonts, colors, localization, assets)

## 10) Immediate Next Actions
1. Grant Figma access for file `TF9CT35dzK0SdpAGwFDyWf` to authenticated user `jakhongir.nematov97@gmail.com` so node IDs can be bound in this matrix.
2. Confirm backend current child contracts:
   - official HTTPS base URL
   - child auth/token scheme for `/api/messages`, `/api/awards`, `/api/members/phone`
   - current websocket endpoints (secure `wss` vs legacy `ws`)
3. Freeze parity baseline:
   - this spec + approved Figma nodes
4. Start implementation with `Auth -> Main -> Chat -> Tasks -> Settings -> Geo socket` order.
