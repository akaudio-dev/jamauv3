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

All core features are implemented and working: NINJAM protocol (connect, auth, chat, audio upload/download), bidirectional OGG Vorbis audio (IntervalBuffer upload + RemoteAudioMixer download), host tempo sync with drift correction and transport snap, Icecast listener mode, server browser with Join button for public servers, metronome (beat 1 / all beats, render-thread sine synthesis), per-user level meters, stereo mode, chat terminal, auto-reconnect, compact top bar UI, XPC rate-limit throttling, iOS/iPadOS support (tested on iPad Pro), deferred engine start for iOS battery savings, no mic passthrough (output = remote audio + metronome + Icecast only). 77 tests pass (protocol, E2E, codec, memory, level preservation) including with TSan.

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
- Progress indicator for first interval — show buffering/waiting state when joining a NINJAM session or starting Icecast listening, before audio begins playing

### 2. Polish (Medium Priority)
- Per-user pan slider (stereo position control, similar to gain slider — linear -1.0 L to +1.0 R, default center)
- Configurable OGG encoder quality (currently hardcoded at 0.1 ≈ 75 kbps; range -0.1 to 1.0, see quality-to-bitrate mapping in `OggVorbisEncoder.qualityForBitrate`)
- Settings persistence (audio quality, latency compensation)
- Error handling improvements (reconnect logic, timeout UX)

### 3. iOS/iPadOS Polish
- Set `preferredContentSize = CGSize(width: 320, height: 480)` in `AudioUnitViewController.viewDidLoad` — iOS hosts (GarageBand, AUM) may give zero-size frame without it
- Gain slider layout too rigid for iPhone — `VerticalGainSlider` hardcoded `frame(width: 30, height: 160)`, needs `GeometryReader` or horizontal `ScrollView`
- Deprecated `onChange` single-closure form in `jamauv3ExtensionMainView.swift` — update to two-parameter `.onChange(of:) { _, _ in }`
- Missing keyboard modifiers on connection fields — `.keyboardType(.URL)`, `.numberPad`, `.textInputAutocapitalization(.never)`
- **Do NOT remove** `inter-app-audio` entitlement from `jamauv3.entitlements` — despite being deprecated, iOS requires it for the host app to discover and load AUv3 extensions via `AVAudioUnitComponentManager`
- `UserDefaults.standard` not shared across AU hosts — consider App Group for cross-host persistence

### 4. Future Ideas
- World map: server `users[]` entries include `lat`/`lon` — render on `MapKit` map (like JamTaba)

### 5. App Store Preparation

