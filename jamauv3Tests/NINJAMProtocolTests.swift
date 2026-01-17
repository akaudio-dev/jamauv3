//
//  NINJAMProtocolTests.swift
//  jamauv3Tests
//
//  Tests for NINJAM protocol message serialization and parsing.
//

import Testing
import Foundation
import CryptoKit
@testable import jamauv3

// MARK: - Test Configuration

/// Test credentials - loaded from environment or config file
/// Set NINJAM_TEST_HOST, NINJAM_TEST_USER, NINJAM_TEST_PASS environment variables
/// Or create a TestConfig.json file in the test bundle
struct TestConfig {
    let host: String
    let port: UInt16
    let username: String
    let password: String

    static var shared: TestConfig? = {
        // Try environment variables first
        if let host = ProcessInfo.processInfo.environment["NINJAM_TEST_HOST"],
           let user = ProcessInfo.processInfo.environment["NINJAM_TEST_USER"],
           let pass = ProcessInfo.processInfo.environment["NINJAM_TEST_PASS"] {
            let port = UInt16(ProcessInfo.processInfo.environment["NINJAM_TEST_PORT"] ?? "2049") ?? 2049
            return TestConfig(host: host, port: port, username: user, password: pass)
        }

        // Try config file
        if let configURL = Bundle(for: BundleToken.self).url(forResource: "TestConfig", withExtension: "json"),
           let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let host = json["host"] as? String,
               let user = json["username"] as? String,
               let pass = json["password"] as? String {
                let port = (json["port"] as? Int).map { UInt16($0) } ?? 2049
                return TestConfig(host: host, port: port, username: user, password: pass)
            }
        }

        return nil
    }()
}

// Helper to get bundle for the test target
private class BundleToken {}

// MARK: - Message Header Tests

@Suite("Message Header")
struct MessageHeaderTests {

    @Test("Header serialization")
    func headerSerialization() {
        let header = NINJAMMessageHeader(type: 0x80, payloadLength: 256)
        let data = header.serialize()

        #expect(data.count == 5)
        #expect(data[0] == 0x80)  // Type
        #expect(data[1] == 0x00)  // Length LSB
        #expect(data[2] == 0x01)  // Length byte 1
        #expect(data[3] == 0x00)  // Length byte 2
        #expect(data[4] == 0x00)  // Length MSB
    }

    @Test("Header parsing")
    func headerParsing() {
        let data = Data([0x00, 0x10, 0x00, 0x00, 0x00])  // Type 0, length 16
        let header = NINJAMMessageHeader(data: data)

        #expect(header != nil)
        #expect(header?.type == 0x00)
        #expect(header?.payloadLength == 16)
    }

    @Test("Header roundtrip")
    func headerRoundtrip() {
        let original = NINJAMMessageHeader(type: 0xC0, payloadLength: 12345)
        let serialized = original.serialize()
        let parsed = NINJAMMessageHeader(data: serialized)

        #expect(parsed?.type == original.type)
        #expect(parsed?.payloadLength == original.payloadLength)
    }

    @Test("Header too short")
    func headerTooShort() {
        let data = Data([0x00, 0x10, 0x00])  // Only 3 bytes
        let header = NINJAMMessageHeader(data: data)

        #expect(header == nil)
    }
}

// MARK: - Auth Challenge Tests

@Suite("Server Auth Challenge")
struct AuthChallengeTests {

    @Test("Parse minimal challenge")
    func parseMinimalChallenge() {
        // 8 bytes challenge + 4 bytes caps + 4 bytes version = 16 bytes minimum
        var data = Data()
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])  // Challenge
        data.append(contentsOf: [0x03, 0x00, 0x00, 0x00])  // Server caps (keepalive=0, license=1)
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])  // Protocol version 0x00020000

        let challenge = ServerAuthChallenge(data: data)

        #expect(challenge != nil)
        #expect(challenge?.challenge.count == 8)
        #expect(challenge?.challenge[0] == 0x01)
        #expect(challenge?.serverCaps == 3)
        #expect(challenge?.requiresLicenseAgreement == true)
        #expect(challenge?.keepaliveInterval == 0)
        #expect(challenge?.protocolVersion == 0x00020000)
        #expect(challenge?.licenseAgreement == nil)
    }

    @Test("Parse challenge with license")
    func parseChallengeWithLicense() {
        var data = Data()
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])  // Challenge
        data.append(contentsOf: [0x01, 0x05, 0x00, 0x00])  // Server caps (keepalive=5, license=1)
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])  // Protocol version
        data.append(contentsOf: "Test License Agreement".utf8)
        data.append(0)  // Null terminator

        let challenge = ServerAuthChallenge(data: data)

        #expect(challenge != nil)
        #expect(challenge?.keepaliveInterval == 5)
        #expect(challenge?.licenseAgreement == "Test License Agreement")
    }
}

