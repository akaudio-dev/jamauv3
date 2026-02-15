//
//  NINJAMProtocol.swift
//  jamauv3Extension
//
//  NINJAM protocol message types and serialization.
//  Reference: https://github.com/cockos/ninjam (netmsg.h, mpb.h)
//

import Foundation
import CryptoKit

// MARK: - Protocol Constants

/// NINJAM default server port
public let NJ_PORT: UInt16 = 2049

/// Maximum message payload size
public let NET_MESSAGE_MAX_SIZE = 16384

/// Protocol version range
public let PROTO_VER_MIN: UInt32 = 0x00020000
public let PROTO_VER_MAX: UInt32 = 0x0002ffff
public let PROTO_VER_CUR: UInt32 = 0x00020000

// MARK: - Message Types

/// Server -> Client message types
public enum NINJAMServerMessageType: UInt8 {
    case authChallenge = 0x00
    case authReply = 0x01
    case configChangeNotify = 0x02
    case userInfoChangeNotify = 0x03
    case downloadIntervalBegin = 0x04
    case downloadIntervalWrite = 0x05
    case keepalive = 0xfd
}

/// Client -> Server message types
public enum NINJAMClientMessageType: UInt8 {
    case authUser = 0x80
    case setUserMask = 0x81
    case setChannelInfo = 0x82
    case uploadIntervalBegin = 0x83
    case uploadIntervalWrite = 0x84
    case chatMessage = 0xC0
    case keepalive = 0xfd
}

// MARK: - Message Header

/// NINJAM message header: 1 byte type + 4 bytes little-endian length
public struct NINJAMMessageHeader {
    public let type: UInt8
    public let payloadLength: UInt32

    public static let size = 5

    public init(type: UInt8, payloadLength: UInt32) {
        self.type = type
        self.payloadLength = payloadLength
    }

    public init?(data: Data) {
        guard data.count >= Self.size else { return nil }
        self.type = data[0]
        self.payloadLength = data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.advanced(by: 1)
            return base.loadUnaligned(as: UInt32.self)
        }
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.append(type)
        var len = payloadLength.littleEndian
        data.append(Data(bytes: &len, count: 4))
        return data
    }
}

// MARK: - Server Messages

/// Server Auth Challenge (0x00)
/// Sent by server immediately after connection
public struct ServerAuthChallenge {
    public let challenge: Data  // 8 bytes
    public let serverCaps: UInt32  // bit 0: license required, bits 8-15: keepalive interval
    public let protocolVersion: UInt32
    public let licenseAgreement: String?

    public var keepaliveInterval: Int {
        Int((serverCaps >> 8) & 0xFF)
    }

    public var requiresLicenseAgreement: Bool {
        (serverCaps & 1) != 0
    }

    public init?(data: Data) {
        guard data.count >= 16 else { return nil }  // 8 + 4 + 4 minimum

        self.challenge = data.subdata(in: 0..<8)

        self.serverCaps = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        }

        self.protocolVersion = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        }

        // License agreement is a null-terminated string after the fixed fields
        if data.count > 16 {
            let licenseData = data.subdata(in: 16..<data.count)
            if let nullIndex = licenseData.firstIndex(of: 0) {
                self.licenseAgreement = String(data: licenseData[0..<nullIndex], encoding: .utf8)
            } else {
                self.licenseAgreement = String(data: licenseData, encoding: .utf8)
            }
        } else {
            self.licenseAgreement = nil
        }
    }
}

/// Server Auth Reply (0x01)
/// Sent in response to client auth
public struct ServerAuthReply {
    public let flag: UInt8  // bit 0: success
    public let errorMessage: String?
    public let maxChannels: UInt8

    public var isSuccess: Bool {
        (flag & 1) != 0
    }

    /// On success, errorMessage contains the effective username assigned by server
    public var effectiveUsername: String? {
        isSuccess ? errorMessage : nil
    }

