//
//  ConnectionManager+Examples.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation

extension ConnectionManager {
    /// Example: Send a simple text message
    func sendTextMessage(_ message: String) {
        send(message) { error in
            if let error = error {
                print("Failed to send message: \(error.localizedDescription)")
            } else {
                print("Message sent successfully: \(message)")
            }
        }
    }
    
    /// Example: Send JSON data
    func sendJSON<T: Encodable>(_ object: T) {
        let encoder = JSONEncoder()
        do {
            let jsonData = try encoder.encode(object)
            send(jsonData) { error in
                if let error = error {
                    print("Failed to send JSON: \(error.localizedDescription)")
                } else {
                    print("JSON sent successfully")
                }
            }
        } catch {
            print("Failed to encode JSON: \(error.localizedDescription)")
        }
    }
    
    /// Example: Send audio metadata
    func sendAudioMetadata(sampleRate: Double, bufferSize: Int, channels: Int) {
        struct AudioMetadata: Codable {
            let sampleRate: Double
            let bufferSize: Int
            let channels: Int
            let timestamp: TimeInterval
        }
        
        let metadata = AudioMetadata(
            sampleRate: sampleRate,
            bufferSize: bufferSize,
            channels: channels,
            timestamp: Date().timeIntervalSince1970
        )
        
        sendJSON(metadata)
    }
    
    /// Example: Send binary audio data with length prefix
    func sendAudioBuffer(_ buffer: [Float]) {
        // Common pattern: send length prefix, then data
        var lengthPrefix = UInt32(buffer.count).bigEndian
        var data = Data(bytes: &lengthPrefix, count: MemoryLayout<UInt32>.size)
        data.append(Data(bytes: buffer, count: buffer.count * MemoryLayout<Float>.stride))
        
        send(data) { error in
            if let error = error {
                print("Failed to send audio buffer: \(error.localizedDescription)")
            } else {
                print("Audio buffer sent: \(buffer.count) samples")
            }
        }
    }
    
    /// Example: Send a message with newline delimiter (common for text protocols)
    func sendLine(_ message: String) {
        send(message + "\n")
    }
}
