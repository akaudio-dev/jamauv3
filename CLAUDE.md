# jamauv3 - Critical Project Context

## What This Is
**jamauv3** - AUv3 plugin for NINJAM (online collaborative music jamming). Targets iOS/iPadOS/macOS.

**NINJAM** - Musicians jam with ~1 interval latency. Audio (OGG Vorbis) streamed to server, redistributed to all. You hear others' *previous* interval.

## Project Structure
```
/Volumes/Data/work/jamauv3/
├── Shared/
│   ├── NINJAM/                 # Protocol implementation
│   │   ├── NINJAMClient.swift  # Main client (@MainActor, ObservableObject)
│   │   └── NINJAMProtocol.swift # All message types + IntervalConfig
│   └── Audio/                  # Shared audio codecs + mixer (added to host + extension targets)
│       ├── OggVorbisDecoder.swift
│       ├── OggVorbisEncoder.swift
│       └── RemoteAudioMixer.swift  # Receives OGG from remote users, decodes, mixes into output
├── jamauv3Extension/           # The AUv3 plugin
│   ├── DSP/                    # Pure Swift audio processing
│   │   ├── DSPKernel.swift     # Render thread processing, captures input + mixes remote output
│   │   ├── CircularBuffer.swift # Lock-free SPSC buffer (Synchronization.Atomic)
│   │   ├── IntervalBuffer.swift # Interval capture → OGG encode → upload messages
│   │   └── IcecastStreamPlayer.swift # HTTP→AudioFileStream→AudioConverter→CircularBuffer→render mix
│   ├── Common/UI/              # ConnectionSettings, AudioUnitViewController (wires IntervalBuffer + RemoteAudioMixer ↔ NINJAMClient)
│   ├── Parameters/             # AU parameters
│   └── UI/                     # Main SwiftUI view
├── jamauv3Tests/               # Tests (protocol, E2E, encoding, memory)
└── jamauv3/                    # Host app for testing
```

## Current Status

