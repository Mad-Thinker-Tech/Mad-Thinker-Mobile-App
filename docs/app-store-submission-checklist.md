# App Store Submission Checklist — Mad Thinker (SkeenaSystem)

Audit performed: 2026-05-13
Submission type: First-time submission
Bundle ID: `com.app.madthinker`
Display name: `Mad Thinker`
Marketing version: `1.0.2` (Release config)

Legend: `[x]` verified in code/config · `[ ]` not done / needs action · `[?]` needs your input

---

## A. BLOCKERS — must be fixed before you can ship

These will either fail the binary upload or trigger an immediate App Review rejection.

- [ ] **App icon has an alpha channel.** `SkeenaSystem/Assets.xcassets/AppIcon.appiconset/MTScript.png` is 1024×1024 8-bit RGBA. App Store Connect rejects icon uploads with transparency. **Action:** re-export as RGB (no alpha), flatten onto an opaque background, replace the file.
- [ ] **Mapbox token is a placeholder in PROD.** `SkeenaSystem/Config/PROD.xcconfig` line 96 has `MAPBOX_ACCESS_TOKEN = YOUR_MAPBOX_TOKEN_HERE`. Maps will fail at runtime in the App Store build. **Action:** either inject the real `pk.*` token via CI before the Release archive, or temporarily commit a non-secret restricted public token to PROD.xcconfig.
- [ ] **Associated-domains entitlement still has a placeholder.** `SkeenaSystem/SkeenaSystem.entitlements` line 11 = `applinks:PLACEHOLDER_DOMAIN`. No code actually handles universal links, so the safe fix is **remove the `com.apple.developer.associated-domains` key entirely** from the entitlements file. (Leaving the placeholder will cause provisioning-profile / capability mismatches at upload.)
- [ ] **Sign in with Apple entitlement is enabled but unused.** `com.apple.developer.applesignin` is in the entitlements file, but there are no `ASAuthorization` / `AuthenticationServices` call sites anywhere in `SkeenaSystem/`. Since the app only offers email/password sign-in (no Google/Facebook/etc.), Sign in with Apple is **not required** by Apple's guidelines. **Action:** either implement it, or remove the entitlement to avoid an unused-capability flag.
- [ ] **Speech-recognition usage string is misleading.** The Info plist string says "We transcribe your field notes **on device** for quick review", but `VoiceNoteView.swift:446` sets `request.requiresOnDeviceRecognition = false` initially and only flips it to `onDeviceRecognition` if the device reports `supportsOnDeviceRecognition`. When that's false, audio goes to Apple's servers. **Action:** either force `requiresOnDeviceRecognition = true` and bail gracefully when unsupported, or rewrite the usage string to "We transcribe your field notes for quick review" (drop "on device").

## B. HIGH-PRIORITY — fix before submitting, low risk of review delay if missed but recommended

- [ ] **iOS deployment target inconsistency between configs.** The app target uses `IPHONEOS_DEPLOYMENT_TARGET = 16.6` in some configs and `26.0` in others (and `26.2` on the test targets). For Release/PROD it's `16.6`, which is what App Store will ship — that part is fine — but the inter-config drift means a debug build may compile against APIs unavailable on 16.6 without you noticing. **Action:** confirm the intended minimum, then unify Debug & Release for the app target.
- [ ] **Marketing version split.** App target = `1.0.2`; test targets = `1.0`. The version that ships is `1.0.2`. Decide if `1.0.2` is really how you want a first submission to enter the App Store (Apple has no policy against it, but some teams prefer `1.0.0`). Build number (`CURRENT_PROJECT_VERSION`) is `1` — that's fine for first upload.
- [?] **App display name disagreement.** Info plist is wired so `APP_DISPLAY_NAME` from PROD.xcconfig (`Bend Fly Shop`) flows through, but `INFOPLIST_KEY_CFBundleDisplayName` in pbxproj is hard-coded to `Mad Thinker` and will override it on the home screen. Confirm which name should appear under the icon, then make the two agree.
- [ ] **PrivacyInfo manifest declares Audio Data, Crash Data, Performance Data, and Other Diagnostic Data, but the app has no crash-reporting / analytics SDK** (no Firebase / Crashlytics / Sentry / Mixpanel / Amplitude / Segment in the codebase). Over-declaring is not a rejection, but it inflates your App Privacy "nutrition label". **Action:** either remove the unused entries, or confirm you plan to add an analytics SDK before submission.
- [ ] **Privacy manifest entry `NSPrivacyCollectedDataTypeName`** — confirm the app collects a user's name (display name on signup?). If not, remove that entry.
- [ ] **iPhone-only landscape support is asymmetric.** `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` allows landscape; iPad supports all four orientations. Apple will test rotation in review. Verify every view (especially `CatchChatViewModel` chat UI, `ReportsListView`, map views) renders correctly in landscape — or lock orientation to portrait to skip the issue.
- [ ] **iPad support is declared (`TARGETED_DEVICE_FAMILY = "1,2"`)** but I didn't see iPad-specific layouts. If you don't intend to support iPad on day one, change to `"1"` (iPhone only) — otherwise Apple will test on iPad and reject for broken layout.

