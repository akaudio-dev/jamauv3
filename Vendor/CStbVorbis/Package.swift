// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov
import PackageDescription

// Local package vendoring stb_vorbis (public domain) for progressive/pushdata OGG
// Vorbis decode — the join-gap first-interval preview needs to decode bytes as they
// arrive, which libvorbis' ov_open pull model can't do. Compiled into both the host
// app and the AUv3 extension targets.
let package = Package(
    name: "CStbVorbis",
    products: [
        .library(name: "CStbVorbis", targets: ["CStbVorbis"]),
    ],
    targets: [
        .target(
            name: "CStbVorbis",
            path: "Sources/CStbVorbis"
        ),
    ]
)
