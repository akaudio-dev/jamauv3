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
- ✅ AudioUnitViewController wires IntervalBuffer + RemoteAudioMixer ↔ NINJAMClient (auto start/stop/config update)
- ✅ Tests: protocol parsing, E2E auth, OGG encode/decode, interval serialization, remote mixer, memory leak detection

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

## Next Steps (Priority Order)

### 1. Integration (High Priority)
- Wire up per-user gain controls (already in UI, RemoteAudioMixer maps users to gain slots 0-7)
- Implement metronome

### 2. Polish (Medium Priority)
- Chat UI (protocol support exists)
- Settings (audio quality, latency compensation)
- Error handling improvements

## Key Facts
- **NINJAM port:** 2049
- **Protocol:** OGG Vorbis @ 64-96 kbps, BPM/BPI-based intervals
- **Common settings:** 120 BPM, 16 BPI = 8 second intervals
- **NINJAMClient:** Use from UI via `@ObservedObject` - has `isConnected`, `connectionStatus`, `lastError`, `bpm`, `bpi`, `currentBeat`, `intervalProgress`
- **Upload messages:** `ClientUploadIntervalBegin` (0x83, fourCC=`0x7667674F` for OGG, 0 for silence) + `ClientUploadIntervalWrite` (0x84, flags bit 0 = end of interval)
- **IntervalConfig:** `IntervalConfig(bpm:bpi:sampleRate:)` → `intervalLengthInSamples` (e.g. 120 BPM, 16 BPI, 44100 Hz = 352800 samples)
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
