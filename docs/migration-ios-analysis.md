# iOS App — Lovable → Mad-Thinker Supabase Migration Analysis

**Generated:** 2026-05-05 (re-run) · **Cutover target:** Wednesday 2026-05-06 · **Read-only audit, no code modified.**

> **TL;DR — backend connection story is unchanged from the 2026-05-04 audit.** Both `DevTEST.xcconfig` and `PROD.xcconfig` still point at `koyegehcwcrvxpfthkxq`. Same handful of file edits required for cutover. **The notable deltas since yesterday** are (a) `AuthService.init` now hydrates cached profile fields synchronously, which changes the *visible* post-cutover UX for offline users from "spinner → login" to "their old landing view → login on first network call"; (b) DevTEST logging is now filtered to `LOG_CATEGORIES = catch, ml` — auth/community/network logs are silenced, must be widened for cutover smoke tests; (c) `CommunityService.joinCommunity` now sends a `member_number` parameter; (d) `MapReportService` now sends a Bearer token in addition to the anon `apikey` header; (e) two new test plans (`UITests.xctestplan`, `UnitTests.xctestplan`) exist and should be added to the cutover test matrix.

---

## Delta since 2026-05-04 audit

23 commits landed on `main` since the prior report (range `45dad31..HEAD`). The migration-relevant subset:

| Commit | File(s) | Migration impact |
|---|---|---|
| `6af6a9f` Hydrate cached profile in `AuthService.init` | `Authentication/AuthService.swift` | **Changes cutover UX.** See Section 5.6. |
| `02a5789` Filter dev logs to catch+ml | `Config/DevTEST.xcconfig` | **Silences auth/community/network logs on DevTEST.** Widen before cutover testing. See Section 6.1.4. |
| `cc49f4e` Require member number on registration | `Authentication/CommunityService.swift`, `Views/Guide/MemberRegistrationView.swift` | `joinCommunity` request body now includes `member_number`. New project's `/functions/v1/join-community` must accept it. See Section 3.4. |
| `a88a49c` Add conditions recall fishery map | `Services/MapReportService.swift` | Now sends `Authorization: Bearer <jwt>` in addition to `apikey`. RLS on the new `/functions/v1/map-reports` must allow this access pattern. |
| `c4af0b3`, `02a5789` Add UI / Unit test plans | `UITests.xctestplan`, `UnitTests.xctestplan` | Two new test plans available for the cutover matrix. See Section 8. |
| `e81049b` Calibrate length heuristic | `Config/Environment.swift` | Adds two ML-only knobs (`PERSON_DETECT_MIN_CONFIDENCE`, `HEURISTIC_DIAG_FRAC_STRENGTH`). No backend impact. |

The DevTEST and PROD xcconfigs themselves are byte-identical to the 2026-05-04 versions on the migration-relevant lines (12-15) — the project ref and anon key were **not** changed yesterday.

---

## Section 1 — Backend connection structure

### 1.1 Supabase URL

The URL is **not hardcoded in Swift source**. It flows: `xcconfig → Info.plist → AppEnvironment.projectURL`.

**Source-of-truth declarations (`koyegehcwcrvxpfthkxq.supabase.co`):**

| File | Line | Key | Value |
|---|---|---|---|
| `SkeenaSystem/Config/DevTEST.xcconfig` | 12 | `SUPABASE_PROJECT_URL` | `https://koyegehcwcrvxpfthkxq.supabase.co` |
| `SkeenaSystem/Config/DevTEST.xcconfig` | 13 | `API_BASE_URL` | `koyegehcwcrvxpfthkxq.supabase.co` |
| `SkeenaSystem/Config/PROD.xcconfig` | 13 | `SUPABASE_PROJECT_URL` | `https://koyegehcwcrvxpfthkxq.supabase.co` |
| `SkeenaSystem/Config/PROD.xcconfig` | 14 | `API_BASE_URL` | `koyegehcwcrvxpfthkxq.supabase.co` |

**Documentation/comment-only references:**
- `SkeenaSystemTests/APITests/BackendHealthSmokeTests.swift:7` — comment only.

`API_BASE_URL` is what Swift reads. `SUPABASE_PROJECT_URL` is exported via `Info.plist:131-132` but no Swift call site reads it. Single live consumer:

```swift
// SkeenaSystem/Config/Environment.swift:109-122
public var projectURL: URL {
    if let url = overrideProjectURL { return url }
    if let raw = stringFromInfo("API_BASE_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
        let normalized: String
        if URL(string: raw)?.scheme == nil {
            normalized = "https://" + raw
        } else {
            normalized = raw
        }
        if let url = URL(string: normalized) { return url }
    }
    fatalError("API_BASE_URL not configured in Info.plist or override.")
}
```

**Direct readers of `API_BASE_URL` from `Info.plist` (i.e., not via `AppEnvironment.shared.projectURL`):**

- `SkeenaSystem/Managers/SynchTrips.swift:94`
- `SkeenaSystem/Views/Guide/AnglerProfilesView.swift:240`

### 1.2 Anon key

Source of truth is the same two xcconfig files (`DevTEST.xcconfig:14`, `PROD.xcconfig:15`). JWT payload decoded: `iss=supabase, ref=koyegehcwcrvxpfthkxq, role=anon, iat=1773761733, exp=2089337733`. Identical between DevTEST and PROD.

