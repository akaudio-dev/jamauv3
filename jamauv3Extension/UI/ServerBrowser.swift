// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  ServerBrowser.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 2/24/26.
//

import SwiftUI
import os

private let log = Logger(subsystem: "jamauv3.com.jamauv3Extension", category: "ServerBrowser")

// MARK: - API Data Model

struct NINJAMServerListResponse: Decodable {
    let servers: [NINJAMServerEntry]
}

struct NINJAMServerEntry: Decodable, Identifiable {
    var id: String { name }

    let host: String
    let port: String
    let bpi: FlexInt
    let bpm: FlexInt
    let name: String
    let pri: Int?
    let sslStream: String?
    let stream: String?
    let userCount: FlexInt?
    let userLimit: FlexInt?
    let userMax: FlexInt?
    let users: [NINJAMServerUser]

    enum CodingKeys: String, CodingKey {
        case host, port, bpi, bpm, name, pri, stream, users
        case sslStream = "ssl_stream"
        case userCount = "user_count"
        case userLimit = "user_limit"
        case userMax = "user_max"
    }

    var portNumber: UInt16 { UInt16(port) ?? 2049 }
    var userCountValue: Int { users.count }
    var maxUsers: Int { userMax?.value ?? userLimit?.value ?? 0 }

    var streamURL: URL? {
        // Server-list JSON is untrusted; only ever hand http(s) URLs to URLSession.
        if let ssl = sslStream, let url = URL(string: ssl), Self.isWebURL(url) { return url }
        if let s = stream, let url = URL(string: s), Self.isWebURL(url) { return url }
        return nil
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

struct NINJAMServerUser: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let co: String?
    let country: String?
    let city: String?
}

/// Handles JSON values that may be either a string or an integer.
struct FlexInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let strVal = try? container.decode(String.self), let parsed = Int(strVal) {
            value = parsed
        } else {
            value = 0
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class ServerBrowserViewModel {
    var servers: [NINJAMServerEntry] = []
    var isLoading = false
    var errorMessage: String?
    var listeningServerID: String?

    var onListenStart: ((URL) -> Void)?
    var onListenStop: (() -> Void)?
    var icecastPeakReader: (() -> Float)?
    /// Polled while listening: false once the stream has ended on its own
    /// (server close, network error, idle timeout) so the UI can tear down
    /// instead of sitting silent on a stuck "listening" row.
    var icecastIsAlive: (() -> Bool)?

    var icecastPeakLevel: Float = 0
    private var refreshTask: Task<Void, Never>?
    private var peakTimer: Task<Void, Never>?

    private static let apiURL = URL(string: "https://ninbot.com/app/servers.php")!

    var sortedServers: [NINJAMServerEntry] {
        servers.sorted { a, b in
            if a.userCountValue != b.userCountValue {
                return a.userCountValue > b.userCountValue
            }
            return (a.pri ?? 999) < (b.pri ?? 999)
        }
    }

    func startAutoRefresh() {
        servers = []  // Clear stale data from @State persistence
        fetch()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.fetch()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        stopListening()
    }

    func fetch() {
        isLoading = true
        errorMessage = nil
        log.notice("Fetching server list from \(Self.apiURL, privacy: .public)")
        Task {
            defer { isLoading = false }
            do {
                // Cache-bust: append timestamp to bypass CDN/proxy caches
                var components = URLComponents(url: Self.apiURL, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]
                var request = URLRequest(url: components.url!)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    log.error("Server list fetch failed: HTTP \(code)")
                    errorMessage = "Server returned an error"
                    return
                }
                // Bound the body (normal responses are ~50 KB) — an unbounded
                // download would OOM the memory-limited AUv3 extension.
                let maxBytes = 4 * 1024 * 1024
                var data = Data()
                data.reserveCapacity(128 * 1024)
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maxBytes {
                        log.error("Server list response exceeded \(maxBytes) bytes")
                        errorMessage = "Server returned an oversized response"
                        return
                    }
                }
                servers = try JSONDecoder().decode(NINJAMServerListResponse.self, from: data).servers
                log.notice("Loaded \(self.servers.count) servers")
            } catch {
                log.error("Server list fetch error: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleListening(for server: NINJAMServerEntry) {
        if listeningServerID == server.id {
            stopListening()
        } else {
            startListening(to: server)
        }
    }

    private func startListening(to server: NINJAMServerEntry) {
        stopListening()
        guard let url = server.streamURL else { return }
        log.info("Starting listen: \(url.absoluteString, privacy: .public)")
        onListenStart?(url)
        listeningServerID = server.id
        startPeakTimer()
    }

    func stopListening() {
        peakTimer?.cancel()
        peakTimer = nil
        icecastPeakLevel = 0
        if listeningServerID != nil {
            onListenStop?()
        }
        listeningServerID = nil
    }

    private func startPeakTimer() {
        peakTimer?.cancel()
        peakTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(67))  // ~15 Hz
                guard let self else { continue }
                if let isAlive = self.icecastIsAlive, !isAlive() {
                    self.stopListening()
                    self.errorMessage = "Stream ended"
                    break
                }
                guard let reader = self.icecastPeakReader else { continue }
                let newPeak = reader()
                let current = self.icecastPeakLevel
                let updated = newPeak > current ? newPeak : current * 0.85
                // Only assign when visually meaningful to avoid @Observable invalidations
                if abs(updated - current) > 0.01 {
                    self.icecastPeakLevel = updated
                }
            }
        }
    }
}

