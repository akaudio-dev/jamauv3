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
│   │   └── IntervalBuffer.swift # Interval capture → OGG encode → upload messages
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
- ✅ Tests: protocol parsing, E2E auth, OGG encode/decode, interval serialization, remote mixer, memory leak detection, **level preservation** (66 tests pass)

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
- Wire up per-user gain controls (already in UI, RemoteAudioMixer maps users to gain slots 0-7)
- Implement metronome (click on beat 1 / all beats, render thread)
- Accept host's audio format dynamically (currently defaults to 44100 Hz)

### 2. Polish (Medium Priority)
- Configurable OGG encoder quality (currently hardcoded at 0.1 ≈ 75 kbps; range -0.1 to 1.0, see quality-to-bitrate mapping in `OggVorbisEncoder.qualityForBitrate`)
- Settings persistence (audio quality, latency compensation)
- Error handling improvements (reconnect logic, timeout UX)
- User list display (show connected users with channel names)

### 3. Platform (Lower Priority)
- iOS/iPadOS build + testing
- Standalone host app improvements
- App Store preparation

## Key Facts
- **NINJAM port:** 2049
- **Protocol:** OGG Vorbis @ 64-96 kbps, BPM/BPI-based intervals
- **Common settings:** 120 BPM, 16 BPI = 8 second intervals
- **NINJAMClient:** Use from UI via `@ObservedObject` - has `isConnected`, `connectionStatus`, `lastError`, `bpm`, `bpi`, `currentBeat`, `intervalProgress`, `hostBPM`, `serverTopic`, `chatMessages`, `isBPMMismatch`
- **Upload messages:** `ClientUploadIntervalBegin` (0x83, fourCC=`0x7647474F` for OGG, 0 for silence) + `ClientUploadIntervalWrite` (0x84, flags bit 0 = end of interval)
- **IntervalConfig:** `IntervalConfig(bpm:bpi:sampleRate:)` → `intervalLengthInSamples` (e.g. 120 BPM, 16 BPI, 44100 Hz = 352800 samples)
- **AU type:** `aumf` (Music Effect) — receives audio + MIDI, enables tempo/transport sync
- **Render block:** Pulls input directly into the output buffer for in-place processing (`pullBlock(..., outputData)`). Do NOT use a separate BufferedInputBus for audio — hosts (e.g. Ableton) return `mDataByteSize=0` when pulling into a separate buffer. `channelCapabilities = [-1, -1]` (any matching N-in/N-out). `canProcessInPlace = true`
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

## Testing

**Test server credentials** are stored in `.claude/settings.local.json` as environment variables (`NINJAM_TEST_HOST`, `NINJAM_TEST_PORT`, `NINJAM_TEST_USER`, `NINJAM_TEST_PASS`). E2E tests use these to connect to a real NINJAM server. Pass them when running tests:
```bash
NINJAM_TEST_HOST="..." NINJAM_TEST_PORT="..." NINJAM_TEST_USER="..." NINJAM_TEST_PASS='...' xcodebuild test -scheme jamauv3 -destination 'platform=macOS' -enableCodeCoverage NO
```

**Note:** Use `-enableCodeCoverage NO` to avoid `___llvm_profile_runtime` linker errors with C package targets (swift-ogg).

## Reference Codebases
- **JamTaba:** `~/work/github/JamTaba/src/Common/ninjam/` - Modern Qt client
- **Original NINJAM:** `~/work/github/ninjam/ninjam/njclient.cpp` - Cockos' implementation

## Git
```
origin: quiet:/storage/git/jamauv3.git
```
