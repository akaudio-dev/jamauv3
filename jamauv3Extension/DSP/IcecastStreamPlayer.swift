//
//  IcecastStreamPlayer.swift
//  jamauv3
//
//  Streams Icecast/Shoutcast audio (MP3/AAC) and decodes to PCM for
//  mixing into the AU render callback. Two-thread model:
//    URLSession delegate queue → AudioFileStream → AudioConverter → CircularBuffer
//    Render thread reads CircularBuffer → additive mix into output
//

import AudioToolbox
import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "jamauv3.com.jamauv3Extension", category: "IcecastStreamPlayer")

final class IcecastStreamPlayer: NSObject, @unchecked Sendable {

    // MARK: - Output ring buffer (decode→render thread)

    let ringBuffer: CircularBuffer

    // MARK: - Stream state (accessed only from delegateQueue)

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var streamID: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    private let outputFormat: AudioStreamBasicDescription
    private let outputChannels: Int

    // Packet buffer for AudioConverter's demand-driven callback
    private var packetData = Data()
    private var packetDescriptions: [AudioStreamPacketDescription] = []
    private var packetOffset: Int = 0

    // Stable buffer for input data — AudioConverter callback pointers must outlive the closure
    private var inputDataBuffer: UnsafeMutableRawPointer?
    private var inputDataBufferSize: Int = 0
    // Stable storage for the current packet description passed to AudioConverter
    private let inputPacketDesc: UnsafeMutablePointer<AudioStreamPacketDescription> = .allocate(capacity: 1)

    // Decode scratch buffer (delegate queue only)
    private let decodeScratchSize = 8192
    private var decodeScratch: UnsafeMutablePointer<Float>

    // Read scratch buffer (render thread only) — avoids allocation in process()
    private let readScratchSize = 8192
    private var readScratch: UnsafeMutablePointer<Float>

    // State tracking
    private let isRunning = Atomic<Bool>(false)
    private var formatDiscovered = false

    // Peak level (render thread writes, main thread reads via exchangePeak)
    private let _peakLevel = Atomic<UInt32>(0)

    /// Read and reset peak level (called from main thread ~15 Hz).
    func exchangePeak() -> Float {
        let bits = _peakLevel.exchange(0, ordering: .relaxed)
        return Float(bitPattern: bits)
    }

    // MARK: - Init / Deinit

    init(sampleRate: Double, channels: Int = 2) {
        self.outputChannels = channels
        self.outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // ~2 seconds of stereo audio at the host sample rate
        let capacity = Int(sampleRate * 2) * channels
        self.ringBuffer = CircularBuffer(capacity: capacity)
        self.decodeScratch = .allocate(capacity: decodeScratchSize)
        self.readScratch = .allocate(capacity: readScratchSize)
        super.init()
    }

    deinit {
        stop()
        decodeScratch.deallocate()
        readScratch.deallocate()
        inputDataBuffer?.deallocate()
        inputPacketDesc.deallocate()
    }

    // MARK: - Public API

    func start(url: URL) {
        guard !isRunning.load(ordering: .acquiring) else { return }
        isRunning.store(true, ordering: .releasing)
        ringBuffer.reset()
        formatDiscovered = false

        log.info("Starting Icecast stream: \(url.absoluteString, privacy: .public)")

        // Open AudioFileStream for MP3 (most Icecast servers serve MP3)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(
            selfPtr,
            icecastPropertyListener,
            icecastPacketsProc,
            kAudioFileMP3Type,
            &streamID
        )
        guard status == noErr else {
            log.error("AudioFileStreamOpen failed: \(status)")
            isRunning.store(false, ordering: .releasing)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("0", forHTTPHeaderField: "Icy-MetaData")

        let delegateQueue = OperationQueue()
        delegateQueue.name = "IcecastStreamPlayer.delegate"
        delegateQueue.maxConcurrentOperationCount = 1

        session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        dataTask = session?.dataTask(with: request)
        dataTask?.resume()
    }

    func stop() {
        guard isRunning.exchange(false, ordering: .acquiringAndReleasing) else { return }
        log.info("Stopping Icecast stream")

        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil

        if let sid = streamID {
            AudioFileStreamClose(sid)
            streamID = nil
        }
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }

        packetData = Data()
        packetDescriptions = []
        packetOffset = 0
    }

    /// Called from the render thread. Reads decoded PCM from the ring buffer
    /// and additively mixes it into the output buffer.
    func mixInto(outputBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard isRunning.load(ordering: .relaxed) else { return }

        let available = ringBuffer.availableToRead
        guard available > 0 else { return }

        // Limit to scratch buffer size and available data
        let maxSamples = min(readScratchSize, available)
        let framesToMix = min(frameCount, maxSamples / outputChannels)
        guard framesToMix > 0 else { return }

        let sampleCount = framesToMix * outputChannels
        let read = ringBuffer.read(into: readScratch, count: sampleCount)
        let framesRead = read / outputChannels
        guard framesRead > 0 else { return }

        let bufferListPtr = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let outChannelCount = bufferListPtr.count

        if outputChannels == 2 && outChannelCount >= 2 {
            // Stereo → stereo: de-interleave and add
            guard let outL = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = bufferListPtr[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<framesRead {
                outL[i] += readScratch[i * 2]
                outR[i] += readScratch[i * 2 + 1]
            }
        } else if outputChannels == 2 && outChannelCount == 1 {
            // Stereo → mono: downmix and add
            guard let out = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<framesRead {
                let mixed: Float = (readScratch[i * 2] + readScratch[i * 2 + 1]) * 0.5
                out[i] += mixed
            }
        } else if outputChannels == 1 && outChannelCount >= 2 {
            // Mono → stereo: duplicate to both channels
            guard let outL = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = bufferListPtr[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<framesRead {
                outL[i] += readScratch[i]
                outR[i] += readScratch[i]
            }
        } else {
            // Mono → mono
            guard let out = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<framesRead {
                out[i] += readScratch[i]
            }
        }

        // Track peak level for UI meter
        var peak: Float = 0
        for i in 0..<read {
            let s = abs(readScratch[i])
            if s > peak { peak = s }
        }
        let peakBits = peak.bitPattern
        let currentBits = _peakLevel.load(ordering: .relaxed)
        if peakBits > currentBits {
            _peakLevel.store(peakBits, ordering: .relaxed)
        }
    }

    // MARK: - AudioFileStream Callbacks

    fileprivate func handlePropertyChange(propertyID: AudioFileStreamPropertyID) {
        guard propertyID == kAudioFileStreamProperty_DataFormat else { return }
        guard let sid = streamID else { return }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileStreamGetProperty(sid, kAudioFileStreamProperty_DataFormat, &size, &format)
        guard status == noErr else {
            log.error("Failed to get stream data format: \(status)")
            return
        }

        inputFormat = format
        formatDiscovered = true
        log.info("Stream format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, formatID=\(format.mFormatID)")

        // Create audio converter: compressed → Float32 PCM
        var outFmt = outputFormat
        var inFmt = inputFormat
        var conv: AudioConverterRef?
        let convStatus = AudioConverterNew(&inFmt, &outFmt, &conv)
        guard convStatus == noErr, let conv else {
            log.error("AudioConverterNew failed: \(convStatus)")
            return
        }
        self.converter = conv
        log.info("AudioConverter created: \(format.mSampleRate)→\(self.outputFormat.mSampleRate) Hz")
    }

    fileprivate func handlePackets(
        byteCount: UInt32,
        packetCount: UInt32,
        data: UnsafeRawPointer,
        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard converter != nil, formatDiscovered else { return }

        // Accumulate packet data and descriptions
        let rawData = Data(bytes: data, count: Int(byteCount))

        for i in 0..<Int(packetCount) {
            guard let desc = descriptions?[i] else { continue }
            let start = Int(desc.mStartOffset)
            let size = Int(desc.mDataByteSize)
            guard start >= 0, start + size <= rawData.count else { continue }

            let packetSlice = rawData[start..<(start + size)]
            let adjustedDesc = AudioStreamPacketDescription(
                mStartOffset: Int64(packetData.count),
                mVariableFramesInPacket: desc.mVariableFramesInPacket,
                mDataByteSize: desc.mDataByteSize
            )
            packetData.append(packetSlice)
            packetDescriptions.append(adjustedDesc)
        }

        // Decode accumulated packets
        decodeAccumulatedPackets()
    }

    private func decodeAccumulatedPackets() {
        guard let converter = self.converter, !packetDescriptions.isEmpty else { return }

        // Copy packetData into a stable raw buffer so AudioConverter callback
        // pointers remain valid (Data.withUnsafeBytes pointers are temporary).
        let dataCount = packetData.count
        if dataCount > inputDataBufferSize {
            inputDataBuffer?.deallocate()
            inputDataBuffer = .allocate(byteCount: dataCount, alignment: 1)
            inputDataBufferSize = dataCount
        }
        packetData.withUnsafeBytes { rawBuf in
            if let src = rawBuf.baseAddress {
                inputDataBuffer!.copyMemory(from: src, byteCount: dataCount)
            }
        }

        packetOffset = 0
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        while packetOffset < packetDescriptions.count {
            var outputBuffer = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outputChannels),
                    mDataByteSize: UInt32(decodeScratchSize * MemoryLayout<Float>.size),
                    mData: decodeScratch
                )
            )
            var outputPacketCount = UInt32(decodeScratchSize / outputChannels)

            let status = AudioConverterFillComplexBuffer(
                converter,
                icecastConverterInputProc,
                selfPtr,
                &outputPacketCount,
                &outputBuffer,
                nil
            )

            if outputPacketCount > 0 {
                let sampleCount = Int(outputPacketCount) * outputChannels
                _ = ringBuffer.write(from: decodeScratch, count: sampleCount)
            }

            if status == icecastConverterNoDataErr {
                break
            }
            if status != noErr {
                break
            }
        }

        // Clear consumed data
        packetData = Data()
        packetDescriptions = []
    }

    /// Called by AudioConverterFillComplexBuffer to pull input packets.
    fileprivate func provideInputPackets(
        ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        guard packetOffset < packetDescriptions.count, let inputData = inputDataBuffer else {
            ioNumberDataPackets.pointee = 0
            return icecastConverterNoDataErr
        }

        let desc = packetDescriptions[packetOffset]
        let start = Int(desc.mStartOffset)
        let size = Int(desc.mDataByteSize)

        guard start >= 0, start + size <= inputDataBufferSize else {
            ioNumberDataPackets.pointee = 0
            return icecastConverterNoDataErr
        }

        ioNumberDataPackets.pointee = 1

        // Point into the stable inputDataBuffer (not a temporary Data.withUnsafeBytes pointer)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = inputFormat.mChannelsPerFrame
        ioData.pointee.mBuffers.mDataByteSize = UInt32(size)
        ioData.pointee.mBuffers.mData = inputData.advanced(by: start)

        if let outDesc = outDataPacketDescription {
            // Write into persistent storage with mStartOffset = 0
            // (mData already points to the packet start)
            inputPacketDesc.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: desc.mVariableFramesInPacket,
                mDataByteSize: desc.mDataByteSize
            )
            outDesc.pointee = inputPacketDesc
        }

        packetOffset += 1
        return noErr
    }
}