**Working:**
- ✅ NINJAM client: connect, authenticate, keepalive, receive messages
- ✅ Protocol: all message types (auth, config, user info, chat, audio download/upload)
- ✅ SwiftUI UI with connection settings + interval timing (BPM/BPI, beat counter, progress bar)
- ✅ OGG Vorbis **encoding** and **decoding** (libvorbis via CVorbis/COgg modules from swift-vorbis/swift-ogg packages)
- ✅ Pure Swift DSP kernel + lock-free CircularBuffer (Synchronization.Atomic)
- ✅ **Interval Buffer System**: sample-accurate capture, incremental OGG encoding, streaming upload
- ✅ **Remote Audio Mixer**: receives OGG from remote users, decodes to PCM, double-buffered playback with RT-safe mixing
- ✅ **Bidirectional audio**: local audio captured and sent to server, remote audio received and mixed into output
- ✅ AudioUnitViewController wires IntervalBuffer + RemoteAudioMixer ↔ NINJAMClient (auto start/stop/config update)
- ✅ **Host Tempo Sync**: reads host musical context (tempo, beat position) every render callback, computes drift at interval boundaries, corrects next interval length ±256 samples. Both IntervalBuffer and RemoteAudioMixer receive the corrected length for synchronized boundaries
- ✅ **Transport Snap**: detects DAW transport start, seek, and initial NINJAM connect — snaps `samplePosition` in both IntervalBuffer and RemoteAudioMixer so interval boundaries align with BPI-multiple beats on the DAW grid. Uses `transportStateBlock` with beat-position-change fallback
- ✅ **HUD overlay**: server topic, host BPM with mismatch warning, chat messages (join/part/message/topic, capped at 50 entries)
- ✅ **Stereo mode**: configurable mono/stereo capture+playback (ConnectionSettings toggle, persisted to UserDefaults)
- ✅ **Chat terminal**: send+receive messages, auto-scroll, server topic bar
- ✅ **Auto-reconnect**: reconnects to saved server on AU load (no UI required)
- ✅ **Memory leak fix**: stale GUID eviction in RemoteAudioMixer prevents unbounded activeDownloads growth
- ✅ **Per-user level meters**: 4px green/red peak meters next to each gain slider, ~15 Hz update with exponential decay, real usernames from server replace "User N" labels. Peaks measured in `mixInto()` (post-gain), collected via DSPKernel-owned scratch buffer, published to atomic storage after render callback — ensures meters are tied to actual output timing
- ✅ **Dynamic host audio format**: AU declares default format matching hardware sample rate (CoreAudio on macOS, AVAudioSession on iOS). Detects sample rate changes across `allocateRenderResources` cycles and reconfigures IntervalBuffer + RemoteAudioMixer. Peak buffers survive dealloc/realloc cycles
- ✅ **Compact top bar UI**: single horizontal strip — `(BPM/BPI)(progress bar)(beat/bpi) ... (● server:port)(disconnect)` when connected, `(○ status)(browse)(connect)` when disconnected. Saves vertical space vs the old stacked layout
- ✅ **Server browser**: fetches public server list from `ninbot.com/app/servers.php`, auto-refreshes every 60s. Shows server name, BPM, BPI, user count, connected usernames. Sorted by user count then priority. Server selection populates connection dialog. File: `jamauv3Extension/UI/ServerBrowser.swift`
- ✅ **Connection overlay**: replaced `.sheet` with inline ZStack overlay (sheets don't work in out-of-process AUv3)
- ✅ **XPC rate-limit fixes**: reduced interval timer from 30 Hz → 5 Hz, meter timer from 15 Hz → 5 Hz, quantized progress updates, batched peak/username publishes, removed persistent KVO on `allParameterValues`, removed debug print in parameter setter. Prevents XPC throttling in out-of-process AU
- ✅ **Host app improvements**: loads AU in-process (`.loadInProcess` — avoids XPC overhead for test host), Ctrl+W close shortcut, audio device checks (skip engine on headless Mac, skip input node if no mic), removed crash observer boilerplate
- ✅ **Log level cleanup**: routine protocol/connection messages demoted from `.info` to `.debug` to reduce noise
- ✅ **Icecast listener mode**: listen to public NINJAM servers without connecting. Manual decode pipeline: `URLSession` → `AudioFileStream` (MP3 parsing) → `AudioConverterFillComplexBuffer` (decode to Float32 PCM) → `CircularBuffer` → render thread `mixInto()`. Works in out-of-process AUv3 where AVPlayer cannot produce audio. Level meter in server browser UI (~15 Hz, exponential decay). File: `jamauv3Extension/DSP/IcecastStreamPlayer.swift`
- ✅ Tests: protocol parsing, E2E auth, OGG encode/decode, interval serialization, remote mixer, memory leak detection, **level preservation** (66 tests pass). Memory leak tests use TSan-aware thresholds (`memoryThresholdMultiplier` in TestHelpers.swift) — pass with both `-enableThreadSanitizer YES` and without

### Interval Buffer Architecture (Upload)
```
Render thread              Encoding thread (background)        Main thread (@MainActor)
DSPKernel.process()        encodingLoop() ~100Hz               NINJAMClient.send()
  │ mix L+R → mono           │ read from CircularBuffer           ▲
  │ write to CircularBuffer   │ feed OggVorbisStreamEncoder        │
  │ count samples             │ produce OGG Data chunks            │
  │ set boundary flag         │ dispatch to main thread ───────────┘
  ▼                           ▼
[CircularBuffer] ──SPSC──> [encoder] ──Task @MainActor──> [upload messages]
```

### Remote Audio Mixer Architecture (Download)
```
@MainActor                      Decode thread (background)        Render thread
─────────────────────           ──────────────────────            ─────────────────
NINJAMClient delegate           decodeLoop() ~100Hz              DSPKernel.process()
  │                               │                                ▲
  │ beginDownload()               │ OggVorbisDecoder.decode()      │
  │ receiveData()                 │ resample if needed             │ read currentBuffer
  │ accumulate OGG by GUID        │ write PCM to PlaybackBuffer    │ apply userGains
  │ on isEnd → dispatch ──────>   │ set nextReady flag             │ additive mix
  ▼                               ▼                                │ (mono → stereo)
[DownloadState dict]           [PlaybackBuffer]                  [mixInto() output]
```

### Host Tempo Sync Architecture
```
Render thread (DSPKernel.process())
  │ contextBlock(&tempo, nil, nil, &beatPosition, nil, nil)
  │ store to hostTempo / hostBeatPosition atomics
  │ snapToBeatGridIfNeeded() — on transport start/seek/connect:
  │   compute targetPosition = (beatPos mod BPI) × samplesPerBeat
  │   IntervalBuffer.snapSamplePosition(target)
  │   RemoteAudioMixer.snapSamplePosition(target)
  │ load correctedIntervalLength
  │ pass to IntervalBuffer.captureAudio(intervalLength:) → returns boundaryHit
  │ pass to RemoteAudioMixer.mixInto(intervalLength:)
  │ if boundaryHit → computeDriftCorrection()
  │   compare hostBeat vs nearest BPI multiple
  │   adjust correctedIntervalLength ±256 samples
  ▼
Main thread (diagnostic timer, 5s)
  │ read hostTempo atomic → ninjamClient.hostBPM
  │ HUD displays host BPM, mismatch warning
```

### Icecast Listener Architecture (Listen Mode)
```
URLSession delegate queue              Render thread (DSPKernel.process)
─────────────────────────              ──────────────────────────────────
HTTP bytes arrive (MP3 stream)
  │ AudioFileStreamParseBytes()
  │ → property callback → AudioConverterNew()
  │ → packets callback → AudioConverterFillComplexBuffer()
  │ → Float32 PCM samples
  │ CircularBuffer.write() ──────────→ CircularBuffer.read()
  ▼                                    │ additive mix into output
[delegate queue]                       │ track peak → _peakLevel atomic
                                       ▼
                                    Main thread (~15 Hz peakTimer)
                                      │ exchangePeak() → decay → UI meter
```

## Known Issues

### Signal Level Investigation (Open)
User reports remote audio requires ~164% gain to match the passthrough signal level (same in both mono and stereo modes). Thorough investigation found:
- **OGG codec is level-transparent**: encode/decode round-trip at quality 0.1 preserves RMS at 100.4%, peak at 103.2% (tested across all quality settings -0.1 to 1.0). See `OggVorbisEncoderTests.levelPreservation` and `streamingLevelPreservation` tests
- **Code path has no hidden attenuation**: every stage (pullBlock → DSPKernel passthrough → IntervalBuffer capture → OGG encode → OGG decode → PlaybackBuffer → RemoteAudioMixer.mixInto) was traced and verified level-preserving
- **Mono 0.5× mixdown ruled out**: stereo mode (no mixdown) shows the same level discrepancy
- **RenderProcessor frameOffset bug**: `processSegment` ignores `frameOffset` parameter, which could cause double-processing with MIDI/parameter events — but this would make audio louder, not quieter
- **Possible causes to investigate**: host routing/metering differences, perceptual loudness differences from spectral changes at low codec quality, server-side behavior, or sample rate mismatch between host and IntervalConfig
- **Next step**: add per-interval RMS diagnostic logging at capture and playback stages to pinpoint the discrepancy in a live session

## Next Steps (Priority Order)

### 1. Integration (High Priority)
- Investigate signal level discrepancy (see Known Issues above)
- Implement metronome (click on beat 1 / all beats, render thread)

### 2. Polish (Medium Priority)
- Configurable OGG encoder quality (currently hardcoded at 0.1 ≈ 75 kbps; range -0.1 to 1.0, see quality-to-bitrate mapping in `OggVorbisEncoder.qualityForBitrate`)
- Settings persistence (audio quality, latency compensation)
- Error handling improvements (reconnect logic, timeout UX)

### 3. Discovery &amp; Listener Mode (Done)
- **Public server browser:** ✅ Done. GET `https://ninbot.com/app/servers.php` → JSON. Auto-refresh 60s + manual refresh button. Cache-busted (`.reloadIgnoringLocalCacheData` + timestamp param). Sorted by user count. Server selection pre-fills connection dialog.
- **Listener mode:** ✅ Done. Manual decode pipeline via `IcecastStreamPlayer`: `URLSession` → `AudioFileStream` → `AudioConverter` → `CircularBuffer` → render thread `mixInto()`. Handles MP3 streams. Level meter bar in server browser row (~15 Hz, exponential 0.85× decay, green/red). Stream lifecycle tied to browser open/close. `Icy-MetaData: 0` header suppresses metadata interleaving.
- **World map:** `users[]` entries include `lat`/`lon` — can render connected users on a `MapKit` map, same as JamTaba.

### 4. iOS/iPadOS (Lower Priority)

The project already declares `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"` and `TARGETED_DEVICE_FAMILY = "1,2,7"`. Platform-conditional code (`hardwareSampleRate`, `setSessionActive`, typealiases, `ViewControllerRepresentable`) is already correct. The following are the remaining blockers, in implementation order:

#### CRITICAL — must fix before anything runs on iOS

**a) ~~`.loadOutOfProcess` fails on iOS~~ — FIXED** (`SimplePlayEngine.swift`)
Host app now uses `.loadInProcess`. This fix also resolves the iOS loading issue since in-process works on all platforms.

