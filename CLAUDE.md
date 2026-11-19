# Bezl: open-source ambient edge lighting for macOS

Bezl is a free, MIT-licensed macOS app. It turns the edges of the screen into a soft glowing rim. The glow pulses with the beat of whatever is playing, and its colors come from the album art. It is an independent, open-source take on the idea behind the paid app **Lumn** (trylumn.xyz).

This file has three parts:
1. **Ground rules** for working in this repo.
2. **Product audit** of Lumn: what we are matching and where we go further.
3. **Build plan**: phases with tasks, technical notes, and acceptance checks. An AI agent should follow it in order.

---

## 1. Ground rules

### Clean-room policy (do not break these)
- Build **only from public descriptions** of Lumn's behavior: its website and this file. Do **not** download, open, disassemble, or inspect the Lumn app or DMG. Its terms forbid reverse engineering, and we want to be clearly independent.
- Do not copy Lumn's name, logo, screenshots, marketing copy, or UI artwork. Bezl gets its own name, icon, wording, and visual design. Matching *features* is fine. Copying *expression* is not.
- Do not use Apple private APIs or frameworks. In particular, no `MediaRemote` and no private `CGS*`/`SkyLight` calls. They break across OS releases and block notarization and review.

### How to work
- Work through the phases in §3 **in order**. Before you start, read the phase's "Done when" list. A phase is done only when every item on it has been verified (built, run, tested). Writing the code is not enough.
- Keep the progress checklist in §3.0 current. Tick boxes as phases finish. If you leave a phase partly done, add a short note saying what is left.
- Only commit or push when the user asks. Commit messages end with the attribution line given in the session's system reminder.
- Prefer the simplest approach that meets the performance budget (§3.2). Do not add dependencies beyond the ones listed in §3.1 without asking.
- Pure logic (DSP, color, geometry, settings models) goes in the `BezlCore` Swift package, so it can be unit tested with `swift test` and no app or permissions. The app target holds only system glue and UI.

### Commands
```sh
brew install xcodegen                      # once
xcodegen generate                          # regenerate Bezl.xcodeproj from project.yml (never hand-edit the .xcodeproj)
swift test --package-path Packages/BezlCore
xcodebuild -project Bezl.xcodeproj -scheme Bezl -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build
pkill -x Bezl; open build/DerivedData/Build/Products/Debug/Bezl.app
log stream --predicate 'subsystem == "io.github.shivshekhar12.bezl"'   # app logs
defaults delete io.github.shivshekhar12.bezl                         # reset settings + onboarding
```
Dev machine: macOS 26.6, Xcode 27.2, Swift 6.4, Apple silicon.

---

## 2. Product audit: Lumn (trylumn.xyz)

Sources: the homepage, /privacy (updated July 27, 2026), and /terms, read November 2026. Version 1.1 was on the site. The FAQ answers mostly did not render, so items below marked *(inferred)* are educated guesses and not stated facts.

### 2.1 What it is
- An ambient "rim lighting" app for the screen edge. Its own one-line summary: color follows the album art, motion follows the beat.
- Platforms: macOS 14+ on **Apple silicon only**, and Windows 10+ (Microsoft Store).
- It is a menu bar app. You "tune it from the menu bar" and there is no Dock window *(inferred: LSUIElement agent app)*.

### 2.2 Features and controls (from the site and its UI mockup)
| Area | Lumn behavior |
|---|---|
| Glow | A rim of light around the screen edge. Intensity runs from "a whisper along the bezel" to "a wash that fills the room". |
| Thickness | From a hairline to a broad band, continuously adjustable. |
| Glow amount | A separate "Glow" control (spread/blur) that is independent of thickness. |
| Color | A two-color **gradient** with weights (mockup shows Primary 60% / Secondary 40%). Each color has a color wheel. |
| Album color | Follows the current track's album art by default. The **"Override album color"** toggle forces the manual gradient instead. |
| Screen color | "Let Lumn read what's on screen and follow it": an on-screen color mode *(probably needs Screen Recording permission)*. |
| Animation | "React to every beat" or "hold one steady idle glow". |
| Music Sync | On/off toggle. |
| Notch | A **"Notch compatibility"** toggle (the rim routes around the camera housing). |
| Displays | A display picker (e.g. "Built-in Retina Display"), so displays are configured one at a time. |
| Status | The panel shows an "Active" indicator. |
| Lock screen | Marketing shows the lock screen ringed with light, and the FAQ mentions a "liquid glass lockscreen player" (answer not visible). |
| Music sources (Mac) | **Apple Music and Spotify only**. |

### 2.3 Permissions and privacy claims
- **System audio only, never the microphone.** The app asks for system-audio access when macOS prompts. This fits the Core Audio **process tap** API (macOS 14.2+) and its "System Audio Recording Only" permission.
- **Automation (Apple Events)** access to Music and Spotify, used to read the current track and artwork. That explains why only those two apps are supported.
- Everything is processed on the device. Nothing is recorded or uploaded. No analytics, tracking, or third-party SDKs.
- Network use: license activation and revalidation through Lemon Squeezy (license key + device ID), plus Sparkle update checks to trylumn.xyz.

### 2.4 Business and distribution
- $9.99 one-time, non-transferable license with an activation limit. Lemon Squeezy is the merchant of record. No trial is mentioned.
- Mac: direct DMG download, drag to Applications, paste a license key into the menu. Auto-updates through **Sparkle**.
- No performance figures are published, although the FAQ asks "Will it slow down my computer or drain battery?".

### 2.5 Gaps and opportunities for Bezl
| Lumn | Bezl |
|---|---|
| Paid, closed source, licensed | Free, MIT, built in public. No license keys and no network calls except optional update checks. |
| Apple silicon only | Universal binary (arm64 + x86_64). Process taps work on Intel too. Minimum is **macOS 14.2** because the tap API needs it. |
| Music + Spotify only | Same two at launch, plus a **"Pure audio" mode**: beat sync from system audio alone, using a manual or screen-sampled palette, with no automation permission. |
| No published performance figures | A published budget (§3.2) and an in-app debug HUD. |
| Single "beat" animation | Beat plus extra modes: Breathe (slow sine) and Static. Presets can be saved and shared as JSON. |
| No mention of shortcuts or multi-display options | Global toggle shortcut, per-display enable, launch at login, auto-hide in full-screen apps or screen sharing (optional). |