## C. CODE/CONFIG — verified by audit

- [x] `ITSAppUsesNonExemptEncryption = false` in Info.plist (you use only standard HTTPS — exempt).
- [x] All required usage strings present in `INFOPLIST_KEY_*` build settings: camera, photo library (read + add), microphone, face ID, location (when-in-use), speech recognition.
- [x] No `NSAllowsArbitraryLoads`; no `http://` requests; all backend hosts are HTTPS (`*.supabase.co`, `madthinkertech.com`, `howtoflyfish.orvis.com`, `img.youtube.com`).
- [x] No `NSLocationAlwaysAndWhenInUseUsageDescription` requested — code only asks for "when in use". No `UIBackgroundModes` for `location`. So this is **not** a background-location app in Apple's sense, even though you selected "background location" in the prompt. (Heads up: if you ever flip to always-allow, you also need a justified usage string + screenshot of in-context prompt.)
- [x] `PrivacyInfo.xcprivacy` is present and declares: email, user ID, precise location, photos/videos, audio data, product interaction, plus `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (app functionality). `NSPrivacyTracking = false`, no tracking domains.
- [x] In-app account deletion is wired — `ManageProfileView.swift:362` `deleteAccountButton` POSTs to `/functions/v1/delete-account`. Required since iOS submissions June 2022.
- [x] Privacy policy URL (`https://madthinkertech.com/privacy-policy`) and acceptable-use URL exist in `SkeenaSystem/Config/LegalURLs.swift`.
- [x] `Secrets.xcconfig` is gitignored and not tracked. (Confirm your real Mapbox token + any other secrets get injected during the Release build.)
- [x] Supabase anon key in `PROD.xcconfig` is correctly the **anon** role (`"role":"anon"`), not service-role. Anon keys are designed to be shipped client-side — safe.
- [x] No third-party SSO (Google / Facebook / etc.) in the codebase, so Sign in with Apple is not mandatory.
- [x] Launch screen is auto-generated (`INFOPLIST_KEY_UILaunchScreen_Generation = YES`). Acceptable; if you want a branded splash, add a `UILaunchScreen` storyboard.
- [x] No push notification entitlement / code → no APNs setup required.
- [x] Encryption export: HTTPS-only qualifies for the standard exemption; flag is set correctly.

## D. App Store Connect — non-code items you said are ready, but worth verifying line-by-line

You said assets are ready; treat this as a final cross-check.

- [?] App Store Connect record created under bundle `com.app.madthinker`
- [?] App name (≤30 chars), subtitle (≤30 chars), promotional text (≤170), description, keywords (≤100)
- [?] Primary + secondary category chosen (likely Sports or Lifestyle; Reference also plausible)
- [?] Age rating filled out — your app has **user-generated content via SocialFeed** + the ability for guides to write field notes. Even though SocialFeed appears to be a placeholder right now (see Section F), if it's enabled in the shipped build you must declare 4+ rating with UGC questions, and you must implement the UGC moderation tools below.
- [?] Screenshots: 6.5" (iPhone 14 Pro Max class) **required**; 6.7" / 6.9" recommended; iPad 13" required because device family includes iPad
- [?] App Preview videos (optional)
- [?] App Store icon (1024×1024, RGB, **no transparency** — same file rule as in Section A)
- [?] Privacy Policy URL + Support URL configured in App Store Connect
- [?] **App Privacy nutrition label** filled out in App Store Connect — the answers must match what's in `PrivacyInfo.xcprivacy`. Mismatch is a common rejection reason.
- [?] Demo account credentials supplied for App Review (you have email/password auth — Apple **will** need a test login, and most likely a test account that exercises Angler, Guide, Researcher, **and** Public roles, since reviewers will look for role-gated UI)
- [?] Sign-in instructions in App Review notes (especially if Guide/Researcher onboarding requires invite codes — `AuthService.signUpWithInvite` exists)
- [?] Export compliance answered "No" (HTTPS-only) in App Store Connect — must match the Info.plist flag
- [?] Content Rights (do you contain or access third-party content?) — Mapbox tiles + Orvis video links count
- [?] Advertising Identifier (IDFA) — **No**, you don't use AdSupport