// MARK: - Auth Reply Tests

@Suite("Server Auth Reply")
struct AuthReplyTests {

    @Test("Parse success reply")
    func parseSuccessReply() {
        var data = Data()
        data.append(0x01)  // Flag: success
        data.append(contentsOf: "effectiveUser".utf8)
        data.append(0)  // Null terminator
        data.append(16)  // Max channels

        let reply = ServerAuthReply(data: data)

        #expect(reply != nil)
        #expect(reply?.isSuccess == true)
        #expect(reply?.effectiveUsername == "effectiveUser")
        #expect(reply?.maxChannels == 16)
    }

    @Test("Parse failure reply")
    func parseFailureReply() {
        var data = Data()
        data.append(0x00)  // Flag: failure
        data.append(contentsOf: "Invalid password".utf8)
        data.append(0)  // Null terminator

        let reply = ServerAuthReply(data: data)

        #expect(reply != nil)
        #expect(reply?.isSuccess == false)
        #expect(reply?.errorMessage == "Invalid password")
    }
}

// MARK: - Config Change Tests

@Suite("Server Config Change")
struct ConfigChangeTests {

    @Test("Parse config change")
    func parseConfigChange() {
        var data = Data()
        // BPM: 120 = 0x78
        data.append(contentsOf: [0x78, 0x00])
        // BPI: 16 = 0x10
        data.append(contentsOf: [0x10, 0x00])

        let config = ServerConfigChangeNotify(data: data)

        #expect(config != nil)
        #expect(config?.beatsPerMinute == 120)
        #expect(config?.beatsPerInterval == 16)
        #expect(config?.intervalDuration == 8.0)  // 16 beats at 120 BPM = 8 seconds
    }

    @Test("Interval duration calculation")
    func intervalDurationCalculation() {
        var data = Data()
        // BPM: 60
        data.append(contentsOf: [0x3C, 0x00])
        // BPI: 4
        data.append(contentsOf: [0x04, 0x00])

        let config = ServerConfigChangeNotify(data: data)

        #expect(config?.intervalDuration == 4.0)  // 4 beats at 60 BPM = 4 seconds
    }
}

// MARK: - Client Auth User Tests

@Suite("Client Auth User")
struct ClientAuthUserTests {

    @Test("Password hash calculation")
    func passwordHashCalculation() {
        // Known test vector
        let username = "testuser"
        let password = "testpass"
        let challenge = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        let auth = ClientAuthUser.create(
            username: username,
            password: password,
            challenge: challenge
        )

        // Verify hash is 20 bytes (SHA1)
        #expect(auth.passwordHash.count == 20)

        // Verify we can recreate the same hash
        let auth2 = ClientAuthUser.create(
            username: username,
            password: password,
            challenge: challenge
        )

        #expect(auth.passwordHash == auth2.passwordHash)
    }

    @Test("Auth message serialization")
    func authMessageSerialization() {
        let auth = ClientAuthUser.create(
            username: "user",
            password: "pass",
            challenge: Data(repeating: 0, count: 8),
            agreesToLicense: true
        )

        let message = auth.buildMessage()

        // Check header
        #expect(message[0] == 0x80)  // AUTH_USER type

        // Extract payload size from header
        let payloadSize = UInt32(message[1]) |
                         (UInt32(message[2]) << 8) |
                         (UInt32(message[3]) << 16) |
                         (UInt32(message[4]) << 24)

        // Payload should contain: 20 bytes hash + "user\0" + 4 bytes caps + 4 bytes version
        // Per NINJAM protocol: passhash(20) + username(NUL) + caps(4) + version(4)
        let expectedPayloadSize: UInt32 = 20 + 5 + 4 + 4  // 33 bytes
        #expect(payloadSize == expectedPayloadSize)
    }