    public init?(data: Data) {
        guard data.count >= 1 else { return nil }

        self.flag = data[0]

        // Error message/username is null-terminated string starting at offset 1
        if data.count > 1 {
            let msgData = data.subdata(in: 1..<data.count)
            if let nullIndex = msgData.firstIndex(of: 0) {
                self.errorMessage = String(data: msgData[0..<nullIndex], encoding: .utf8)
                // maxchan is after the null terminator
                if nullIndex + 1 < msgData.count {
                    self.maxChannels = msgData[nullIndex + 1]
                } else {
                    self.maxChannels = 32
                }
            } else {
                self.errorMessage = String(data: msgData, encoding: .utf8)
                self.maxChannels = 32
            }
        } else {
            self.errorMessage = nil
            self.maxChannels = 32
        }
    }
}

/// Server Config Change Notify (0x02)
/// Sent when BPM/BPI changes (and initially after auth)
public struct ServerConfigChangeNotify {
    public let beatsPerMinute: UInt16
    public let beatsPerInterval: UInt16

    /// Duration of one interval in seconds
    public var intervalDuration: TimeInterval {
        guard beatsPerMinute > 0 else { return 0 }
        return TimeInterval(beatsPerInterval) * 60.0 / TimeInterval(beatsPerMinute)
    }

    public init?(data: Data) {
        guard data.count >= 4 else { return nil }

        self.beatsPerMinute = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
        }

        self.beatsPerInterval = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
        }
    }
}

/// User channel info from USERINFO_CHANGE_NOTIFY
public struct RemoteChannelInfo {
    public let isActive: Bool
    public let channelIndex: UInt8
    public let volume: Int16  // dB * 10 (e.g., -30 = -3.0 dB)
    public let pan: Int8      // -128 to 127
    public let flags: UInt8   // bit 0: no subscribe, bit 1: instamode
    public let username: String
    public let channelName: String

    public var volumeDB: Float {
        Float(volume) / 10.0
    }

    public var panNormalized: Float {
        Float(pan) / 128.0  // -1.0 to ~1.0
    }
    
    public init(isActive: Bool, channelIndex: UInt8, volume: Int16, pan: Int8, flags: UInt8, username: String, channelName: String) {
        self.isActive = isActive
        self.channelIndex = channelIndex
        self.volume = volume
        self.pan = pan
        self.flags = flags
        self.username = username
        self.channelName = channelName
    }
}

/// Server User Info Change Notify (0x03)
/// Sent when users join/leave or channel info changes
public struct ServerUserInfoChangeNotify {
    public let channels: [RemoteChannelInfo]

    public init?(data: Data) {
        var channels: [RemoteChannelInfo] = []
        var offset = 0

        while offset < data.count {
            // Each record: active(1) + chanidx(1) + volume(2) + pan(1) + flags(1) + username(NUL) + channame(NUL)
            guard offset + 6 <= data.count else { break }

            let isActive = data[offset] != 0
            let channelIndex = data[offset + 1]
            let volume = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)
            }
            let pan = Int8(bitPattern: data[offset + 4])
            let flags = data[offset + 5]
            offset += 6

            // Read username (null-terminated)
            guard let usernameEnd = data[offset...].firstIndex(of: 0) else { break }
            let username = String(data: data[offset..<usernameEnd], encoding: .utf8) ?? ""
            offset = usernameEnd + 1

            // Read channel name (null-terminated)
            guard offset < data.count else { break }
            guard let channameEnd = data[offset...].firstIndex(of: 0) else { break }
            let channelName = String(data: data[offset..<channameEnd], encoding: .utf8) ?? ""
            offset = channameEnd + 1

            channels.append(RemoteChannelInfo(
                isActive: isActive,
                channelIndex: channelIndex,
                volume: volume,
                pan: pan,
                flags: flags,
                username: username,
                channelName: channelName
            ))
        }

        self.channels = channels
    }
}

/// Server Download Interval Begin (0x04)
/// Announces start of audio data for a user's channel
public struct ServerDownloadIntervalBegin {
    public let guid: Data  // 16 bytes - transfer identifier
    public let estimatedSize: UInt32
    public let fourCC: UInt32  // 'OGGv' for Vorbis
    public let channelIndex: UInt8
    public let username: String

    public var isOggVorbis: Bool {
        fourCC == 0x7667674F  // 'OGGv' little-endian
    }