// MARK: - URLSessionDataDelegate

extension IcecastStreamPlayer: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            log.info("Stream response: HTTP \(http.statusCode), type=\(contentType, privacy: .public)")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isRunning.load(ordering: .relaxed), let sid = streamID else { return }

        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            let status = AudioFileStreamParseBytes(sid, UInt32(data.count), ptr, [])
            if status != noErr {
                log.debug("AudioFileStreamParseBytes: \(status)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            log.error("Stream error: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("Stream completed normally")
        }
    }
}

// MARK: - C Callback Trampolines

/// Custom error code to signal "no more data" to AudioConverter
/// FourCC 'nodt' = 0x6E6F6474
private let icecastConverterNoDataErr: OSStatus = 0x6E6F_6474

private func icecastPropertyListener(
    clientData: UnsafeMutableRawPointer,
    streamID: AudioFileStreamID,
    propertyID: AudioFileStreamPropertyID,
    ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    let player = Unmanaged<IcecastStreamPlayer>.fromOpaque(clientData).takeUnretainedValue()
    player.handlePropertyChange(propertyID: propertyID)
}

private func icecastPacketsProc(
    clientData: UnsafeMutableRawPointer,
    byteCount: UInt32,
    packetCount: UInt32,
    data: UnsafeRawPointer,
    descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    let player = Unmanaged<IcecastStreamPlayer>.fromOpaque(clientData).takeUnretainedValue()
    player.handlePackets(byteCount: byteCount, packetCount: packetCount, data: data, descriptions: descriptions)
}

private func icecastConverterInputProc(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        return icecastConverterNoDataErr
    }
    let player = Unmanaged<IcecastStreamPlayer>.fromOpaque(inUserData).takeUnretainedValue()
    return player.provideInputPackets(
        ioNumberDataPackets: ioNumberDataPackets,
        ioData: ioData,
        outDataPacketDescription: outDataPacketDescription
    )
}
