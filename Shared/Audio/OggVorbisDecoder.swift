// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  OggVorbisDecoder.swift
//  jamauv3Extension
//
//  Swift wrapper for OGG Vorbis audio decoding using libvorbis (swift-vorbis).
//

import Foundation
import AVFoundation
import CVorbis
import Darwin

/// Errors that can occur during OGG decoding
public enum OggDecoderError: Error, LocalizedError {
    case invalidFile
    case invalidParameter
    case decodeFailed
    case endOfFile
    case unsupported
    case unknown(Int32)

    init(code: Int32) {
        switch code {
        case OV_ENOTVORBIS, OV_EBADHEADER:
            self = .invalidFile
        case OV_EINVAL, OV_EFAULT:
            self = .invalidParameter
        case OV_EOF:
            self = .endOfFile
        case OV_EIMPL, OV_ENOSEEK:
            self = .unsupported
        default:
            self = .decodeFailed
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Invalid or corrupted OGG/Vorbis file"
        case .invalidParameter:
            return "Invalid parameter passed to decoder"
        case .decodeFailed:
            return "Failed to decode OGG/Vorbis audio"
        case .endOfFile:
            return "End of file"
        case .unsupported:
            return "Unsupported OGG/Vorbis feature"
        case .unknown(let code):
            return "Unknown decoder error (code: \(code))"
        }
    }
}

/// Information about decoded audio
public struct OggAudioFormat {
    public let sampleRate: Int
    public let channels: Int
    public let totalSamples: Int64

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(totalSamples) / TimeInterval(sampleRate)
    }
}

/// Decoded audio data with format information
public struct DecodedOggAudio {
    public let format: OggAudioFormat
    public let samples: [Float]  // Interleaved samples

    /// Returns samples de-interleaved into separate channel arrays
    public func deinterleavedSamples() -> [[Float]] {
        guard format.channels > 0 else { return [] }

        var channels = [[Float]](repeating: [], count: format.channels)
        let samplesPerChannel = samples.count / format.channels

        for ch in 0..<format.channels {
            channels[ch].reserveCapacity(samplesPerChannel)
        }

        for i in stride(from: 0, to: samples.count, by: format.channels) {
            for ch in 0..<format.channels {
                if i + ch < samples.count {
                    channels[ch].append(samples[i + ch])
                }
            }
        }

        return channels
    }

    /// Converts to AVAudioPCMBuffer for use with AVAudioEngine
    public func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let audioFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels)
        ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(format.totalSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount

        // De-interleave into the buffer's channel data
        guard let floatChannelData = buffer.floatChannelData else {
            return nil
        }

        for frame in 0..<Int(frameCount) {
            for channel in 0..<format.channels {
                let sampleIndex = frame * format.channels + channel
                if sampleIndex < samples.count {
                    floatChannelData[channel][frame] = samples[sampleIndex]
                }
            }
        }

        return buffer
    }
}

/// OGG Vorbis audio decoder
fileprivate final class VorbisMemoryStream {
    let data: UnsafeRawPointer
    let size: Int
    var offset: Int

    init(data: UnsafeRawPointer, size: Int) {
        self.data = data
        self.size = size
        self.offset = 0
    }
}

fileprivate let vorbisReadCallback: @convention(c) (UnsafeMutableRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, datasource in
    guard let ptr = ptr, let datasource = datasource else { return 0 }
    let stream = Unmanaged<VorbisMemoryStream>.fromOpaque(datasource).takeUnretainedValue()
    let bytesRequested = size * nmemb
    let bytesAvailable = max(0, stream.size - stream.offset)
    let bytesToRead = min(bytesRequested, bytesAvailable)
    if bytesToRead <= 0 { return 0 }
    memcpy(ptr, stream.data.advanced(by: stream.offset), bytesToRead)
    stream.offset += bytesToRead
    return bytesToRead / max(size, 1)
}

fileprivate let vorbisSeekCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int32 = { datasource, offset, whence in
    guard let datasource = datasource else { return -1 }
    let stream = Unmanaged<VorbisMemoryStream>.fromOpaque(datasource).takeUnretainedValue()
    let newOffset: Int
    switch whence {
    case Int32(SEEK_SET):
        newOffset = Int(offset)
    case Int32(SEEK_CUR):
        newOffset = stream.offset + Int(offset)
    case Int32(SEEK_END):
        newOffset = stream.size + Int(offset)
    default:
        return -1
    }
    guard newOffset >= 0, newOffset <= stream.size else { return -1 }
    stream.offset = newOffset
    return 0
}

