//
//  OggVorbisEncoder.swift
//  jamauv3Extension
//
//  Swift wrapper for OGG Vorbis audio encoding using libvorbis (swift-vorbis).
//

import Foundation
import CVorbis
import COgg

// MARK: - Error Type

/// Errors that can occur during OGG encoding
public enum OggEncoderError: Error, LocalizedError {
    case initializationFailed
    case invalidParameter
    case encodingFailed
    case alreadyFinished

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize OGG/Vorbis encoder"
        case .invalidParameter:
            return "Invalid parameter passed to encoder"
        case .encodingFailed:
            return "Failed to encode OGG/Vorbis audio"
        case .alreadyFinished:
            return "Encoder has already been finished"
        }
    }
}

// MARK: - Stream Encoder

/// Streaming OGG Vorbis encoder for incremental audio encoding
public final class OggVorbisStreamEncoder {
    private var vi = vorbis_info()
    private var vc = vorbis_comment()
    private var vd = vorbis_dsp_state()
    private var vb = vorbis_block()
    private var os = ogg_stream_state()

    private let channels: Int
    private var isFinished = false
    private var headerData: Data
    private var headerEmitted = false

    // Track initialization state for safe cleanup in deinit
    private var infoInitialized = false
    private var commentInitialized = false
    private var dspInitialized = false
    private var blockInitialized = false
    private var streamInitialized = false

    /// Initialize a streaming OGG Vorbis encoder
    /// - Parameters:
    ///   - sampleRate: Audio sample rate in Hz (e.g., 44100)
    ///   - channels: Number of audio channels (1=mono, 2=stereo)
    ///   - quality: Vorbis VBR quality (-0.1 to 1.0). Default 0.1 ≈ 75 kbps mono
    ///   - serialNumber: OGG stream serial number (random if nil)
    public init(sampleRate: Int, channels: Int, quality: Float = 0.1, serialNumber: Int32? = nil) throws {
        guard sampleRate > 0, channels > 0, channels <= 255 else {
            throw OggEncoderError.invalidParameter
        }
        self.channels = channels
        self.headerData = Data()

        // 1. Initialize vorbis_info
        vorbis_info_init(&vi)
        infoInitialized = true

        // 2. Set up VBR encoding
        let ret = vorbis_encode_init_vbr(&vi, Int(channels), Int(sampleRate), quality)
        guard ret == 0 else {
            throw OggEncoderError.initializationFailed
        }

        // 3. Initialize comment
        vorbis_comment_init(&vc)
        commentInitialized = true
        let encoderTag = strdup("ENCODER")
        let encoderName = strdup("jamauv3")
        defer { free(encoderTag); free(encoderName) }
        vorbis_comment_add_tag(&vc, encoderTag, encoderName)

        // 4. Initialize DSP state and block
        vorbis_analysis_init(&vd, &vi)
        dspInitialized = true

        vorbis_block_init(&vd, &vb)
        blockInitialized = true

        // 5. Initialize OGG stream
        let serial = serialNumber ?? Int32.random(in: Int32.min...Int32.max)
        ogg_stream_init(&os, serial)
        streamInitialized = true

        // 6. Write header packets
        var header = ogg_packet()
        var headerComm = ogg_packet()
        var headerCode = ogg_packet()
        vorbis_analysis_headerout(&vd, &vc, &header, &headerComm, &headerCode)

        ogg_stream_packetin(&os, &header)
        ogg_stream_packetin(&os, &headerComm)
        ogg_stream_packetin(&os, &headerCode)

        // Flush header pages
        var og = ogg_page()
        while ogg_stream_flush(&os, &og) != 0 {
            appendPage(og, to: &headerData)
        }
    }

    deinit {
        if streamInitialized { ogg_stream_clear(&os) }
        if blockInitialized { vorbis_block_clear(&vb) }
        if dspInitialized { vorbis_dsp_clear(&vd) }
        if commentInitialized { vorbis_comment_clear(&vc) }
        if infoInitialized { vorbis_info_clear(&vi) }
    }

    // MARK: - Public API