Canonical reader at `SkeenaSystem/Config/Environment.swift:125-129`:

```swift
public var anonKey: String {
    if let v = overrideAnonKey { return v }
    if let v = stringFromInfo("SUPABASE_ANON_KEY") { return v }
    fatalError("SUPABASE_ANON_KEY not configured.")
}
```

`AuthService.publicAnonKey` (`AuthService.swift:35`) re-exposes the same value to call sites that don't import `AppEnvironment`.

**Direct `Info.plist` readers (bypass `AppEnvironment`):**

- `SkeenaSystem/Views/Guide/ReportsListView.swift:35, 201`
- `SkeenaSystem/Views/Guide/FishingForecastRequestView.swift:320, 403`
- `SkeenaSystem/Views/Shared/ActivitiesView.swift:77`

**Indirect readers via `AppEnvironment.shared.anonKey` or `AuthService.shared.publicAnonKey`:** ~30 call sites. Representative:

- `SkeenaSystem/Authentication/AuthService.swift:22`, `CommunityService.swift:59`
- `SkeenaSystem/Services/{TripAPI,OpsTicketsAPI,MapReportService,WeatherSnapshotService,CatchStoryService,MemberProfileFieldsAPI}.swift`
- `SkeenaSystem/Managers/{UploadObservations,UploadFarmedReports,SynchTrips}.swift`
- Many `Views/Angler/*.swift`, `Views/Guide/*.swift`, `Views/Public/PublicLandingView.swift`

**No JWT-shaped strings (`eyJ…`) appear anywhere in Swift source.** All reads are dynamic from `Info.plist`. The only literal JWTs are in the two xcconfig files.

### 1.3 Supabase client initialization

**There is no `SupabaseClient`.** No `supabase-swift` dependency. `Podfile` declares only `MediaPipeTasksVision`; no SPM packages reference Supabase. Everything is hand-rolled on `URLSession`.

The closest thing to "client init" is the `AuthService` singleton:

- `SkeenaSystem/Authentication/AuthService.swift:11-12, 21-22, 71-89` — `static let shared = AuthService()` reads `projectURL` and `anonPublicKey` once at init, then calls `loadCachedAuthState()` (line 106-137) which reads Keychain + UserDefaults synchronously to set `isAuthenticated`, `currentUserType`, `currentFirstName`, `currentLastName`, `currentMemberId`.
- `SkeenaSystem/SkeenaSystemApp.swift:14-34` — `@main` `init()` runs early; logs `AppEnvironment.shared.projectURL`. **No network I/O at app init.** A comment at `AuthService.swift:87-88` is explicit: *"Do not start network I/O from init()."*

> **Δ vs. prior audit:** previously `AuthService.init` only set `isAuthenticated` and left the other fields nil; now it hydrates the full cached profile so the app can route to the correct landing on a cold offline launch. Tests in `SkeenaSystemTests/Authentication/OfflineColdLaunchRoutingTests.swift` lock this behavior. **Migration-relevant implication discussed in Section 5.6 and 7.1.**

Other singletons that hold the same env values lazily: `CommunityService.shared` (`Authentication/CommunityService.swift:13, 58-59`), `AuthStore.shared`.

### 1.4 xcconfig files

| Path | Purpose |
|---|---|
| `SkeenaSystem/Config/DevTEST.xcconfig` | DevTEST build configuration |
| `SkeenaSystem/Config/PROD.xcconfig` | PROD (and Release) build configuration |
| `SkeenaSystem/Config/Secrets.xcconfig` | Gitignored. `#include? "Secrets.xcconfig"` at `DevTEST.xcconfig:99`. Holds `MAPBOX_ACCESS_TOKEN`. PROD has a placeholder (`PROD.xcconfig:89`) `MAPBOX_ACCESS_TOKEN = YOUR_MAPBOX_TOKEN_HERE`. |
| `Pods/Target Support Files/Pods-SkeenaSystem/*.xcconfig` | Auto-generated by CocoaPods; wired via `baseConfigurationReference` for each of Debug/DevTEST/PROD/Release. |

DevTEST.xcconfig and PROD.xcconfig define the same key set (backend, log level/categories, edge-function paths, compile-time entitlement fallbacks, branding fallbacks, geography fallbacks, Mapbox, ML calibration). The full key listing did not change since 2026-05-04, except:

- `DevTEST.xcconfig:15` — `LOG_LEVEL = debug` (was `error`)
- `DevTEST.xcconfig:19` — `LOG_CATEGORIES = catch, ml` (was empty)

### 1.5 Build configurations

Four configurations declared in `SkeenaSystem.xcodeproj/project.pbxproj`: `Debug`, `Release`, `DevTEST`, `PROD`. Wiring (from `baseConfigurationReference` lines 482-483, 766-767, 905-906):

| Configuration | SkeenaSystem target xcconfig | Notes |
|---|---|---|
| `Debug` | none | Building under plain Debug would `fatalError("API_BASE_URL not configured")`. The team uses `DevTEST` instead of `Debug`. |
| `Release` | `Config/PROD.xcconfig` | Release reads PROD values. |
| `DevTEST` | `Config/DevTEST.xcconfig` | The default development scheme target. |
| `PROD` | `Config/PROD.xcconfig` | Explicit prod build. |