// MARK: - Server Browser View

struct ServerBrowserView: View {
    @ObservedObject var connectionSettings: ConnectionSettings
    let onSelectServer: (NINJAMServerEntry) -> Void
    let onJoinServer: (NINJAMServerEntry) -> Void
    let onDismiss: () -> Void
    var onListenStart: ((URL) -> Void)?
    var onListenStop: (() -> Void)?
    var icecastPeakReader: (() -> Float)?
    var icecastIsAlive: (() -> Bool)?

    @State private var viewModel = ServerBrowserViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Public Servers")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.fetch() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)
                Button("Done") {
                    viewModel.stopAutoRefresh()
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                Image(systemName: "person")
                    .foregroundColor(.secondary)
                TextField("Username", text: $connectionSettings.username)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Body
            if viewModel.isLoading && viewModel.servers.isEmpty {
                Spacer()
                ProgressView("Loading servers...")
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.servers.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { viewModel.fetch() }
                        .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            } else {
                ZStack(alignment: .top) {
                    List(viewModel.sortedServers) { server in
                        ServerRowView(
                            server: server,
                            isListening: viewModel.listeningServerID == server.id,
                            peakLevel: viewModel.listeningServerID == server.id ? viewModel.icecastPeakLevel : 0,
                            onListen: { viewModel.toggleListening(for: server) },
                            onConnect: {
                                viewModel.stopAutoRefresh()
                                onSelectServer(server)
                            },
                            onJoin: {
                                viewModel.stopAutoRefresh()
                                onJoinServer(server)
                            }
                        )
                    }
                    .listStyle(.plain)

                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.onListenStart = onListenStart
            viewModel.onListenStop = onListenStop
            viewModel.icecastPeakReader = icecastPeakReader
            viewModel.icecastIsAlive = icecastIsAlive
            viewModel.startAutoRefresh()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let server: NINJAMServerEntry
    let isListening: Bool
    var peakLevel: Float = 0
    let onListen: () -> Void
    let onConnect: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onConnect) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.callout.bold())
                            .foregroundColor(.primary)

                        HStack(spacing: 8) {
                            Label("\(server.bpm.value)", systemImage: "metronome")
                            Text("\(server.bpi.value) BPI")
                            Label("\(server.userCountValue)/\(server.maxUsers)",
                                  systemImage: "person.2")
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)

                        if !server.users.isEmpty {
                            Text(server.users.map { u in
                                let parts = [u.city, u.co].compactMap { s -> String? in
                                    guard let s, !s.isEmpty else { return nil }
                                    return s.count > 16 ? String(s.prefix(16)) + "…" : s
                                }
                                if !parts.isEmpty { return "\(u.name) (\(parts.joined(separator: ", ")))" }
                                return u.name
                            }.joined(separator: ", "))
                                .font(.footnote)
                                .foregroundColor(.green)
                                .lineLimit(16)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onJoin) {
                    Image(systemName: "person.badge.plus")
                        .font(.title3)
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)

                if server.streamURL != nil {
                    Button(action: onListen) {
                        Image(systemName: isListening ? "stop.circle.fill" : "headphones.circle")
                            .font(.title3)
                            .foregroundColor(isListening ? .red : .accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Level meter bar when listening
            if isListening {
                GeometryReader { geo in
                    let clamped = min(CGFloat(peakLevel), 1.5)
                    let width = max(0, geo.size.width * clamped / 1.5)
                    Rectangle()
                        .fill(peakLevel > 1.0 ? Color.red : Color.green)
                        .frame(width: width)
                }
                .frame(height: 3)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 2)
    }
}
