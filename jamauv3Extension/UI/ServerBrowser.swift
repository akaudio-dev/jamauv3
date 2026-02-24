//
//  ServerBrowser.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 2/24/26.
//

import SwiftUI
import AVFoundation
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
    var userCountValue: Int { userCount?.value ?? users.count }
    var maxUsers: Int { userMax?.value ?? userLimit?.value ?? 0 }

    var streamURL: URL? {
        if let ssl = sslStream, let url = URL(string: ssl) { return url }
        if let s = stream, let url = URL(string: s) { return url }
        return nil
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

    private var refreshTask: Task<Void, Never>?
    private var player: AVPlayer?

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
        log.info("Fetching server list from \(Self.apiURL, privacy: .public)")
        Task {
            defer { isLoading = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.apiURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    log.error("Server list fetch failed: HTTP \(code)")
                    errorMessage = "Server returned an error"
                    return
                }
                servers = try JSONDecoder().decode(NINJAMServerListResponse.self, from: data).servers
                log.info("Loaded \(self.servers.count) servers")
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
        log.info("Starting stream: \(url.absoluteString, privacy: .public)")
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Icy-MetaData": "0"]
        ])
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player?.play()
        listeningServerID = server.id
    }

    func stopListening() {
        player?.pause()
        player = nil
        listeningServerID = nil
    }
}

// MARK: - Server Browser View

struct ServerBrowserView: View {
    @ObservedObject var connectionSettings: ConnectionSettings
    let onSelectServer: (NINJAMServerEntry) -> Void
    let onDismiss: () -> Void

    @State private var viewModel = ServerBrowserViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Public Servers")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    viewModel.stopAutoRefresh()
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

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
                        .font(.caption)
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
                            onListen: { viewModel.toggleListening(for: server) },
                            onConnect: {
                                viewModel.stopAutoRefresh()
                                onSelectServer(server)
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
        .frame(minWidth: 360, minHeight: 400)
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let server: NINJAMServerEntry
    let isListening: Bool
    let onListen: () -> Void
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onConnect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.caption.bold())
                        .foregroundColor(.primary)

                    HStack(spacing: 8) {
                        Label("\(server.bpm.value)", systemImage: "metronome")
                        Text("\(server.bpi.value) BPI")
                        Label("\(server.userCountValue)/\(server.maxUsers)",
                              systemImage: "person.2")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    if !server.users.isEmpty {
                        Text(server.users.map(\.name).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundColor(.green)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if server.streamURL != nil {
                Button(action: onListen) {
                    Image(systemName: isListening ? "stop.circle.fill" : "headphones.circle")
                        .font(.title3)
                        .foregroundColor(isListening ? .red : .accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