> DevTEST and PROD currently both point to `koyegehcwcrvxpfthkxq`. There is no environment-separated staging vs. prod today.

---

## Section 2 — Remote config awareness

**Finding B (with one nuance, unchanged from 2026-05-04).**

There is **no remote config fetch on app launch.** Greps for `remoteConfig`, `RemoteConfig`, `fetchConfig`, `appConfig`, `/config` → zero hits in `SkeenaSystem/`. `SkeenaSystemApp.init()` does no network I/O. `AuthService.init()` explicitly forbids it (`AuthService.swift:87-88`).

The app does have a **server-driven *community* config** — different concept. After login, `CommunityService.fetchMemberships()` (`Authentication/CommunityService.swift:103, 129`) does:

```swift
GET {projectURL}/rest/v1/user_communities?select=id,community_id,role,is_active,communities(...,logo_url,logo_asset_name,tagline,display_name,learn_url,custom_urls,donation_url,...,geography,units,community_types(id,name,entitlements))
```

This drives runtime overrides for branding (logo, name, tagline), entitlements, and geography. It does **not** override `API_BASE_URL` or `SUPABASE_ANON_KEY`. Those are compile-time only.

**Build-config-to-backend mapping today:**

| Build config | API_BASE_URL | SUPABASE_ANON_KEY (project ref) |
|---|---|---|
| `DevTEST` | `koyegehcwcrvxpfthkxq.supabase.co` | `koyegehcwcrvxpfthkxq` |
| `PROD` | `koyegehcwcrvxpfthkxq.supabase.co` | `koyegehcwcrvxpfthkxq` |
| `Release` | `koyegehcwcrvxpfthkxq.supabase.co` (uses PROD.xcconfig) | `koyegehcwcrvxpfthkxq` |
| `Debug` | unconfigured — fatalErrors | unconfigured |

---

## Section 3 — Edge function URLs

The app routes essentially **all** business logic through Supabase Edge Functions. **No fully-qualified hardcoded function URLs.** Every call site composes the URL from `projectURL` + a path read from `Info.plist` (xcconfig-defined) with a hardcoded path fallback if the key is missing.

### 3.1 Endpoints declared in `Environment.swift` (canonical accessors)

All defined in `SkeenaSystem/Config/Environment.swift`. Pattern: *"override → Info.plist key → hardcoded fallback path"*. Line numbers as of HEAD:

| Accessor | Info.plist key | Fallback path | Line |
|---|---|---|---|
| `uploadCatchURL` | `UPLOAD_CATCH_URL` | `/functions/v1/upload-catch-reports-v5` | 221-225 |
| `manageTripURL` | `MANAGE_TRIP_URL` | `/functions/v1/manage-trip` | 228-232 |
| `riverConditionsURL` | `RIVER_CONDITIONS_URL` | `/functions/v1/river-conditions` | 244-248 |
| `tacticsRecommendationsURL` | `TACTICS_RECOMMENDATIONS_URL` | `/functions/v1/tactics-recommendations` | 251-255 |
| `downloadCatchURL` | `DOWNLOAD_CATCH_URL` | `/functions/v1/download-catch-reports` | 258-262 |
| `anglerForecastURL` | `ANGLER_FORECAST_URL` | `/functions/v1/angler-forecast` | 265-269 |
| `classifiedLicensesURL` | `CLASSIFIED_LICENSES_URL` | `/functions/v1/classified-licenses` | 272-276 |
| `catchStoryURL` | `CATCH_STORY_URL` | `/functions/v1/catch-story` | 279-283 |
| `notesUploadURL` | `NOTES_UPLOAD_URL` | `/functions/v1/notes` | 286-290 |
| `anglerProfileURL` | `ANGLER_PROFILE_URL` | `/functions/v1/angler-profile` | 293-297 |
| `myProfileURL` | `MY_PROFILE_URL` | `/functions/v1/my-profile` | 300-304 |
| `deleteAccountURL` | `DELETE_ACCOUNT_URL` | `/functions/v1/delete-account` | 307-317 |
| `anglerContextURL` | `ANGLER_CONTEXT_URL` | `/functions/v1/angler-context` | 320-324 |
| `proficiencyURL` | `PROFICIENCY_URL` | `/functions/v1/proficiency` | 327-331 |
| `gearURL` | `GEAR_URL` | `/functions/v1/gear` | 334-338 |
| `observationsURL` | `OBSERVATIONS_URL` | `functions/v1/observations` | 341-351 |
| `opsTicketsURL` | `OPS_TICKETS_URL` | `functions/v1/ops-tickets` | 354-362 |

All derive their host from `projectURL` (i.e., `API_BASE_URL`). Updating `API_BASE_URL` redirects all of them in lockstep.

### 3.2 Endpoints not surfaced through `Environment.swift` but still derived from `projectURL`