**Out of scope, and why:** drawing on the **lock screen**. Third-party windows cannot appear above the login window without private APIs or security-sensitive hacks. Revisit only if Apple ships a public API. Windows support is also out of scope (this repo is macOS only).

---

## 3. Build plan

### 3.0 Progress
"Code ✓" means written, compiling with zero warnings, and unit-tested where possible. "Verified" means checked by a person on real hardware.

- [x] Phase 0: Project skeleton. Code ✓, builds.
- [x] Phase 1: Overlay windows + glow renderer. Verified on a 14" MacBook Pro: the rim renders, routes around the notch, and clicks pass through. Not yet checked: Spaces, external display plug/unplug.
- [ ] Phase 2: Settings model + menu bar UI. Code ✓, **needs visual check**.
- [x] Phase 3: System audio capture. Verified: the tap runs at 48 kHz over Bluetooth headphones. TCC grants `kTCCServiceAudioCapture`, and **auto-denies** the microphone service because the app has no `audio-input` entitlement. Keep it that way. Not yet checked: switching outputs mid-song, leaked aggregate device after quit.
- [ ] Phase 4: Beat detection + animation. DSP ✓ (36 tests pass). Measured pulsing on real music: edge brightness in rapid screenshots swings 0.31–0.44, vs 0.06 with Bezl off. **Still needs the user's feel check** of the tuning.
- [x] Phase 5: Now playing + album-art colors. Verified with Spotify: the rim takes the album colors. Black-and-white art (`Palette.isNeutral`) falls back to the manual colors, because a gray rim is nearly invisible. Apple Music is not yet checked.
- [ ] Phase 6: Polish. Code ✓ for notch toggle, per-display settings, full-screen hiding, screen-capture hiding, presets, ⌃⌥⌘L hotkey, launch at login, sleep/low-power handling, Reduce Motion, onboarding. **Not done:** measuring the §3.2 budget, rebindable hotkey.
- [x] Phase 6b: Lumn-parity extras (2026-11-19).
  - **Verified on screen:**
    - The **now-playing window** (`PlayerView`, AppKit-hosted via `HostedWindow`) has artwork, live position, the ±15 s/prev/play/next controls and a toolbar.
    - The **Settings window**.
  - **Built:** **synced lyrics** from LRCLIB (opt-in consent dialog; `SyncedLyrics` parser is tested). The API format was verified with a public song; the in-app flow still needs a click-through.
  - **Built:** **Show in Dock** (activation policy; a Dock click opens the player), and an **update checker** (GitHub Releases; off by default; `SemanticVersion` tested).
  - **Untested:** the **lock-screen player** (experimental). It raises the overlays and a glass card to `CGShieldingWindowLevel()+1` on `com.apple.screenIsLocked`. A person needs to test it by locking the screen; macOS may keep the lock UI on top.
  - **Verified:** the **resizable player** (min 380×560). A `Metrics` struct scales artwork, type and controls from the 440×700 design size.
  - **Verified: stage mode** (native full screen on the player window, ⌃⌘F / F / Esc). The background is pure black, so only the bezel glow and the centered, scaled-up player remain. The overlay shows on the full-screen Space because of `.fullScreenAuxiliary`.   - **Verified: stage layout v2** (`stageLayout` in `PlayerView`):
    - The artwork is **centered on the screen**. The lower half holds the title plus one wide **Liquid Glass** control panel: progress row, transport, a lyrics toggle and an exit button.
    - The panel uses `.glassEffect` on macOS 26 and `.ultraThinMaterial` earlier, via `View.bezlGlass(_:tint:)`, tinted by the album color.
    - Secondary toggles and Settings sit in a glass pill in the top-right corner. Don't put them under the panel: centering the artwork leaves no room there.
    - With lyrics on, the artwork column takes the left half and the synced lyrics the right half. **Synced lyrics verified end-to-end** with real Spotify playback.
    - The windowed player keeps its original layout.
    - **Idle fade (verified):**
      - After 3 s with no input (`IdleTracker`: a local `NSEvent` monitor; the player window has `acceptsMouseMovedEvents`), stage mode fades out the title, the glass controls and the toolbar (`fadesWhenIdle`), and hides the cursor.
      - Only the artwork, the lyrics (if on) and the bezel glow stay.
      - Any mouse or key input wakes it.
      - It never fades while the settings drawer is open.
      - **It also applies in windowed mode, verified for both the stacked and the wide split layout.** In a window the cursor is not hidden (`IdleTracker.hidesCursor` is true only in stage mode), and `.onContinuousHover` wakes the player even when Bezl isn't the active app.
    - **Glass transparency:** stage controls use the `.clear` Liquid Glass variant with a 6% album tint (`bezlGlass(_:tint:clear: true)`), per user feedback that `.regular` was too opaque.
  - **Verified: settings in the player.** The player's **Settings** button opens an in-app drawer (`settingsDrawer` in `PlayerView`, state in `AppModel.playerSettingsOpen`), so you can edit settings in stage mode without leaving it. Esc or clicking outside closes it. In windows at least 732 pt wide (player minimum 380 + drawer 352), the drawer sits **beside** the player and the player reflows. Narrower windows overlay and dim it. The **menu bar panel is unchanged**.
  - **Typeface: Figtree** (SIL OFL), bundled as `Resources/Fonts/Figtree.ttf` with its license and registered at launch (`BezlFont.register()`). Use `Font.bezl(size, weight)` and `.bezlCaption`/`.bezlHeadline`/etc., never `.system`/`.caption`, in Bezl's own UI. Spotify's typeface (Spotify Mix/Circular) is proprietary and **must not** be bundled; Figtree is the closest free match.
  - **Window safety (`HostedWindow`):** `isRestorable = false`, and `keepOnScreen` clamps the frame to the visible area on every show and after leaving full screen. **Bug fixed 2026-11-19:** quitting while the player was full screen let macOS restore it as a screen-sized window with its title bar under the menu bar ("stuck"). The reopen handler now opens the player only when "Show in Dock" is on, because `open` also sends a reopen event.
  - **Glass design rules for the in-player settings drawer** (verified 2026-11-19):
    - It's a **floating** Liquid Glass card: 360 pt wide, 30 pt corners, 16 pt inset from the edges, with a shadow. It is never an edge-to-edge slab.
    - Sections are inset rounded **cards** (`group(_:)` / `CollapsibleSection(carded:)`, white 6% fill, 18 pt corners), with no dividers.
    - Controls take the **album color** as the accent (`.tint(accent)`), not system blue.
    - The menu bar panel keeps the compact divider style (`inWindow == false`).
    - **Drawer placement (`DrawerLayout`):** the card is positioned in a full-window `GeometryReader` that ignores the safe area, so the title bar and notch strip are included in the measurements.
      - **Wide window:** 16 pt margins on the top, right and bottom. The card may rise into the transparent title bar.
      - **Narrow window** (where it overlays and dims the player): centered horizontally. If it would cover the traffic lights, the top and bottom margins become 40 pt.
      - **Full screen:** the notch strip plus 16 pt, top and bottom.
    - **Vertical centering in full screen:** on notched Macs, full-screen content starts below the camera-housing strip. The drawer's bottom margin therefore adds `NSScreen.main.safeAreaInsets.top`. `GeometryReader.safeAreaInsets` reports 0 there, so don't rely on it. Verify by measuring edge pixels in a screenshot.
  - **Stage controls size:** the panel is ≈1.2× the artwork width (max 50% of the screen). Transport buttons are 17/21/30 pt.
  - **Settings table layout (`MenuPanel`):**
    - Every toggle uses `RowToggleStyle`: label left, switch right-aligned, full width.
    - Non-toggle controls use the `row(_:control:)` helper, the same label-and-control layout.
    - Collapsible groups use `CollapsibleSection`: the same uppercase header as COLOR/MOTION/SHAPE, a chevron, and no indent.
    - Sections are COLOR, MOTION, SHAPE, DISPLAY, BEHAVIOR, UPDATES and DIAGNOSTICS.
    - The panel is 320 pt in the menu bar and fills the width in the drawer.
    - Keep new settings in these patterns so the table stays aligned. `AppModel.showSettings()`, a separate window, is no longer used by the player. It leaves stage mode first if called.
  - **Wide window split (`wideLayout`, `PlayerView.isWide`):** when the width is at least 720 pt and at least 1.15× the height:
    - **Lyrics off:** artwork on the left half; title, artist, album, progress, controls and the Lyrics button large on the right.
    - **Lyrics on:** artwork, title and controls on the left; synced lyrics on the right.
    - The lyrics-off variant is verified. The lyrics-on variant still needs a look.
  - **Lyrics transition (verified with a screenshot burst):**
    - Lyrics are **prefetched** whenever the player is open and consent was given, so the pane slides in with finished text.
    - `LyricsPane` fades between states (`.id(stateKey)` plus an opacity/offset transition).
    - The windowed player animates the toggle with a spring.
    - Lyrics state lives in `AppModel.playerLyricsOpen`.
  - **Dev flags:** `--toggle-lyrics` flips lyrics every 4 s, for transition testing. **Always relaunch Bezl without flags after testing**: the maintainer uses the running app, and a leftover `--toggle-lyrics` kept flipping their lyrics. `open Bezl.app --args --player`, `--settings`, `--stage` or `--player-settings` (the player with its drawer open) opens those windows on launch, which lets you test without clicking.
