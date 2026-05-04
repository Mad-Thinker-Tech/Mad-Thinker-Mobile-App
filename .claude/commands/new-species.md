---
description: Walk through adding a new species class to the iOS app after an ML retrain
---

The human-readable playbook lives at [`docs/new-species-onboarding.md`](../../docs/new-species-onboarding.md) — read it before starting. This slash command is the execution wrapper.

Target species (from $ARGUMENTS, or ask the user if missing): **$ARGUMENTS**

## Step 0 — Confirm prerequisites before touching anything

Ask the user (or check if already stated):

1. Has the ML agent retrained and re-exported **both** `~/dev/MadThinkerML/models/ViTFishSpecies.mlpackage` **and** `~/dev/MadThinkerML/models/LengthRegressor.mlmodel`? The regressor retrain is not optional — `species_index` is a regressor input feature, and alphabetical insertion shifts every subsequent index.
2. What's the new label's position in Python `ImageFolder` alphabetical order? (This determines its array index. **Not** the end of the list.)
3. What was the val accuracy and training-image count for the new class? Flag as a weak class in the commit message if accuracy < 70% or image count < ~100.

If any of #1 is missing, **STOP.** Updating code against a half-baked model produces silent misclassification.

## Step 1 — Feature branch + copy artifacts

```bash
git checkout main && git pull
git checkout -b species-<new-class>-expansion
rm -rf SkeenaSystem/Models/ViTFishSpecies.mlpackage
cp -R  ~/dev/MadThinkerML/models/ViTFishSpecies.mlpackage SkeenaSystem/Models/
cp     ~/dev/MadThinkerML/models/LengthRegressor.mlmodel  SkeenaSystem/Models/
```

`.mlpackage` is a directory bundle — `cp -R` is required. The project uses Xcode 16 file-system-synchronized groups, so the artifacts auto-register with the app target.

## Step 2 — `speciesLabels` in [`SkeenaSystem/Managers/CatchPhotoAnalyzer.swift`](../../SkeenaSystem/Managers/CatchPhotoAnalyzer.swift)

Insert the new label in its alphabetical position. If the label uses the `<species>_<lifecycle>` pattern, confirm the lifecycle suffix is `holding` or `traveler` — `splitSpecies()` only recognizes those two. Any other suffix needs a parser update.

## Step 3 — `regressorBypassSpecies` (same file, single `static let`)

Add the new species to the bypass set. The LengthRegressor has no calibrated length data for it until real catches with measured lengths exist. Heuristic fallback applies until then.

## Step 4 — `speciesDisplayNames` in [`SkeenaSystem/ViewModels/CatchChatViewModel.swift`](../../SkeenaSystem/ViewModels/CatchChatViewModel.swift)

Key is the lowercased, **underscore-stripped** species prefix (no lifecycle stage). Value is the user-facing display name. Example: `"coho salmon": "Coho Salmon"`.

## Step 5 — `speciesDisplayToLabel` in `CatchPhotoAnalyzer.swift`

Used by `reEstimateLength` to round-trip the user's corrected species back to a model label. Key matches the `speciesDisplayNames` key form (lowercased, underscore-stripped); value MUST exist in `speciesLabels`. Skipping this is the bug that made `"rainbow trout"` map to a nonexistent `"rainbow_holding"` and silently land the regressor on `speciesIdx=0`.

For a lifecycle-split species, default the value to the `_holding` variant — `reEstimateLength` upgrades to `_traveler` if the stage is supplied. For a single-label species (rainbow, brown, chinook, etc.) map directly to that label.

## Step 6 — `speciesLengthRanges` — always provide a heuristic range

Same file as Step 2. Add the new species with a plausible biological range (FishBase, agency size records, typical caught range). These are heuristic placeholders, NOT measured-data fits — tighten them later as real catch data accumulates.

Without an entry, the species inherits the generic 10–47" steelhead-shaped envelope, which produces nonsense for anything smaller or larger. Round ranges to clean 2" or 5" increments. If the new species is lifecycle-split, give holding and traveler the same range unless there's evidence to differentiate.

## Step 7 — Preprocessing sanity check (should already be correct)

Verify `runViT` in `CatchPhotoAnalyzer.swift` passes `mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5]` (Inception-style, timm default for `vit_tiny_patch16_224`). If it's defaulting to ImageNet norms, the species model will silently misfire. This was fixed in commit `ad51607` — shouldn't regress, but worth a glance.

## Step 8 — Bi-catch UX preservation

The `other` class has custom UX: display name is `"Bi-catch"`, sex is suppressed to `"-"`, and the researcher flow has a tail-message branching (`identificationPrompt()` in `ResearcherCatchFlowManager.swift`) that asks the user to name the species when species is currently Bi-catch, or to optionally provide sex after they correct it. Don't break this when adding new classes.

## Step 9 — Build + sim verification

Run `/build` (or `xcodebuild` per `CLAUDE.md`). Then on the sim:

| Input | Expected |
|-------|----------|
| Known steelhead photo | `steelhead_*` with high confidence — regression sentinel |
| New class photo | New label, moderate-to-high confidence, heuristic length path |
| OOD / exotic fish | `other` → "Bi-catch" display |

Confirm the regressor bypass engaged by grepping Console for `Using species-scaled heuristic for <species> (regressor not yet calibrated)`.

## Step 10 — Sync check + commit

Read all five species lists and verify alignment:

- **`speciesLabels`** (source of truth) — every entry has a corresponding key in `speciesDisplayNames` (after lifecycle-stripping) AND a corresponding value in `speciesDisplayToLabel`.
- **`regressorBypassSpecies`** — every entry exists in `speciesLabels`.
- **`speciesDisplayToLabel`** — every value exists in `speciesLabels`; every key matches a key in `speciesDisplayNames`. This is the one that historically rotted (`"rainbow trout"` → nonexistent `"rainbow_holding"`).
- **`speciesLengthRanges`** — new species has an entry; every key exists in `speciesLabels`.
- **`speciesDisplayNames`** — every key is the lifecycle-stripped form of at least one `speciesLabels` entry; no stale keys.

Drift in any of these silently produces wrong regressor inputs, wrong heuristic length ranges, or wrong UI display.

Then stage, commit, push the feature branch. Hold off on merging to main until the user confirms sim verification.

## Step 11 — Summarize

Give the user a one-paragraph summary including:

- Which classes shifted indices.
- New class's val accuracy + training image count (from Step 0).
- Whether the new species is in `regressorBypassSpecies` (yes until calibrated length data exists).
- Any gotchas you hit.
