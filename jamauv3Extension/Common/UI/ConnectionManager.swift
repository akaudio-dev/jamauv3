//
//  ConnectionManager.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation
import Network
import Combine
import os

private let log = Logger(subsystem: "jamauv3.com.jamauv3Extension", category: "ConnectionManager")

@MainActor
class ConnectionManager: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var connectionStatus: String = "Not connected"
    @Published var lastError: String?
    
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "jamauv3.tcp.network", qos: .userInitiated)
    
    // Store a nonisolated reference for cleanup in deinit
    private nonisolated(unsafe) var connectionForCleanup: NWConnection?
    
    /// Establish a long-lived TCP connection to the specified server and port
    func connect(to host: String, port: String) {
        // Validate port number
        guard let portNumber = UInt16(port), portNumber > 0 else {
            updateStatus(connected: false, status: "Invalid port number", error: "Port must be a valid number between 1-65535")
            log.error("Invalid port number: \(port)")
            return
        }
        
        // Disconnect existing connection if any
        disconnect()
        
        // Create endpoint
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: portNumber)!)
        
        // Create TCP parameters - use NWParameters.tcp for app extensions
        let parameters = NWParameters.tcp
        
        // Configure TCP options
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 60
        tcpOptions.keepaliveInterval = 30
        tcpOptions.keepaliveCount = 5
        tcpOptions.connectionTimeout = 30
        tcpOptions.noDelay = true // Disable Nagle's algorithm for lower latency
        
        parameters.defaultProtocolStack.transportProtocol = tcpOptions
        parameters.includePeerToPeer = true
        parameters.expiredDNSBehavior = .allow
        
        // Create TCP connection
        connection = NWConnection(to: endpoint, using: parameters)
        connectionForCleanup = connection // Store for deinit cleanup
        
        // Set up state change handler
        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }
        
        // Start the connection
        connection?.start(queue: queue)
        
        updateStatus(connected: false, status: "Connecting to \(host):\(port)...", error: nil)
        log.info("Attempting TCP connection to \(host):\(portNumber)")
    }
    
    /// Disconnect from the TCP server
    func disconnect() {
        connection?.cancel()
        connection = nil
        connectionForCleanup = nil
        updateStatus(connected: false, status: "Disconnected", error: nil)
        log.info("TCP connection closed")
    }
    
    /// Send data over TCP
    func send(_ data: Data, completion: ((Error?) -> Void)? = nil) {
        guard let connection = connection, isConnected else {
            let error = NSError(domain: "ConnectionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
            completion?(error)
            log.warning("Attempted to send data while not connected")
            return
        }
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                Task { @MainActor in
                    self?.updateStatus(connected: false, status: "Send failed", error: error.localizedDescription)
                    log.error("Failed to send data: \(error.localizedDescription)")
                }
                completion?(error)
            } else {
                log.debug("Data sent successfully (\(data.count) bytes)")
                completion?(nil)
            }
        })
    }
    
    /// Send a string over TCP
    func send(_ message: String, completion: ((Error?) -> Void)? = nil) {
        guard let data = message.data(using: .utf8) else {
            let error = NSError(domain: "ConnectionManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode string"])
            completion?(error)
            return
        }
        send(data, completion: completion)
    }
    
    /// Start receiving data
    func startReceiving(messageHandler: @escaping (Data) -> Void) {
        receiveNextMessage(messageHandler: messageHandler)
    }
    
    private func receiveNextMessage(messageHandler: @escaping (Data) -> Void) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                log.debug("Received \(data.count) bytes")
                messageHandler(data)
            }
            
            if let error = error {
                Task { @MainActor in
                    self?.updateStatus(connected: false, status: "Receive error", error: error.localizedDescription)
                    log.error("Receive error: \(error.localizedDescription)")
                }
                return
            }
            
            if isComplete {
                Task { @MainActor in
                    self?.updateStatus(connected: false, status: "Connection closed by server", error: nil)
                    log.info("Connection closed by server")
                }
                return
            }
            
            // Continue receiving
            self?.receiveNextMessage(messageHandler: messageHandler)
        }
    }
    
    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            updateStatus(connected: true, status: "Connected", error: nil)
            log.info("TCP connection established (long-lived)")
            // Start receiving data
            startReceiving { data in
                // Handle received data here
                log.debug("Received data: \(data.count) bytes")
            }
            
        case .waiting(let error):
            updateStatus(connected: false, status: "Waiting to connect...", error: error.localizedDescription)
            log.warning("Connection waiting: \(error.localizedDescription)")
            
        case .failed(let error):
            updateStatus(connected: false, status: "Connection failed", error: error.localizedDescription)
            log.error("Connection failed: \(error.localizedDescription)")
            
        case .cancelled:
            updateStatus(connected: false, status: "Disconnected", error: nil)
            log.info("Connection cancelled")
            
        case .preparing:
            updateStatus(connected: false, status: "Preparing...", error: nil)
            log.debug("Connection preparing")
            
        case .setup:
            updateStatus(connected: false, status: "Setting up...", error: nil)
            log.debug("Connection setup")
            
        @unknown default:
            updateStatus(connected: false, status: "Unknown state", error: nil)
            log.warning("Unknown connection state")
        }
    }
    
    private func updateStatus(connected: Bool, status: String, error: String?) {
        isConnected = connected
        connectionStatus = status
        lastError = error
    }
    
    nonisolated deinit {
        // Cancel connection from deinit - NWConnection.cancel() is thread-safe
        connectionForCleanup?.cancel()
    }
}
