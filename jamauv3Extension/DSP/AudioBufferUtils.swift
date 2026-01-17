//
//  AudioBufferUtils.swift
//  jamauv3Extension
//
//  Pure Swift audio buffer utilities - replaces C++ BufferedAudioBus classes.
//

import Foundation
import AVFoundation
import AudioToolbox

/// Manages an audio bus with pre-allocated buffers for render thread safety.
class BufferedAudioBus: @unchecked Sendable {
    
    private(set) var bus: AUAudioUnitBus?
    private(set) var maxFrames: AUAudioFrameCount = 0
    private var pcmBuffer: AVAudioPCMBuffer?
    
    var originalAudioBufferList: UnsafePointer<AudioBufferList>? {
        return pcmBuffer?.audioBufferList
    }
    
    var mutableAudioBufferList: UnsafeMutablePointer<AudioBufferList>? {
        return pcmBuffer?.mutableAudioBufferList
    }
    
    func initialize(format: AVAudioFormat, maxChannels: AVAudioChannelCount) {
        maxFrames = 0
        pcmBuffer = nil
        
        bus = try? AUAudioUnitBus(format: format)
        bus?.maximumChannelCount = maxChannels
    }
    
    func allocateRenderResources(maxFrames: AUAudioFrameCount) {
        self.maxFrames = maxFrames
        
        guard let format = bus?.format else { return }
        pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames)
    }
    
    func deallocateRenderResources() {
        pcmBuffer = nil
        maxFrames = 0
    }
}

/// Output bus with buffer preparation for null output pointers.
final class BufferedOutputBus: BufferedAudioBus {
    
    /// Prepares the output buffer list, copying internal buffer pointers
    /// if the caller passed null buffer pointers.
    func prepareOutputBufferList(_ outBufferList: UnsafeMutablePointer<AudioBufferList>,
                                  frameCount: AUAudioFrameCount,
                                  zeroFill: Bool) {
        guard let originalList = originalAudioBufferList else { return }
        
        let byteSize = UInt32(frameCount) * UInt32(MemoryLayout<Float>.size)
        let outBuffers = UnsafeMutableAudioBufferListPointer(outBufferList)
        let origBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: originalList))
        
        for i in 0..<outBuffers.count {
            outBuffers[i].mNumberChannels = origBuffers[i].mNumberChannels
            outBuffers[i].mDataByteSize = byteSize
            
            if outBuffers[i].mData == nil {
                outBuffers[i].mData = origBuffers[i].mData
            }
            
            if zeroFill, let data = outBuffers[i].mData {
                memset(data, 0, Int(byteSize))
            }
        }
    }
}

/// Input bus that can pull audio data from upstream.
final class BufferedInputBus: BufferedAudioBus {
    
    /// Pulls input data by preparing the buffer list and calling the pull block.
    func pullInput(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                   timestamp: UnsafePointer<AudioTimeStamp>,
                   frameCount: AUAudioFrameCount,
                   inputBusNumber: Int,
                   pullInputBlock: AURenderPullInputBlock?) -> AUAudioUnitStatus {
        
        guard let pullBlock = pullInputBlock else {
            return kAudioUnitErr_NoConnection
        }
        
        guard let mutableList = mutableAudioBufferList else {
            return kAudioUnitErr_Uninitialized
        }
        
        prepareInputBufferList(frameCount: frameCount)
        
        return pullBlock(actionFlags, timestamp, frameCount, inputBusNumber, mutableList)
    }
    
    /// Resets mutableAudioBufferList pointers from originalAudioBufferList.
    /// Must be called each render cycle as upstream may overwrite pointers.
    func prepareInputBufferList(frameCount: AUAudioFrameCount) {
        guard let originalList = originalAudioBufferList,
              let mutableList = mutableAudioBufferList else { return }
        
        let byteSize = UInt32(min(frameCount, maxFrames)) * UInt32(MemoryLayout<Float>.size)
        let mutableBuffers = UnsafeMutableAudioBufferListPointer(mutableList)
        let origBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: originalList))
        
        mutableList.pointee.mNumberBuffers = originalList.pointee.mNumberBuffers
        
        for i in 0..<origBuffers.count {
            mutableBuffers[i].mNumberChannels = origBuffers[i].mNumberChannels
            mutableBuffers[i].mData = origBuffers[i].mData
            mutableBuffers[i].mDataByteSize = byteSize
        }
    }
}