- [ ] Phase 7: Screen-color mode (optional). Not started. `ColorSource` has no `.screen` case yet.
- [ ] Phase 8: Packaging.
  - **Done:** README ✓, CI workflow ✓, app icon ✓ (`scripts/make-icon.swift`).
  - **DMG installer ✓** (`scripts/make-dmg.sh`):
    - Universal arm64 + x86_64, ad-hoc signed with hardened runtime and entitlements.
    - Debug symbols are **stripped**: they contained absolute build paths with the builder's username. The script refuses to package if `$HOME` still appears in the binary.
    - It is never signed with a personal Apple Development certificate, which embeds the owner's name and email.
  - **Not done:** Developer ID signing + notarization (needs a paid account; until then users must "Open Anyway"), Sparkle, Homebrew cask, CONTRIBUTING/SECURITY.

**Deviations from the plan (deliberate):**
- **The shader is compiled at runtime** from `App/Overlay/GlowShader.swift` (`makeLibrary(source:)`), not from a `.metal` file. Xcode 27 needs a separate Metal Toolchain download to compile `.metal` files, and this keeps building from source a one-step job. Contributors should keep it that way.
- **`LookSettings.animation` is renamed to `motion`.** `$binding.animation` clashes with SwiftUI's `Binding.animation(_:)`.
- **Diagnostics moved.** They're a "Diagnostics" disclosure in the menu panel instead of an ⌥-click HUD.
- **The audio ring buffer is a small C target** (`BezlRing`), because Swift's `Synchronization` atomics need macOS 15.
- **Beat thresholds come from a parameter sweep.** The plan said 1.5× median, which fired ~4×/s on white noise. The tuned values are 3.5× median + 0.4 × recent peak: zero false triggers on noise and 100% of clicks hit at 120 and 174 BPM.
- **Signing.** `Config/Base.xcconfig` signs ad-hoc by default. The git-ignored `Config/Signing.local.xcconfig` holds the maintainer's identity, so TCC permissions survive rebuilds.

### 3.1 Architecture