**b) Extension has no entitlements file — network blocked on iOS** (`project.pbxproj`)
`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` is a macOS-only sandbox key; iOS ignores it. The extension has no `CODE_SIGN_ENTITLEMENTS` file at all. Since `.loadOutOfProcess` will be `[]` on iOS (in-process), the extension inherits the host app's network access — so this may be automatically resolved once (a) is fixed. Verify after fixing (a); if the TCP connection still fails, create `jamauv3Extension/jamauv3Extension.entitlements` with `com.apple.security.network.client = true` and wire `CODE_SIGN_ENTITLEMENTS` in both Debug+Release extension build configs.

**c) Extension microphone entitlement missing** (`project.pbxproj` extension build configs, lines ~472 and ~524)
`ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = NO` in the extension. Same in-process logic applies as (b): if loaded in-process the host app's mic permission covers it. Verify after (a). If mic capture still fails: set `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES` and add `INFOPLIST_KEY_NSMicrophoneUsageDescription` to the extension's build settings.

**d) No `AVAudioSession` setup in extension** (`AudioUnitViewController.swift` or `jamauv3ExtensionAudioUnit.swift:allocateRenderResources`)
The extension process starts with `.soloAmbient` category on iOS — recording is disabled. Add in `AudioUnitViewController.viewDidLoad`:
```swift
#if os(iOS)
let session = AVAudioSession.sharedInstance()
try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
try? session.setActive(true)
#endif
```
`.measurement` mode disables system audio processing. `.mixWithOthers` prevents silencing the host DAW.

