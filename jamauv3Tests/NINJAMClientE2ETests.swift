//
//  NINJAMClientE2ETests.swift
//  jamauv3Tests
//
//  End-to-end tests for NINJAM protocol authentication flow.
//  These tests connect to a real NINJAM server to verify the protocol implementation.
//
//  Configuration (in order of priority):
//  1. Environment variables: NINJAM_TEST_HOST, NINJAM_TEST_USER, NINJAM_TEST_PASS, NINJAM_TEST_PORT
//  2. UserDefaults from the app (jamauv3.connection.*)
//

import XCTest
import Network
@testable import jamauv3

// MARK: - E2E Test Configuration

// Helper to get bundle for the test target
private class E2EBundleToken {}

/// Configuration for E2E tests - tries multiple sources
struct E2ETestConfig {
    let host: String
    let port: UInt16
    let username: String
    let password: String

    static var shared: E2ETestConfig? = {
        // Priority 1: Environment variables
        if let host = ProcessInfo.processInfo.environment["NINJAM_TEST_HOST"],
           let user = ProcessInfo.processInfo.environment["NINJAM_TEST_USER"],
           let pass = ProcessInfo.processInfo.environment["NINJAM_TEST_PASS"],
           !host.isEmpty, !user.isEmpty {
            let port = UInt16(ProcessInfo.processInfo.environment["NINJAM_TEST_PORT"] ?? "2049") ?? 2049
            return E2ETestConfig(host: host, port: port, username: user, password: pass)
        }

        // Priority 2: TestConfig.json in test bundle
        if let configURL = Bundle(for: E2EBundleToken.self).url(forResource: "TestConfig", withExtension: "json"),
           let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let host = json["host"] as? String,
           let user = json["username"] as? String,
           let pass = json["password"] as? String,
           !host.isEmpty, !user.isEmpty {
            let port = (json["port"] as? Int).map { UInt16($0) } ?? 2049
            return E2ETestConfig(host: host, port: port, username: user, password: pass)
        }

        // Priority 3: UserDefaults (saved from the app)
        let defaults = UserDefaults.standard
        if let host = defaults.string(forKey: "jamauv3.connection.serverName"),
           let user = defaults.string(forKey: "jamauv3.connection.username"),
           let pass = defaults.string(forKey: "jamauv3.connection.password"),
           !host.isEmpty, !user.isEmpty {
            let portStr = defaults.string(forKey: "jamauv3.connection.port") ?? "2049"
            let port = UInt16(portStr) ?? 2049
            return E2ETestConfig(host: host, port: port, username: user, password: pass)
        }

        return nil
    }()
}

// MARK: - E2E Protocol Tests

class NINJAMProtocolE2ETests: XCTestCase {

