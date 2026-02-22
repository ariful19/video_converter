# Android 16 Folder Resolution + Size Reduction Plan

## Status
- Implemented.
- Verified with `flutter analyze`, `flutter test`, and `flutter build apk --debug`.

## Problem statement
Two issues remain in the current Android flow:
1. Video picker often shows: **"Video loaded, but source folder could not be resolved."**  
2. Converted file size is sometimes close to input size, even after lowering resolution.

Goal: reliably save to the same source folder (with proper permissions on Android 16) and enforce proportional file-size reduction when resolution is reduced.

## Current codebase findings
- `MainActivity.kt` queries `MediaStore.MediaColumns.RELATIVE_PATH` directly from the returned document URI.
- On Android 16/SAF providers, this column is frequently unavailable for the selected URI, so folder resolution fails.
- Current conversion model in `video_converter_service.dart` applies bitrate scaling, but does not guarantee meaningful size reduction for all inputs (especially when source bitrate metadata is unreliable or audio dominates).

## Confirmed behavior choice
- If same-folder path cannot be auto-resolved, app should **prompt once for folder access and reuse it** (persisted permission).

## Implemented approach
1. **Improve source-folder resolution on Android**
   - Add robust URI resolution path:
     - try MediaStore-backed resolution when possible,
     - fallback to persisted SAF tree URI mapping when direct folder metadata is missing.
   - Keep source URI metadata (authority/document id/relative path candidates) in picker response.

2. **Add one-time folder permission flow**
   - When unresolved, trigger `ACTION_OPEN_DOCUMENT_TREE`.
   - Persist URI permission and selected tree URI for reuse.
   - Reuse this grant in future conversions without repeatedly prompting.

3. **Strengthen proportional size reduction logic**
   - Rework target bitrate calculation to use:
     - source duration + source file size (effective source bitrate),
     - pixel-ratio reduction factor,
     - explicit min/max guardrails for video and audio.
   - Guarantee downward pressure on bitrate for lower target resolutions.
   - Add optional quality cap logic (CRF or constrained VBR policy) to avoid near-identical sizes.

4. **Update UI flow and messaging**
   - Show clear state for:
     - unresolved folder requiring permission,
     - persisted folder access enabled,
     - expected size-reduction targets (or estimated bitrate).
   - Keep conversion disabled only when mandatory access is missing.

5. **Validation**
   - Completed: `flutter analyze`, `flutter test`, `flutter build apk --debug`.
   - Recommended manual Android 16 validation:
     - pick video where folder is initially unresolved,
     - grant folder access once,
     - convert 4K → 720p (or similar),
     - confirm output appears in the source folder and size is reduced proportionately.

## Todo breakdown (SQL-tracked)
1. `android-folder-access-bridge` - implement Android URI folder resolution improvements.
2. `folder-permission-persistence` - add one-time folder picker + persisted tree URI access.
3. `conversion-target-bitrate-rework` - redesign bitrate model for proportional size reduction.
4. `ui-flow-updates` - update user-facing states for permission and conversion readiness.
5. `conversion-quality-validation` - validate output bitrate/resolution/size behavior.
6. `verification-android16` - run full verification on Android 16 scenarios.

## Notes
- This plan is Android-first and keeps existing conversion architecture intact.
- Main focus is deterministic folder accessibility + predictable size reduction behavior.
