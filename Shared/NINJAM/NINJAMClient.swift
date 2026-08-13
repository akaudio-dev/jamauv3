// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  NINJAMClient.swift
//  jamauv3Extension
//
//  NINJAM client - handles connection, authentication, and message flow.
//

import Foundation
import Network
import os.log
import Combine

// MARK: - Client State

/// Connection state for the NINJAM client
enum NINJAMConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case awaitingChallenge      // TCP connected, waiting for server's AUTH_CHALLENGE
    case authenticating         // Sent AUTH_USER, waiting for AUTH_REPLY
    case connected              // Authenticated and ready
    case error(String)
}

// MARK: - Chat Entry

struct ChatEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: ChatEntryType

    enum ChatEntryType {
        case message(from: String, text: String)
        case join(username: String)
        case part(username: String)
        case topic(text: String)
    }
}

// MARK: - Client Delegate

/// Delegate protocol for NINJAM client events
@MainActor
protocol NINJAMClientDelegate: AnyObject {
    func client(_ client: NINJAMClient, didChangeState state: NINJAMConnectionState)
    func client(_ client: NINJAMClient, didReceiveConfig bpm: Int, bpi: Int)
    func client(_ client: NINJAMClient, didReceiveUserInfo channels: [RemoteChannelInfo])
    func client(_ client: NINJAMClient, didReceiveChatMessage message: ServerChatMessage)
    func client(_ client: NINJAMClient, didReceiveAudioBegin guid: Data, username: String, channelIndex: Int, fourCC: UInt32)
    func client(_ client: NINJAMClient, didReceiveAudioData guid: Data, data: Data, isEnd: Bool)
    func client(_ client: NINJAMClient, didReceiveLicenseAgreement license: String) -> Bool
}

// Default implementations for optional delegate methods
extension NINJAMClientDelegate {
    func client(_ client: NINJAMClient, didReceiveLicenseAgreement license: String) -> Bool { true }
    func client(_ client: NINJAMClient, didReceiveAudioBegin guid: Data, username: String, channelIndex: Int, fourCC: UInt32) {}
    func client(_ client: NINJAMClient, didReceiveAudioData guid: Data, data: Data, isEnd: Bool) {}
}

// MARK: - NINJAM Client

/// Main NINJAM client class
@MainActor
final class NINJAMClient: ObservableObject {

    // MARK: - Properties

    weak var delegate: NINJAMClientDelegate?

    // Published properties for SwiftUI binding
    @Published var isConnected: Bool = false
    @Published var connectionStatus: String = "Not connected"
    @Published var lastError: String?

    // Timing properties for UI
    @Published var bpm: Int = 0
    @Published var bpi: Int = 0
    @Published var currentBeat: Int = 0
    @Published var intervalProgress: Double = 0.0

    // HUD properties
    @Published var hostBPM: Double = 0.0
    @Published var serverTopic: String = ""
    @Published var chatMessages: [ChatEntry] = []

    // Per-user meter levels and slot usernames (updated ~15 Hz by meter timer)
    @Published var userPeaks: [Float] = Array(repeating: 0, count: 8)
    @Published var slotUsernames: [String] = Array(repeating: "", count: 8)

    var isBPMMismatch: Bool {
        hostBPM > 0 && bpm > 0 && abs(hostBPM - Double(bpm)) > 0.5
    }

    struct ServerInfo {
        let host: String
        let port: UInt16
        var bpm: Int = 120
        var bpi: Int = 16
        var maxChannels: Int = 32
        var effectiveUsername: String?
    }

    // State - now directly accessible since we're @MainActor
    private var state: NINJAMConnectionState = .disconnected
    private var serverInfo: ServerInfo?
    private var receiveBuffer = Data()
    private var keepaliveInterval: Int = 3
    private var lastSendTime: Date = Date()
    private var lastReceiveTime: Date = Date()
    private var username: String = ""
    private var password: String = ""

    /// Last server notice (empty-sender chat MSG) that looks like a kick.
    /// A kick has no protocol message — the server broadcasts the notice, then
    /// closes the socket — so this becomes the disconnect reason.
    private var lastServerNotice: String?

    // Connection
    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.jamauv3.ninjam.connection")

    // Keepalive timer runs on main thread
    private var keepaliveTimer: Timer?