    /// Test: Raw TCP connection and AUTH_CHALLENGE reception
    func testReceiveAuthChallenge() async throws {
        guard let config = E2ETestConfig.shared else {
            throw XCTSkip("No test configuration available. Set NINJAM_TEST_* env vars or save connection in app.")
        }

        let challengeExpectation = expectation(description: "Should receive AUTH_CHALLENGE")
        var receivedChallenge: ServerAuthChallenge?

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!
        )

        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 5, maximumLength: 1024) { data, _, _, error in
                    guard let data = data, error == nil else { return }

                    guard let header = NINJAMMessageHeader(data: data) else { return }

                    if header.type == NINJAMServerMessageType.authChallenge.rawValue {
                        let payloadStart = NINJAMMessageHeader.size
                        let payload = data.subdata(in: payloadStart..<data.count)

                        if let challenge = ServerAuthChallenge(data: payload) {
                            receivedChallenge = challenge
                            challengeExpectation.fulfill()
                        }
                    }
                }
            }
        }

        connection.start(queue: .global())

        await fulfillment(of: [challengeExpectation], timeout: 10.0)

        connection.cancel()

        XCTAssertNotNil(receivedChallenge)
        if let challenge = receivedChallenge {
            XCTAssertEqual(challenge.challenge.count, 8, "Challenge should be 8 bytes")
            XCTAssertGreaterThanOrEqual(challenge.protocolVersion, PROTO_VER_MIN)
            XCTAssertLessThan(challenge.protocolVersion, PROTO_VER_MAX)
            print("AUTH_CHALLENGE received:")
            print("  Protocol: 0x\(String(challenge.protocolVersion, radix: 16))")
            print("  Keepalive: \(challenge.keepaliveInterval)s")
        }
    }

    /// Test: Full authentication handshake - connect, receive challenge, send auth, receive reply
    func testFullAuthHandshake() async throws {
        guard let config = E2ETestConfig.shared else {
            throw XCTSkip("No test configuration available. Set NINJAM_TEST_* env vars or save connection in app.")
        }

        let authReplyExpectation = expectation(description: "Should receive AUTH_REPLY")
        var receivedReply: ServerAuthReply?

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!
        )

        let connection = NWConnection(to: endpoint, using: .tcp)
        var receiveBuffer = Data()

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                guard let data = data, error == nil else { return }
                receiveBuffer.append(data)

                // Parse complete messages from buffer
                while receiveBuffer.count >= NINJAMMessageHeader.size {
                    guard let header = NINJAMMessageHeader(data: receiveBuffer) else { break }
                    let totalLen = NINJAMMessageHeader.size + Int(header.payloadLength)
                    guard receiveBuffer.count >= totalLen else { break }

                    let payload = receiveBuffer.subdata(in: NINJAMMessageHeader.size..<totalLen)
                    receiveBuffer.removeSubrange(0..<totalLen)

                    switch header.type {
                    case NINJAMServerMessageType.authChallenge.rawValue:
                        if let challenge = ServerAuthChallenge(data: payload) {
                            // Build and send AUTH_USER response
                            let authUser = ClientAuthUser.create(
                                username: config.username,
                                password: config.password,
                                challenge: challenge.challenge,
                                agreesToLicense: true
                            )
                            let message = authUser.buildMessage()
                            connection.send(content: message, completion: .contentProcessed { _ in })
                        }

                    case NINJAMServerMessageType.authReply.rawValue:
                        if let reply = ServerAuthReply(data: payload) {
                            receivedReply = reply
                            authReplyExpectation.fulfill()
                            return
                        }

                    default:
                        break
                    }
                }

                if !isComplete {
                    receiveNext()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                receiveNext()
            }
        }

        connection.start(queue: .global())

        await fulfillment(of: [authReplyExpectation], timeout: 10.0)

        connection.cancel()

        XCTAssertNotNil(receivedReply)
        if let reply = receivedReply {
            XCTAssertTrue(reply.isSuccess, "Authentication should succeed")
            print("AUTH_REPLY received:")
            print("  Success: \(reply.isSuccess)")
            print("  Max channels: \(reply.maxChannels)")
            if let username = reply.effectiveUsername {
                print("  Effective username: \(username)")
            }
        }
    }

    /// Test: Authentication fails with wrong password
    func testAuthFailsWithWrongPassword() async throws {
        guard let config = E2ETestConfig.shared else {
            throw XCTSkip("No test configuration available.")
        }

        let authReplyExpectation = expectation(description: "Should receive AUTH_REPLY")
        var receivedReply: ServerAuthReply?

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!
        )

        let connection = NWConnection(to: endpoint, using: .tcp)
        var receiveBuffer = Data()

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                guard let data = data, error == nil else { return }
                receiveBuffer.append(data)

                while receiveBuffer.count >= NINJAMMessageHeader.size {
                    guard let header = NINJAMMessageHeader(data: receiveBuffer) else { break }
                    let totalLen = NINJAMMessageHeader.size + Int(header.payloadLength)
                    guard receiveBuffer.count >= totalLen else { break }

                    let payload = receiveBuffer.subdata(in: NINJAMMessageHeader.size..<totalLen)
                    receiveBuffer.removeSubrange(0..<totalLen)

                    switch header.type {
                    case NINJAMServerMessageType.authChallenge.rawValue:
                        if let challenge = ServerAuthChallenge(data: payload) {
                            // Send auth with WRONG password
                            let authUser = ClientAuthUser.create(
                                username: config.username,
                                password: "definitely_wrong_password_12345",
                                challenge: challenge.challenge,
                                agreesToLicense: true
                            )
                            connection.send(content: authUser.buildMessage(), completion: .contentProcessed { _ in })
                        }

                    case NINJAMServerMessageType.authReply.rawValue:
                        if let reply = ServerAuthReply(data: payload) {
                            receivedReply = reply
                            authReplyExpectation.fulfill()
                            return
                        }

                    default:
                        break
                    }
                }

                if !isComplete {
                    receiveNext()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                receiveNext()
            }
        }

        connection.start(queue: .global())

        await fulfillment(of: [authReplyExpectation], timeout: 10.0)

        connection.cancel()

        XCTAssertNotNil(receivedReply)
        if let reply = receivedReply {
            XCTAssertFalse(reply.isSuccess, "Authentication should fail with wrong password")
            print("AUTH_REPLY (expected failure):")
            print("  Success: \(reply.isSuccess)")
            if let error = reply.errorMessage {
                print("  Error: \(error)")
            }
        }
    }

    /// Test: Receive OGG audio fragments from other users
    func testReceiveOggFragments() async throws {
        guard let config = E2ETestConfig.shared else {
            throw XCTSkip("No test configuration available. Set NINJAM_TEST_* env vars or save connection in app.")
        }

        let fragmentReceivedExpectation = expectation(description: "Should receive OGG audio fragments")
        fragmentReceivedExpectation.assertForOverFulfill = false // Allow multiple fragments

        var audioStreams: [Data: (username: String, channelIndex: Int, chunks: [Data])] = [:]
        var receivedFragmentCount = 0
        var completedStreamCount = 0

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!
        )

        let connection = NWConnection(to: endpoint, using: .tcp)
        var receiveBuffer = Data()
        var isAuthenticated = false
        var hasSentChannelInfo = false

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                guard let data = data, error == nil else { return }
                receiveBuffer.append(data)

                // Parse complete messages from buffer
                while receiveBuffer.count >= NINJAMMessageHeader.size {
                    guard let header = NINJAMMessageHeader(data: receiveBuffer) else { break }
                    let totalLen = NINJAMMessageHeader.size + Int(header.payloadLength)
                    guard receiveBuffer.count >= totalLen else { break }

                    let payload = receiveBuffer.subdata(in: NINJAMMessageHeader.size..<totalLen)
                    receiveBuffer.removeSubrange(0..<totalLen)

                    switch header.type {
                    case NINJAMServerMessageType.authChallenge.rawValue:
                        if let challenge = ServerAuthChallenge(data: payload) {
                            let authUser = ClientAuthUser.create(
                                username: config.username,
                                password: config.password,
                                challenge: challenge.challenge,
                                agreesToLicense: true
                            )
                            connection.send(content: authUser.buildMessage(), completion: .contentProcessed { _ in })
                            print("✓ Sent AUTH_USER")
                        }

                    case NINJAMServerMessageType.authReply.rawValue:
                        if let reply = ServerAuthReply(data: payload) {
                            XCTAssertTrue(reply.isSuccess, "Authentication should succeed")
                            isAuthenticated = true
                            print("✓ Authenticated as \(reply.effectiveUsername ?? config.username)")

                            // Send our channel info to fully join the session
                            let channelInfo = ClientSetChannelInfo(channels: [
                                ClientSetChannelInfo.Channel(name: "test")
                            ])
                            connection.send(content: channelInfo.buildMessage(), completion: .contentProcessed { _ in })
                            hasSentChannelInfo = true
                            print("✓ Sent channel info")
                        }

                    case NINJAMServerMessageType.configChangeNotify.rawValue:
                        if let config = ServerConfigChangeNotify(data: payload) {
                            print("✓ Config: \(config.beatsPerMinute) BPM, \(config.beatsPerInterval) BPI (\(config.intervalDuration)s)")
                        }

                    case NINJAMServerMessageType.userInfoChangeNotify.rawValue:
                        if let userInfo = ServerUserInfoChangeNotify(data: payload) {
                            print("✓ User info: \(userInfo.channels.count) channels")
                            for channel in userInfo.channels {
                                print("  - \(channel.username)/\(channel.channelName) (active: \(channel.isActive))")
                            }

                            // Subscribe to all active users so the server sends us their audio
                            var subscriptionsByUser: [String: UInt32] = [:]
                            for channel in userInfo.channels where channel.isActive {
                                let mask = subscriptionsByUser[channel.username] ?? 0
                                subscriptionsByUser[channel.username] = mask | (1 << UInt32(channel.channelIndex))
                            }
                            if !subscriptionsByUser.isEmpty {
                                let subscriptions = subscriptionsByUser.map { (username, mask) in
                                    ClientSetUserMask.UserSubscription(username: username, channelMask: mask)
                                }
                                let userMask = ClientSetUserMask(subscriptions: subscriptions)
                                connection.send(content: userMask.buildMessage(), completion: .contentProcessed { _ in })
                                print("✓ Subscribed to \(subscriptions.count) users")
                            }
                        }

                    case NINJAMServerMessageType.downloadIntervalBegin.rawValue:
                        if let begin = ServerDownloadIntervalBegin(data: payload) {
                            print("✓ Audio BEGIN: \(begin.username) ch\(begin.channelIndex)")
                            print("  GUID: \(begin.guid.map { String(format: "%02x", $0) }.joined())")
                            print("  Size: \(begin.estimatedSize) bytes")
                            print("  Format: \(begin.isOggVorbis ? "OGG Vorbis" : "silence (0x\(String(begin.fourCC, radix: 16)))")")

                            // Only track OGG intervals; silence intervals (fourCC=0) are normal
                            guard begin.isOggVorbis else { break }

                            // Initialize stream tracking
                            audioStreams[begin.guid] = (begin.username, Int(begin.channelIndex), [])
                        }

                    case NINJAMServerMessageType.downloadIntervalWrite.rawValue:
                        if let write = ServerDownloadIntervalWrite(data: payload) {
                            // Accumulate audio data
                            if var stream = audioStreams[write.guid] {
                                stream.chunks.append(write.audioData)
                                audioStreams[write.guid] = stream

                                receivedFragmentCount += 1
                                print("✓ Audio WRITE: \(write.audioData.count) bytes (end: \(write.isEndOfInterval))")

                                if write.isEndOfInterval {
                                    // Complete stream received
                                    let totalSize = stream.chunks.reduce(0) { $0 + $1.count }
                                    print("✓ Audio COMPLETE: \(stream.username) ch\(stream.channelIndex)")
                                    print("  Total: \(totalSize) bytes in \(stream.chunks.count) fragments")

                                    // Combine all chunks into a single OGG stream
                                    var completeOgg = Data()
                                    for chunk in stream.chunks {
                                        completeOgg.append(chunk)
                                    }

                                    // Verify OGG header (starts with "OggS")
                                    XCTAssertGreaterThan(completeOgg.count, 4, "OGG data should not be empty")
                                    if completeOgg.count >= 4 {
                                        let header = String(data: completeOgg.prefix(4), encoding: .ascii)
                                        XCTAssertEqual(header, "OggS", "Should start with OGG capture pattern")
                                        print("✓ OGG header verified: \(completeOgg.count) bytes")
                                    }

                                    completedStreamCount += 1
                                    audioStreams.removeValue(forKey: write.guid)

                                    // Fulfill after receiving at least one complete stream
                                    if completedStreamCount >= 1 {
                                        fragmentReceivedExpectation.fulfill()
                                    }
                                }
                            }
                        }

                    case NINJAMServerMessageType.keepalive.rawValue:
                        // Send keepalive back
                        connection.send(content: KeepaliveMessage.buildMessage(), completion: .contentProcessed { _ in })

                    default:
                        break
                    }
                }

                if !isComplete {
                    receiveNext()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                print("✓ TCP connected")
                receiveNext()
            }
        }

        connection.start(queue: .global())

        // Wait up to 60 seconds for audio fragments (some servers have long intervals)
        await fulfillment(of: [fragmentReceivedExpectation], timeout: 60.0)

        connection.cancel()

        print("\n=== Test Summary ===")
        print("Fragments received: \(receivedFragmentCount)")
        print("Completed streams: \(completedStreamCount)")

        XCTAssertGreaterThan(receivedFragmentCount, 0, "Should receive at least one audio fragment")
        XCTAssertGreaterThan(completedStreamCount, 0, "Should receive at least one complete audio stream")
    }
}