#### IMPORTANT — needed for usable UI on iPhone

**e) `preferredContentSize` not set** (`AudioUnitViewController.swift:viewDidLoad`)
Without this, iOS hosts (GarageBand, AUM) may give the plugin a zero-size frame. Add:
```swift
preferredContentSize = CGSize(width: 320, height: 480)
```

**f) Gain slider layout too rigid for iPhone** (`ParameterSlider.swift`)
`VerticalGainSlider` has hardcoded `frame(width: 30, height: 160)`. 8 sliders × 30pt = 240pt minimum — barely fits 320pt iPhone screen with no padding. Replace hardcoded height with a `GeometryReader`-proportional value, or wrap the slider row in a `ScrollView(.horizontal)`.

#### MODERATE — polish

**g) Deprecated `onChange` form** (`jamauv3ExtensionMainView.swift:168`)
`.onChange(of: ninjamClient.chatMessages.count) { _ in` — single-closure form deprecated in iOS 17+. Update to two-parameter form: `.onChange(of: ninjamClient.chatMessages.count) { _, _ in }`.

**h) Missing keyboard modifiers on connection fields** (`jamauv3ExtensionMainView.swift` connection sheet)
Add to server field: `.keyboardType(.URL).autocorrectionDisabled()`. Port field: `.keyboardType(.numberPad)`. Username: `.textInputAutocapitalization(.never).autocorrectionDisabled()`.

#### LOW — cleanup

**i) Deprecated `inter-app-audio` entitlement** (`jamauv3.entitlements`)
Remove `<key>inter-app-audio</key>` — deprecated since iOS 13, may cause App Store review friction.

**j) `UserDefaults.standard` not shared across AU hosts** (`ConnectionSettings.swift:13`)
Connection settings (server, port, user) saved to `UserDefaults.standard` are not visible when the plugin is loaded in a different host app (GarageBand vs AUM etc). If cross-host persistence is desired: add an App Group entitlement to both host and extension, configure a suite name, and use `UserDefaults(suiteName: "group.com.jamauv3")`.

### 5. App Store preparation