    /// Encode interleaved Float samples
    /// - Parameter samples: Interleaved audio samples (frameCount * channels elements)
    /// - Returns: Encoded OGG data (may be empty if no pages are ready yet)
    public func write(samples: [Float]) throws -> Data {
        guard !isFinished else { throw OggEncoderError.alreadyFinished }
        return try samples.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return emitHeader() }
            return try write(samples: ptr, frameCount: buf.count / channels)
        }
    }

    /// Encode samples from a pointer
    /// - Parameters:
    ///   - samples: Pointer to interleaved Float samples
    ///   - frameCount: Number of frames (total samples / channels)
    /// - Returns: Encoded OGG data
    public func write(samples: UnsafePointer<Float>, frameCount: Int) throws -> Data {
        guard !isFinished else { throw OggEncoderError.alreadyFinished }
        guard frameCount > 0 else { return emitHeader() }

        var output = emitHeader()

        // Get analysis buffer from libvorbis
        guard let buffer = vorbis_analysis_buffer(&vd, Int32(frameCount)) else {
            throw OggEncoderError.encodingFailed
        }

        // De-interleave input samples into per-channel buffers
        if channels == 1 {
            if let ch0 = buffer[0] {
                ch0.update(from: samples, count: frameCount)
            }
        } else {
            for frame in 0..<frameCount {
                for ch in 0..<channels {
                    buffer[ch]?[frame] = samples[frame * channels + ch]
                }
            }
        }

        vorbis_analysis_wrote(&vd, Int32(frameCount))

        // Drain encoded pages
        drainPages(into: &output)

        return output
    }

    /// Signal end of stream and flush remaining data
    /// - Returns: Final OGG data including EOS page
    public func finish() throws -> Data {
        guard !isFinished else { throw OggEncoderError.alreadyFinished }
        isFinished = true

        var output = emitHeader()

        // Signal EOS to encoder
        vorbis_analysis_wrote(&vd, 0)

        // Drain all remaining pages
        drainPages(into: &output)

        return output
    }

    // MARK: - Private Helpers

    private func emitHeader() -> Data {
        if !headerEmitted {
            headerEmitted = true
            return headerData
        }
        return Data()
    }

    private func drainPages(into output: inout Data) {
        while vorbis_analysis_blockout(&vd, &vb) == 1 {
            vorbis_analysis(&vb, nil)
            vorbis_bitrate_addblock(&vb)

            var op = ogg_packet()
            while vorbis_bitrate_flushpacket(&vd, &op) != 0 {
                ogg_stream_packetin(&os, &op)

                var og = ogg_page()
                while ogg_stream_pageout(&os, &og) != 0 {
                    appendPage(og, to: &output)
                }
            }
        }
    }

    private func appendPage(_ og: ogg_page, to data: inout Data) {
        // ogg_page header/body point to internal ogg_stream_state memory —
        // must copy before the next ogg_stream call
        if let headerPtr = og.header {
            data.append(headerPtr, count: og.header_len)
        }
        if let bodyPtr = og.body {
            data.append(bodyPtr, count: og.body_len)
        }
    }
}

// MARK: - One-Shot Encoder

/// One-shot OGG Vorbis encoding convenience methods
public final class OggVorbisEncoder {

    /// Encode audio samples to OGG Vorbis using VBR quality
    public static func encode(samples: [Float], sampleRate: Int, channels: Int, quality: Float = 0.1) throws -> Data {
        let encoder = try OggVorbisStreamEncoder(
            sampleRate: sampleRate, channels: channels, quality: quality
        )

        let chunkSize = 1024
        let totalFrames = samples.count / channels
        var output = Data()

        try samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < totalFrames {
                let frames = min(chunkSize, totalFrames - offset)
                let data = try encoder.write(
                    samples: base.advanced(by: offset * channels),
                    frameCount: frames
                )
                output.append(data)
                offset += frames
            }
        }

        output.append(try encoder.finish())
        return output
    }

    /// Encode audio samples to OGG Vorbis using target bitrate (kbps)
    public static func encode(samples: [Float], sampleRate: Int, channels: Int, bitrate: Int) throws -> Data {
        let quality = qualityForBitrate(bitrate, channels: channels)
        return try encode(samples: samples, sampleRate: sampleRate, channels: channels, quality: quality)
    }

    /// Convert bitrate (kbps) to Vorbis quality value
    /// Based on WDL/vorbisencdec.h mapping for mono 44kHz
    public static func qualityForBitrate(_ bitrate: Int, channels: Int) -> Float {
        var br = bitrate
        if channels == 2 {
            br = (br * 5) / 8
        }

        let qv: Float
        if br < 40 {
            qv = -0.1
        } else if br < 64 {
            qv = -0.1 + Float(br - 40) * (0.1 / 24.0)
        } else if br < 75 {
            qv = Float(br - 64) * (0.1 / 9.0)
        } else if br < 95 {
            qv = 0.1 + Float(br - 75) * (0.2 / 20.0)
        } else if br < 110 {
            qv = 0.3 + Float(br - 95) * (0.2 / 15.0)
        } else if br < 140 {
            qv = 0.5 + Float(br - 110) * (0.25 / 30.0)
        } else {
            qv = 0.75 + Float(br - 140) * (0.25 / 100.0)
        }

        return max(-0.1, min(1.0, qv))
    }
}
