# Jam AUv3

A NINJAM client for macOS, packaged as an **AUv3 plugin** (Audio Unit Music Effect) with a standalone host app. Jam with other musicians over the internet — from inside your DAW.

By Andrei Kozlov. Sibling project: [AK Audio](https://github.com/akaudio-dev/akaudio), a VCV Rack plugin with a NINJAM module built on the same ideas.

## What is NINJAM?

[NINJAM](https://www.cockos.com/ninjam/) is a protocol for online collaborative music. Instead of fighting network latency, it embraces it: everyone plays along to a shared tempo grid (e.g. 120 BPM, 16 beats per interval), your audio is streamed to the server as OGG Vorbis, and you hear the other players' **previous** interval while you play the current one. It feels less like a phone call and more like trading loops in time — and it works across continents.

## Features

- **AUv3 Music Effect** (`aumf`) — load it in Logic, Ableton Live, GarageBand, or any AU host; your track's audio is what you send to the jam
- **Standalone app** — jam without a DAW; captures your audio input directly
- **Bidirectional audio** — OGG Vorbis upload and download, mono or stereo
- **Host tempo sync** — reads the DAW's tempo and beat position, snaps the interval clock to the transport, and drift-corrects against the host grid
- **Server browser** — public server list with one-click join
- **Listen mode** — tune into a server's Icecast stream without joining
- **Metronome** — render-thread synthesized click, beat-1-only or all beats
- **Per-user mixing** — gain slider and level meter for every player in the room
- **Chat** — the NINJAM chat terminal, join/part notices, server topic

## Install

Download the latest notarized build from [Releases](https://github.com/akaudio-dev/jamauv3/releases), open the DMG, and drag **Jam AUv3.app** to Applications. Launch the app once — that registers the AUv3 plugin with the system; after that it appears in your DAW's Audio Unit list (Music Effect category).

Requires macOS 26.2 or later, Apple Silicon.

## Build from source

Open `jamauv3.xcodeproj` in Xcode and build the `jamauv3` scheme, or:

```bash
xcodebuild build -scheme jamauv3 -destination 'platform=macOS'
```

Dependencies are fetched automatically via Swift Package Manager (swift-ogg and swift-vorbis for the OGG Vorbis codec); stb_vorbis is vendored locally under `Vendor/CStbVorbis` for progressive/streaming decode. See [Acknowledgements](#acknowledgements) for full attribution. `build-and-run.sh` builds, re-registers the extension with `pluginkit`, and launches the host app — useful during development, when macOS likes to cache stale extension binaries.

Tests:

```bash
xcodebuild test -scheme jamauv3 -destination 'platform=macOS' \
  -enableCodeCoverage NO -parallel-testing-enabled NO
```

Four end-to-end tests connect to a real NINJAM server and are skipped unless `NINJAM_TEST_HOST` / `NINJAM_TEST_PORT` / `NINJAM_TEST_USER` / `NINJAM_TEST_PASS` are set.

## Privacy

Jam AUv3 makes network connections **only when you ask it to**. There is **no telemetry, no analytics, no tracking, and no account** — nothing is collected, and nothing leaves your machine except the connections below, only while you're connected.

**Outgoing — this sends your audio and text to a server and other people:**

- **Joining a NINJAM server** connects to the server you choose and **transmits your audio input** so the other participants can hear you, in real time. Chat messages you send go to the same server. Connecting is always an explicit action — the app never joins a server on its own.

**Incoming only:**

- **Listen mode** plays a server's public Icecast stream; nothing is transmitted.
- **The server browser** fetches the public room list from ninbot.com only when you open it.

**Your credentials stay on your machine.** Server passwords are stored in the macOS Keychain (encrypted at rest) and sent only to the NINJAM server you're logging into — as a SHA-1 challenge response, never in cleartext.

**Know what the protocol exposes.** NINJAM traffic (port 2049) is unencrypted TCP: your audio, chat, and username travel in cleartext, and the login is protected only by the protocol's challenge-response. Don't reuse a valuable password for NINJAM servers, and treat anything you play or type in a session as public.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

"NINJAM" is a protocol and software by Cockos Incorporated; this is an independent, compatible client and is not affiliated with or endorsed by Cockos.

## Acknowledgements

This project builds on the work of others, all under GPL-compatible licenses:

- **[NINJAM](https://www.cockos.com/ninjam/)** — the collaborative-jamming protocol, by Cockos Incorporated.
- **[stb_vorbis](https://github.com/nothings/stb)** by Sean Barrett — public-domain single-file OGG Vorbis decoder, vendored under `Vendor/CStbVorbis` for progressive (pushdata) decode. Dual-licensed MIT / Unlicense; the original license text is preserved in the vendored source.
- **[swift-ogg](https://github.com/readdle/swift-ogg)** and **[swift-vorbis](https://github.com/readdle/swift-vorbis)** by Readdle — Swift packages wrapping the Xiph reference codecs.
- **libogg** and **libvorbis** by the [Xiph.Org Foundation](https://xiph.org) — the reference OGG container and Vorbis codec (BSD-style license).