fileprivate let vorbisTellCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int = { datasource in
    guard let datasource = datasource else { return 0 }
    let stream = Unmanaged<VorbisMemoryStream>.fromOpaque(datasource).takeUnretainedValue()
    return stream.offset
}

public final class OggVorbisDecoder {

    private static let readChunkSize = 4096
    fileprivate static func openFile(_ fileURL: URL) throws -> OggVorbis_File {
        var vf = OggVorbis_File()
        let result = fileURL.path.withCString { ov_fopen($0, &vf) }
        guard result == 0 else {
            throw OggDecoderError(code: result)
        }
        return vf
    }

    private static func openMemory(pointer: UnsafeRawPointer, size: Int, streamHolder: inout VorbisMemoryStream?) throws -> OggVorbis_File {
        var vf = OggVorbis_File()
        let stream = VorbisMemoryStream(data: pointer, size: size)
        streamHolder = stream
        let callbacks = ov_callbacks(
            read_func: vorbisReadCallback,
            seek_func: vorbisSeekCallback,
            close_func: nil,
            tell_func: vorbisTellCallback
        )
        let result = ov_open_callbacks(Unmanaged.passUnretained(stream).toOpaque(), &vf, nil, 0, callbacks)
        guard result == 0 else {
            throw OggDecoderError(code: Int32(result))
        }
        return vf
    }

    fileprivate static func extractFormat(from vf: inout OggVorbis_File) throws -> OggAudioFormat {
        guard let info = ov_info(&vf, -1) else {
            throw OggDecoderError.decodeFailed
        }
        let channels = Int(info.pointee.channels)
        let sampleRate = Int(info.pointee.rate)
        // Header fields are attacker-controlled and flow into allocation sizes
        // (frames × channels, resample ratio). NINJAM audio is mono or stereo;
        // reject anything else before it can size a buffer.
        guard (1...2).contains(channels), (8000...192_000).contains(sampleRate) else {
            throw OggDecoderError.unsupported
        }
        let totalSamples = Int64(ov_pcm_total(&vf, -1))
        return OggAudioFormat(sampleRate: sampleRate, channels: channels, totalSamples: totalSamples)
    }

    private static func readAllSamples(from vf: inout OggVorbis_File, channels: Int,
                                       maxFrames: Int? = nil) throws -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(channels * 4096)

        var bitstream: Int32 = 0
        var pcmChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?

        while true {
            // Truncate at maxFrames: bounds output against decompression bombs
            // (tiny compressed input expanding to unbounded PCM).
            if let maxFrames, output.count >= maxFrames * channels { break }

            let readCount = ov_read_float(&vf, &pcmChannels, Int32(readChunkSize), &bitstream)
            if readCount == 0 { break }
            if readCount < 0 {
                throw OggDecoderError(code: Int32(readCount))
            }

            guard let pcmChannels = pcmChannels else { continue }
            for i in 0..<Int(readCount) {
                for ch in 0..<channels {
                    if let channelPtr = pcmChannels[ch] {
                        output.append(channelPtr[i])
                    }
                }
            }
        }

        return output
    }

    // MARK: - One-Shot Decoding

    /// Decode an OGG file from a URL
    public static func decode(fileURL: URL) throws -> DecodedOggAudio {
        var vf = try openFile(fileURL)
        defer { ov_clear(&vf) }

        let format = try extractFormat(from: &vf)
        let samples = try readAllSamples(from: &vf, channels: format.channels)
        return DecodedOggAudio(format: format, samples: samples)
    }

    /// Decode OGG data from memory.
    /// - Parameter maxFrames: If set, decoding stops (truncates) after this many frames.
    public static func decode(data: Data, maxFrames: Int? = nil) throws -> DecodedOggAudio {
        return try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw OggDecoderError.invalidParameter
            }
            var stream: VorbisMemoryStream?
            var vf = try openMemory(pointer: baseAddress, size: bytes.count, streamHolder: &stream)
            defer { ov_clear(&vf) }

            let format = try extractFormat(from: &vf)
            let samples = try readAllSamples(from: &vf, channels: format.channels, maxFrames: maxFrames)
            _ = stream
            return DecodedOggAudio(format: format, samples: samples)
        }
    }

    // MARK: - Info Only

    /// Get audio format info without fully decoding
    public static func getInfo(fileURL: URL) throws -> OggAudioFormat {
        var vf = try openFile(fileURL)
        defer { ov_clear(&vf) }
        return try extractFormat(from: &vf)
    }

    /// Get audio format info from memory without fully decoding
    public static func getInfo(data: Data) throws -> OggAudioFormat {
        return try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw OggDecoderError.invalidParameter
            }
            var stream: VorbisMemoryStream?
            var vf = try openMemory(pointer: baseAddress, size: bytes.count, streamHolder: &stream)
            defer { ov_clear(&vf) }
            _ = stream
            return try extractFormat(from: &vf)
        }
    }
}