**Stack:** Swift 6 (strict concurrency), SwiftUI for the UI, AppKit for windows, Metal for the glow, Core Audio + Accelerate for audio, and `NSAppleScript` for the music apps. **XcodeGen** (`project.yml`) defines the project so it stays text-based and diff-friendly. Dependencies: **Sparkle** (Phase 8, SPM) and nothing else. Write global hotkeys with Carbon `RegisterEventHotKey` instead of adding a package.

**Repository layout**
```
bezl/
├── CLAUDE.md, README.md, LICENSE, project.yml, .gitignore
├── App/                       # app target (system glue + UI)
│   ├── BezlApp.swift          # @main, MenuBarExtra, AppDelegate adaptor
│   ├── Info.plist             # LSUIElement, usage strings
│   ├── Bezl.entitlements
│   ├── Overlay/               # OverlayManager, OverlayWindow, GlowView (MTKView), Shaders.metal
│   ├── Audio/                 # SystemAudioTap, AudioRingBuffer
│   ├── NowPlaying/            # NowPlayingService, MusicAppSource, SpotifySource
│   ├── ScreenColor/           # (Phase 7) ScreenColorSampler
│   ├── UI/                    # MenuPanel, ColorControls, DisplayPicker, DebugHUD
│   └── Support/               # LaunchAtLogin, Hotkey, Permissions
├── Packages/BezlCore/         # SwiftPM library, no AppKit UI dependencies
│   ├── Sources/BezlCore/
│   │   ├── DSP/               # FFTAnalyzer, OnsetDetector, Envelope, BeatEngine
│   │   ├── Color/             # PaletteExtractor (k-means in Lab), ColorMath
│   │   ├── Geometry/          # EdgeGeometry (rounded rect + notch params)
│   │   └── Settings/          # BezlSettings, DisplaySettings, Preset (Codable)
│   └── Tests/BezlCoreTests/
└── Resources/                 # Assets.xcassets (app icon, menu bar glyph)
```

**Runtime data flow**
```
SystemAudioTap (real-time IO thread)
   └─▶ AudioRingBuffer (lock-free, preallocated)
         └─▶ BeatEngine @ ~94 Hz on a utility queue  ─▶  LightState {level, pulse, beat}
NowPlayingService (distributed notifications + AppleScript)
   └─▶ artwork → PaletteExtractor ─▶ Palette {primary, secondary}
Settings (ObservableObject, persisted)
                                     ▼
                  GlowRenderer per display (MTKView, display-linked)
                  uniforms = settings ⊕ palette (cross-faded) ⊕ LightState (smoothed)
```
`LightState` and `Palette` are published to the renderers through one `@MainActor` `LightingModel`. Each renderer reads the latest values every frame. The renderer must never block the audio thread, and the audio thread must never touch the main actor.

### 3.2 Performance and quality budget (verify in Phase 6)
- **CPU:** under 3% of one core on an M1-class machine while music plays on one 120 Hz display. **0%** when idle: no audio for 5 s in Beat mode, or the static glow has settled. Rendering pauses in those states.
- **GPU:** one full-screen quad per display. The fragment shader uses analytic math only, with no textures or blur passes.
- **Latency:** under 50 ms from an audible kick to the visible pulse.
- **Memory:** under 60 MB resident.
- **Never** steal focus, intercept clicks, appear in Cmd-Tab or Mission Control, or show up in screenshots unless the user wants it to (§Phase 6).

---

### Phase 0: Project skeleton
**Tasks**
1. `brew install xcodegen`.
2. Create `project.yml`:
   - App target `Bezl`, bundle id `io.github.shivshekhar12.bezl`, deployment target **macOS 14.2**, `ARCHS = arm64 x86_64` for Release.
   - `SWIFT_VERSION 6`, strict concurrency complete, hardened runtime ON.
   - Local package dependency `Packages/BezlCore`.
3. Create `Packages/BezlCore/Package.swift` (macOS 14, a library and a test target using Swift Testing).
4. `Info.plist`:
   - `LSUIElement = YES`.
   - `NSAudioCaptureUsageDescription` ("Bezl listens to your Mac's system audio to sync the glow to the beat. Audio is analyzed on-device and never recorded.").
   - `NSAppleEventsUsageDescription` ("Bezl asks Music and Spotify for the current track's artwork to color the glow.").
5. Entitlements: **not sandboxed**, so process taps and Apple Events to other apps work without temporary exceptions. Hardened runtime with `com.apple.security.automation.apple-events = true`. (Record this decision in the README. Mac App Store distribution is not a goal.)
6. A minimal `BezlApp` with a `MenuBarExtra("Bezl", systemImage: "rays")` (`.menuBarExtraStyle(.window)`) and a Quit button.
7. `.gitignore`: `*.xcodeproj` (generated), `build/`, `DerivedData/`, `.DS_Store`, `*.xcuserstate`, `.swiftpm/`.

**Done when:** `xcodegen generate` works, the app builds and launches with no Dock icon and a menu bar item, and `swift test` passes with one placeholder test.

---

