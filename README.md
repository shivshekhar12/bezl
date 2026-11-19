# Bezl

**Free, open-source ambient light for your Mac.** Bezl adds a soft glowing rim around the edges of your screen. The colors come from your album art, and the glow pulses with the beat.

- **Beat sync:** pulses on the kicks of whatever your Mac is playing, in any app: Music, Spotify, YouTube, games.
- **Album colors:** pulls a two-color gradient from the current track's artwork in Music or Spotify.
- **Your look:** choose your own colors, the balance between them, a slow color drift, the thickness (from a hairline to a broad band), the glow spread and the brightness.
- **Motion modes:** Beat, Breathe or Still.
- **Notch aware:** the rim follows around the camera housing on MacBooks. Each display has its own settings.
- **Presets:** four built-in looks. Save your own and share them as `.bezl.json` files.
- **Stays out of the way:** clicks pass through and focus never moves to Bezl. It can hide in full-screen apps and from screenshots or screen sharing. Turn it on or off from anywhere with ⌃⌥⌘L.

> Inspired by paid apps like Lumn. Bezl is an independent, from-scratch implementation under the MIT license.

## Requirements

- macOS **14.2** or later, on Apple silicon or Intel
- Music or Spotify, for album colors (optional: beat sync works with any audio)

## Install

Releases are not published yet. Build it from source:

```sh
brew install xcodegen
git clone https://github.com/shivshekhar12/bezl.git && cd bezl
xcodegen generate
xcodebuild -project Bezl.xcodeproj -scheme Bezl -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Bezl.app
```

Or open `Bezl.xcodeproj` in Xcode and press Run.

To stop macOS from asking for permission again after every rebuild, sign with your own development certificate. Create `Config/Signing.local.xcconfig` (it's git-ignored):

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

## Permissions and privacy

Bezl asks for two permissions, and each one is optional:

| Permission | Why | Without it |
|---|---|---|
| **System Audio Recording** | To find the beat in what your Mac is playing. It uses a Core Audio process tap, which **never touches the microphone**. Audio is analyzed in memory and thrown away immediately. Nothing is recorded or saved. | The glow doesn't pulse. Breathe and Still still work. |
| **Automation → Music / Spotify** | To read the current track's artwork for colors. Bezl only talks to these apps while they're already running. It never launches them. | Your manual colors are used. |

Bezl has no analytics, accounts or license keys. The only network request it makes is downloading Spotify's cover image, because Spotify gives out a link to the artwork rather than the image itself. That request sends nothing about you.

The audio tap only runs while Beat mode and Music sync are both on. In Breathe or Still mode, or with sync off, Bezl doesn't capture audio at all.

## How it works

| Part | Approach |
|---|---|
| Overlay | One borderless, transparent, click-through `NSPanel` per display. It sits above full-screen apps and joins every Space. |
| Rendering | A single Metal fragment shader computes each pixel's distance to the rounded screen edge and the notch. That gives a bright core band plus an exponential halo, colored by a looping two-color gradient. The renderer redraws only when something changes. With nothing playing it pauses completely. |
| Audio | A Core Audio process tap plus a private aggregate device (macOS 14.2+) captures the audio. The real-time callback mixes to mono into a lock-free ring buffer written in C. |
| Beat detection | Accelerate FFT (1024-sample frames, 512-sample hop), then spectral flux on the low band, then an adaptive median threshold with peak picking. Separately, an RMS envelope with automatic gain tracks loudness. Everything is tested against synthetic click tracks. |
| Album colors | Music and Spotify post distributed notifications on every track change, so Bezl never polls. It reads the artwork with AppleScript, then runs k-means in CIELAB to pick two distinct, vivid colors, and cross-fades between palettes. |

The pure logic lives in the [`BezlCore`](Packages/BezlCore) Swift package (DSP, color, geometry and settings), so you can test it with no app or permissions:

```sh
swift test --package-path Packages/BezlCore
```

## Contributing

Issues and pull requests are welcome. [`CLAUDE.md`](CLAUDE.md) has the full design notes and roadmap. `project.yml` defines the Xcode project, so don't edit the generated `.xcodeproj`. Run `xcodegen generate` after adding files.

## License

[MIT](LICENSE)