## Key Facts
- **NINJAM port:** 2049
- **Protocol:** OGG Vorbis @ 64-96 kbps, BPM/BPI-based intervals
- **Common settings:** 120 BPM, 16 BPI = 8 second intervals
- **NINJAMClient:** Use from UI via `@ObservedObject` - has `isConnected`, `connectionStatus`, `lastError`, `bpm`, `bpi`, `currentBeat`, `intervalProgress`, `hostBPM`, `serverTopic`, `chatMessages`, `isBPMMismatch`, `userPeaks`, `slotUsernames`
- **Upload messages:** `ClientUploadIntervalBegin` (0x83, fourCC=`0x7647474F` for OGG, 0 for silence) + `ClientUploadIntervalWrite` (0x84, flags bit 0 = end of interval)
- **IntervalConfig:** `IntervalConfig(bpm:bpi:sampleRate:)` → `intervalLengthInSamples` (e.g. 120 BPM, 16 BPI, 44100 Hz = 352800 samples)
- **AU type:** `aumf` (Music Effect) — receives audio + MIDI, enables tempo/transport sync
- **Render block:** Pulls input directly into the output buffer for in-place processing (`pullBlock(..., outputData)`). Do NOT use a separate BufferedInputBus for audio — hosts (e.g. Ableton) return `mDataByteSize=0` when pulling into a separate buffer. `channelCapabilities = [-1, -1]` (any matching N-in/N-out). `canProcessInPlace = true`. Default format uses hardware sample rate (CoreAudio on macOS, AVAudioSession on iOS); `onSampleRateChange` callback reconfigures IntervalBuffer + RemoteAudioMixer on mid-session rate changes
- **Musical context:** `DSPKernel.musicalContextBlock` reads host tempo + beat position every render callback. `DSPKernel.transportStateBlock` reads transport moving/stopped state. Both wired in `allocateRenderResources()`. Tempo/beat stored in `hostTempo`/`hostBeatPosition` atomics (render→main thread). Used for drift correction and transport snap
- **Drift correction:** `DSPKernel.computeDriftCorrection()` compares host beat position to nearest BPI multiple at each interval boundary. Only active when host BPM ≈ NINJAM BPM (within 0.5). Adjusts `correctedIntervalLength` by up to ±256 samples. Both IntervalBuffer and RemoteAudioMixer receive the corrected length
- **Transport snap:** `DSPKernel.snapToBeatGridIfNeeded()` detects transport start (`transportMoving && !wasTransportMoving`), seek (beat position jump > 2× expected), and initial connect (`needsInitialSnap` flag). Snaps `samplePosition` in IntervalBuffer and RemoteAudioMixer to `(beatPos mod BPI) × samplesPerBeat`. Falls back to beat-position-change detection if `transportStateBlock` is nil. One-interval glitch at snap is acceptable — next boundary starts fresh
- **NINJAM timing:** No server-side timestamps or beat positions. All timing is pure local sample counting against `intervalLengthInSamples`. Matches njclient.cpp and JamTaba reference implementations
- **HUD:** `ChatEntry` struct with `.message`/`.join`/`.part`/`.topic` types. `NINJAMClient.addChatEntry()` caps at 50 entries. `AudioUnitViewController.didReceiveChatMessage` populates entries + sets `serverTopic`. Diagnostic timer reads `hostTempo` atomic → `ninjamClient.hostBPM`
- **OGG encoder quality:** Default 0.1 ≈ 75 kbps mono. Scale: -0.1 (45 kbps) → 0.0 (64 kbps) → 0.1 (75 kbps) → 0.3 (95 kbps) → 0.5 (110 kbps) → 0.75 (140 kbps) → 1.0 (240 kbps). Codec is lossy (psychoacoustic, like MP3) but level-transparent (RMS preserved at ~100%)
- **Stereo mode:** Configurable via `ConnectionSettings.stereo` toggle (persisted to UserDefaults). Mono: `(L+R)×0.5` mixdown, 1-channel OGG. Stereo: interleaved L/R capture, 2-channel OGG. Both IntervalBuffer and RemoteAudioMixer handle mono and stereo independently
- **User gain range:** 0.0–2.0 (linear), default 1.0. Parameters use `.linearGain` units. UI displays as 0–200%
- **IntervalBuffer:** 3-thread model (render → SPSC CircularBuffer → encoding thread → @MainActor callbacks). Start/stop managed by AudioUnitViewController via NINJAMClientDelegate
- **RemoteAudioMixer:** 3-thread model (@MainActor accumulates OGG fragments → decode thread decodes to PCM → render thread mixes). Double-buffered: decode writes nextBuffer, render swaps at interval boundary. Uses PlaybackBuffer (flat linear buffer) not CircularBuffer. Lives in Shared/Audio/ (compiled into both host + extension)
- **Download messages:** `ServerDownloadIntervalBegin` (0x04, GUID, username, channelIndex, fourCC) + `ServerDownloadIntervalWrite` (0x05, GUID, flags, audioData). Delegate passes fourCC so mixer can skip silence intervals
- **Level meters:** Per-slot peaks measured in `RemoteAudioMixer.mixInto()` (post-gain) via `outPeaks` parameter — a DSPKernel-owned scratch buffer passed into `mixInto()`. DSPKernel resets scratch to zero each render callback, collects peaks during mix, then publishes to `userPeakStorage` (UInt32 bit patterns, max-accumulated). `AudioUnitViewController.meterTask` (~5 Hz) reads+resets via `DSPKernel.exchangeUserPeak(slot:)`, applies ×0.85 decay, writes `NINJAMClient.userPeaks`/`.slotUsernames`. `VerticalGainSlider` renders 4px green/red bar (red when >1.0) + real username. Peaks are tied to the render callback that writes the output buffer, ensuring meters reflect actual playback timing
- **XPC rate limits:** Out-of-process AUv3 has ~32 Hz XPC message limit. All timers and publishes are throttled: interval timer 5 Hz, meter timer 5 Hz, progress quantized to 100 steps, peaks batched with 0.005 threshold, usernames diffed before publish. KVO on `allParameterValues` replaced with one-time sync
- **Server browser:** `ServerBrowserViewModel` (@Observable) fetches from `https://ninbot.com/app/servers.php`, parses `NINJAMServerEntry` array. `FlexInt` handles JSON values that may be string or int. `streamURL` prefers `ssl_stream` over `stream`. UI is `ServerBrowserView` presented as inline overlay via `ActiveSheet` enum
- **AUv3 out-of-process audio limitation:** The extension process (appex) has NO audio output device. `AVPlayer`/`AVAudioEngine` decode audio but produce silence — the AudioQueue output goes nowhere. All audible output MUST go through the AU render callback (`DSPKernel.process()`). This affects listener mode: must manually decode and mix into render output
- **IcecastStreamPlayer:** 2-thread model (URLSession delegate queue decodes, render thread mixes). `AudioFileStreamOpen` (MP3 type hint) + `AudioConverterFillComplexBuffer` for decode. Pre-allocated scratch buffers for both decode and render threads. Ring buffer capacity = 2 seconds stereo. Peak tracked via `_peakLevel` atomic (UInt32 bit pattern), read+reset via `exchangePeak()`. Lifecycle: `AudioUnitViewController` creates/destroys player, wires to `DSPKernel.icecastPlayer`. Callbacks (`onListenStart`/`onListenStop`/`icecastPeakReader`) flow from `AudioUnitViewController` → `jamauv3ExtensionMainView` → `ServerBrowserView` → `ServerBrowserViewModel`
- **Build scripts:** `build-and-run.sh` kills stale processes, builds, re-registers extension via `pluginkit -a`, launches from DerivedData. Proactively removes `/Applications/jamauv3.app` to prevent pluginkit conflicts. `build-and-install.sh` same but copies to `/Applications` for system-wide availability. Both prevent the "stale extension" problem where macOS loads a cached old binary
- **Host app loads AU in-process** (`.loadInProcess`): avoids XPC rate-limit noise and NSRemoteView overhead for the test host. Real DAW hosts load out-of-process with their own sandboxing