// MARK: - Streaming Decoder

/// Streaming OGG decoder for large files or real-time processing
public final class OggVorbisStreamDecoder {
    private var file = OggVorbis_File()
    private var isOpen = false
    private var memoryStream: VorbisMemoryStream?
    public private(set) var format: OggAudioFormat

    /// Open a streaming decoder from a file URL
    public init(fileURL: URL) throws {
        file = try OggVorbisDecoder.openFile(fileURL)
        isOpen = true
        format = try OggVorbisDecoder.extractFormat(from: &file)
    }

    /// Open a streaming decoder from memory
    /// Note: The data must remain valid for the lifetime of this decoder
    public init(data: UnsafeRawBufferPointer) throws {
        guard let baseAddress = data.baseAddress else {
            throw OggDecoderError.invalidParameter
        }
        let stream = VorbisMemoryStream(data: baseAddress, size: data.count)
        memoryStream = stream
        let callbacks = ov_callbacks(
            read_func: vorbisReadCallback,
            seek_func: vorbisSeekCallback,
            close_func: nil,
            tell_func: vorbisTellCallback
        )
        let result = ov_open_callbacks(Unmanaged.passUnretained(stream).toOpaque(), &file, nil, 0, callbacks)
        guard result == 0 else {
            throw OggDecoderError(code: Int32(result))
        }
        isOpen = true
        format = try OggVorbisDecoder.extractFormat(from: &file)
    }

    deinit {
        if isOpen {
            ov_clear(&file)
        }
    }

    /// Read samples into a pre-allocated buffer
    /// Returns the number of samples read (per channel), 0 at end of stream
    public func read(into buffer: UnsafeMutableBufferPointer<Float>, maxSamples: Int) -> Int {
        guard isOpen, let baseAddress = buffer.baseAddress else { return 0 }
        var bitstream: Int32 = 0
        var pcmChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
        let readCount = ov_read_float(&file, &pcmChannels, Int32(maxSamples), &bitstream)
        if readCount <= 0 { return 0 }
        guard let pcmChannels = pcmChannels else { return 0 }
        var outIndex = 0
        for i in 0..<Int(readCount) {
            for ch in 0..<format.channels {
                if let channelPtr = pcmChannels[ch] {
                    baseAddress[outIndex] = channelPtr[i]
                    outIndex += 1
                }
            }
        }
        return Int(readCount)
    }

    /// Read samples and return as an array
    /// Returns empty array at end of stream
    public func read(maxSamples: Int) -> [Float] {
        guard isOpen else { return [] }
        var buffer = [Float](repeating: 0, count: maxSamples * format.channels)
        let samplesRead = buffer.withUnsafeMutableBufferPointer { ptr in
            read(into: ptr, maxSamples: maxSamples)
        }
        if samplesRead <= 0 { return [] }
        let totalSamples = samplesRead * format.channels
        return Array(buffer.prefix(totalSamples))
    }

    /// Seek to a specific sample position
    public func seek(to samplePosition: Int64) throws {
        guard isOpen else { throw OggDecoderError.invalidParameter }
        let result = ov_pcm_seek(&file, samplePosition)
        if result != 0 {
            throw OggDecoderError(code: Int32(result))
        }
    }

    /// Get current sample position
    public var currentPosition: Int64 {
        guard isOpen else { return 0 }
        return Int64(ov_pcm_tell(&file))
    }
}
