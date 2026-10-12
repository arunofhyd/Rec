# Brag Plan: Rec

## What is this app?
Rec is a native, lightweight macOS screen and internal audio recorder built with Apple's ScreenCaptureKit that records system audio alongside high-framerate video without requiring third-party loopback audio drivers or kernel extensions.

## The angle
Every Mac screen recorder either requires installing sketchy 3rd-party audio kexts/drivers (like Soundflower or BlackHole), costs $29/year, or uploads recordings to an invasive cloud. Rec flips the script: it's 100% native, runs completely on-device, captures internal system audio out of the box with zero drivers, and costs nothing.

## Hook (first 2-3 seconds)
A stark black frame with a glowing red Apple recording dot and the provocative question:
*"Why does recording system audio on a Mac still feel like configuring a Linux server?"*
Cut abruptly to: *"No drivers. No BlackHole. Just Rec."*

## Key moments (the middle)
- **Zero-Driver Internal Audio:** A clean comparison callout showing competitor driver hell vs Rec's instant native ScreenCaptureKit capture.
- **Sleek Floating Controller:** The minimalist dark-glass floating control panel with modes (Full Screen, Region, App Window) and live audio meters.
- **Auto-Hide & Clean Export:** 3-2-1 countdown rings, the UI vanishes during capture, and the recording exports directly as hardware-accelerated `.mov` to Downloads.

## Outro / punchline
*"Your recording. Yours alone."*
One-line terminal command reveal:
`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/arunofhyd/Rec/main/install-rec.command)"`
Followed by the vibrant Rec icon and Apple Silicon native badge.

## User flow worth showing
1. **Entry:** Floating pill appears on screen → User clicks the target mode and toggles Internal Audio ON.
2. **Action:** Hits Record → 3-2-1 countdown triggers with tactile SFX → Floating UI automatically hides from footage.
3. **Result:** User taps Stop from menu bar or shortcut → Instant zero-wait `.mov` saved directly into Downloads folder.

## Tone
- **Preset:** `polished`
- **Creative direction:** Sleek Apple Keynote product reveal: precision typography, dark mode glass, glowing recording red accents, razor-sharp focus on ending audio driver misery.
- **Interpretation:** Serious, elegant, high-restraint pacing. Scenes hold long enough to read every word; transitions are fluid Apple-grade fades and depth glides.

## Format: landscape — 1920x1080
## Duration: 20s

## Visual identity (from the project)
- **Background:** `#0b0d10` (Dark obsidian canvas)
- **Panel Surface:** `#15181d` with 1px `rgba(255, 255, 255, 0.08)` border
- **Accent Red:** `#FF3B30` (Apple Recording Red glow `rgba(255, 59, 48, 0.4)`)
- **Accent Green:** `#34C759` (Audio signal & ScreenCaptureKit active status)
- **Text:** `#ffffff` (Headlines) / `#9ca3af` (Secondary copy)
- **Display font:** `Inter` (Bold 700 / SemiBold 600)
- **Mono font:** `Fira Code` / `SF Mono`
- **Strongest visual element:** The pulsing Apple-red record pill and the floating dark frosted glass control bar.

## Share copy (draft)
Stop installing messy audio drivers just to record your Mac screen. Rec captures native screen + internal audio in one lightweight click. 100% on-device. Zero subscriptions. 🎥🔊

## Audio direction
- **Role:** Polished modern tech groove with crisp UI clicks and subtle bass drops.
- **Music:** `happy-beats-business-moves-vol-10-by-ende-dot-app.mp3`
- **Music treatment:** Starts at t=0s at 70% volume, ducks slightly during key text reveals, swells into the feature montage, and fades gently under the final logo.
- **Music cue guidance:** Strong cue drop at t=3.0s (reveal of the Rec floating controller); secondary accent at t=12.0s; final outro resolve at t=18.0s.
- **Audio-reactive treatment:** Subtle red glow pulse synced to musical downbeats.
- **SFX posture:** Sparse and motion-matched. Professional restraint.
- **Audio-coupled moments:**
  - t=1.5s: Bass sub-impact on problem statement cut
  - t=3.5s: Tactile click on mode toggle
  - t=9.0s: Tactile toggle click on "Internal Audio: ON"
  - t=14.0s: Clean camera shutter/beep on 3-2-1 countdown completion
  - t=18.0s: Final chime on logo reveal
- **Restraint rule:** Never let SFX overpower the voice or groove. No arcade bleeps; only tactile macOS haptic-style clicks.

## Storyboard

### Scene 1 — The Driver Problem — 3.5s
Dark void. Pulsing red dot.
Headline: *"Recording internal Mac audio shouldn't require third-party drivers."*
Subhead: *"No Soundflower. No BlackHole. No kernel extensions."*
Sequential/interaction: Red dot pulses; headline fades in with high contrast typography.
Audio intent: Intriguing, tension-building opening.
Audio-coupled idea: Subtle sub-impact at headline settle.
Music: Groove begins cleanly.
Transition mood: Fast snap zoom → Scene 2

### Scene 2 — Meet Rec (The Reveal) — 4.0s
Hero floating controller appears in frosted glass with glowing red Rec emblem.
Headline: *"Meet Rec."*
Subhead: *"Native Screen & Audio Recorder for macOS."*
Sequential/interaction: Glass toolbar slides smoothly into center stage with live audio level meters dancing in emerald green.
Audio intent: Confident, refreshing product arrival.
Audio-coupled idea: Soft glass swoosh and crisp switch click.
Transition mood: Soft slide → Scene 3

### Scene 3 — Internal Audio Built-In — 5.0s
Feature spotlight card:
Badge: `Apple ScreenCaptureKit`
Feature 1: `🔊 Internal System Audio: Native Loopback`
Feature 2: `🎯 Modes: Full Screen · Region · App Window`
Feature 3: `⚡ Custom Scaling: Native Retina, 1080p, 60 FPS`
Sequential/interaction: 3 feature badges cascade in one-by-one with green checkmarks.
Audio intent: Impressive technical clarity and relief.
Audio-coupled idea: Three subtle staggered clicks on badge arrivals.
Transition mood: Elegant dissolve → Scene 4

### Scene 4 — Zero Friction Workflow — 4.5s
Demonstrating the floating UI auto-hiding during recording.
Headline: *"Unobtrusive floating controls."*
Subhead: *"Hides automatically from your video. Instant .mov export."*
Sequential/interaction: Simulated mouse click on 'Record' → 3-2-1 countdown rings → Toolbar smoothly vanishes → Toast: `Saved to Downloads`.
Audio intent: Dynamic payoff and satisfaction.
Audio-coupled idea: Countdown countdown beeps and satisfying completion click.
Transition mood: Clean wipe → Scene 5

### Scene 5 — Punchline & Install — 3.0s
Final branded hero lockup.
Logo: Rec Icon + *"Your recording. Simplified."*
Call to Action terminal block:
`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/arunofhyd/Rec/main/install-rec.command)"`
Subtext: `100% On-Device · Free & Open Source · macOS 14+`
Sequential/interaction: Logo settles; terminal install string glows with copyable highlight.
Audio intent: Confident resolution and final musical fade.
Audio-coupled idea: Gentle chime resolve.

**Music mood for this video:** Modern, upbeat, polished electronic groove.
**Audio summary:** Starts with suspenseful groove build, settles into confident tech rhythm with motion-matched UI accents, and resolves into a clean logo chime.