### Phase 1: Overlay windows + static glow renderer
**Window: `OverlayWindow: NSPanel`**
- `styleMask: [.borderless, .nonactivatingPanel]`, `backing: .buffered`, frame = `screen.frame` (the full frame, not `visibleFrame`, so the glow covers the menu bar and Dock edges).
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `ignoresMouseEvents = true`.
- `level = .screenSaver`. If that is too high or low in testing, try `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))`. Record the chosen level and the reason in a code comment.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`.
- `canBecomeKey/canBecomeMain` → false. `isReleasedWhenClosed = false`. `animationBehavior = .none`.
- Call `orderFrontRegardless()`. Never `makeKey`.

**`OverlayManager` (@MainActor)**
- Creates one window per `NSScreen`, keyed by `CGDirectDisplayID` (`screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`).
- Rebuilds on `NSApplication.didChangeScreenParametersNotification` (displays added or removed, resolution or arrangement changed). Window frames must track their screens.

**Renderer: `GlowView: MTKView` + `Shaders.metal`**
- Draw a single full-screen triangle. `layer.isOpaque = false`, clear color `(0,0,0,0)`, **premultiplied alpha** output, `colorPixelFormat = .bgra8Unorm`, `framebufferOnly = true`.
- Fragment shader, per pixel `p` in points (pass `drawableSize/contentsScale`):
  1. `d` = signed distance from `p` to the inside of the screen's rounded-rect boundary (corner radius `R`, default 10 pt on notched MacBooks and 0 on external displays, user adjustable). If notch mode is on, the shape is the union of the screen edge and the notch outline (see geometry below), so the rim follows around the camera housing.
  2. `edge = max(0, -d)`, the distance inward from the edge.
  3. Core band: `core = 1 - smoothstep(thickness - 1, thickness + 1, edge)`.
  4. Glow falloff: `glow = exp(-max(0, edge - thickness) / max(glowRadius, 0.001))`.
  5. `alpha = clamp(intensity * max(core, glow * glowAmount), 0, 1)`.
  6. Color: take the angle around the screen center, `t = (atan2(p.y - c.y, p.x - c.x) / 2π + 0.5 + rotation)`, and map it to a two-stop **looping** gradient using `weight` (primary covers `weight` of the loop with smooth blends at both seams). Mix in Lab-ish space, or at least in linear RGB.
  7. Output `float4(color * alpha, alpha)`.
- Uniforms struct (shared with Swift through a bridging header or matched layout): `size, cornerRadius, thickness, glowRadius, glowAmount, intensity, primary, secondary, weight, rotation, notchRect (x,y,w,h), notchRadius, notchEnabled, pulse`.
- **Rendering policy:** `isPaused = true` and `enableSetNeedsDisplay = true` by default, so it redraws only when uniforms change. When animating (Phase 4), unpause with `preferredFramesPerSecond = screen.maximumFramesPerSecond`.

**Geometry (`BezlCore/Geometry/EdgeGeometry.swift`)**: a testable struct that turns an `NSScreen`'s public data into shader parameters:
- `notchRect`: if `screen.safeAreaInsets.top > 0`, the notch spans the gap between `auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX`, with height `safeAreaInsets.top`. Convert to a top-left-origin pixel space for the shader.
- Defaults: `cornerRadius` 10 pt if a notch is present, else 0. `notchRadius` ≈ 8 pt.

**Done when:** a static two-color rim (hard-coded colors) shows on every connected display. It covers the menu bar and full-screen apps, stays on all Spaces, lets every click through, never takes focus, and redraws correctly after a display is plugged or unplugged. Unit tests cover `EdgeGeometry` (notch rect math with synthetic inputs).

---

### Phase 2: Settings model + menu bar UI
**`BezlCore/Settings`**
```swift
enum AnimationMode: String, Codable { case beat, breathe, still }
enum ColorSource: String, Codable { case albumArt, manual, screen }   // screen = Phase 7
struct DisplaySettings: Codable { var enabled = true; var cornerRadius: Double?; var notchCompatible = true }
struct BezlSettings: Codable {
  var isActive = true
  var primary: RGBA; var secondary: RGBA; var primaryWeight = 0.6
  var colorSource: ColorSource = .albumArt          // "Override album color" == .manual
  var animation: AnimationMode = .beat
  var musicSync = true
  var thickness = 6.0        // pt, range 1...40   ("hairline" → "broad band")
  var glow = 0.6             // 0...1 → glowRadius 0...120 pt and glowAmount ("whisper" → "wash")
  var intensity = 0.85       // 0...1 overall brightness
  var beatStrength = 0.7     // 0...1 how hard beats push intensity/thickness
  var rotationSpeed = 0.0    // turns/min, slow gradient drift (0 = off)
  var displays: [String: DisplaySettings] = [:]   // keyed by display UUID string (CGDisplayCreateUUIDFromDisplayID), stable across reboots
}
```
- Persist as JSON in `UserDefaults` under a single `settings.v1` key. Save with a 300 ms debounce. Use a versioned key so migrations are explicit.
- Add `Codable` round-trip tests and default-value tests.

**Menu panel UI (`MenuBarExtra`, `.window` style, ~300 pt wide)**
Sections, top to bottom:
1. Header: app name, **On/Off master toggle**, status line ("Syncing to Spotify", "Listening (no track info)", "Paused", "Needs permission").
2. **Color:** a segmented control for Album art / Manual / Screen (Screen disabled until Phase 7). Two `ColorPicker`s plus a weight slider (Manual only, or always visible to set fallback colors). Show a live gradient preview swatch.
3. **Motion:** a segmented control for Beat / Breathe / Still, and a Beat strength slider.
4. **Shape:** sliders for Thickness, Glow, Brightness.
5. **Display:** a picker (All displays + each screen's `localizedName`), a per-display enable toggle, a "Follow notch" toggle (shown only if that screen has a notch), and a corner radius slider.
6. Footer: a Permissions row (the status of each with a "Fix" button that opens the right System Settings pane), Launch at login, Presets menu (Phase 6), About, Quit.
- Each control updates the glow live.
- Menu bar icon: an SF Symbol (`rays` / `light.max`). Dim it when inactive.

**Done when:** every control visibly changes the overlay live, settings survive relaunch, and the master toggle hides and shows all overlays.

---

### Phase 3: System audio capture (Core Audio process tap, macOS 14.2+)
**`SystemAudioTap`**
1. `let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObjectID])`, `desc.uuid = UUID()`, `desc.muteBehavior = .unmuted`, `desc.isPrivate = true`. Look up our own process object with `kAudioHardwarePropertyTranslatePIDToProcessObject`.
2. `AudioHardwareCreateProcessTap(desc, &tapID)`.
3. Create a **private aggregate device** with `AudioHardwareCreateAggregateDevice` and this dictionary:
   - `kAudioAggregateDeviceNameKey: "Bezl Tap"`, `kAudioAggregateDeviceUIDKey: UUID().uuidString`, `kAudioAggregateDeviceIsPrivateKey: true`.
   - `kAudioAggregateDeviceMainSubDeviceKey`: current default output device UID.
   - `kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]]`.
   - `kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]`, `kAudioAggregateDeviceTapAutoStartKey: true`.
4. Read the format from `kAudioTapPropertyFormat` (expect Float32, 48 kHz, 2 ch, possibly non-interleaved).
5. `AudioDeviceCreateIOProcIDWithBlock` on the aggregate device. In the block, **mix to mono and write into `AudioRingBuffer`** (preallocated, single-producer/single-consumer, atomics from `Synchronization`). Do not allocate, lock, log, or touch Swift actors in the callback. Then `AudioDeviceStart`.
6. Teardown, in order: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`.
7. **Default output changes** (AirPods connect, etc.): listen on `kAudioHardwarePropertyDefaultOutputDevice` and rebuild the aggregate device.
8. **Permission:** the first start triggers the system "audio recording" prompt (using `NSAudioCaptureUsageDescription`). There is no public API to check the status ahead of time. Treat a tap that delivers only zeros for over 2 s while known audio is playing as "possibly denied". Show "Needs permission" with a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` (check that this anchor exists on the current OS; fall back to the Privacy & Security root).
9. Add a debug HUD (hidden; toggle with ⌥-click on the menu bar icon) showing RMS, sample rate, and callback rate.

**Done when:** playing audio in Music, Spotify, a browser, or YouTube shows a moving RMS in the HUD. The microphone indicator (orange dot) **never** appears, but the purple/system-audio indicator may. Switching output to headphones keeps the tap working. Quitting leaves no stray aggregate device in Audio MIDI Setup.

> Reference: Apple's sample "Capturing system audio with Core Audio taps" and the `AudioCap` open-source sample (insidegui/AudioCap, BSD-2). Read them for API shape. Do not copy code without keeping its license header.

---

### Phase 4: Beat detection + animation (`BezlCore/DSP`, all unit-tested)
**`FFTAnalyzer`**: frame size 1024, hop 512 (≈10.7 ms at 48 kHz → ~94 analysis frames/s), Hann window (`vDSP.window`), `vDSP.FFT` / `vDSP_DFT_zrop` real FFT, magnitude spectrum, then log compression `log1p(γ·mag)` with γ≈100.

**`OnsetDetector` (low-band spectral flux)**
- Bands: **kick** 30–150 Hz (main) and **broadband** 150 Hz–8 kHz (secondary, weighted 0.3).
- Flux = Σ max(0, mag[k] − prevMag[k]) over band bins.
- Adaptive threshold over the last ~1 s (≈94 frames): `thr = median(flux) * 1.5 + 0.02 * runningMax`. A frame is an **onset** if `flux > thr` **and** it is a local maximum within ±3 frames (adds 3 frames ≈32 ms of latency) **and** at least 200 ms have passed since the last onset.
- Optional (stretch): tempo tracking by autocorrelation of the flux over 4 s to predict beats. Ship only if the tests show it helps.

**`Envelope` + `BeatEngine` → `LightState`**
- `level`: RMS with attack 10 ms, release 300 ms, normalized by a slowly decaying running peak (AGC over ~10 s), so quiet and loud tracks both move. Use 0 when below a −60 dBFS gate.
- `pulse`: jumps to `onsetStrength` (0…1) on an onset, then decays exponentially (τ ≈ 180 ms).
- `isSilent`: level under the gate for over 5 s.
- Output is published at the analysis rate. The renderer smooths it again per frame (critically damped spring) so motion looks fluid at 120 Hz.

**Mapping to visuals (renderer side)**
- Beat mode: `intensity' = intensity * (0.55 + 0.45 * level) + beatStrength * 0.35 * pulse`. `thickness' = thickness * (1 + beatStrength * 0.6 * pulse)`. `glowRadius' = glowRadius * (1 + 0.4 * pulse)`.
- Breathe: a sine at 0.2 Hz modulating intensity by ±25%. Ignores audio.
- Still: constant. The renderer stays paused.
- Silence in Beat mode: fade to the Still look over 1.5 s, then **pause rendering** (0% CPU).

