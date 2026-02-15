# jamauv3 - Critical Project Context

## What This Is
**jamauv3** - AUv3 plugin for NINJAM (online collaborative music jamming). Targets iOS/iPadOS/macOS.

**NINJAM** - Musicians jam with ~1 interval latency. Audio (OGG Vorbis) streamed to server, redistributed to all. You hear others' *previous* interval.

## Project Structure
```
/Volumes/Data/work/jamauv3/
├── Shared/NINJAM/              # Protocol implementation
│   ├── NINJAMClient.swift      # Main client (@MainActor, ObservableObject)
│   └── NINJAMProtocol.swift    # All message types
├── jamauv3Extension/           # The AUv3 plugin
│   ├── DSP/                    # Pure Swift audio processing (incl. CircularBuffer)
│   ├── Common/UI/              # ConnectionSettings, AudioUnitViewController
│   ├── Parameters/             # AU parameters
│   └── UI/                     # Main SwiftUI view
├── jamauv3Tests/               # Tests (NINJAMProtocolTests, E2E tests)
└── jamauv3/                    # Host app for testing
```

## Current Status

**Working:**
- ✅ NINJAM client: connect, authenticate, keepalive, receive messages
- ✅ Protocol: all message types (auth, config, user info, chat, audio download)
- ✅ SwiftUI UI with connection settings + interval timing (BPM/BPI, beat counter, progress bar)
- ✅ OGG Vorbis **decoding** (libvorbis via CVorbis module from swift-vorbis package)
- ✅ Pure Swift DSP kernel + lock-free CircularBuffer (Synchronization.Atomic)
- ✅ 32 passing tests (protocol parsing, E2E auth, OGG fragment reception)

## Next Steps (Priority Order)

### 1. OGG Vorbis Encoding (High Priority - Core Functionality)
**New file:** `jamauv3Extension/Common/Audio/OggVorbisEncoder.swift`

Create Swift wrapper for libvorbis encoding (similar to existing OggVorbisDecoder.swift):
- Use CVorbis module (already in project via swift-vorbis package)
- Target quality: ~64-96 kbps for NINJAM
- Input: Float samples from DSP
- Output: Data (OGG stream)

Write tests for encode/decode round-trip.

### 2. Interval Buffer System (High Priority - Core Functionality)
**New file:** `jamauv3Extension/DSP/IntervalBuffer.swift`

Implement:
- BPM/BPI-based interval timing
- Capture audio from DSP kernel during interval
- Encode to OGG when interval completes
- Send via `ClientUploadIntervalBegin` + `ClientUploadIntervalWrite` messages

### 3. Audio Mixing & Playback (Medium Priority)
Implement:
- Decode received OGG streams (already have decoder)
- Mix multiple remote user streams
- Sync playback with interval boundaries
- Route to DSP output

### 4. Integration (Medium Priority)
- Connect NINJAMClient to DSP kernel (bidirectional audio flow)
- Wire up per-user gain controls (already in UI)
- Implement metronome

### 5. Polish (Lower Priority)
- Chat UI (protocol support exists)
- Settings (audio quality, latency compensation)
- Error handling improvements

## Key Facts
- **NINJAM port:** 2049
- **Protocol:** OGG Vorbis @ 64-96 kbps, BPM/BPI-based intervals
- **Common settings:** 120 BPM, 16 BPI = 8 second intervals
- **NINJAMClient:** Use from UI via `@ObservedObject` - has `isConnected`, `connectionStatus`, `lastError`, `bpm`, `bpi`, `currentBeat`, `intervalProgress`

## Reference Codebases
- **JamTaba:** `~/work/github/JamTaba/src/Common/ninjam/` - Modern Qt client
- **Original NINJAM:** `~/work/github/ninjam/ninjam/njclient.cpp` - Cockos' implementation

## Git
```
origin: quiet:/storage/git/jamauv3.git
```
