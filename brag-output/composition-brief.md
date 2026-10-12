# Hyperframes Composition Brief: Rec

## Objective
Create a short, polished, shareable launch brag video for Rec — the native macOS screen and internal audio recorder.

## Output
- Composition directory: `scratch/Rec/brag-output/composition/`
- Rendered video: `scratch/Rec/brag-output/brag.mp4`
- Format: landscape — 1920x1080 (30fps)
- Duration: 20 seconds

## Source Material
- Project root: `/Users/arunthomas/.gemini/antigravity-ide/scratch/Rec/`
- Primary files read: `index.html`, `README.md`, `logo.svg`, `version.json`, `main.swift`
- Product name: Rec
- Tagline / strongest claim: "Record anything. Yours alone. Internal audio without the drivers."
- Key UI or visual moment to recreate:
  - Frosted glass floating toolbar with live audio meters and mode switcher
  - Pulsing Apple-recording-red status indicator
  - 3-second countdown ring and auto-hiding interface
  - One-line terminal installation command
- Copy that must appear verbatim:
  - "No third-party drivers needed."
  - "100% native. Captured locally on your Mac."
  - "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/arunofhyd/Rec/main/install-rec.command)\""

## Creative Direction
- Tone preset: `polished`
- Creative direction: Sleek Apple Keynote product reveal: dark mode glass, precision typography, razor-sharp focus on solving macOS audio driver complexity.
- Interpretation: Serious, elegant, high-restraint pacing. Clear readability (0.3s per word), deliberate transitions without visual clutter or generic SaaS tropes.
- Angle: Rec delivers native macOS screen recording and system audio capture using ScreenCaptureKit with zero driver configuration, zero subscriptions, and 100% on-device privacy.
- Hook: "Recording internal Mac audio shouldn't require third-party drivers. No Soundflower. No BlackHole."
- Outro / punchline: "Your recording. Yours alone." followed by the one-line terminal installer.
- Avoid:
  - Generic SaaS phrases like "streamline your workflow" or "all-in-one platform"
  - Abstract filler graphics or stock illustrations
  - Low-contrast text or overly rapid cuts that harm readability

## Visual Identity
- Background: `#0b0d10`
- Panel Surface: `#15181d` with `1px solid rgba(255, 255, 255, 0.08)`
- Primary Accent: `#FF3B30` (Apple Recording Red, box-shadow: `0 0 25px rgba(255,59,48,0.5)`)
- Secondary Accent: `#34C759` (Emerald Green for ScreenCaptureKit status)
- Text Primary: `#ffffff`
- Text Secondary: `#9ca3af`
- Display font: `Inter, -apple-system, BlinkMacSystemFont, sans-serif`
- Monospace font: `'Fira Code', 'SF Mono', monospace`
- Visual references from the project:
  - `logo.svg`: Red core within white ring on rounded dark rectangle
  - UI badges: `bg-brand-red/10 border border-brand-red/30 text-brand-red`

## Storyboard
Use `brag-output/brag-plan.md` as the contract:
1. **Scene 1 (0.0s – 3.5s)**: The Driver Problem — dark canvas, pulsing red dot, bold statement contrasting competitor driver hell with clean simplicity.
2. **Scene 2 (3.5s – 7.5s)**: Meet Rec — floating dark frosted glass controller glides into center with active audio VU meters and clean mode pills.
3. **Scene 3 (7.5s – 12.5s)**: Three Key Superpowers — ScreenCaptureKit native audio, multi-mode capture, 60fps hardware accelerated encoding.
4. **Scene 4 (12.5s – 17.0s)**: Seamless Flow — Click Record, 3-2-1 countdown rings, UI vanishes, instant .mov save toast.
5. **Scene 5 (17.0s – 20.0s)**: Branded Outro & Terminal Install — Rec logo, "Yours alone", one-line install command with copy badge.

## Audio
- Audio role: Warm modern tech groove with crisp UI clicks and subtle impact accents.
- Audio arc: Building curiosity in scene 1, settling into groove for product showcase, clean musical fade with outro chime.
- Music: `assets/music/happy-beats-business-moves-vol-10-by-ende-dot-app.mp3`
- Music treatment: Starts at 70% volume, ducks 15% under scene 1 text, full volume through scenes 2-4, gentle fade under scene 5 logo.
- SFX files:
  - `click1.ogg`: Button and mode selection clicks
  - `switch1.ogg`: Internal audio toggle flip
- Exact SFX choice: Synchronized to visual motion and keyframe transitions.

## Hyperframes / Engine Instructions
- Render at 1920x1080 at 30fps.
- Maintain 100% vector sharpness and crisp typography.
- Keep all scenes within safe margins.
