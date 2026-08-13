// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  AudioBufferUtils.swift
//  jamauv3Extension
//
//  Pure Swift audio buffer utilities - replaces C++ BufferedAudioBus classes.
//

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

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

/// Input bus wrapper: holds the AUAudioUnitBus and its pre-allocated buffer.
/// Audio is NOT pulled through this bus — the render block pulls input directly
/// into the host's output buffer for in-place processing (see RenderProcessor).
final class BufferedInputBus: BufferedAudioBus, @unchecked Sendable {}
