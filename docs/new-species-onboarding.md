# New Species Onboarding — iOS Playbook

When the ML training pipeline ships a newly retrained `ViTFishSpecies.mlpackage` with an added class, these are the iOS steps to integrate it cleanly. Every step is mechanical — no judgment calls once the model is delivered.

This is the human-readable reference. The matching slash command is `.claude/commands/new-species.md` (keep it in sync when this doc changes).

## Prerequisites

Before starting, confirm with the ML agent that all of the following are true:

- [ ] `~/dev/MadThinkerML/models/ViTFishSpecies.mlpackage` was regenerated with the new class.
- [ ] `~/dev/MadThinkerML/models/LengthRegressor.mlmodel` was **retrained against the new class indices**. This is not optional — indices shift when a species is inserted (see "Index shift cascade" below) and the regressor will silently produce wrong-distribution predictions if it isn't aligned.
- [ ] The ML agent reported validation metrics. If the new class has val accuracy < 70% or fewer than ~100 training images, flag it as a weak class in the commit message.
- [ ] You know **exactly** where the new label falls in Python `ImageFolder` alphabetical order. This determines its index — the label is not appended to the end of the list.

If any of these are false, **stop**. Updating app code against a half-baked model produces silent misclassification.

## Branch setup

```bash
git checkout main
git pull
git checkout -b species-<new-class>-expansion   # e.g. species-coho-salmon-expansion
```

Don't commit to main until after local sim verification.

## Step 1 — Copy the model artifacts

`.mlpackage` is a directory bundle, not a file. Use `cp -R` and remove the old package first to avoid stale files surviving the copy:

```bash
rm -rf SkeenaSystem/Models/ViTFishSpecies.mlpackage
cp -R  ~/dev/MadThinkerML/models/ViTFishSpecies.mlpackage SkeenaSystem/Models/
cp     ~/dev/MadThinkerML/models/LengthRegressor.mlmodel  SkeenaSystem/Models/
```

**Don't commit** `.mlmodelc` files — those are build artifacts Xcode compiles from `.mlpackage` on first build. `.gitignore` should already cover them.

The project uses Xcode 16 file-system-synchronized groups, so dropping files into `SkeenaSystem/Models/` auto-registers them with the app target. Verify in Xcode that both files appear under `SkeenaSystem/Models/` in the navigator AND in the target's "Copy Bundle Resources" phase.

## Step 2 — Update `speciesLabels`

File: [`SkeenaSystem/Managers/CatchPhotoAnalyzer.swift`](../SkeenaSystem/Managers/CatchPhotoAnalyzer.swift) — search for `private let speciesLabels`.

Insert the new label in its **alphabetical position** (matching Python `ImageFolder` order). Example — adding `coho_salmon` to the current 5-class list:

```swift
private let speciesLabels: [String] = [
    "atlantic_salmon",
    "coho_salmon",         // NEW — alphabetically between atlantic and other
    "other",
    "sea_run_trout",
    "steelhead_holding",
    "steelhead_traveler"
]
```

### Lifecycle-stage gotcha

If the label uses the `<species>_<lifecycle>` pattern (like `steelhead_holding`), confirm the lifecycle suffix is `holding` or `traveler` — `splitSpecies()` in `CatchChatViewModel.swift` only parses those two trailing words. Any other suffix will fail to split correctly. Update `splitSpecies()` if you need a new stage.

## Step 3 — Update `regressorBypassSpecies`

Same file. Single `static let` definition near `speciesLabels` (was previously inline at two call sites — kept consolidated since [commit history]). Edit just the one set literal.

Bypass the new species from the CoreML length regressor until it has calibrated ground-truth length data. Until real catches with measured lengths exist for the new species, the regressor will extrapolate wildly.

```swift
// Was:
let regressorBypassSpecies: Set<String> = ["sea_run_trout", "other", "atlantic_salmon"]
// Now:
let regressorBypassSpecies: Set<String> = ["sea_run_trout", "other", "atlantic_salmon", "coho_salmon"]
```

Remove a species from this set in a future round **only** after you have enough real catches with measured lengths to retrain the regressor against it. Heuristic placeholders in `speciesLengthRanges` (Step 6) are not enough — those just shape the heuristic fallback's display range.

## Step 4 — Update `speciesDisplayNames`

File: [`SkeenaSystem/ViewModels/CatchChatViewModel.swift`](../SkeenaSystem/ViewModels/CatchChatViewModel.swift) — search for `private static let speciesDisplayNames`.

The key is the **lowercased, underscore-stripped** species prefix (lifecycle stage dropped). The value is the user-facing display name shown in the chat and on catch reports.

```swift
private static let speciesDisplayNames: [String: String] = [
    "atlantic salmon": "Atlantic Salmon",
    "coho salmon":     "Coho Salmon",     // NEW
    "sea run trout":   "Sea-Run Trout",
    "steelhead":       "Steelhead",
    "other":           "Bi-catch",
]
```

