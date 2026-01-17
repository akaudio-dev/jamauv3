# jamauv3 - Project Context for Claude

## What This Project Is

**jamauv3** is a modern AUv3 (Audio Unit v3) reimplementation of JamTaba - a client for NINJAM online music jamming. Target platforms: iOS, iPadOS, macOS (and potentially tvOS later).

### What is NINJAM?

NINJAM (Novel Intervallic Jamming Architecture for Music) is a protocol for real-time collaborative music over the internet. Key concepts:
- Musicians play together with ~1 measure latency
- Audio is compressed (OGG Vorbis) and streamed to server
- Server redistributes audio to all participants
- Everyone hears what others played in the *previous* interval
- This creates a unique "time-shifted" jamming experience

### Why This Project?

JamTaba is Qt-based and desktop-only. This project brings NINJAM to Apple mobile devices as a native AUv3 plugin that works in GarageBand, AUM, Cubasis, etc.

## Reference Codebases

### 1. JamTaba (Primary Reference)
**Location:** `~/work/github/JamTaba`

Modern Qt-based NINJAM client with GUI. Key source paths:
- `src/Common/ninjam/` - NINJAM protocol implementation
- `src/Common/audio/` - Audio processing
- `src/Common/NinjamController.cpp` - Main jam session logic
- `src/Plugins/` - VST/AU plugin implementations

### 2. Official NINJAM (Protocol Reference)
**Location:** `~/work/github/ninjam`

Cockos' original NINJAM implementation. Key files:
- `ninjam/njclient.cpp` / `njclient.h` - Core client (90KB+ of protocol logic)
- `ninjam/netmsg.cpp` / `netmsg.h` - Network message definitions
- `ninjam/mpb.cpp` / `mpb.h` - Message parsing/building
- `ninjam/server/` - Server implementation
- `WDL/` - Cockos utility library (strings, networking, etc.)

### 3. Expert Sleepers Plugin (AU Reference)
**Location:** `~/work/github/sleepers/ninjamplugin`

Old Carbon-era AU plugin (2006). Useful for:
- `njinterface.cpp` - How AU integrates with njclient
- Shows audio buffer handling approach

## Current Project Structure

```
/Volumes/Data/work/jamauv3/
├── jamauv3/                    # Host app (for testing AU)
│   └── Common/Audio/           # Audio playback engine
├── jamauv3Extension/           # The AUv3 plugin
│   ├── DSP/                    # C/C++ audio processing
│   │   ├── jamauv3ExtensionDSPKernel.hpp
│   │   ├── OggDecoder.c/h      # OGG Vorbis decoding (stb_vorbis)
│   │   └── stb_vorbis.h        # stb_vorbis library
│   ├── Common/
│   │   ├── Audio Unit/         # AUAudioUnit Swift implementation
│   │   ├── UI/                 # SwiftUI views, ConnectionManager
│   │   └── Audio/              # OggVorbisDecoder.swift wrapper
│   └── Parameters/             # AU parameter definitions
├── jamauv3Tests/
└── jamauv3UITests/
```

## What's Already Implemented

1. **Basic AUv3 scaffold** - Music Effect type AU with Swift UI
2. **TCP networking** - ConnectionManager for persistent connections
3. **OGG Vorbis decoding** - stb_vorbis integrated with Swift wrapper
4. **MIDI 2.0 support** - Protocol handling in DSP kernel

## What Needs to Be Built

### Protocol Layer
- [ ] NINJAM message parsing (see `ninjam/netmsg.cpp`, `mpb.cpp`)
- [ ] Authentication handshake
- [ ] BPM/BPI synchronization
- [ ] User/channel management

### Audio Layer
- [ ] OGG Vorbis encoding (for sending audio)
- [ ] Interval-based audio buffering
- [ ] Mixing remote user streams
- [ ] Metronome with configurable sounds

### UI Layer
- [ ] Server browser / connection UI
- [ ] Mixer view for remote users
- [ ] Chat interface
- [ ] Settings (latency, audio quality)

## Key Technical Notes

### NINJAM Protocol Basics
- Default port: 2049
- Uses OGG Vorbis @ typically 64-96 kbps
- Intervals measured in BPM/BPI (beats per interval)
- Common: 120 BPM, 16 BPI = 8 second intervals

### AUv3 Constraints
- Must be sandbox-safe
- Network access requires appropriate entitlements
- Real-time audio thread - no blocking operations
- Swift for UI, can use C/C++ for DSP via bridging header

### File Locations Quick Reference
```
JamTaba NINJAM code:     ~/work/github/JamTaba/src/Common/ninjam/
Original njclient:       ~/work/github/ninjam/ninjam/njclient.cpp
Network messages:        ~/work/github/ninjam/ninjam/netmsg.cpp
Server code:             ~/work/github/ninjam/ninjam/server/
This project:            /Volumes/Data/work/jamauv3/
```

## Building

```bash
# Build from command line
xcodebuild -project jamauv3.xcodeproj -scheme jamauv3 -destination 'platform=macOS' build

# Or open in Xcode
open jamauv3.xcodeproj
```

## Git Remote

```
origin: quiet:/storage/git/jamauv3.git
```