    @Test("Client caps flags")
    func clientCapsFlags() {
        let authWithLicense = ClientAuthUser.create(
            username: "u", password: "p", challenge: Data(count: 8), agreesToLicense: true
        )

        let authWithoutLicense = ClientAuthUser.create(
            username: "u", password: "p", challenge: Data(count: 8), agreesToLicense: false
        )

        // Bit 0 = agrees to license, Bit 1 = supports version
        #expect(authWithLicense.clientCaps & 0x01 == 1)
        #expect(authWithLicense.clientCaps & 0x02 == 2)

        #expect(authWithoutLicense.clientCaps & 0x01 == 0)
        #expect(authWithoutLicense.clientCaps & 0x02 == 2)
    }
}

// MARK: - Channel Info Tests

@Suite("Client Channel Info")
struct ChannelInfoTests {

    @Test("Single channel serialization")
    func singleChannelSerialization() {
        let channel = ClientSetChannelInfo.Channel(name: "guitar", volumeDB: -3.0, pan: 0.5)
        let channelInfo = ClientSetChannelInfo(channels: [channel])

        let message = channelInfo.buildMessage()

        #expect(message[0] == 0x82)  // SET_CHANNEL_INFO type
    }

    @Test("Multiple channels")
    func multipleChannels() {
        let channels = [
            ClientSetChannelInfo.Channel(name: "guitar"),
            ClientSetChannelInfo.Channel(name: "vocals"),
            ClientSetChannelInfo.Channel(name: "drums")
        ]
        let channelInfo = ClientSetChannelInfo(channels: channels)

        let payload = channelInfo.serialize()

        // Should contain param size (2) + 3x (name + null + volume(2) + pan(1) + flags(1))
        #expect(payload.count > 2)

        // First two bytes are param size
        let paramSize = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        #expect(paramSize == 4)
    }

    @Test("Volume and pan conversion")
    func volumePanConversion() {
        let channel = ClientSetChannelInfo.Channel(name: "test", volumeDB: -6.0, pan: -1.0)

        #expect(channel.volume == -60)  // -6.0 dB * 10
        #expect(channel.pan == -128)    // -1.0 * 128, clamped
    }
}

// MARK: - Chat Message Tests

@Suite("Chat Messages")
struct ChatMessageTests {

    @Test("Build MSG command")
    func buildMsgCommand() {
        let chat = ClientChatMessage(command: .message("Hello world"))
        let payload = chat.serialize()

        // Should be: "MSG\0Hello world\0"
        let expected = Data("MSG".utf8) + Data([0]) + Data("Hello world".utf8) + Data([0])
        #expect(payload == expected)
    }

    @Test("Build PRIVMSG command")
    func buildPrivmsgCommand() {
        let chat = ClientChatMessage(command: .privateMessage(to: "bob", text: "Hi Bob"))
        let payload = chat.serialize()

        let expected = Data("PRIVMSG".utf8) + Data([0]) + Data("bob".utf8) + Data([0]) + Data("Hi Bob".utf8) + Data([0])
        #expect(payload == expected)
    }

    @Test("Parse server MSG")
    func parseServerMsg() {
        var data = Data()
        data.append(contentsOf: "MSG".utf8)
        data.append(0)
        data.append(contentsOf: "alice".utf8)
        data.append(0)
        data.append(contentsOf: "Hello everyone".utf8)
        data.append(0)

        let message = ServerChatMessage(data: data)

        #expect(message != nil)
        if case .message(let from, let text) = message?.messageType {
            #expect(from == "alice")
            #expect(text == "Hello everyone")
        } else {
            Issue.record("Expected .message type")
        }
    }

    @Test("Parse JOIN notification")
    func parseJoinNotification() {
        var data = Data()
        data.append(contentsOf: "JOIN".utf8)
        data.append(0)
        data.append(contentsOf: "newuser".utf8)
        data.append(0)

        let message = ServerChatMessage(data: data)

        if case .join(let username) = message?.messageType {
            #expect(username == "newuser")
        } else {
            Issue.record("Expected .join type")
        }
    }
}

// MARK: - User Info Tests

@Suite("User Info Change")
struct UserInfoChangeTests {