Missing keys fall back to `valueOnly.capitalized`, which produces `"Coho Salmon"` anyway. The explicit entry is still useful for stylization (hyphens, title case, etc.) and as a contract declaration.

## Step 5 — Update `speciesDisplayToLabel`

File: [`SkeenaSystem/Managers/CatchPhotoAnalyzer.swift`](../SkeenaSystem/Managers/CatchPhotoAnalyzer.swift) — search for `private static let speciesDisplayToLabel`.

This map is used by `reEstimateLength` when the user corrects the species in the chat. It maps the **lowercased display name** (the same key form used in `speciesDisplayNames`) back to a **model label** that exists in `speciesLabels`. Skipping this step silently lands the regressor on `speciesIdx=0` with the wrong species feature — no error, just a wrong number.

```swift
private static let speciesDisplayToLabel: [String: String] = [
    // Lifecycle-split species — default to _holding (reEstimateLength upgrades to _traveler when stage is supplied)
    "steelhead":       "steelhead_holding",
    "atlantic salmon": "atlantic_salmon_holding",
    "coho salmon":     "coho_holding",         // NEW — if coho is lifecycle-split

    // Single-label species
    "rainbow trout":   "rainbow_trout",
    // … etc.
]
```

**Lockstep rules:**

- Every value MUST exist in `speciesLabels`. If you map `"coho salmon"` → `"coho_holding"`, the matching `coho_holding` entry must be in `speciesLabels` (not just `coho_salmon`).
- Every key in `speciesDisplayNames` (Step 4) MUST appear as a key here. Sync check at end of playbook (Step 10) catches drift.
- Bi-catch is `"bi-catch"` → `"other"`.

## Step 6 — `speciesLengthRanges` — provide a plausible biological range

