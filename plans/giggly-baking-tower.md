# Plan: Remove Hardcoded Codec Bypass for Dynamic Hardware/Software Fallback

## Context

Currently, the SVP project hardcodes AV1 and VP9 to always use FFmpeg (software) decoding, bypassing VideoToolbox entirely. This prevents dynamic fallback based on actual hardware capabilities.

The user wants to:
- Remove hardcoded codec bypasses (AV1/VP9)
- Let VideoToolbox try first for ALL codecs
- Fall back to software only when hardware decoding actually fails

## Current Architecture

The `DefaultVideoPipeline` in `VideoDecoder.swift` already has dynamic fallback infrastructure:

1. **`shouldBypassPrimary(for:)`** (lines 152-160) - Currently returns `true` for AV1/VP9, forcing them to always use FFmpeg
2. **`softwareForcedCodecs: Set<CodecID>`** (line 89) - Tracks codecs that have failed hardware decode
3. **`shouldForceSoftwareFallback(for:)`** (lines 162-170) - Returns `true` for `unsupportedCodec`, `backendUnavailable`, `sessionCreationFailed` errors
4. **`VideoToolboxDecoder`** - Only supports H.264 and HEVC; throws `unsupportedCodec` for other codecs (line 269)

## Solution

**Remove lines 155-156 in `shouldBypassPrimary`** - the AV1/VP9 bypass:

```swift
// CHANGE FROM:
private func shouldBypassPrimary(for codec: CodecID) -> Bool {
    guard preferHardware else { return false }
    switch codec {
    case .av1, .vp9:    // <-- REMOVE THESE 2 LINES
        return true     // <-- REMOVE
    default:
        return false
    }
}

// TO:
private func shouldBypassPrimary(for codec: CodecID) -> Bool {
    guard preferHardware else { return false }
    return false
}
```

Or simplify to just:
```swift
private func shouldBypassPrimary(for codec: CodecID) -> Bool {
    return preferHardware
}
```

## How It Works After Change

1. **First AV1/VP9 frame arrives** → tries VideoToolbox → fails with `unsupportedCodec`
2. **`shouldForceSoftwareFallback`** catches error → returns `true`
3. Codec added to `softwareForcedCodecs` set (line 133)
4. **All subsequent frames** for that codec → use FFmpeg directly via `shouldUseSoftwareDecoder` (line 172-173)

The same pattern works for any codec that VT cannot handle on the current hardware.

## Files to Modify

- `/Users/jfdufour/git-repositories/svp/Sources/Decode/VideoDecoder.swift`
  - Function: `shouldBypassPrimary(for:)` at lines 152-160

## Verification

Build the project and test with:
1. H.264/HEVC content - should use VideoToolbox (hardware) if available
2. AV1/VP9 content - should try VideoToolbox first, then dynamically fall back to FFmpeg on failure
3. Check logs for `softwareForcedCodecs` entries to confirm fallback is triggered