## Testing

**Test server credentials** are stored in `.claude/settings.local.json` as environment variables (`NINJAM_TEST_HOST`, `NINJAM_TEST_PORT`, `NINJAM_TEST_USER`, `NINJAM_TEST_PASS`). E2E tests use these to connect to a real NINJAM server. Pass them when running tests:
```bash
NINJAM_TEST_HOST="..." NINJAM_TEST_PORT="..." NINJAM_TEST_USER="..." NINJAM_TEST_PASS='...' xcodebuild test -scheme jamauv3 -destination 'platform=macOS' -enableCodeCoverage NO
```

**Note:** Use `-enableCodeCoverage NO` to avoid `___llvm_profile_runtime` linker errors with C package targets (swift-ogg).

**Thread Sanitizer:** All tests pass with `-enableThreadSanitizer YES`. Memory leak tests auto-detect TSan via `TSAN_OPTIONS` env var and relax thresholds (10×) to accommodate shadow memory overhead. See `memoryThresholdMultiplier` in `TestHelpers.swift`.

## Reference Codebases
- **JamTaba:** `~/work/github/JamTaba/src/Common/ninjam/` - Modern Qt client
- **Original NINJAM:** `~/work/github/ninjam/ninjam/njclient.cpp` - Cockos' implementation

## Git
```
origin: quiet:/storage/git/jamauv3.git
```
