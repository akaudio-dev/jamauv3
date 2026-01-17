//
//  NINJAMClient.swift
//  jamauv3Extension
//
//  NINJAM client - handles connection, authentication, and message flow.
//

import Foundation
import Network
import os.log

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

// MARK: - Client Delegate

/// Delegate protocol for NINJAM client events
@MainActor
protocol NINJAMClientDelegate: AnyObject {
    func client(_ client: NINJAMClient, didChangeState state: NINJAMConnectionState)
    func client(_ client: NINJAMClient, didReceiveConfig bpm: Int, bpi: Int)
    func client(_ client: NINJAMClient, didReceiveUserInfo channels: [RemoteChannelInfo])
    func client(_ client: NINJAMClient, didReceiveChatMessage message: ServerChatMessage)
    func client(_ client: NINJAMClient, didReceiveAudioBegin guid: Data, username: String, channelIndex: Int)
    func client(_ client: NINJAMClient, didReceiveAudioData guid: Data, data: Data, isEnd: Bool)
    func client(_ client: NINJAMClient, didReceiveLicenseAgreement license: String) -> Bool
}

// Default implementations for optional delegate methods
extension NINJAMClientDelegate {
    func client(_ client: NINJAMClient, didReceiveLicenseAgreement license: String) -> Bool { true }
    func client(_ client: NINJAMClient, didReceiveAudioBegin guid: Data, username: String, channelIndex: Int) {}
    func client(_ client: NINJAMClient, didReceiveAudioData guid: Data, data: Data, isEnd: Bool) {}
}

// MARK: - NINJAM Client

/// Main NINJAM client class
final class NINJAMClient: Sendable {

    // MARK: - Properties

    @MainActor weak var delegate: NINJAMClientDelegate?

    struct ServerInfo: Sendable {
        let host: String
        let port: UInt16
        var bpm: Int = 120
        var bpi: Int = 16
        var maxChannels: Int = 32
        var effectiveUsername: String?
    }

    // Thread-safe state using actor-like pattern with a lock
    private let lock = NSLock()
    private var _state: NINJAMConnectionState = .disconnected
    private var _serverInfo: ServerInfo?
    private var _receiveBuffer = Data()
    private var _keepaliveInterval: Int = 3
    private var _lastSendTime: Date = Date()
    private var _lastReceiveTime: Date = Date()
    private var _username: String = ""
    private var _password: String = ""

    var state: NINJAMConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var serverInfo: ServerInfo? {
        lock.lock()
        defer { lock.unlock() }
        return _serverInfo
    }

    // Connection
    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.jamauv3.ninjam.connection")

    // Keepalive timer runs on main thread
    @MainActor private var keepaliveTimer: Timer?

    private let logger = Logger(subsystem: "com.jamauv3", category: "NINJAMClient")

    // MARK: - Initialization

    init() {}

    deinit {
        connection?.cancel()
    }

    // MARK: - State Management (thread-safe)