    public init?(data: Data) {
        guard data.count >= 25 else { return nil }  // 16 + 4 + 4 + 1 minimum

        self.guid = data.subdata(in: 0..<16)

        self.estimatedSize = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        }

        self.fourCC = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
        }

        self.channelIndex = data[24]

        // Username is null-terminated starting at offset 25
        if data.count > 25 {
            let usernameData = data.subdata(in: 25..<data.count)
            if let nullIndex = usernameData.firstIndex(of: 0) {
                self.username = String(data: usernameData[0..<nullIndex], encoding: .utf8) ?? ""
            } else {
                self.username = String(data: usernameData, encoding: .utf8) ?? ""
            }
        } else {
            self.username = ""
        }
    }
}

/// Server Download Interval Write (0x05)
/// Audio data chunk for an interval
public struct ServerDownloadIntervalWrite {
    public let guid: Data  // 16 bytes - matches the Begin message
    public let flags: UInt8  // bit 0: end of interval
    public let audioData: Data

    public var isEndOfInterval: Bool {
        (flags & 1) != 0
    }

    public init?(data: Data) {
        guard data.count >= 17 else { return nil }  // 16 + 1 minimum

        self.guid = data.subdata(in: 0..<16)
        self.flags = data[16]
        self.audioData = data.count > 17 ? data.subdata(in: 17..<data.count) : Data()
    }
}

// MARK: - Client Messages

/// Client Auth User (0x80)
/// Response to server auth challenge
public struct ClientAuthUser {
    public let username: String
    public let passwordHash: Data  // 20 bytes SHA1
    public let clientCaps: UInt32  // bit 0: agreed to license, bit 1: supports version
    public let clientVersion: UInt32

    /// Create auth response from credentials and server challenge
    public static func create(
        username: String,
        password: String,
        challenge: Data,
        agreesToLicense: Bool = true
    ) -> ClientAuthUser {
        // Step 1: SHA1(username:password)
        let credentials = "\(username):\(password)"
        let credentialsHash = Insecure.SHA1.hash(data: Data(credentials.utf8))

        // Step 2: SHA1(credentialsHash + challenge)
        var hashInput = Data(credentialsHash)
        hashInput.append(challenge)
        let finalHash = Insecure.SHA1.hash(data: hashInput)

        var caps: UInt32 = 0x02  // bit 1: we support version field
        if agreesToLicense {
            caps |= 0x01
        }

        return ClientAuthUser(
            username: username,
            passwordHash: Data(finalHash),
            clientCaps: caps,
            clientVersion: PROTO_VER_CUR
        )
    }

    public init(username: String, passwordHash: Data, clientCaps: UInt32, clientVersion: UInt32) {
        self.username = username
        self.passwordHash = passwordHash
        self.clientCaps = clientCaps
        self.clientVersion = clientVersion
    }

    public func serialize() -> Data {
        var data = Data()

        // Password hash (20 bytes)
        data.append(passwordHash)

        // Username (null-terminated)
        data.append(Data(username.utf8))
        data.append(0)

        // Client caps (4 bytes LE)
        var caps = clientCaps.littleEndian
        data.append(Data(bytes: &caps, count: 4))

        // Client version (4 bytes LE) - only if bit 1 of caps is set
        if (clientCaps & 0x02) != 0 {
            var ver = clientVersion.littleEndian
            data.append(Data(bytes: &ver, count: 4))
        }

        return data
    }

    public func buildMessage() -> Data {
        let payload = serialize()
        let header = NINJAMMessageHeader(
            type: NINJAMClientMessageType.authUser.rawValue,
            payloadLength: UInt32(payload.count)
        )
        return header.serialize() + payload
    }
}

/// Client Set Channel Info (0x82)
/// Tells server about our local channels
public struct ClientSetChannelInfo {
    public struct Channel {
        public let name: String
        public let volume: Int16  // dB * 10
        public let pan: Int8
        public let flags: UInt8   // bit 0: no subscribe, bit 1: instamode

        public init(name: String, volumeDB: Float = 0, pan: Float = 0, flags: UInt8 = 0) {
            self.name = name
            self.volume = Int16(volumeDB * 10)
            self.pan = Int8(clamping: Int(pan * 128))
            self.flags = flags
        }
    }

