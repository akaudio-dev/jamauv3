//
//  OggVorbisDecoder.swift
//  jamauv3Extension
//
//  Swift wrapper for OGG Vorbis audio decoding using stb_vorbis.
//

import Foundation
import AVFoundation

/// Errors that can occur during OGG decoding
public enum OggDecoderError: Error, LocalizedError {
    case invalidFile
    case outOfMemory
    case invalidParameter
    case decodeFailed
    case unknown(Int32)

    init(code: Int32) {
        switch code {
        case OGG_DECODER_ERROR_INVALID_FILE.rawValue:
            self = .invalidFile
        case OGG_DECODER_ERROR_OUT_OF_MEMORY.rawValue:
            self = .outOfMemory
        case OGG_DECODER_ERROR_INVALID_PARAMETER.rawValue:
            self = .invalidParameter
        case OGG_DECODER_ERROR_DECODE_FAILED.rawValue:
            self = .decodeFailed
        default:
            self = .unknown(code)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Invalid or corrupted OGG file"
        case .outOfMemory:
            return "Out of memory during decoding"
        case .invalidParameter:
            return "Invalid parameter passed to decoder"
        case .decodeFailed:
            return "Failed to decode OGG audio"
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
public final class OggVorbisDecoder {

    // MARK: - One-Shot Decoding

    /// Decode an OGG file from a URL
    public static func decode(fileURL: URL) throws -> DecodedOggAudio {
        var outputBuffer: UnsafeMutablePointer<Float>?
        var audioInfo = OggAudioInfo()

        let result = ogg_decoder_decode_file(
            fileURL.path,
            &outputBuffer,
            &audioInfo
        )

        if result < 0 {
            throw OggDecoderError(code: result)
        }

        guard let buffer = outputBuffer else {
            throw OggDecoderError.decodeFailed
        }

        defer {
            ogg_decoder_free_buffer(buffer)
        }

        let format = OggAudioFormat(
            sampleRate: Int(audioInfo.sampleRate),
            channels: Int(audioInfo.channels),
            totalSamples: audioInfo.totalSamples
        )

        let totalSampleCount = Int(result) * Int(audioInfo.channels)
        let samples = Array(UnsafeBufferPointer(start: buffer, count: totalSampleCount))

        return DecodedOggAudio(format: format, samples: samples)
    }

    /// Decode OGG data from memory
    public static func decode(data: Data) throws -> DecodedOggAudio {
        var outputBuffer: UnsafeMutablePointer<Float>?
        var audioInfo = OggAudioInfo()

        let result = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            guard let baseAddress = bytes.baseAddress else {
                return OGG_DECODER_ERROR_INVALID_PARAMETER.rawValue
            }
            return ogg_decoder_decode_memory(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                &outputBuffer,
                &audioInfo
            )
        }

        if result < 0 {
            throw OggDecoderError(code: result)
        }

        guard let buffer = outputBuffer else {
            throw OggDecoderError.decodeFailed
        }

        defer {
            ogg_decoder_free_buffer(buffer)
        }

        let format = OggAudioFormat(
            sampleRate: Int(audioInfo.sampleRate),
            channels: Int(audioInfo.channels),
            totalSamples: audioInfo.totalSamples
        )

        let totalSampleCount = Int(result) * Int(audioInfo.channels)
        let samples = Array(UnsafeBufferPointer(start: buffer, count: totalSampleCount))

        return DecodedOggAudio(format: format, samples: samples)
    }

    // MARK: - Info Only

    /// Get audio format info without fully decoding
    public static func getInfo(fileURL: URL) throws -> OggAudioFormat {
        var audioInfo = OggAudioInfo()

        let result = ogg_decoder_get_info_file(fileURL.path, &audioInfo)

        if result != OGG_DECODER_SUCCESS.rawValue {
            throw OggDecoderError(code: result)
        }

        return OggAudioFormat(
            sampleRate: Int(audioInfo.sampleRate),
            channels: Int(audioInfo.channels),
            totalSamples: audioInfo.totalSamples
        )
    }

    /// Get audio format info from memory without fully decoding
    public static func getInfo(data: Data) throws -> OggAudioFormat {
        var audioInfo = OggAudioInfo()

        let result = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            guard let baseAddress = bytes.baseAddress else {
                return OGG_DECODER_ERROR_INVALID_PARAMETER.rawValue
            }
            return ogg_decoder_get_info_memory(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                &audioInfo
            )
        }

        if result != OGG_DECODER_SUCCESS.rawValue {
            throw OggDecoderError(code: result)
        }

        return OggAudioFormat(
            sampleRate: Int(audioInfo.sampleRate),
            channels: Int(audioInfo.channels),
            totalSamples: audioInfo.totalSamples
        )
    }
}

// MARK: - Streaming Decoder

/// Streaming OGG decoder for large files or real-time processing
public final class OggVorbisStreamDecoder {
    private var context: OpaquePointer?
    public private(set) var format: OggAudioFormat