| Call site | Path |
|---|---|
| `SkeenaSystem/Managers/UploadFarmedReports.swift:103` | `functions/v1/upload-no-catch-reports` |
| `SkeenaSystem/Authentication/CommunityService.swift:317` | `/functions/v1/join-community` |
| `SkeenaSystem/Authentication/CommunityService.swift:371` | `/rest/v1/community_addons` |
| `SkeenaSystem/Authentication/CommunityService.swift:129` | `/rest/v1/user_communities` |
| `SkeenaSystem/Authentication/AuthService.swift:203, 266` | `/auth/v1/signup` |
| `SkeenaSystem/Authentication/AuthService.swift:342, 922` | `/auth/v1/token` |
| `SkeenaSystem/Authentication/AuthService.swift:431` | `/auth/v1/recover` |
| `SkeenaSystem/Authentication/AuthService.swift:477` | `/auth/v1/logout` |
| `SkeenaSystem/Authentication/AuthService.swift:525, 746` | `/auth/v1/user` |
| `SkeenaSystem/Authentication/AuthService.swift:651` | `/functions/v1/my-profile` |
| `SkeenaSystem/Services/MapReportService.swift:62` | `/functions/v1/map-reports` |
| `SkeenaSystem/Services/WeatherSnapshotService.swift:61` | `/functions/v1/weather-snapshot` |
| `SkeenaSystem/Services/TripAPI.swift:40` | `/functions/v1/manage-trip` (via `MANAGE_TRIP_PATH`) |
| `SkeenaSystem/Views/Guide/AnglerProfilesView.swift:244, 248` | `/functions/v1/trip-roster`, `/functions/v1/member-details` |
| `SkeenaSystem/Views/Angler/AnglerFlights.swift:97, 104` | `/functions/v1/flight-details`, `/functions/v1/flight-status` |
| `SkeenaSystem/Views/Public/PublicLandingView.swift:24` | `/functions/v1/download-catch-reports` |
| `SkeenaSystem/Views/Angler/AnglerLandingView.swift:32` | `/functions/v1/download-catch-reports` |
| `SkeenaSystem/Views/Angler/MeetStaff.swift:20` | `/functions/v1/staff-bios` |
| `SkeenaSystem/Views/Angler/StaffDetailView.swift:20` | `/functions/v1/staff-bio-detail` |
| `SkeenaSystem/Views/Guide/MemberRegistrationView.swift:15` | `/auth/v1/signup` |

**No call site uses a string-literal full URL with `koyegehcwcrvxpfthkxq` baked in.** Confirmed by grepping `koyegehcwcrvxpfthkxq` across `**/*.swift` — only test-comment hits remain (`SkeenaSystemTests/APITests/BackendHealthSmokeTests.swift:7`).

### 3.3 Edge functions referenced anywhere (deduplicated)

`upload-catch-reports-v5`, `upload-no-catch-reports`, `manage-trip`, `download-catch-reports`, `river-conditions`, `tactics-recommendations`, `angler-forecast`, `angler-profile`, `angler-context`, `angler-details`, `my-profile`, `delete-account`, `proficiency`, `gear`, `member-profile-fields`, `member-details`, `classified-licenses`, `catch-story`, `notes`, `trip-roster`, `observations`, `ops-tickets`, `staff-bios`, `staff-bio-detail`, `flight-details`, `flight-status`, `join-community`, `map-reports`, `weather-snapshot`.

All of these need to exist on the new `skeena-prod` project on cutover, with the same request/response contracts.

### 3.4 Δ — `join-community` request shape changed

`Authentication/CommunityService.swift:307-355`. Body now includes `member_number` (`MemberNumber`-normalized 9-char code from invite email):

```swift
let body: [String: String] = [
    "community_code": code.uppercased(),
    "member_number": memNum,      // ← added 2026-05-04
    "role": role
]
```

Server-side response codes the iOS client maps:
- 200 → success
- 400 → `invalidCodeFormat`
- 403 → `invalidMemberNumber` (new)
- 404 → `invalidCode`

The new project's `/functions/v1/join-community` must accept the `member_number` field and return the appropriate 4xx codes. If the new function silently ignores `member_number`, anyone can join any community using just the 6-char code — a regression worth flagging to the backend team.

### 3.5 Δ — `MapReportService` now sends bearer token

`Services/MapReportService.swift:85-89` (rewritten 2026-05-04 in commit `a88a49c`):

```swift
req.setValue(AppEnvironment.shared.anonKey, forHTTPHeaderField: "apikey")

if let token = await AuthService.shared.currentAccessToken(), !token.isEmpty {
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
}
```

The endpoint accepts both the anon `apikey` and a per-user JWT now. RLS policies on `/functions/v1/map-reports` on the new project should accommodate this: the function may perform per-user filtering when the JWT is present (e.g., the new researcher-scoped map at `Views/Researcher/...` relies on this).

---

## Section 4 — Storage URL handling

**Finding: the iOS app does not construct `/storage/v1/...` URLs anywhere in production code.**

Greps for `/storage/v1`, `object/public`, `object/sign`, `createSignedURL`, `bucket`, `voice-notes` in `SkeenaSystem/` return zero production hits. The only matches are:

- `SkeenaSystemTests/Guide/GuideLandingRegressionTests.swift:121, 340` — inside a `MockURLProtocol` stub that intercepts requests in unit tests. They do not hit the network.

### 4.1 How storage actually flows in this app (unchanged)