    public let channels: [Channel]
    public let paramSize: UInt16  // Usually 4 (volume + pan + flags + reserved)

    public init(channels: [Channel], paramSize: UInt16 = 4) {
        self.channels = channels
        self.paramSize = paramSize
    }

    public func serialize() -> Data {
        var data = Data()

        // Param size (2 bytes LE)
        var ps = paramSize.littleEndian
        data.append(Data(bytes: &ps, count: 2))

        for channel in channels {
            // Channel name (null-terminated)
            data.append(Data(channel.name.utf8))
            data.append(0)

            // Volume (2 bytes LE)
            var vol = channel.volume.littleEndian
            data.append(Data(bytes: &vol, count: 2))

            // Pan (1 byte)
            data.append(UInt8(bitPattern: channel.pan))

            // Flags (1 byte)
            data.append(channel.flags)
        }

        return data
    }

    public func buildMessage() -> Data {
        let payload = serialize()
        let header = NINJAMMessageHeader(
            type: NINJAMClientMessageType.setChannelInfo.rawValue,
            payloadLength: UInt32(payload.count)
        )
        return header.serialize() + payload
    }
}

/// Client Chat Message (0xC0)
public struct ClientChatMessage {
    public enum Command {
        case message(String)           // MSG <text>
        case privateMessage(to: String, text: String)  // PRIVMSG <user> <text>
        case topic(String)             // TOPIC <text>
    }

    public let command: Command

    public init(command: Command) {
        self.command = command
    }

    public func serialize() -> Data {
        var data = Data()

        switch command {
        case .message(let text):
            data.append(Data("MSG".utf8))
            data.append(0)
            data.append(Data(text.utf8))
            data.append(0)

        case .privateMessage(let to, let text):
            data.append(Data("PRIVMSG".utf8))
            data.append(0)
            data.append(Data(to.utf8))
            data.append(0)
            data.append(Data(text.utf8))
            data.append(0)

        case .topic(let text):
            data.append(Data("TOPIC".utf8))
            data.append(0)
            data.append(Data(text.utf8))
            data.append(0)
        }

        return data
    }

    public func buildMessage() -> Data {
        let payload = serialize()
        let header = NINJAMMessageHeader(
            type: NINJAMClientMessageType.chatMessage.rawValue,
            payloadLength: UInt32(payload.count)
        )
        return header.serialize() + payload
    }
}

/// Client Upload Interval Begin (0x83)
/// Announces start of audio upload for a local channel
public struct ClientUploadIntervalBegin {
    public let guid: Data        // 16 bytes - transfer identifier
    public let estimatedSize: UInt32
    public let fourCC: UInt32    // 'OGGv' (0x7667674F) for Vorbis, 0 for silence
    public let channelIndex: UInt8

    /// OGG Vorbis fourCC value ('OGGv' little-endian)
    public static let oggVorbisFourCC: UInt32 = 0x7667674F

    /// Create an audio upload begin message with a random GUID
    public static func audio(channelIndex: UInt8, estimatedSize: UInt32 = 0) -> ClientUploadIntervalBegin {
        var guidBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { guidBytes[i] = UInt8.random(in: 0...255) }
        return ClientUploadIntervalBegin(
            guid: Data(guidBytes),
            estimatedSize: estimatedSize,
            fourCC: oggVorbisFourCC,
            channelIndex: channelIndex
        )
    }

    /// Create a silence upload begin message (all-zero GUID, fourCC=0)
    public static func silence(channelIndex: UInt8) -> ClientUploadIntervalBegin {
        return ClientUploadIntervalBegin(
            guid: Data(count: 16),
            estimatedSize: 0,
            fourCC: 0,
            channelIndex: channelIndex
        )
    }

    public init(guid: Data, estimatedSize: UInt32, fourCC: UInt32, channelIndex: UInt8) {
        self.guid = guid
        self.estimatedSize = estimatedSize
        self.fourCC = fourCC
        self.channelIndex = channelIndex
    }

    public func serialize() -> Data {
        var data = Data(capacity: 25)
        data.append(guid.prefix(16))
        if guid.count < 16 { data.append(Data(count: 16 - guid.count)) }
        var size = estimatedSize.littleEndian
        data.append(Data(bytes: &size, count: 4))
        var fcc = fourCC.littleEndian
        data.append(Data(bytes: &fcc, count: 4))
        data.append(channelIndex)
        return data
    }

