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

    // MARK: - Stream state (delegateQueue, serialized against stop() by streamLock)

    /// Serializes stop()'s disposal of streamID/converter against an in-flight
    /// parse on the delegate queue: dataTask.cancel() is asynchronous, so a data
    /// chunk can still be inside AudioFileStreamParseBytes when stop() runs.
    /// Held for the whole parse→convert path (delegate queue) and for disposal
    /// (stop); the AudioFileStream/AudioConverter callbacks run inside the
    /// already-held lock and must not re-acquire it.
    private let streamLock = NSLock()

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var streamID: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    private let outputFormat: AudioStreamBasicDescription
    private let outputChannels: Int

    // Packet accumulation buffer — written directly by handlePackets, read by AudioConverter.
    // Eliminates an intermediate Swift Data copy on every decode cycle.
    private var inputDataBuffer: UnsafeMutableRawPointer?
    private var inputDataBufferCapacity: Int = 0
    private var inputDataWritePos: Int = 0
    private var packetDescriptions: [AudioStreamPacketDescription] = []
    private var packetOffset: Int = 0
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
    private let prebuffering = Atomic<Bool>(true)
    private let prebufferThreshold: Int  // samples needed before playback starts/resumes
    private var formatDiscovered = false

    // Session counters for stop summary
    private var totalBytesReceived: Int = 0
    private var totalPacketsDecoded: Int = 0
    private let _totalFramesMixed = Atomic<Int>(0)
    private let _underrunCount = Atomic<Int>(0)

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
        // Match JamTaba's BUFFER_SIZE = 128000 for prebuffer threshold.
        // Ring buffer holds ~8 seconds — well above the prebuffer watermark.
        self.prebufferThreshold = 128000
        let capacity = max(128000 * 4, Int(sampleRate * 8) * channels)
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
        prebuffering.store(true, ordering: .releasing)
        ringBuffer.reset()
        formatDiscovered = false

        totalBytesReceived = 0
        totalPacketsDecoded = 0
        _totalFramesMixed.store(0, ordering: .relaxed)
        _underrunCount.store(0, ordering: .relaxed)

        log.info("Starting Icecast stream: \(url.absoluteString, privacy: .public) @ \(self.outputFormat.mSampleRate) Hz \(self.outputChannels)ch")

        // Open AudioFileStream for MP3 (most Icecast servers serve MP3)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        streamLock.lock()
        let status = AudioFileStreamOpen(
            selfPtr,
            icecastPropertyListener,
            icecastPacketsProc,
            kAudioFileMP3Type,
            &streamID
        )
        streamLock.unlock()
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
        log.info("Stopping Icecast stream: \(self.totalBytesReceived) bytes, \(self.totalPacketsDecoded) pkts decoded, \(self._totalFramesMixed.load(ordering: .relaxed)) frames mixed, \(self._underrunCount.load(ordering: .relaxed)) underruns")

        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil

        streamLock.lock()
        defer { streamLock.unlock() }

        if let sid = streamID {
            AudioFileStreamClose(sid)
            streamID = nil
        }
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }

        inputDataWritePos = 0
        packetDescriptions = []
        packetOffset = 0
    }

    /// Called from the render thread. Reads decoded PCM from the ring buffer
    /// and additively mixes it into the output buffer.
    func mixInto(outputBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard isRunning.load(ordering: .relaxed) else { return }

        let available = ringBuffer.availableToRead

        // Prebuffer watermark: wait until enough data accumulates before starting,
        // and re-enter prebuffering on underrun to avoid rapid fill/drain glitches.
        if prebuffering.load(ordering: .relaxed) {
            if available >= prebufferThreshold {
                prebuffering.store(false, ordering: .relaxed)
            } else {
                return  // Still filling — output silence
            }
        } else if available == 0 {
            prebuffering.store(true, ordering: .relaxed)
            _underrunCount.store(_underrunCount.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
            return
        }

        // Limit to scratch buffer size and available data
        let maxSamples = min(readScratchSize, available)
        let framesToMix = min(frameCount, maxSamples / outputChannels)
        guard framesToMix > 0 else { return }

        let sampleCount = framesToMix * outputChannels
        let read = ringBuffer.read(into: readScratch, count: sampleCount)
        let framesRead = read / outputChannels
        guard framesRead > 0 else { return }

        _totalFramesMixed.store(_totalFramesMixed.load(ordering: .relaxed) &+ framesRead, ordering: .relaxed)

        let peak = additiveMix(
            source: readScratch, framesRead: framesRead, sourceChannels: outputChannels,
            into: outputBufferList)

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
        log.info("Stream format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch")

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

        // Accumulate packet data directly into the raw inputDataBuffer,
        // avoiding an intermediate Swift Data allocation + copy.
        for i in 0..<Int(packetCount) {
            guard let desc = descriptions?[i] else { continue }
            let start = Int(desc.mStartOffset)
            let size = Int(desc.mDataByteSize)
            guard start >= 0, start + size <= Int(byteCount) else { continue }

            // Ensure raw buffer has capacity
            let needed = inputDataWritePos + size
            if needed > inputDataBufferCapacity {
                let newCap = max(needed, inputDataBufferCapacity * 2, 4096)
                let newBuf = UnsafeMutableRawPointer.allocate(byteCount: newCap, alignment: 1)
                if let old = inputDataBuffer, inputDataWritePos > 0 {
                    newBuf.copyMemory(from: old, byteCount: inputDataWritePos)
                }
                inputDataBuffer?.deallocate()
                inputDataBuffer = newBuf
                inputDataBufferCapacity = newCap
            }

            let adjustedDesc = AudioStreamPacketDescription(
                mStartOffset: Int64(inputDataWritePos),
                mVariableFramesInPacket: desc.mVariableFramesInPacket,
                mDataByteSize: desc.mDataByteSize
            )
            inputDataBuffer!.advanced(by: inputDataWritePos)
                .copyMemory(from: data.advanced(by: start), byteCount: size)
            inputDataWritePos += size
            packetDescriptions.append(adjustedDesc)
        }

        decodeAccumulatedPackets()
    }

    private func decodeAccumulatedPackets() {
        guard let converter = self.converter, !packetDescriptions.isEmpty else { return }

        // Data already accumulated directly in inputDataBuffer — no copy needed.
        packetOffset = 0
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var batchDecodeErrors = 0

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
                let written = ringBuffer.write(from: decodeScratch, count: sampleCount)
                if written < sampleCount {
                    log.debug("Ring buffer overflow: tried \(sampleCount), wrote \(written)")
                }
            }

            if status == icecastConverterNoDataErr {
                break
            }
            if status != noErr {
                batchDecodeErrors += 1
                if batchDecodeErrors <= 3 {
                    log.debug("AudioConverterFillComplexBuffer error: \(status)")
                }
                break
            }
        }

        totalPacketsDecoded += packetOffset

        // Reset for next batch (keep backing storage for reuse)
        inputDataWritePos = 0
        packetDescriptions.removeAll(keepingCapacity: true)
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

        guard start >= 0, start + size <= inputDataBufferCapacity else {
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
        streamLock.lock()
        defer { streamLock.unlock() }
        guard isRunning.load(ordering: .relaxed), let sid = streamID else { return }

        totalBytesReceived += data.count

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