    private func setState(_ newState: NINJAMConnectionState) {
        let oldState: NINJAMConnectionState
        lock.lock()
        oldState = _state
        _state = newState
        lock.unlock()

        if newState != oldState {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.delegate?.client(self, didChangeState: newState)
            }
        }
    }

    // MARK: - Connection

    /// Connect to a NINJAM server
    func connect(host: String, port: UInt16 = NJ_PORT, username: String, password: String) {
        lock.lock()
        guard _state == .disconnected else {
            lock.unlock()
            logger.warning("Already connecting or connected")
            return
        }

        _username = username
        _password = password
        _serverInfo = ServerInfo(host: host, port: port)
        _state = .connecting
        lock.unlock()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Set TCP_NODELAY for lower latency
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        parameters.defaultProtocolStack.transportProtocol = tcpOptions

        connection = NWConnection(to: endpoint, using: parameters)

        connection?.stateUpdateHandler = { [weak self] newState in
            self?.handleConnectionStateChange(newState)
        }

        connection?.start(queue: connectionQueue)

        // Start keepalive on main thread
        Task { @MainActor [weak self] in
            self?.startKeepaliveTimer()
        }
    }

    /// Disconnect from the server
    func disconnect() {
        // Stop keepalive timer on main thread
        Task { @MainActor [weak self] in
            self?.keepaliveTimer?.invalidate()
            self?.keepaliveTimer = nil
        }

        connection?.cancel()
        connection = nil

        lock.lock()
        _receiveBuffer.removeAll()
        _serverInfo = nil
        _state = .disconnected
        lock.unlock()
    }

    // MARK: - Connection State Handling

    private func handleConnectionStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            logger.info("TCP connection established")
            setState(.awaitingChallenge)
            startReceiving()

        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription)")
            setState(.error("Connection failed: \(error.localizedDescription)"))

        case .cancelled:
            logger.info("Connection cancelled")
            setState(.disconnected)

        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Receive error: \(error.localizedDescription)")
                self.setState(.error("Receive error: \(error.localizedDescription)"))
                return
            }

            if let data = data, !data.isEmpty {
                self.lock.lock()
                self._lastReceiveTime = Date()
                self._receiveBuffer.append(data)
                self.lock.unlock()

                self.processReceivedData()
            }

            if isComplete {
                self.logger.info("Connection closed by server")
                self.setState(.disconnected)
            } else {
                // Continue receiving
                self.startReceiving()
            }
        }
    }

    private func processReceivedData() {
        // Process all complete messages in the buffer
        while true {
            lock.lock()
            guard _receiveBuffer.count >= NINJAMMessageHeader.size else {
                lock.unlock()
                return
            }

            guard let header = NINJAMMessageHeader(data: _receiveBuffer) else {
                lock.unlock()
                logger.error("Invalid message header")
                setState(.error("Invalid message header"))
                return
            }

            let totalLength = NINJAMMessageHeader.size + Int(header.payloadLength)

            guard _receiveBuffer.count >= totalLength else {
                lock.unlock()
                // Need more data
                return
            }

            // Extract payload
            let payloadStart = NINJAMMessageHeader.size
            let payloadEnd = payloadStart + Int(header.payloadLength)
            let payload = _receiveBuffer.subdata(in: payloadStart..<payloadEnd)

            // Remove processed message from buffer
            _receiveBuffer.removeSubrange(0..<totalLength)
            lock.unlock()

            // Handle the message
            handleMessage(type: header.type, payload: payload)
        }
    }

    // MARK: - Message Handling

    private func handleMessage(type: UInt8, payload: Data) {
        logger.debug("Received message type: 0x\(String(type, radix: 16)), payload: \(payload.count) bytes")

        switch type {
        case NINJAMServerMessageType.authChallenge.rawValue:
            handleAuthChallenge(payload)

        case NINJAMServerMessageType.authReply.rawValue:
            handleAuthReply(payload)

        case NINJAMServerMessageType.configChangeNotify.rawValue:
            handleConfigChange(payload)

        case NINJAMServerMessageType.userInfoChangeNotify.rawValue:
            handleUserInfoChange(payload)

        case NINJAMServerMessageType.downloadIntervalBegin.rawValue:
            handleDownloadIntervalBegin(payload)

        case NINJAMServerMessageType.downloadIntervalWrite.rawValue:
            handleDownloadIntervalWrite(payload)

        case NINJAMServerMessageType.keepalive.rawValue:
            logger.debug("Keepalive received")

        case NINJAMClientMessageType.chatMessage.rawValue:
            handleChatMessage(payload)

        default:
            logger.warning("Unknown message type: 0x\(String(type, radix: 16))")
        }
    }

    private func handleAuthChallenge(_ payload: Data) {
        guard let challenge = ServerAuthChallenge(data: payload) else {
            logger.error("Failed to parse auth challenge")
            setState(.error("Invalid auth challenge from server"))
            return
        }

        // Check protocol version
        guard challenge.protocolVersion >= PROTO_VER_MIN && challenge.protocolVersion < PROTO_VER_MAX else {
            logger.error("Incompatible protocol version: \(challenge.protocolVersion)")
            setState(.error("Server has incompatible protocol version"))
            disconnect()
            return
        }

        lock.lock()
        _keepaliveInterval = challenge.keepaliveInterval > 0 ? challenge.keepaliveInterval : 3
        let username = _username
        let password = _password
        lock.unlock()

        // Handle license agreement - for now, auto-agree
        let agreesToLicense = true

        // Build and send auth response
        let authUser = ClientAuthUser.create(
            username: username,
            password: password,
            challenge: challenge.challenge,
            agreesToLicense: agreesToLicense
        )

        setState(.authenticating)
        send(data: authUser.buildMessage())

        logger.info("Sent auth response for user: \(username)")
    }

    private func handleAuthReply(_ payload: Data) {
        guard let reply = ServerAuthReply(data: payload) else {
            logger.error("Failed to parse auth reply")
            setState(.error("Invalid auth reply from server"))
            return
        }

        if reply.isSuccess {
            lock.lock()
            _serverInfo?.maxChannels = Int(reply.maxChannels)
            if let effectiveUsername = reply.effectiveUsername {
                _serverInfo?.effectiveUsername = effectiveUsername
            }
            lock.unlock()

            if let effectiveUsername = reply.effectiveUsername {
                logger.info("Server assigned username: \(effectiveUsername)")
            }

            setState(.connected)
            logger.info("Authentication successful!")

            // Send our channel info
            sendChannelInfo()

        } else {
            let errorMsg = reply.errorMessage ?? "Authentication failed"
            logger.error("Auth failed: \(errorMsg)")
            setState(.error(errorMsg))
            disconnect()
        }
    }

    private func handleConfigChange(_ payload: Data) {
        guard let config = ServerConfigChangeNotify(data: payload) else {
            logger.error("Failed to parse config change")
            return
        }

        lock.lock()
        _serverInfo?.bpm = Int(config.beatsPerMinute)
        _serverInfo?.bpi = Int(config.beatsPerInterval)
        lock.unlock()

        logger.info("Config: BPM=\(config.beatsPerMinute), BPI=\(config.beatsPerInterval), interval=\(config.intervalDuration)s")

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.client(self, didReceiveConfig: Int(config.beatsPerMinute), bpi: Int(config.beatsPerInterval))
        }
    }

    private func handleUserInfoChange(_ payload: Data) {
        guard let userInfo = ServerUserInfoChangeNotify(data: payload) else {
            logger.error("Failed to parse user info change")
            return
        }

        logger.info("User info update: \(userInfo.channels.count) channels")
        for channel in userInfo.channels {
            logger.debug("  \(channel.username)/\(channel.channelName) active=\(channel.isActive)")
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.client(self, didReceiveUserInfo: userInfo.channels)
        }
    }

    private func handleDownloadIntervalBegin(_ payload: Data) {
        guard let begin = ServerDownloadIntervalBegin(data: payload) else {
            logger.error("Failed to parse download interval begin")
            return
        }

        logger.debug("Audio begin: \(begin.username) ch\(begin.channelIndex) size=\(begin.estimatedSize)")

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.client(self, didReceiveAudioBegin: begin.guid, username: begin.username, channelIndex: Int(begin.channelIndex))
        }
    }

    private func handleDownloadIntervalWrite(_ payload: Data) {
        guard let write = ServerDownloadIntervalWrite(data: payload) else {
            logger.error("Failed to parse download interval write")
            return
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.client(self, didReceiveAudioData: write.guid, data: write.audioData, isEnd: write.isEndOfInterval)
        }
    }

    private func handleChatMessage(_ payload: Data) {
        guard let chat = ServerChatMessage(data: payload) else {
            logger.error("Failed to parse chat message")
            return
        }

        switch chat.messageType {
        case .message(let from, let text):
            logger.info("Chat from \(from): \(text)")
        case .privateMessage(let from, let text):
            logger.info("PM from \(from): \(text)")
        case .topicChange(let topic):
            logger.info("Topic: \(topic)")
        case .join(let username):
            logger.info("\(username) joined")
        case .part(let username):
            logger.info("\(username) left")
        case .unknown(let params):
            logger.debug("Unknown chat: \(params)")
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.client(self, didReceiveChatMessage: chat)
        }
    }

    // MARK: - Sending

    private func send(data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            } else {
                self?.lock.lock()
                self?._lastSendTime = Date()
                self?.lock.unlock()
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

        logger.info("Sent channel info: \(channelsToSend.map { $0.name })")
    }

    /// Send a chat message
    func sendChat(_ text: String) {
        let chat = ClientChatMessage(command: .message(text))
        send(data: chat.buildMessage())
    }

    /// Send a private message
    func sendPrivateMessage(to user: String, text: String) {
        let chat = ClientChatMessage(command: .privateMessage(to: user, text: text))
        send(data: chat.buildMessage())
    }

    // MARK: - Keepalive

    @MainActor
    private func startKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkKeepalive()
        }
    }

    private func checkKeepalive() {
        lock.lock()
        let keepaliveInterval = _keepaliveInterval
        let lastSendTime = _lastSendTime
        let lastReceiveTime = _lastReceiveTime
        lock.unlock()

        let now = Date()

        // Send keepalive if we haven't sent anything recently
        if now.timeIntervalSince(lastSendTime) >= TimeInterval(keepaliveInterval) {
            send(data: KeepaliveMessage.buildMessage())
            logger.debug("Sent keepalive")
        }

        // Check for timeout (3x keepalive interval without receiving)
        if now.timeIntervalSince(lastReceiveTime) >= TimeInterval(keepaliveInterval * 3) {
            logger.error("Connection timeout - no data received")
            setState(.error("Connection timeout"))
            disconnect()
        }
    }
}