    public func buildMessage() -> Data {
        let payload = serialize()
        let header = NINJAMMessageHeader(
            type: NINJAMClientMessageType.uploadIntervalBegin.rawValue,
            payloadLength: UInt32(payload.count)
        )
        return header.serialize() + payload
    }
}

/// Client Upload Interval Write (0x84)
/// Audio data chunk for an upload interval
public struct ClientUploadIntervalWrite {
    public let guid: Data    // 16 bytes - matches the Begin message
    public let flags: UInt8  // bit 0: end of interval
    public let audioData: Data

    public var isEndOfInterval: Bool {
        (flags & 1) != 0
    }

    public init(guid: Data, flags: UInt8, audioData: Data) {
        self.guid = guid
        self.flags = flags
        self.audioData = audioData
    }

    /// Create a write message with audio data
    public static func data(guid: Data, audioData: Data, isEnd: Bool) -> ClientUploadIntervalWrite {
        return ClientUploadIntervalWrite(guid: guid, flags: isEnd ? 1 : 0, audioData: audioData)
    }

    public func serialize() -> Data {
        var data = Data(capacity: 17 + audioData.count)
        data.append(guid.prefix(16))
        if guid.count < 16 { data.append(Data(count: 16 - guid.count)) }
        data.append(flags)
        data.append(audioData)
        return data
    }

    public func buildMessage() -> Data {
        let payload = serialize()
        let header = NINJAMMessageHeader(
            type: NINJAMClientMessageType.uploadIntervalWrite.rawValue,
            payloadLength: UInt32(payload.count)
        )
        return header.serialize() + payload
    }
}

/// Server Chat Message (parsed from 0xC0)
public struct ServerChatMessage {
    public enum MessageType {
        case message(from: String, text: String)
        case privateMessage(from: String, text: String)
        case topicChange(topic: String)
        case join(username: String)
        case part(username: String)
        case unknown(params: [String])
    }

    public let messageType: MessageType

    public init?(data: Data) {
        // Parse null-terminated strings
        var params: [String] = []
        var offset = 0

        while offset < data.count {
            if let nullIndex = data[offset...].firstIndex(of: 0) {
                let str = String(data: data[offset..<nullIndex], encoding: .utf8) ?? ""
                params.append(str)
                offset = nullIndex + 1
            } else {
                break
            }
        }

        guard !params.isEmpty else { return nil }

        switch params[0].uppercased() {
        case "MSG" where params.count >= 3:
            self.messageType = .message(from: params[1], text: params[2])
        case "PRIVMSG" where params.count >= 3:
            self.messageType = .privateMessage(from: params[1], text: params[2])
        case "TOPIC" where params.count >= 2:
            self.messageType = .topicChange(topic: params[1])
        case "JOIN" where params.count >= 2:
            self.messageType = .join(username: params[1])
        case "PART" where params.count >= 2:
            self.messageType = .part(username: params[1])
        default:
            self.messageType = .unknown(params: params)
        }
    }
}

// MARK: - Interval Config

/// Configuration derived from NINJAM server BPM/BPI settings
public struct IntervalConfig: Sendable {
    public let bpm: Int
    public let bpi: Int
    public let sampleRate: Double

    public init(bpm: Int, bpi: Int, sampleRate: Double) {
        self.bpm = bpm
        self.bpi = bpi
        self.sampleRate = sampleRate
    }

    /// Number of samples in one interval: (BPI / (BPM / 60)) * sampleRate
    public var intervalLengthInSamples: Int {
        guard bpm > 0 else { return 0 }
        let intervalSeconds = Double(bpi) * 60.0 / Double(bpm)
        return Int(intervalSeconds * sampleRate)
    }
}

// MARK: - Keepalive

/// Keepalive message (0xFD) - empty payload
public struct KeepaliveMessage {
    public static func buildMessage() -> Data {
        let header = NINJAMMessageHeader(type: 0xFD, payloadLength: 0)
        return header.serialize()
    }
}