1. **Photos / videos for catch reports** — uploaded as base64 / multipart **inside the JSON body of `/functions/v1/upload-catch-reports-v5`**, not via direct storage uploads. Edge function writes to a bucket server-side. (See `SkeenaSystem/Managers/UploadCatchReport.swift`.)
2. **Voice notes** — uploaded as audio bytes in the multipart body of `/functions/v1/notes` (`NOTES_UPLOAD_URL`, `Environment.swift:286-290`, `DevTEST.xcconfig:57`). The iOS app **never** references a `voice-notes` bucket name, never builds a `voice-notes` URL, never reads a public `voice-notes` URL.
3. **Observations audio** — uploaded as DTO with embedded base64 audio (`AudioDTO`, `SkeenaSystem/Managers/UploadObservations.swift:127, 174-201`) inside the body of `/functions/v1/observations`.
4. **Community logos** (and `donation_url`, `learn_url`, `custom_urls`) — server-supplied URL strings stored in the `communities` table, surfaced through `CommunityService.fetchMemberships()` and rendered with plain `AsyncImage(url:)` (`Views/Components/CommunityLogoView.swift:22`). The app trusts whatever URL the backend hands it.

### 4.2 voice-notes bucket — public → private flip

**No iOS change required.** The iOS client never directly addresses the `voice-notes` bucket. The flip is invisible to it as long as `/functions/v1/notes` and `/functions/v1/observations` continue to accept the documented upload contracts.

The only fragility: if any **server-supplied URL string** in `communities.logo_url`, `donation_url`, `custom_urls[].url` happens to be a public storage URL pointing at the *old* project, those rows must be re-uploaded to the new project's storage before cutover.

---

## Section 5 — Auth flow

Implementation in `SkeenaSystem/Authentication/AuthService.swift` (~1396 lines as of HEAD). Hand-rolled GoTrue-compatible client over `URLSession`.

### 5.1 Login flow (`signIn`, line 326-427)

1. POST `{projectURL}/auth/v1/token?grant_type=password` with `{"email":..., "password":...}` JSON body, header `apikey: <ANON_KEY>`.
2. On 2xx → decode `TokenResponse {access_token, refresh_token, expires_in}`. Persist tokens (5.2). Then `loadUserProfile()` (`/auth/v1/user` → `/functions/v1/my-profile`) populates role + member fields. Set `isAuthenticated = true`.
3. On HTTP error → mapped via `mapAuthHTTPError` (`AuthService.swift:153-178`): 400/401 → `.invalidCredentials` or `.emailNotConfirmed`, 429 → `.rateLimited`, 5xx → `.serverUnavailable`.
4. On `URLError` → fall back to **offline cached credentials** (Section 5.4) if email + password match what was stored locally; restore cached profile and set `isAuthenticated = true`.

### 5.2 Token caching (`persistTokens`, line ~1116-1130)