**Tests (synthetic signals, no audio files committed)**
- 120 BPM click track (50 ms 60 Hz sine bursts plus noise at −30 dB): ≥95% of beats detected, each within ±25 ms, and fewer than 5% false positives.
- Steady sine or pink noise: no onsets after warm-up.
- Silence: `isSilent` becomes true after 5 s, and `level == 0`.
- Loud vs. quiet copies of the same click track: the same onset count (AGC works).
- A performance test: analyzing 60 s of 48 kHz audio takes under 300 ms on Apple silicon.

**Done when:** the tests pass, and with real music the rim visibly hits on the kicks (judged by eye and against the debug HUD's onset flash).

---

### Phase 5: Now playing + album-art colors
**`NowPlayingService` (@MainActor)**: publishes `Track? {app, title, artist, artworkImage}`.
- **Change triggers:** none of this needs polling. Subscribe with `DistributedNotificationCenter` to:
  - Music: `com.apple.Music.playerInfo` (userInfo contains `Player State`, `Name`, `Artist`, `PersistentID`).
  - Spotify: `com.spotify.client.PlaybackStateChanged` (userInfo contains `Player State`, `Track ID`, `Name`, `Artist`).
- Also read state once at launch, and when `NSWorkspace` reports either app launching or quitting.
- **Artwork via AppleScript (`NSAppleScript`, run on a background serial queue; it blocks):**
  - **Guard first:** only script an app if `NSRunningApplication.runningApplications(withBundleIdentifier:)` is non-empty (`com.apple.Music`, `com.spotify.client`). `tell application` would otherwise **launch** the app.
  - Music: `tell application "Music" to get raw data of artwork 1 of current track` → `NSAppleEventDescriptor.data` → `NSImage`. Handle tracks with no artwork.
  - Spotify: `tell application "Spotify" to get artwork url of current track` → fetch the HTTPS image with `URLSession` (ephemeral config, no cookies). Document in the README that this is the **only** network request Bezl makes besides update checks. It only downloads cover art and sends no user data.
  - Cache by track ID (last 20 artworks in memory).
- **Choosing the source:** if both apps are playing, prefer whichever posted the most recent "Playing" notification.
- **Automation permission:** the first script triggers the "Bezl wants to control Music" prompt. Detect `errAEEventNotPermitted (-1743)` and show it in the Permissions row with a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.

**`PaletteExtractor` (BezlCore, pure, works on a raw RGBA buffer)**
1. Downsample to 48×48 (the app side does the `CGContext` draw).
2. Convert pixels to CIELAB. Drop pixels with alpha < 0.5.
3. k-means with k = 6, k-means++ seeding, a fixed RNG seed (deterministic), and at most 12 iterations.
4. Score each cluster: `population^0.6 * (0.3 + chroma/100)`. Penalize near-black (L < 15) and near-white (L > 92, chroma < 10) by ×0.2.
5. Primary = the top score. Secondary = the next cluster with ΔE76 > 25 from the primary. If none qualifies, derive the secondary by rotating the primary's hue 35° and adjusting lightness.
6. Boost for display: clamp L to 45–80 and raise chroma ×1.2 (capped to the sRGB gamut), so the rim glows instead of looking muddy.
- Tests: a solid red image gives red plus a derived secondary. A 70/30 red/blue split gives red primary and blue secondary. Black-and-white-heavy art still picks the accent color. Results are deterministic across runs.

**Color application:** when the palette changes, cross-fade the renderer's colors over 800 ms (interpolated in Lab). If there is no track or no artwork, fall back to the manual colors. `colorSource == .manual` ignores album colors entirely ("Override album color").

**Done when:** changing tracks in Music and in Spotify recolors the rim within ~1 s with a smooth fade, neither app is launched by Bezl, denied permissions show clearly in the UI, and the palette tests pass.

---

### Phase 6: Polish
1. **Notch:** the per-display "Follow notch" toggle (on by default for notched screens). When off, the rim takes the straight top edge and is hidden behind the notch.
2. **Multi-display:** per-display enable and corner radius are keyed by display UUID. Displays not yet configured inherit the global defaults.
3. **Full-screen and sharing behavior (settings, both default off):** "Hide in full-screen apps" (watch `NSWorkspace.activeSpaceDidChangeNotification` plus the frontmost window's full-screen state) and "Hide from screenshots and screen sharing" (`window.sharingType = .none`).
4. **Presets:** save, rename, delete, and apply named presets (a `Preset` Codable containing the visual subset of settings). Import and export as `.bezl.json`. Ship 4 built-ins with original names, e.g. "Ember", "Lagoon", "Neon", "Paper".
5. **Global shortcut:** ⌃⌥⌘L toggles On/Off by default (Carbon `RegisterEventHotKey`), and is rebindable later.
6. **Launch at login:** `SMAppService.mainApp.register()` / `unregister()`, with a toggle in the footer.
7. **Power:** pause rendering when screens sleep (`NSWorkspace.screensDidSleepNotification`), the session resigns (fast user switching), or the display is asleep. In Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`), cap the frame rate at 60.
8. **Onboarding:** a one-time small window on first launch that explains the two permissions and has "Start listening" and "Connect Music/Spotify" buttons, so the prompts appear in context.
9. **Accessibility:** respect `NSWorkspace.accessibilityDisplayShouldReduceMotion` by defaulting to Still mode and limiting pulse amplitude. All controls need labels for VoiceOver.
10. **Measure the budget (§3.2):** check CPU with Activity Monitor and `top -pid`, and GPU and frame pacing with Instruments (Metal System Trace). Record the numbers in the README.

**Done when:** every item works, the budget numbers are measured and written down, and the QA checklist (§3.4) passes.

---

### Phase 7: Screen-color mode (optional)
- Uses **ScreenCaptureKit** (`SCStream`) at a tiny size (e.g. 64×36) and 2–4 fps, excluding Bezl's own windows (`SCContentFilter(display:excludingApplications:[self])`). The frames feed the same `PaletteExtractor`, with a 1.5 s cross-fade.
- Requires the **Screen Recording** permission. Only ask for it when the user picks the "Screen" color source, and explain it in the UI. Stop the stream whenever another color source is selected.
- **Done when:** the rim follows the dominant colors of a video playing on screen, at under 2% extra CPU.

---

### Phase 8: Packaging and release
1. **README.md:**
   - What Bezl is, a GIF demo, and install instructions (DMG and `brew install --cask` later).
   - How to build from source, the permissions explained plainly, the privacy statement (no data leaves the Mac except Spotify cover-art downloads and update checks), and the measured performance figures.
   - An inspired-by credit ("Inspired by apps like Lumn"; no logos), contributing notes, and the MIT license.
2. **App icon:** an original design. Do not use Lumn's icon.
3. **Signing:** CI builds are unsigned. If the maintainer adds a Developer ID, add `scripts/release.sh`: archive, sign, notarize (`xcrun notarytool submit --wait`), staple, and build the DMG (`hdiutil create`).
4. **GitHub Actions:** on push and PR, run `macos-latest`, `swift test --package-path Packages/BezlCore`, and `xcodebuild build`. On a tag `v*`, build a universal Release and attach a DMG and zip to the GitHub Release.
5. **Sparkle (SPM):** host the appcast on GitHub Pages, sign updates with EdDSA (`generate_keys`, private key stored in a repo secret, never committed). Put a "Check for updates" item in the footer, with automatic checks opt-in on first launch.
6. **Homebrew cask:** submit once there's a notarized release.
7. Add `CONTRIBUTING.md`, issue templates (bug report with the macOS version, chip, music app, and HUD screenshot), and a `SECURITY.md`.

**Done when:** a tagged release produces a downloadable DMG that runs on a clean Mac, and CI is green.

---

### 3.2b Release process
- **Cut a release:** `scripts/release.sh X.Y.Z`. It refuses unless you're on a clean `main` that's in sync with origin. It then:
  1. Bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and runs the tests.
  2. Builds the DMG with `scripts/make-dmg.sh`.
  3. Commits `Release vX.Y.Z`, tags it, pushes, and publishes the GitHub Release (notes = commits since the last tag, plus install steps and SHA-256).
  - **Dry run:** `scripts/release.sh X.Y.Z --dry-run` builds and prints the notes without committing or publishing.
- **Signing today:** ad-hoc, so users click "Open Anyway" once.
- **To ship notarized builds (one-time, maintainer only):**
  1. Enroll in the Apple Developer Program ($99/yr) with the maintainer's Apple ID.
  2. In Xcode → Settings → Accounts → Manage Certificates, add a **Developer ID Application** certificate.
  3. Create an app-specific password at appleid.apple.com. Then run `xcrun notarytool store-credentials bezl --apple-id <id> --team-id <TEAMID>`, which stores it in the keychain. Never commit it.
  4. Release with `BEZL_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" BEZL_NOTARY_PROFILE=bezl scripts/release.sh X.Y.Z`. `make-dmg.sh` then signs with a timestamp, notarizes, staples and checks with `spctl`.
  - A Developer ID signature necessarily shows the account holder's name. That is expected for notarized apps.

### 3.3 Known pitfalls
- `tell application "X"` **launches** X. Always check that it's running first.
- AppleScript calls are synchronous and can hang for seconds if the target app is busy. Run them off the main thread with a timeout (`with timeout of 2 seconds`).
- Process tap IO blocks run on a real-time thread. Any allocation, lock, `print`, or Swift actor hop there causes audio glitches system-wide.
- A leaked aggregate device persists until reboot or coreaudiod restarts. Always tear down on quit (`applicationWillTerminate`) and on output-device change.
- `NSScreen` coordinates have a bottom-left origin, while Metal and the shader expect top-left. Convert once in `EdgeGeometry` and test it.
- Overlay windows set to `.canJoinAllSpaces` still disappear on Space switches if `.stationary` is missing. Include both.
- Distributed notifications from Spotify arrive with `Player State` of `Paused` or `Stopped`. Treat both as not playing.
- `CATapDescription` APIs need macOS 14.2. Guard with `@available` and set the deployment target to 14.2. Do not try to support 14.0–14.1.
- HDR/EDR displays: start with `.bgra8Unorm` (SDR). EDR glow (`.rgba16Float` + `wantsExtendedDynamicRangeContent`) is a possible later improvement and should be opt-in.

### 3.3b Lessons from the first real run (2026-11-19)
- **Real-time callbacks must be built outside the main actor.** A closure written inside a `@MainActor` method inherits that isolation. Swift 6 then traps (`dispatch_assert_queue`) when Core Audio calls it on the IO thread. Build such blocks in a `nonisolated static func` (see `SystemAudioTap.makeIOBlock`).
- **`st` is a reserved word in AppleScript** (the ordinal suffix). The script fails to compile with error -2741. Use descriptive variable names.
- **In zsh, `log` is a shell builtin.** Call `/usr/bin/log show ...`. Plain `log show` prints nothing.
- **A display can be switched off from the panel**, which leaves the screen silently dark. The status line now says "Every display is turned off".
- **Screenshots show glow inside the notch area** (a solid block). Those pixels are physically hidden by the camera housing. The cause is not investigated; it's low priority.
- **Saved settings** are JSON in `defaults read io.github.shivshekhar12.bezl settings.v1` (data). Decode them with `plistlib` to debug.

### 3.3c The look (target, studied from Lumn's public demo video, 2026-11-19)
The local file `lumn-demo.mp4` is git-ignored. It's another product's copyrighted material: study it, never commit it. The target behaviors, now implemented in `GlowShader.swift` and `LightingController.frame`:
- **Band:** a soft, translucent tint (~14 pt default) with a blurred inner edge. No hard line and no white-hot core.
- **Liquid edge:** the band's thickness ripples along the perimeter (three incommensurate sines, ±35%). It flows slowly, faster when the music is loud. It freezes in Still mode.
- **Color:** two large regions with wide seams (0.16 turn). On a beat the gradient eases **half a turn** (a critically damped spring, ~0.6 s), so the colors trade places by sweeping along the edge. Swaps are rate-limited to one per second, roughly once a bar.
- **Brightness:** each swap dips ~35% in 80 ms, then swells back over ~0.5 s. Loudness adds only gentle following (±15%). There are no strobe flashes.
- **Verify motion with a burst of still screenshots** (`screencapture -x` in a loop). `screencapture -V` video recordings leave the overlay out.

### 3.4 Manual QA checklist (run before each release)
- [ ] Fresh install: the onboarding window appears, both permission prompts appear in context, and denying each shows a clear "Fix" path.
- [ ] Music: play, pause, and skip. Colors and motion follow, and Bezl never launches Music by itself.
- [ ] Spotify: same as Music. Cover art loads, and an offline Spotify falls back to the manual colors.
- [ ] A browser or YouTube with no track info: the beat still syncs (pure audio) and the colors are manual.
- [ ] Silence: rendering pauses within ~7 s, and Activity Monitor shows ~0% CPU.
- [ ] Notched MacBook: the rim follows the notch, and toggling the notch setting works.
- [ ] An external display: plug and unplug while running, per-display settings persist, and resolution changes are handled.
- [ ] Full-screen video, Mission Control, and Space switching: the overlay behaves as configured and never takes clicks.
- [ ] Switching to AirPods mid-song: the tap survives.
- [ ] Quit: no "Bezl Tap" device remains in Audio MIDI Setup.
- [ ] Reduce Motion on: defaults are respected.
- [ ] The CPU and latency budgets in §3.2 are met.