## E. Apple Developer / Signing

- [?] Apple Developer Program membership active under the team that owns `com.app.madthinker`
- [?] App ID `com.app.madthinker` created in Developer portal with the **Sign in with Apple** and **Associated Domains** capabilities matching the entitlements file (and once you remove those entitlements per Section A, regenerate provisioning profiles)
- [?] Distribution certificate + App Store provisioning profile installed
- [?] TestFlight build is signed with the **App Store** profile (the external TestFlight history confirms signing works — but verify the next archive uses the right profile)
- [?] Archive in Xcode with `Generic iOS Device` destination, then Window → Organizer → Distribute App → App Store Connect

## F. Sensitive features review (you selected "Account sign-in" + "Background location")

### Account creation / sign-in
- [x] Email/password sign-in (`AuthService.signIn`) — fine
- [x] Invite-code signup (`signUpWithInvite`) — fine
- [x] In-app account deletion — fine
- [ ] **Make sure the App Review demo account works on a clean install** and has access to enough sample data to demonstrate the value prop (catch list, photos, social feed). Reviewers usually only see what the demo account sees.
- [ ] If you collect a date of birth or display age-gating, document it. Doesn't look like you do.

### Location (when-in-use)
- [x] Only requests when-in-use; no background-location entitlement
- [x] Usage string is specific to the catch-tagging feature ("Your location tags each catch report with the river or water body where you caught the fish")
- [ ] You answered "background location" in our prompt — confirm whether you want that capability. If yes, this becomes substantially more involved (separate `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes` entry, justified review note explaining why background is required). If no, leave as-is.

### Social feed / UGC (worth flagging since the codebase has `SocialFeedView`)
- [?] `SocialFeedView.swift` is marked as a "Placeholder Instagram-style social feed". Reviewers **will** tap on it. If it shows real users' photos/posts in the shipped build, Apple Guideline 1.2 kicks in and you'll need:
  - Content reporting mechanism (no `reportContent` / `reportAbuse` code currently exists)
  - User blocking
  - A method to filter objectionable material
  - A way for the developer to remove offending users
  Action: either disable / hide `SocialFeedView` from the shipped build via a feature flag, or implement the four UGC items above before submitting.

## G. Functional / on-device verification (do these on a real device with the Release archive)

- [ ] First-launch flow works end-to-end with no developer-only assumptions
- [ ] All three permission prompts (Location, Camera, Photo Library, Microphone, Speech) display the right strings and the app degrades gracefully on Deny
- [ ] Take a photo → analyze → estimate length → upload — full ML pipeline runs on at least one supported lowest-spec device (iPhone 12 or thereabouts if minimum is iOS 16.6)
- [ ] Account deletion actually deletes the record (or schedules deletion) — Apple sometimes tests this
- [ ] No console references to internal infrastructure that could embarrass you in App Review (debug logs are fine, but no internal hostnames or `TODO:` toasts shown to the user)
- [ ] App handles airplane mode / no-connectivity (you have offline catch storage — verify the offline path)
- [ ] Memory / battery test for the ML pipeline (CoreML + MediaPipe + ViT) — Apple sometimes pings apps that drain battery aggressively
- [ ] VoiceOver: at minimum the primary flow (sign in, capture catch, view report) should be navigable. Spot-check `accessibilityIdentifier` coverage — looks like you've already added these for testing, which helps.

---

## Open questions for you (Geoff)

1. The 1024×1024 app icon is RGBA — do you have a flat (no transparency) PNG ready, or should I help you flatten it?
2. Sign in with Apple entitlement: you don't use it. Remove it, or are you planning to add SIWA before launch?
3. Universal links: `applinks:PLACEHOLDER_DOMAIN` — what's the real domain (or remove)?
4. Background location: you selected it in the prompt, but the code only asks for when-in-use. Was that intentional?
5. SocialFeedView is a placeholder — is it visible in the shipped build? If yes, we need to implement UGC reporting/blocking; if no, gate it behind a feature flag.
6. App name on the home screen: `Mad Thinker` (from pbxproj) or `Bend Fly Shop` (from PROD.xcconfig)?
7. Mapbox token: do you have a real production token you can paste into PROD.xcconfig (or wire into CI), and should it be URL-restricted to your app's bundle ID?
8. Crash/analytics SDK: are you planning to add one before launch (so the PrivacyInfo manifest entries make sense), or should I trim them out?

Once those are settled, the path to "submit" should be: rebuild icon → flip entitlements → update usage string → archive → upload → fill the App Store Connect metadata → submit.