    // Interval timing
    private var intervalTimer: Timer?
    private var intervalStartTime: Date?
    private var intervalDuration: TimeInterval = 0

    private let logger = Logger(subsystem: "com.jamauv3", category: "NINJAMClient")

    // MARK: - Initialization

    init() {}

    deinit {
        connection?.cancel()
    }

    // MARK: - State Management

    private func setState(_ newState: NINJAMConnectionState) {
        let oldState = state
        state = newState

        // Update UI properties
        switch newState {
        case .disconnected:
            isConnected = false
            connectionStatus = "Disconnected"
        case .connecting:
            isConnected = false
            connectionStatus = "Connecting..."
        case .awaitingChallenge:
            isConnected = false
            connectionStatus = "Awaiting server challenge..."
        case .authenticating:
            isConnected = false
            connectionStatus = "Authenticating..."
        case .connected:
            isConnected = true
            connectionStatus = "Connected"
            lastError = nil
        case .error(let message):
            isConnected = false
            connectionStatus = "Error"
            lastError = message
        }

        if newState != oldState {
            delegate?.client(self, didChangeState: newState)
        }
    }

    // MARK: - Connection

    /// Connect to a NINJAM server
    func connect(host: String, port: UInt16 = NJ_PORT, username: String, password: String) {
        switch state {
        case .disconnected, .error:
            break
        default:
            logger.warning("Already connecting or connected")
            return
        }

        self.username = username
        self.password = password
        self.serverInfo = ServerInfo(host: host, port: port)
        // Fresh keepalive clocks: stale times from a previous session would trip
        // the 3× receive timeout on the first tick and kill the handshake.
        lastSendTime = Date()
        lastReceiveTime = Date()
        lastServerNotice = nil
        lastError = nil
        logger.info("Connecting to \(host, privacy: .public):\(port, privacy: .public) as \(username, privacy: .public)")
        setState(.connecting)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.error("Invalid port \(port)"))
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Set TCP_NODELAY for lower latency
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        parameters.defaultProtocolStack.transportProtocol = tcpOptions

        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn

        // Capture the connection and compare identity in every callback: after a
        // rapid disconnect/connect, a stale event from the previous connection
        // (.cancelled, .failed, a receive error) must not stomp the new session.
        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self, self.connection === conn else { return }
                self.handleConnectionStateChange(newState)
            }
        }

        conn.start(queue: connectionQueue)

        // Start keepalive timer
        startKeepaliveTimer()
    }

    /// Disconnect from the server (user-initiated)
    func disconnect() {
        logger.debug("Disconnecting (state: \(String(describing: self.state)))")
        teardown()
        setState(.disconnected)
    }

    /// Stop timers and drop the connection without changing state.
    /// Callers set the final state: .disconnected for a user Leave,
    /// .error(reason) for a failure or a server-initiated close.
    private func teardown() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        stopIntervalTimer()

        connection?.cancel()
        connection = nil

        receiveBuffer.removeAll()
        serverInfo = nil
        // Don't retain plaintext credentials past the session; connect() sets
        // fresh ones and auto-reconnect re-supplies them from settings.
        username = ""
        password = ""
    }

    // MARK: - Connection State Handling

    private func handleConnectionStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            setState(.awaitingChallenge)
            startReceiving()

        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            teardown()
            setState(.error("Connection failed: \(error.localizedDescription)"))

        case .cancelled:
            logger.debug("Connection cancelled")
            teardown()
            setState(.disconnected)

        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === conn else { return }

                if let error = error {
                    self.logger.error("Receive error: \(error.localizedDescription)")
                    self.teardown()
                    self.setState(.error("Receive error: \(error.localizedDescription)"))
                    return
                }

                if let data = data, !data.isEmpty {
                    self.lastReceiveTime = Date()
                    self.receiveBuffer.append(data)
                    self.processReceivedData()
                }

                if isComplete {
                    // Server closed the socket under us (kick, shutdown, drop).
                    // Tear down now — previously the dead connection lingered until
                    // the keepalive timeout surfaced a misleading "Connection
                    // timeout" ~9 s later — and prefer the server's own kick
                    // notice as the reason.
                    self.logger.debug("Connection closed by server")
                    let reason = self.lastServerNotice ?? "Disconnected by server"
                    self.teardown()
                    self.setState(.error(reason))
                } else if self.connection === conn {
                    // Re-check identity: a delegate callback inside
                    // processReceivedData() could have swapped the connection;
                    // re-arming then would attach a second receive loop to it.
                    self.startReceiving()
                }
            }
        }
    }

    private func processReceivedData() {
        // Process all complete messages in the buffer
        while true {
            guard receiveBuffer.count >= NINJAMMessageHeader.size else {
                return
            }

            guard let header = NINJAMMessageHeader(data: receiveBuffer) else {
                logger.error("Invalid message header")
                setState(.error("Invalid message header"))
                return
            }

            // The protocol caps messages at NET_MESSAGE_MAX_SIZE (netmsg.cpp rejects
            // larger); an unchecked length would let a hostile server grow
            // receiveBuffer toward the full 4 GiB the UInt32 can claim.
            guard Int(header.payloadLength) <= NET_MESSAGE_MAX_SIZE else {
                logger.error("Oversized message: type 0x\(String(header.type, radix: 16)) length \(header.payloadLength)")
                teardown()
                setState(.error("Protocol error: oversized message"))
                return
            }

            let totalLength = NINJAMMessageHeader.size + Int(header.payloadLength)

            guard receiveBuffer.count >= totalLength else {
                // Need more data
                return
            }

            // Extract payload
            let payloadStart = NINJAMMessageHeader.size
            let payloadEnd = payloadStart + Int(header.payloadLength)
            let payload = receiveBuffer.subdata(in: payloadStart..<payloadEnd)

            // Remove processed message from buffer
            receiveBuffer.removeSubrange(0..<totalLength)

            // Handle the message
            handleMessage(type: header.type, payload: payload)
        }
    }

    // MARK: - Message Handling

    private func handleMessage(type: UInt8, payload: Data) {
        // Gate on connection state so the server can't drive our state machine:
        // no unsolicited AUTH_REPLY jumping straight to .connected, no
        // mid-session re-challenge (an unbounded hash oracle that also churns
        // the UI), and no session traffic before authentication completes.
        switch type {
        case NINJAMServerMessageType.authChallenge.rawValue:
            guard case .awaitingChallenge = state else { return dropUnexpected(type) }
            handleAuthChallenge(payload)

        case NINJAMServerMessageType.authReply.rawValue:
            guard case .authenticating = state else { return dropUnexpected(type) }
            handleAuthReply(payload)

        case NINJAMServerMessageType.configChangeNotify.rawValue:
            guard case .connected = state else { return dropUnexpected(type) }
            handleConfigChange(payload)

        case NINJAMServerMessageType.userInfoChangeNotify.rawValue:
            guard case .connected = state else { return dropUnexpected(type) }
            handleUserInfoChange(payload)

        case NINJAMServerMessageType.downloadIntervalBegin.rawValue:
            guard case .connected = state else { return dropUnexpected(type) }
            handleDownloadIntervalBegin(payload)

        case NINJAMServerMessageType.downloadIntervalWrite.rawValue:
            guard case .connected = state else { return dropUnexpected(type) }
            handleDownloadIntervalWrite(payload)

        case NINJAMServerMessageType.keepalive.rawValue:
            break

        case NINJAMClientMessageType.chatMessage.rawValue:
            guard case .connected = state else { return dropUnexpected(type) }
            handleChatMessage(payload)

        default:
            logger.warning("Unknown message type: 0x\(String(type, radix: 16))")
        }
    }

    private func dropUnexpected(_ type: UInt8) {
        logger.warning("Dropping message 0x\(String(type, radix: 16)) unexpected in state \(String(describing: self.state))")
    }

    private func handleAuthChallenge(_ payload: Data) {
        guard let challenge = ServerAuthChallenge(data: payload) else {
            logger.error("Failed to parse auth challenge")
            teardown()
            setState(.error("Invalid auth challenge from server"))
            return
        }

        // Check protocol version
        guard challenge.protocolVersion >= PROTO_VER_MIN && challenge.protocolVersion < PROTO_VER_MAX else {
            logger.error("Incompatible protocol version: \(challenge.protocolVersion)")
            teardown()
            setState(.error("Server has incompatible protocol version"))
            return
        }

        keepaliveInterval = challenge.keepaliveInterval > 0 ? challenge.keepaliveInterval : 3
        let password = self.password

        // NINJAM protocol: prefix username with "anonymous:" when password is empty (public servers)
        let authUsername = password.isEmpty ? "anonymous:\(self.username)" : self.username

        // Handle license agreement - for now, auto-agree
        let agreesToLicense = true

        // Build and send auth response
        let authUser = ClientAuthUser.create(
            username: authUsername,
            password: password,
            challenge: challenge.challenge,
            agreesToLicense: agreesToLicense
        )

        setState(.authenticating)
        send(data: authUser.buildMessage())
    }

    private func handleAuthReply(_ payload: Data) {
        guard let reply = ServerAuthReply(data: payload) else {
            logger.error("Failed to parse auth reply")
            teardown()
            setState(.error("Invalid auth reply from server"))
            return
        }

        if reply.isSuccess {
            serverInfo?.maxChannels = Int(reply.maxChannels)
            if let effectiveUsername = reply.effectiveUsername {
                serverInfo?.effectiveUsername = effectiveUsername
            }

            setState(.connected)

            // Send our channel info
            sendChannelInfo()

        } else {
            let errorMsg = reply.errorMessage ?? "Authentication failed"
            logger.error("Auth failed: \(errorMsg, privacy: .public)")
            teardown()
            setState(.error(errorMsg))
        }
    }

    private func handleConfigChange(_ payload: Data) {
        guard let config = ServerConfigChangeNotify(data: payload) else {
            logger.error("Failed to parse config change")
            return
        }

        let newBpm = Int(config.beatsPerMinute)
        let newBpi = Int(config.beatsPerInterval)

        serverInfo?.bpm = newBpm
        serverInfo?.bpi = newBpi
        bpm = newBpm
        bpi = newBpi

        startIntervalTimer()
        delegate?.client(self, didReceiveConfig: newBpm, bpi: newBpi)
    }

    private func handleUserInfoChange(_ payload: Data) {
        guard let userInfo = ServerUserInfoChangeNotify(data: payload) else {
            logger.error("Failed to parse user info change")
            return
        }

        // Subscribe to all active users' channels so the server sends us their audio
        subscribeToActiveUsers(userInfo.channels)

        delegate?.client(self, didReceiveUserInfo: userInfo.channels)
    }

    /// Send SetUserMask (0x81) to subscribe to all active remote users.
    /// Without this, the server may not send us download audio.
    private func subscribeToActiveUsers(_ channels: [RemoteChannelInfo]) {
        // Build subscriptions: subscribe to all channels for each active user
        var subscriptionsByUser: [String: UInt32] = [:]
        // The mask has 32 bits; higher indices would smart-shift to 0 and
        // produce no-op subscriptions, so drop them explicitly.
        for channel in channels where channel.isActive && channel.channelIndex < 32 {
            let mask = subscriptionsByUser[channel.username] ?? 0
            subscriptionsByUser[channel.username] = mask | (1 << UInt32(channel.channelIndex))
        }

        guard !subscriptionsByUser.isEmpty else { return }

        let subscriptions = subscriptionsByUser.map { (username, mask) in
            ClientSetUserMask.UserSubscription(username: username, channelMask: mask)
        }
        let userMask = ClientSetUserMask(subscriptions: subscriptions)
        send(data: userMask.buildMessage())
    }

    private func handleDownloadIntervalBegin(_ payload: Data) {
        guard let begin = ServerDownloadIntervalBegin(data: payload) else {
            logger.error("Failed to parse download interval begin")
            return
        }

        delegate?.client(self, didReceiveAudioBegin: begin.guid, username: begin.username, channelIndex: Int(begin.channelIndex), fourCC: begin.fourCC)
    }

    private func handleDownloadIntervalWrite(_ payload: Data) {
        guard let write = ServerDownloadIntervalWrite(data: payload) else {
            logger.error("Failed to parse download interval write")
            return
        }

        delegate?.client(self, didReceiveAudioData: write.guid, data: write.audioData, isEnd: write.isEndOfInterval)
    }

    private func handleChatMessage(_ payload: Data) {
        guard let chat = ServerChatMessage(data: payload) else {
            logger.error("Failed to parse chat message")
            return
        }

        // A kick arrives as a server notice (empty sender) immediately before
        // the socket closes; keep it to use as the disconnect reason.
        if case .message(let from, let text) = chat.messageType,
           from.isEmpty, text.localizedCaseInsensitiveContains("kick") {
            lastServerNotice = text
        }

        delegate?.client(self, didReceiveChatMessage: chat)
    }

    // MARK: - Sending

    private func send(data: Data) {
        guard let connection = connection else {
            logger.debug("send: no connection (disconnected), dropping \(data.count)B")
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            } else {
                Task { @MainActor [weak self] in
                    self?.lastSendTime = Date()
                }
            }
        })
    }

    /// Send our local channel information to the server
    func sendChannelInfo(channels: [ClientSetChannelInfo.Channel] = []) {
        let channelsToSend = channels.isEmpty
            ? [ClientSetChannelInfo.Channel(name: "main")]
            : channels

        let channelInfo = ClientSetChannelInfo(channels: channelsToSend)
        send(data: channelInfo.buildMessage())
    }

    /// Send a chat message. Text starting with '/' is sent as an ADMIN command.
    func sendChat(_ text: String) {
        let command: ClientChatMessage.Command
        if text.hasPrefix("/") {
            command = .admin(String(text.dropFirst()))
        } else {
            command = .message(text)
        }
        send(data: ClientChatMessage(command: command).buildMessage())
    }

    /// Send a private message
    func sendPrivateMessage(to user: String, text: String) {
        let chat = ClientChatMessage(command: .privateMessage(to: user, text: text))
        send(data: chat.buildMessage())
    }

    /// Send an upload interval begin message
    func sendUploadBegin(_ message: ClientUploadIntervalBegin) {
        send(data: message.buildMessage())
    }

    /// Send an upload interval write message
    func sendUploadWrite(_ message: ClientUploadIntervalWrite) {
        send(data: message.buildMessage())
    }

    // MARK: - Keepalive

    private func startKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkKeepalive()
            }
        }
    }

    private func checkKeepalive() {
        let now = Date()

        // Send keepalive if we haven't sent anything recently
        if now.timeIntervalSince(lastSendTime) >= TimeInterval(keepaliveInterval) {
            send(data: KeepaliveMessage.buildMessage())
        }

        // Check for timeout (3x keepalive interval without receiving)
        if now.timeIntervalSince(lastReceiveTime) >= TimeInterval(keepaliveInterval * 3) {
            logger.error("Connection timeout - no data received")
            teardown()
            setState(.error("Connection timeout"))
        }
    }

    // MARK: - Interval Timing

    /// Reset interval timer to sync with sample-accurate interval boundary
    func resetIntervalTimer() {
        guard bpm > 0, bpi > 0 else { return }
        intervalStartTime = Date()
        currentBeat = 0
        intervalProgress = 0.0
    }

    private func startIntervalTimer() {
        intervalTimer?.invalidate()

        guard bpm > 0, bpi > 0 else { return }

        intervalDuration = TimeInterval(bpi) * 60.0 / TimeInterval(bpm)
        intervalStartTime = Date()
        currentBeat = 0
        intervalProgress = 0.0

        // ~5 Hz — smooth for progress bar, combined with meter timer stays under XPC 32 Hz limit
        intervalTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateIntervalProgress()
            }
        }
    }

    private func stopIntervalTimer() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        intervalStartTime = nil
        intervalDuration = 0
        bpm = 0
        bpi = 0
        currentBeat = 0
        intervalProgress = 0.0

        // Clear HUD state
        hostBPM = 0
        serverTopic = ""
        chatMessages.removeAll()
    }

    private func updateIntervalProgress() {
        guard let startTime = intervalStartTime, intervalDuration > 0 else { return }

        let elapsed = Date().timeIntervalSince(startTime)

        // Wrap around when interval completes
        let elapsedInInterval = elapsed.truncatingRemainder(dividingBy: intervalDuration)
        let progress = elapsedInInterval / intervalDuration
        let beat = Int(progress * Double(bpi))

        // Only publish when values actually change to avoid XPC rate-limiting
        if beat != currentBeat {
            currentBeat = beat
        }
        // Quantize progress to ~100 steps to reduce update frequency
        let quantized = (progress * 100).rounded() / 100
        if quantized != (intervalProgress * 100).rounded() / 100 {
            intervalProgress = quantized
        }
    }

    // MARK: - Chat / HUD

    func addChatEntry(_ entry: ChatEntry) {
        chatMessages.append(entry)
        if chatMessages.count > 50 { chatMessages.removeFirst(chatMessages.count - 50) }
    }
}