Same file as Step 2 (`CatchPhotoAnalyzer.swift`). This dict shapes the heuristic fallback: raw pixel-length is normalized within the global `[FISH_MIN_LENGTH_INCHES, FISH_MAX_LENGTH_INCHES]` envelope (currently 10–47") and then **linearly remapped into the species' (min, max)**. Without an entry, the species inherits the generic 10–47" envelope — which is shaped for steelhead and produces nonsense for anything smaller or larger.

**Always add an entry when onboarding a new species.** A heuristic biological range is fine — these are explicitly placeholders, not regression fits.

Suggested sources for the initial range:
- FishBase species page (typical "common length" / "max length")
- Regional state/provincial agency size records (e.g. WDFW, BC ENV)
- The species' typical adult range encountered in fishing — not absolute world-record extremes

Round to clean increments (5" or 2") and add a comment if the source is non-obvious. Tighten the range later as real catch data accumulates.

```swift
private static let speciesLengthRanges: [String: (min: Double, max: Double)] = [
    "rainbow_trout":       (min: 10, max: 36),
    "coho_salmon":         (min: 18, max: 36),  // NEW — typical caught range
    "sea_run_trout":       (min: 8,  max: 20),
    "steelhead_holding":   (min: 24, max: 42),
    "steelhead_traveler":  (min: 24, max: 42),
]
```

Both call sites use `if let range = Self.speciesLengthRanges[species]` — a missing key silently falls through to the wrong default rather than crashing, which is exactly why missing entries are easy to ship.

## Step 7 — Build + simulator verification

```bash
xcodebuild -workspace SkeenaSystem.xcworkspace \
  -scheme SkeenaSystem \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

If you hit cache issues, `rm -rf ~/Library/Developer/Xcode/DerivedData/SkeenaSystem-*` and rebuild.

Then on the sim, run through this checklist:

| Input | Expected species | Expected length source | Expected display |
|-------|------------------|------------------------|------------------|
| Known steelhead photo | `steelhead_holding` or `steelhead_traveler`, high confidence | CoreML regressor | "Steelhead" |
| Photo of the new class | The new label, moderate-to-high confidence | **Heuristic** (bypass) | Display name from Step 4 |
| OOD / exotic fish | `other` | **Heuristic** (bypass) | "Bi-catch" |

For the bypass confirmation, search Console for the log line `Using species-scaled heuristic for <species> (regressor not yet calibrated)` — that's emitted from the bypass branch.

**Regression check:** a known steelhead photo must still predict `steelhead_*` correctly. If it now predicts something else, the model package didn't take — re-check Step 1.

## Step 8 — Sync check (catches lockstep drift)

Before committing, verify the five species lists are aligned:

1. **`speciesLabels`** (`CatchPhotoAnalyzer.swift`) — source of truth, must match Python `ImageFolder` order.
2. **`regressorBypassSpecies`** (same file) — every entry must exist in `speciesLabels`.
3. **`speciesDisplayToLabel`** (same file) — every value must exist in `speciesLabels`; every key must appear in `speciesDisplayNames`.
4. **`speciesLengthRanges`** (same file) — the new species has an entry; every key must exist in `speciesLabels`.
5. **`speciesDisplayNames`** (`CatchChatViewModel.swift`) — every key must be the lifecycle-stripped form of at least one `speciesLabels` entry.

A drift in any of these silently produces wrong regressor inputs, wrong heuristic length ranges, or wrong UI display. Manual audit for now — a unit test would be a worthy follow-up.

## Step 9 — Commit, merge, clean up

Once sim checks pass:

```bash
# Include the model artifacts — weight.bin and model.mlmodel will show as modified.
git add SkeenaSystem/Managers/CatchPhotoAnalyzer.swift \
        SkeenaSystem/ViewModels/CatchChatViewModel.swift \
        SkeenaSystem/Models/LengthRegressor.mlmodel \
        SkeenaSystem/Models/ViTFishSpecies.mlpackage

git commit -m "Expand ViTFishSpecies — add <new_species>"
git push -u origin species-<new-class>-expansion

# After review / user sign-off:
git checkout main
git merge --ff-only species-<new-class>-expansion
git push
git branch -d species-<new-class>-expansion
git push origin --delete species-<new-class>-expansion
```

Include in the commit message:
- Which classes shifted indices (every class alphabetically after the new one)
- Val accuracy of the new class, and training image count if weak
- Whether the new class is in `regressorBypassSpecies`

## Index shift cascade — why the regressor retrain is non-optional

`speciesLabels` must match Python `ImageFolder` alphabetical order exactly, and `speciesIndex` is a feature the LengthRegressor uses. Inserting a species alphabetically shifts every subsequent index by +1.

Concrete example — adding `chinook_salmon` to the current 5 classes:

```
Before:                     After:
0: atlantic_salmon         0: atlantic_salmon
1: other                   1: chinook_salmon   ← NEW
2: sea_run_trout           2: other            ← shifted +1
3: steelhead_holding       3: sea_run_trout    ← shifted +1
4: steelhead_traveler      4: steelhead_holding ← shifted +1
                           5: steelhead_traveler ← shifted +1
```

If the LengthRegressor was trained against the old indices, every species now sends a stale index in — the regressor treats `sea_run_trout` inputs as if they were `other`, and so on. The regressor doesn't error; it just quietly produces wrong-distribution predictions.

**Always retrain the LengthRegressor alongside ViT.** If the ML agent ships only a new `.mlpackage` without a new `.mlmodel`, push back before merging.

## Known landmines

- **Preprocessing norms.** `runViT` passes `mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5]` (Inception-style, timm's default for `vit_tiny_patch16_224`) — not ImageNet. This is already correct in `CatchPhotoAnalyzer.swift` and you shouldn't need to change it, but don't revert it either. Matching training preprocessing is load-bearing; feeding ImageNet-normalized inputs to an Inception-trained model produces silent garbage.
- **Confidence threshold.** `SPECIES_DETECTION_THRESHOLD` in xcconfig (`DevTEST.xcconfig` / `PROD.xcconfig`) gates when the model's top prediction is trusted vs. when we fall back to "Species: Unable to confidently detect". Tune via xcconfig, not in code.
- **Don't touch `splitSpecies()` lifecycle parsing.** It only recognizes `holding` and `traveler`. Any other trailing word will be treated as part of the species name.
- **Bi-catch UX.** The `other` class gets special treatment — `"Bi-catch"` display name, `Sex: -` override, and a custom tail message in the researcher flow prompting the user to name the actual species. Preserve this behavior. See `beginResearcherFlow` in `CatchChatViewModel.swift` and `identificationPrompt()` / `identificationSummary()` in `ResearcherCatchFlowManager.swift`.
- **Never add `MediaPipeTasksVision` to the test target.** Duplicate-symbol crashes. The test target gets headers via search paths only.

## Related files for context

- [`SkeenaSystem/Managers/CatchPhotoAnalyzer.swift`](../SkeenaSystem/Managers/CatchPhotoAnalyzer.swift) — all ML inference, `speciesLabels`, `regressorBypassSpecies`, `speciesDisplayToLabel`, `speciesLengthRanges`, `runViT`, `reEstimateLength`.
- [`SkeenaSystem/ViewModels/CatchChatViewModel.swift`](../SkeenaSystem/ViewModels/CatchChatViewModel.swift) — `speciesDisplayNames`, `splitSpecies`, chat rendering.
- [`SkeenaSystem/ViewModels/ResearcherCatchFlowManager.swift`](../SkeenaSystem/ViewModels/ResearcherCatchFlowManager.swift) — identification flow, Bi-catch tail branching.
- [`.claude/CLAUDE.md`](../.claude/CLAUDE.md) — project rules (lifecycle-stage parser, nonisolated requirements, libz.tbd, etc.).
- [`.claude/commands/new-species.md`](../.claude/commands/new-species.md) — Claude slash command version of this playbook.