    @Test("Parse single user channel")
    func parseSingleUserChannel() {
        var data = Data()
        data.append(1)  // active
        data.append(0)  // channel index
        data.append(contentsOf: [0xE2, 0xFF])  // volume: -30 (little endian)
        data.append(0x40)  // pan: 64
        data.append(0)  // flags
        data.append(contentsOf: "testuser".utf8)
        data.append(0)
        data.append(contentsOf: "guitar".utf8)
        data.append(0)

        let userInfo = ServerUserInfoChangeNotify(data: data)

        #expect(userInfo != nil)
        #expect(userInfo?.channels.count == 1)

        let channel = userInfo?.channels.first
        #expect(channel?.isActive == true)
        #expect(channel?.channelIndex == 0)
        #expect(channel?.volume == -30)
        #expect(channel?.pan == 64)
        #expect(channel?.username == "testuser")
        #expect(channel?.channelName == "guitar")
    }

    @Test("Parse multiple channels")
    func parseMultipleChannels() {
        var data = Data()

        // First channel
        data.append(1)  // active
        data.append(0)  // channel index
        data.append(contentsOf: [0x00, 0x00])  // volume: 0
        data.append(0x00)  // pan: 0
        data.append(0)  // flags
        data.append(contentsOf: "user1".utf8)
        data.append(0)
        data.append(contentsOf: "ch1".utf8)
        data.append(0)

        // Second channel
        data.append(1)  // active
        data.append(1)  // channel index
        data.append(contentsOf: [0x00, 0x00])  // volume: 0
        data.append(0x00)  // pan: 0
        data.append(0)  // flags
        data.append(contentsOf: "user2".utf8)
        data.append(0)
        data.append(contentsOf: "ch2".utf8)
        data.append(0)

        let userInfo = ServerUserInfoChangeNotify(data: data)

        #expect(userInfo?.channels.count == 2)
        #expect(userInfo?.channels[0].username == "user1")
        #expect(userInfo?.channels[1].username == "user2")
    }
}

// MARK: - Download Interval Tests

@Suite("Download Interval")
struct DownloadIntervalTests {

    @Test("Parse interval begin")
    func parseIntervalBegin() {
        var data = Data()
        // GUID: 16 bytes
        data.append(contentsOf: (0..<16).map { UInt8($0) })
        // Est size: 1000 = 0x3E8
        data.append(contentsOf: [0xE8, 0x03, 0x00, 0x00])
        // FourCC: 'OGGv' = 0x7667674F
        data.append(contentsOf: [0x4F, 0x67, 0x67, 0x76])
        // Channel index
        data.append(0)
        // Username
        data.append(contentsOf: "player".utf8)
        data.append(0)

        let begin = ServerDownloadIntervalBegin(data: data)

        #expect(begin != nil)
        #expect(begin?.guid.count == 16)
        #expect(begin?.estimatedSize == 1000)
        #expect(begin?.isOggVorbis == true)
        #expect(begin?.channelIndex == 0)
        #expect(begin?.username == "player")
    }

    @Test("Parse interval write")
    func parseIntervalWrite() {
        var data = Data()
        // GUID: 16 bytes
        data.append(contentsOf: (0..<16).map { UInt8($0) })
        // Flags: 1 = end
        data.append(1)
        // Audio data
        data.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])

        let write = ServerDownloadIntervalWrite(data: data)

        #expect(write != nil)
        #expect(write?.isEndOfInterval == true)
        #expect(write?.audioData.count == 4)
        #expect(write?.audioData == Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }
}

// MARK: - Keepalive Tests

@Suite("Keepalive")
struct KeepaliveTests {

    @Test("Build keepalive message")
    func buildKeepaliveMessage() {
        let message = KeepaliveMessage.buildMessage()

        #expect(message.count == 5)
        #expect(message[0] == 0xFD)  // Keepalive type
        // Payload length should be 0
        #expect(message[1] == 0)
        #expect(message[2] == 0)
        #expect(message[3] == 0)
        #expect(message[4] == 0)
    }
}

// MARK: - Integration Tests (require server)

@Suite("Integration", .disabled("Requires NINJAM server - set NINJAM_TEST_* env vars"))
struct IntegrationTests {

    @Test("Connect to server")
    func connectToServer() async throws {
        guard let config = TestConfig.shared else {
            Issue.record("Test config not available - set NINJAM_TEST_HOST, NINJAM_TEST_USER, NINJAM_TEST_PASS")
            return
        }

        // This would require async/await support in the client
        // For now, this serves as a placeholder for manual testing
        print("Would connect to \(config.host):\(config.port) as \(config.username)")
    }
}
