// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  OggVorbisPushdataDecoder.swift
//  Shared/Audio
//
//  Progressive ("pushdata") OGG Vorbis decoder built on the vendored stb_vorbis.
//
//  libvorbis (OggVorbisDecoder / OggVorbisStreamDecoder) is a *pull* decoder:
//  ov_open_callbacks needs the whole interval present before it can read headers,
//  so it can only decode a completed interval. The join-gap first-interval preview
//  needs the opposite — decode the in-flight interval as its OGG pages stream in —
//  which is exactly what stb_vorbis' pushdata API does. This wrapper mirrors the
//  akaudio (VCV twin) pushdataFeed path: buffer arriving bytes in an undecoded
//  tail, open the decoder once the headers land, then drain whole frames as they
//  become available, returning them interleaved-stereo at the SOURCE sample rate.
//  The caller resamples to the engine rate (see PreviewResampler).
//

import Foundation
import CStbVorbis

final class OggVorbisPushdataDecoder {
    /// stb_vorbis is an opaque struct → OpaquePointer in Swift.
    private var handle: OpaquePointer?
    /// Undecoded bytes carried between feed() calls (stb_vorbis tells us how much
    /// it consumed; the rest must be re-presented next time, plus more).
    private var tail: [UInt8] = []
    /// Set once open/validation fails — the transfer is junk, stop feeding it.
    private(set) var failed = false

    private(set) var channels = 0
    private(set) var sampleRate = 0

    /// Cumulative frames decoded so far — bounds a decompression bomb. A hostile
    /// interval (a few MB of low-complexity max-blocksize packets) can decode to
    /// orders of magnitude more PCM than any legit interval; without this the drain
    /// loop would grow `out` (and downstream the FIFO) without limit and hang the
    /// main thread. Mirrors the pull path's `decode(maxFrames: NJ_MAX_INTERVAL_SAMPLES)`.
    private var decodedFrames = 0

    /// Bound the undecoded tail. A healthy stream stays tiny (we drain as fast as
    /// chunks arrive); a stream that keeps growing it is broken/hostile — drop and
    /// resync at the next page rather than growing unboundedly. Matches akaudio.
    private static let maxTail = 1 << 20 // 1 MiB

    deinit {
        if let handle { stb_vorbis_close(handle) }
    }

    /// Feed a chunk of arriving OGG bytes. Returns any newly decoded audio as
    /// INTERLEAVED STEREO (mono sources duplicated to both channels) at the source
    /// sample rate — empty if the decoder needs more data or has failed.
    func feed(_ data: Data) -> [Float] {
        guard !failed, !data.isEmpty else { return [] }

        if tail.count + data.count > Self.maxTail {
            tail.removeAll(keepingCapacity: true)
            if let handle { stb_vorbis_flush_pushdata(handle) }
        }
        tail.append(contentsOf: data)

        var out: [Float] = []
        // Compute how many bytes to retire and whether to reset INSIDE the buffer
        // access, but perform every mutation of `tail` AFTER it — mutating `tail`
        // while `withUnsafeMutableBufferPointer` holds it is an exclusivity violation.
        var consumed = 0
        var clearTail = false
        tail.withUnsafeMutableBufferPointer { buf -> Void in
            guard let base = buf.baseAddress else { return }
            var off = 0

            if handle == nil {
                var used: Int32 = 0
                var err: Int32 = 0
                handle = stb_vorbis_open_pushdata(base, Int32(buf.count), &used, &err, nil)
                guard let handle else {
                    // VORBIS_need_more_data (1) just means headers are incomplete;
                    // any other error means junk we'll never open — but we keep the
                    // tail and let subsequent bytes either complete or overflow-reset.
                    return
                }
                off = Int(used)
                let info = stb_vorbis_get_info(handle)
                channels = Int(info.channels)
                sampleRate = Int(info.sample_rate)
                // Reject junk header values before they drive buffer sizing.
                if channels < 1 || channels > 2 || sampleRate < 8000 || sampleRate > 192000 {
                    stb_vorbis_close(handle)
                    self.handle = nil
                    failed = true
                    clearTail = true
                    return
                }
            }
            guard let handle else { return }

            while true {
                var nch: Int32 = 0
                var outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>? = nil
                var samples: Int32 = 0
                let used = stb_vorbis_decode_frame_pushdata(
                    handle, base + off, Int32(buf.count - off), &nch, &outputs, &samples)
                if used == 0 { break } // needs more data
                off += Int(used)
                if samples > 0, nch >= 1, let outputs {
                    let L = outputs[0]
                    let R = nch >= 2 ? outputs[1] : outputs[0]
                    if let L, let R {
                        let n = Int(samples)
                        // Decompression-bomb guard: stop and fail once cumulative
                        // decoded frames exceed one legit interval's worth.
                        if decodedFrames + n > NJ_MAX_INTERVAL_SAMPLES {
                            failed = true
                            stb_vorbis_close(handle)
                            self.handle = nil
                            break
                        }
                        decodedFrames += n
                        out.reserveCapacity(out.count + n * 2)
                        for i in 0..<n {
                            out.append(L[i])
                            out.append(R[i])
                        }
                    }
                }
            }
            consumed = off
        }
        // Retire consumed bytes / reset — now that the buffer access has ended.
        if clearTail {
            tail.removeAll(keepingCapacity: false)
        } else if consumed > 0 {
            tail.removeFirst(consumed)
        }
        return out
    }
}

/// Fixed-ratio linear resampler for interleaved-stereo preview frames, carrying the
/// fractional read position across calls so successive chunks join seamlessly.
/// Mirrors akaudio's voiceDeliver resample. Not thread-safe: owned by one decode
/// worker per channel.
struct PreviewResampler {
    /// Leftover source frames (interleaved stereo) not yet consumed by resampling.
    private var pending: [Float] = []
    /// Fractional source-frame read position carried between resample() calls.
    private var rsPos: Double = 0

    /// Append newly decoded interleaved-stereo source frames and resample to the
    /// engine rate. Returns interleaved-stereo output frames at `toRate`.
    mutating func resample(_ srcInterleaved: [Float], fromRate: Int, toRate: Int) -> [Float] {
        guard fromRate > 0, toRate > 0 else { return [] }
        if !srcInterleaved.isEmpty { pending.append(contentsOf: srcInterleaved) }

        let ratio = Double(fromRate) / Double(toRate) // source frames per output frame
        let srcFrames = pending.count / 2
        guard srcFrames >= 2 else { return [] }

        var out: [Float] = []
        var pos = rsPos
        while pos + 1.0 < Double(srcFrames) { // interpolation needs pos+1
            let i0 = Int(pos)
            let frac = Float(pos - Double(i0))
            let aL = pending[i0 * 2],     aR = pending[i0 * 2 + 1]
            let bL = pending[(i0 + 1) * 2], bR = pending[(i0 + 1) * 2 + 1]
            out.append(aL + frac * (bL - aL))
            out.append(aR + frac * (bR - aR))
            pos += ratio
        }
        // Retire fully-consumed source frames, keep the fractional phase.
        var consumed = Int(pos)
        if consumed > 0 {
            if consumed > srcFrames { consumed = srcFrames }
            pending.removeFirst(consumed * 2)
            rsPos = pos - Double(consumed)
        }
        return out
    }
}