    /// Open a streaming decoder from a file URL
    public init(fileURL: URL) throws {
        var error = OGG_DECODER_SUCCESS
        context = ogg_decoder_open_file(fileURL.path, &error)

        if context == nil {
            throw OggDecoderError(code: error.rawValue)
        }

        var audioInfo = OggAudioInfo()
        ogg_decoder_stream_get_info(context, &audioInfo)

        format = OggAudioFormat(
            sampleRate: Int(audioInfo.sampleRate),
            channels: Int(audioInfo.channels),
            totalSamples: audioInfo.totalSamples
        )
    }

    /// Open a streaming decoder from memory
    /// Note: The data must remain valid for the lifetime of this decoder
    public init(data: UnsafeRawBufferPointer) throws {
        var error = OGG_DECODER_SUCCESS

        guard let baseAddress = data.baseAddress else {
            throw OggDecoderError.invalidParameter
        }

        context = ogg_decoder_open_memory(
            baseAddress.assumingMemoryBound(to: UInt8.self),
            data.count,
            &error
        )

        if context == nil {
            throw OggDecoderError(code: error.rawValue)
        }

        var audioInfo = OggAudioInfo()
        ogg_decoder_stream_get_info(context, &audioInfo)

        format = OggAudioFormat(
            sampleRate: Int(audioInfo.sampleRate),
            channels: Int(audioInfo.channels),
            totalSamples: audioInfo.totalSamples
        )
    }

    deinit {
        if let context = context {
            ogg_decoder_close(context)
        }
    }

    /// Read samples into a pre-allocated buffer
    /// Returns the number of samples read (per channel), 0 at end of stream
    public func read(into buffer: UnsafeMutableBufferPointer<Float>, maxSamples: Int) -> Int {
        guard let context = context else { return 0 }

        let result = ogg_decoder_stream_read_float(
            context,
            buffer.baseAddress,
            Int32(maxSamples)
        )

        return max(0, Int(result))
    }

    /// Read samples and return as an array
    /// Returns empty array at end of stream
    public func read(maxSamples: Int) -> [Float] {
        guard let context = context else { return [] }

        var buffer = [Float](repeating: 0, count: maxSamples * format.channels)

        let samplesRead = buffer.withUnsafeMutableBufferPointer { ptr in
            ogg_decoder_stream_read_float(
                context,
                ptr.baseAddress,
                Int32(maxSamples)
            )
        }

        if samplesRead <= 0 {
            return []
        }

        let totalSamples = Int(samplesRead) * format.channels
        return Array(buffer.prefix(totalSamples))
    }

    /// Seek to a specific sample position
    public func seek(to samplePosition: Int64) throws {
        guard let context = context else {
            throw OggDecoderError.invalidParameter
        }

        let result = ogg_decoder_stream_seek(context, samplePosition)
        if result != OGG_DECODER_SUCCESS.rawValue {
            throw OggDecoderError(code: result)
        }
    }

    /// Get current sample position
    public var currentPosition: Int64 {
        guard let context = context else { return 0 }
        return ogg_decoder_stream_tell(context)
    }
}