## Key Facts
- **NINJAM port:** 2049
- **Protocol:** OGG Vorbis @ 64-96 kbps, BPM/BPI-based intervals
- **Common settings:** 120 BPM, 16 BPI = 8 second intervals
- **NINJAMClient:** Use from UI via `@ObservedObject` - has `isConnected`, `connectionStatus`, `lastError`, `bpm`, `bpi`, `currentBeat`, `intervalProgress`, `hostBPM`, `serverTopic`, `chatMessages`, `isBPMMismatch`, `userPeaks`, `slotUsernames`
- **Upload messages:** `ClientUploadIntervalBegin` (0x83, fourCC=`0x7647474F` for OGG, 0 for silence) + `ClientUploadIntervalWrite` (0x84, flags bit 0 = end of interval)
- **IntervalConfig:** `IntervalConfig(bpm:bpi:sampleRate:)` → `intervalLengthInSamples` (e.g. 120 BPM, 16 BPI, 44100 Hz = 352800 samples)
- **AU type:** `aumf` (Music Effect) — receives audio + MIDI, enables tempo/transport sync
- **Render block:** Pulls input directly into the output buffer for in-place processing (`pullBlock(..., outputData)`). Do NOT use a separate BufferedInputBus for audio — hosts (e.g. Ableton) return `mDataByteSize=0` when pulling into a separate buffer. `channelCapabilities = [-1, -1]` (any matching N-in/N-out). `canProcessInPlace = true`. Default format uses hardware sample rate (CoreAudio on macOS, AVAudioSession on iOS); `onSampleRateChange` callback reconfigures IntervalBuffer + RemoteAudioMixer on mid-session rate changes. **No passthrough**: output buffers are zeroed (not copied from input) to prevent mic→speaker feedback — output contains only remote audio, metronome, and Icecast. Input is still captured by IntervalBuffer for NINJAM upload
- **Metronome:** RT-safe sine click synthesis in `DSPKernel.mixMetronome()`. Beat 1: 1000 Hz, full gain. Other beats: 800 Hz, 0.25× gain. Duration: `sampleRate/100` (~10ms) with exponential decay envelope. Tracks own `metronomeSamplePos` (render-thread-only Int), synced via `boundaryHit` reset and transport snap. Config via `Atomic<UInt8>` flags (`metronomeEnabled`, `metronomeBeat1Only`) written from main thread via Combine subscribers. UI: metronome button in top bar (tap toggle, context menu for mode). Defaults to off each session (not persisted). Only plays during NINJAM sessions (not in Icecast listen-only mode)
- **`needsAudio` parameter:** AU parameter at address 100 (boolean). Extension sets to 1.0 when NINJAM connected or Icecast listening, 0.0 when idle. On iOS, host observes this and starts/stops `AVAudioEngine` on demand (500ms debounce on stop). On macOS, engine runs immediately. Defined in `jamauv3ExtensionParameterAddresses.h`, handled in DSPKernel, set by `AudioUnitViewController.updateNeedsAudio()`, observed by `SimplePlayEngine.observeNeedsAudio()`
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
- **IcecastStreamPlayer:** 2-thread model (URLSession delegate queue decodes, render thread mixes). `AudioFileStreamOpen` (MP3 type hint) + `AudioConverterFillComplexBuffer` for decode. Pre-allocated scratch buffers for both decode and render threads. Ring buffer capacity = ~4 seconds stereo. Prebuffer watermark: 128000 samples (matching JamTaba's `BUFFER_SIZE`) — playback delayed until threshold reached, re-enters prebuffering on underrun. Packet data accumulated directly into raw `inputDataBuffer` (no intermediate Swift `Data` copy). Peak tracked via `_peakLevel` atomic (UInt32 bit pattern), read+reset via `exchangePeak()`. Lifecycle: `AudioUnitViewController` creates/destroys player, wires to `DSPKernel.icecastPlayer`. Callbacks (`onListenStart`/`onListenStop`/`icecastPeakReader`) flow from `AudioUnitViewController` → `jamauv3ExtensionMainView` → `ServerBrowserView` → `ServerBrowserViewModel`
- **`additiveMix()` utility:** Shared `@inline(__always)` free function in `RemoteAudioMixer.swift` — handles all 4 channel format combinations (stereo→stereo, stereo→mono downmix, mono→stereo, mono→mono) with gain and peak tracking. Used by both `RemoteAudioMixer.mixInto()` and `IcecastStreamPlayer.mixInto()`. RT-safe: no allocations, no locks
- **Build scripts:** `build-and-run.sh` kills stale processes, builds, re-registers extension via `pluginkit -a`, launches from DerivedData. Proactively removes `/Applications/Jam AUv3.app` to prevent pluginkit conflicts. `build-and-install.sh` same but copies to `/Applications` for system-wide availability. Both prevent the "stale extension" problem where macOS loads a cached old binary
- **Host app loads AU in-process** (`.loadInProcess` on macOS, `[]` on iOS): avoids XPC rate-limit noise and NSRemoteView overhead for the test host. On iOS, activates `AVAudioSession(.playAndRecord)` before wiring the audio graph, defers engine start until `needsAudio` parameter signals 1.0. Format validation guard prevents crash if input node returns invalid format. CoreMIDI setup skipped on iOS (`MIDIClientCreateWithBlock` hangs on XPC). Real DAW hosts load out-of-process with their own sandboxing

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