Stored in Keychain via the local `Keychain` enum (accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`):

| Account key | Contents |
|---|---|
| `epicwaters.auth.access_token` | Latest access JWT |
| `epicwaters.auth.refresh_token` | Latest refresh token |
| `epicwaters.auth.access_token_exp` | Unix epoch seconds for access expiry |

Validity check (`isJWTValid`): valid if `exp - now > 120s`. Falls back to decoding the JWT's `exp` claim if no stored expiry.

### 5.3 Refresh token flow (`refreshAccessToken`, line ~893-1025)

POST `{projectURL}/auth/v1/token?grant_type=refresh_token` with form-encoded body.

- 2xx → persist new tokens (handles refresh-token rotation).
- **400 / 401 → hard failure**: calls `handleRefreshFailure()`, which calls `clearStoredTokens()` (deletes Keychain access/refresh/exp), `AuthStore.shared.clear()`, `CommunityService.shared.clear()`, sets `isAuthenticated = false`. Sign-out is observable to UI.
- 429 / 5xx → retried once after 1-second sleep.
- Network error → tokens preserved.

A serial `refreshTask` + `refreshQueue` ensures only one refresh runs at a time across concurrent callers.

### 5.4 Auth failure behavior (and offline caching)

- **Hard refresh failure (400/401)**: tokens cleared, `isAuthenticated = false`, `CommunityService` cleared. The user is bumped to login. **No interstitial UI** — looks like normal sign-out. The user logs in again.
- **Offline cached credentials** (line ~1073-1101): when "Remember Me" is on, email is stored in `UserDefaults["OfflineLastEmail"]` and password in Keychain account `OfflinePassword`. Cached profile fields (firstName, lastName, userType, memberId) are also stored in `UserDefaults`.
- **Biometric / FaceID** (line ~857-879): triggers `LAContext.evaluatePolicy`, then attempts session resume from stored refresh token; if that fails, uses cached offline credentials.

### 5.5 Cutover behavior — confirming expected behavior

For the migration:

- bcrypt-transplant preserves passwords on the new project.
- **Currently-stored access_token and refresh_token are signed with the old project's JWT secret.** On cutover, the next call to `/auth/v1/token?grant_type=refresh_token` against the new project will return **400/401**. That triggers `handleRefreshFailure`:
  1. Clears Keychain.
  2. Sets `isAuthenticated = false`.
  3. Clears the active community.
- The user lands on `LoginView`, types email + password, the new project's GoTrue verifies via the transplanted bcrypt hash, issues fresh tokens. **App handles this cleanly.**

### 5.6 Δ — Cold-launch hydration changes the visible UX

Previously on a cold launch with stale tokens, `AuthService.init` set only `isAuthenticated = true` (because a stored refresh token existed). `currentUserType` etc. stayed nil, so `AppRootView` displayed a loading spinner waiting for `loadUserProfile()` to run.

Since commit `6af6a9f` (2026-05-04), `AuthService.init` now calls `loadCachedAuthState()` (lines 95-137) and synchronously hydrates `currentUserType`, `currentFirstName`, `currentLastName`, `currentMemberId` from `UserDefaults` so the role-based landing view renders immediately. Locked by `SkeenaSystemTests/Authentication/OfflineColdLaunchRoutingTests.swift`.

**Migration implication:** on first cold launch after cutover, a previously-signed-in user will see **their role's landing view** (cached), then any network call (which the landing view immediately makes — typically `fetchMemberships`, `download-catch-reports`, etc.) will trigger the access-token refresh, fail with 400/401, and bounce them to `LoginView`. The UX flicker is **landing → login** rather than **spinner → login**. Functionally fine; cosmetically slightly weirder. Worth a release-note line: *"You'll be asked to sign in again after this update — your password hasn't changed."*

---

## Section 6 — What changes are needed for Wednesday

> **Most of the cutover is two xcconfig edits + a fresh anon key.** No Swift logic changes are required.

### 6.1 Required iOS changes

#### Change 1 — Update `PROD.xcconfig` to point at `skeena-prod`

**File:** `SkeenaSystem/Config/PROD.xcconfig:13-15`

```xcconfig
# CURRENT
SUPABASE_PROJECT_URL = https://koyegehcwcrvxpfthkxq.supabase.co
API_BASE_URL = koyegehcwcrvxpfthkxq.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtveWVnZWhjd2NydnhwZnRoa3hxIiwicm9sZSI6ImFub24i...

# AFTER
SUPABASE_PROJECT_URL = https://<NEW_PROJECT_REF>.supabase.co
API_BASE_URL = <NEW_PROJECT_REF>.supabase.co
SUPABASE_ANON_KEY = <NEW_PROJECT_ANON_KEY_JWT>
```

**Why:** Single source of truth for Release/PROD builds. ~30 indirect call sites pick up the new values automatically.
**Effort:** 5 minutes.

#### Change 2 — Update `DevTEST.xcconfig`

**File:** `SkeenaSystem/Config/DevTEST.xcconfig:12-14`

Same edit as Change 1 with the staging or prod ref of your choice.
**Effort:** 5 minutes.

#### Change 3 — Verify the comment in `BackendHealthSmokeTests.swift:7`

Cosmetic — the comment will be wrong post-cutover. Test logic reads `AppEnvironment.shared.anonKey` so it's already dynamic.
**Effort:** 2 minutes.

#### Change 4 — Widen DevTEST log filter for cutover smoke tests

**File:** `SkeenaSystem/Config/DevTEST.xcconfig:19`

```xcconfig
# CURRENT (silences auth/community/network logs — bad for cutover triage)
LOG_CATEGORIES = catch, ml

# RECOMMENDED FOR CUTOVER
LOG_CATEGORIES = auth, community, network, upload, catch, ml
```

**Why:** With the current filter, when DevTEST builds hit the new backend and (e.g.) `fetchMemberships` returns an empty array because RLS isn't permissive enough, the iOS-side log silently shows nothing under `.community` — making remote diagnosis hard. Widen for the cutover window, narrow back after.
**Effort:** 1 minute. Revert after cutover.

#### Change 5 — None needed for storage / voice-notes bucket flip

No Swift change required (Section 4).

#### Change 6 — None needed for tokens / auth invalidation

`handleRefreshFailure` already does the right thing on 400/401 (Section 5.5).

#### Change 7 — None needed for edge function URLs

All edge function URLs derive from `projectURL` + path (Section 3).

### 6.2 Optional follow-up (not for Wednesday)

Add a true Finding-A remote config fetch in `AppRootView.task` that returns `{api_base_url, anon_key}` and use the existing `AppEnvironment.overrideProjectURL` / `overrideAnonKey` hooks (`Environment.swift:26-27`). Lets you flip backends without an App Store release. **Effort: ~4-6 hours** including offline cache, fail-closed-to-bundled-defaults, and a basic cache-busting key. Out of scope.

### 6.3 Cumulative iOS effort

| Item | Hours |
|---|---|
| Edit PROD.xcconfig | 0.1 |
| Edit DevTEST.xcconfig | 0.1 |
| Widen `LOG_CATEGORIES` for cutover | 0.05 |
| Update test comment | 0.05 |
| Build + smoke-test on simulator (DevTEST + PROD) | 0.5 – 1.0 |
| Test plan execution (Section 8) | 1.5 – 3.0 |
| **Total** | **~2.5 – 5 hours** |

---

## Section 7 — Risk assessment

### 7.1 Cached auth tokens from old project

- **Behavior:** access_token will be expired (or close to it) for most users; on first network call, `currentAccessToken` triggers `refreshAccessToken` → `/auth/v1/token?grant_type=refresh_token` on the **new** project → 400/401 → `handleRefreshFailure` clears Keychain, signs out, kicks to LoginView.
- **Risk:** Low. Sign-out is graceful.
- **Δ from prior audit:** with cold-launch hydration (Section 5.6), the visible UX is now *landing → login* rather than *spinner → login* on cold restart. Feels slightly weirder — consider a release-note line.
- **Mitigation:** None code-side.

### 7.2 Cached storage URLs from old project (e.g., already-cached voice notes)

- **Voice notes:** the iOS app does not store remote voice-note URLs. After upload, voice notes are referenced server-side; the iOS app holds only `UUID` + local file (`SkeenaSystem/Managers/VoiceNoteStore.swift` / `Views/Guide/VoiceNoteView.swift`). **No cached URLs to invalidate.**
- **Community logos / donation links / learn URLs:** stored as `String` in `CommunityConfig` and persisted to `UserDefaults` for cold-launch rendering (`Authentication/CommunityService.swift:70-73, kActiveCommunityConfig`). On first post-cutover login, `fetchMemberships` overwrites with whatever the new project returns. **Risk only if the new project's `communities` rows still hold strings pointing at `koyegehcwcrvxpfthkxq.supabase.co/storage/...`.** Server-side data-migration concern.
- **AsyncImage cache:** SwiftUI's `AsyncImage` caches in `URLCache.shared`. Old logo URLs will fail with 404 once the old project is wound down; AsyncImage degrades to placeholder.

### 7.3 Offline behavior during cutover

- A fully-offline user with a not-yet-expired cached access_token stays "logged in" locally — `isJWTValid` only checks expiry, not signature.
- The instant they go online and any API call is made, the access token will fail signature verification on the new project → triggers refresh → 400/401 → forced logout. Same flow as 7.1.
- An offline user with cached "remember-me" credentials but no valid token: `canSignInOffline` lets them sign in locally. They stay in this offline state until network returns.
- **Risk:** Low — no half-authenticated state; the worst case is a forced re-login.

### 7.4 AI feature calls

The iOS app has no direct calls to OpenAI / Anthropic / etc. AI features (catch story generation, tactics recommendations, river conditions narrative, angler-forecast, angler-context, conditions-recall) all hit edge functions. Photo analysis is on-device (CoreML / MediaPipe) — backend-independent.

If those edge functions are deployed on `skeena-prod` with their secrets wired up (`OPENAI_API_KEY`, etc.), the iOS app hits them through `projectURL` and they "just work." **No separate URL configuration for AI calls.** Risk: redeploying the edge functions to the new project without their secrets configured — iOS would see 5xx and surface a generic error.

### 7.5 Other notable risks

- **`mapAuthHTTPError` substring matching** (`AuthService.swift:153-178`) is sensitive to GoTrue version differences. If the new project runs a different GoTrue version, error copy may regress to generic.
- **`joinCommunity` member_number requirement** (Section 3.4) — if the new edge function silently ignores `member_number`, the security guard becomes invisible. Worth confirming with the backend team that the new function rejects requests where the supplied `member_number` doesn't match an invite row.
- **MapReportService now sends bearer token** (Section 3.5) — RLS or the function logic on the new project must allow authenticated requests in addition to the anon `apikey`.
- **PROD.xcconfig Mapbox token** (`PROD.xcconfig:89`: `MAPBOX_ACCESS_TOKEN = YOUR_MAPBOX_TOKEN_HERE`) — a placeholder. If Release builds use this xcconfig, Mapbox is broken in Release today. Pre-existing, not migration-caused.
- **`BETA_RELEASE = true`** (`DevTEST.xcconfig:20`) — no Swift readers, appears informational. Worth confirming nothing on the new backend gates by it.

---

## Section 8 — Test plan suggestions

The repo now has **five** xctestplans (was three on 2026-05-04). New ones bolded:

- `SmokeTests.xctestplan` — fastest sanity (`AppLaunchSmokeTests`, `AuthSmokeTests`, `BackendHealthSmokeTests`).
- `PostLoginTests.xctestplan` — authed flows (Onboarding, Home, RecordActivity, FisheriesConditions, Profile, Community, Explore, Privacy, MLTrainingOptOutUpload).
- `RegressionTests.xctestplan` — `PublicUserAPITests` + `PublicUserFlowTests`.
- **`UnitTests.xctestplan`** — `SkeenaSystemTests` minus `BackendHealthSmokeTests`, `MLTrainingOptOutUploadTests`, `PublicUserAPITests` (i.e., everything that doesn't need network).
- **`UITests.xctestplan`** — `SkeenaSystemUITests` only.

Run all five against the new backend before flipping users.

### 8.1 Specific user journeys

These map to the auth flow and the most-trafficked edge functions:

1. **Cold launch → Login** with a known-good email/password (Public + Guide + Angler + Researcher accounts). Verifies `/auth/v1/token` and `/auth/v1/user` and `/functions/v1/my-profile` and `/rest/v1/user_communities`.
2. **Refresh token rotation across an app restart.** Sign in, kill the app, relaunch, observe `/auth/v1/token?grant_type=refresh_token` returns a fresh access token.
3. **Forced refresh-token failure path.** Use `-resetAuthForUITests` (`SkeenaSystemApp.swift:17-21`) or hand-edit Keychain to leave a stale token, then attempt sign-in — confirm clean bump to LoginView.
4. **Cold-launch with stale tokens (cutover-specific).** New: leave stale tokens in Keychain *and* cached profile fields in UserDefaults, cold-launch the app, watch it route to (e.g.) the Guide landing view, then observe the first network call (catch list, map reports, conditions tile) trigger `handleRefreshFailure` and flip to LoginView. Confirms the `OfflineColdLaunchRoutingTests` behavior under live conditions.
5. **Sign up new user** — `/auth/v1/signup` (no community code, with community code, and invite-based via `signUpWithInvite`).
6. **Join community with member number** — `/functions/v1/join-community` with `community_code` + `member_number`. Verify 400, 403, and 404 paths return the right friendly copy via `CommunityError`. Confirms the new function honors the `member_number` validation.
7. **Catch report upload** — `/functions/v1/upload-catch-reports-v5`. Confirms photo bytes survive the round-trip and end up in the new project's storage.
8. **Voice note attached to a catch** — `/functions/v1/notes`. Confirms the `voice-notes` bucket privacy flip didn't break the upload path. Verify the audio plays back when the report is fetched again.
9. **Researcher observation upload** — `/functions/v1/observations` with embedded audio.
10. **Catch story generation** — `/functions/v1/catch-story` (kicks off AI gen); validates AI secrets are wired up on the new project.
11. **Conditions recall fishery map** (new since 2026-05-04) — `/functions/v1/map-reports` with bearer token. Validates the auth-augmented call site.
12. **Researcher map** — same endpoint, scoped to `member_id`. Validates per-user RLS / function logic.
13. **Community switching** — `CommunityPickerView`, `CommunitySwitcherView`. Confirms `fetchMemberships` returns the new community's `logo_url`, `geography`, and entitlements.
14. **Sign out then sign back in** — `/auth/v1/logout` then `/auth/v1/token`.
15. **Password reset** — `/auth/v1/recover`. Confirms the new project's email templates fire and the reset link works.
16. **Delete account** — `/functions/v1/delete-account`.
17. **Inactive member view** (new) — sign in as a deactivated member, confirm the `InactiveMemberView` renders and its logout button (added 2026-05-04) clears auth state.

### 8.2 Specific error scenarios

- **Bad password** → mapped to `.invalidCredentials`. Confirms the new GoTrue's error body contains the substrings the mapper looks for (`AuthService.swift:153-178`: "invalid login", "invalid email or password", "invalid credentials"). **Mapping is fragile** — if Supabase changes wording on the new instance, friendly copy regresses to generic.
- **Unconfirmed email** → `/auth/v1/signup` then attempted `/auth/v1/token` should yield "email not confirmed" → `.emailNotConfirmed`.
- **Rate limit (429)** → "Too many attempts."
- **Network drop mid-sign-in** → forces the offline path; with a remembered user, fall through to cached credentials.
- **Stale refresh token** (the cutover scenario) — verified in 8.1 #3 and #4.
- **Wrong `member_number` on join-community** → expect 403 → `invalidMemberNumber` copy.
- **Missing `Info.plist` keys** — `AppEnvironment` `fatalError`s on missing `API_BASE_URL` or `SUPABASE_ANON_KEY`. If a paste-typo causes either to be empty post-edit, the app crashes at first read.

### 8.3 Things the codebase suggests are fragile

- **`mapAuthHTTPError` substring matching** — sensitive to GoTrue version differences.
- **`SynchTrips.anonKey()`** (`Managers/SynchTrips.swift:136-145`) silently returns `""` on empty. Misconfigured anon key produces silent 401s on trip uploads.
- **Offline-credentials path** (`AuthService.swift:1073-1101`): plaintext password compare. Unchanged from prior audit.
- **`CommunityService.fetchMemberships` is the gate on the entire app** — if `/rest/v1/user_communities` returns the wrong shape, RLS blocks the user, or the join to `community_types` fails, the user lands on `CommunityPickerView` with nothing selectable. **Most likely visible failure mode if RLS policies are imported imperfectly to the new project.** Verify `user_communities` SELECT RLS on `skeena-prod` returns rows for an authenticated user.
- **`AsyncImage` for community logos is unauthenticated** — if the new project's `logo_url` rows point to **private** storage URLs (not signed URLs), images fail silently → placeholder.
- **DevTEST log filter** (`LOG_CATEGORIES = catch, ml`) — silences the diagnostic categories most likely to reveal cutover problems. Widen during cutover.

---

## Appendix — File quick reference

- Config (xcconfig + Swift accessor): `SkeenaSystem/Config/{DevTEST,PROD}.xcconfig`, `SkeenaSystem/Config/Environment.swift`, `SkeenaSystem/Info.plist`
- Legal URL constants (external, non-Supabase): `SkeenaSystem/Config/LegalURLs.swift` (new since prior audit)
- Auth: `SkeenaSystem/Authentication/AuthService.swift`, `SkeenaSystem/Authentication/CommunityService.swift`
- App entry: `SkeenaSystem/SkeenaSystemApp.swift`
- Project file (build configs): `SkeenaSystem.xcodeproj/project.pbxproj`
- API utility: `SkeenaSystem/Services/APIURLUtilities.swift` (used by `SynchTrips.swift:94-95`)
- Test plans: `SmokeTests.xctestplan`, `PostLoginTests.xctestplan`, `RegressionTests.xctestplan`, `UnitTests.xctestplan`, `UITests.xctestplan`
- Cold-launch routing regression: `SkeenaSystemTests/Authentication/OfflineColdLaunchRoutingTests.swift`
- Backend reference (regenerate before cutover): `docs/api-reference.md` (run `/sync-api`)
