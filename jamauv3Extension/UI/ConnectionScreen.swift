// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  ConnectionScreen.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 3/10/26.
//

import SwiftUI

/// Unified connection screen: recent servers dropdown, connect form, and public server browser.
struct ConnectionScreen: View {
    @ObservedObject var connectionSettings: ConnectionSettings
    @ObservedObject var ninjamClient: NINJAMClient

    var onListenStart: ((URL) -> Void)?
    var onListenStop: (() -> Void)?
    var icecastPeakReader: (() -> Float)?
    var icecastIsAlive: (() -> Bool)?

    @State private var browserViewModel = ServerBrowserViewModel()
    @State private var showAbout = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Title bar
                HStack {
                    Text("Jam AUv3")
                        .font(.headline)
                    Spacer()
                    Button(action: { showAbout = true }) {
                        Image(systemName: "info.circle")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(spacing: 16) {
                        connectSection
                        publicServersSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            if showAbout {
                AboutView(onDismiss: { showAbout = false })
            }
        }
        .onAppear {
            browserViewModel.onListenStart = onListenStart
            browserViewModel.onListenStop = onListenStop
            browserViewModel.icecastPeakReader = icecastPeakReader
            browserViewModel.icecastIsAlive = icecastIsAlive
            browserViewModel.startAutoRefresh()
        }
        .onDisappear {
            browserViewModel.stopAutoRefresh()
        }
    }

    // MARK: - Connect Section

    private var connectSection: some View {
        VStack(spacing: 10) {
            // Recent servers dropdown (above the form)
            if !connectionSettings.recentServers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.secondary)
                        .font(.callout)
                    Menu {
                        ForEach(connectionSettings.recentServers) { server in
                            Button(action: {
                                connectionSettings.applyRecent(server)
                            }) {
                                Label(server.displayLabel, systemImage: "server.rack")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            for s in connectionSettings.recentServers {
                                connectionSettings.removeRecent(s)
                            }
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                    } label: {
                        HStack {
                            Text("Recent Servers")
                                .font(.callout)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }

            // Connect form
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect to Server")
                        .font(.subheadline.bold())

                    HStack(spacing: 8) {
                        TextField("Server", text: $connectionSettings.serverName)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS) || os(visionOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("Port", text: $connectionSettings.port)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS) || os(visionOS)
                            .keyboardType(.numberPad)
                            #endif
                            .frame(maxWidth: 80)
                    }

                    HStack(spacing: 8) {
                        TextField("Username", text: $connectionSettings.username)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        SecureField("Password", text: $connectionSettings.password)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Toggle("Stereo", isOn: $connectionSettings.stereo)
                            .fixedSize()

                        Spacer()

                        Button(action: handleConnect) {
                            HStack(spacing: 4) {
                                Image(systemName: "network")
                                Text("Connect")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionSettings.serverName.isEmpty
                                  || connectionSettings.port.isEmpty
                                  || connectionSettings.username.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }

            // Error message
            if let error = ninjamClient.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            // Connecting status
            if !ninjamClient.isConnected && ninjamClient.connectionStatus != "Disconnected" && ninjamClient.connectionStatus != "" {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(ninjamClient.connectionStatus)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Public Servers Section

    private var publicServersSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Public Servers")
                    .font(.subheadline.bold())
                Spacer()
                if browserViewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: { browserViewModel.fetch() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(browserViewModel.isLoading)
            }

            if let error = browserViewModel.errorMessage, browserViewModel.servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Retry") { browserViewModel.fetch() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if browserViewModel.servers.isEmpty && browserViewModel.isLoading {
                ProgressView("Loading servers...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(browserViewModel.sortedServers) { server in
                        ServerRowView(
                            server: server,
                            isListening: browserViewModel.listeningServerID == server.id,
                            peakLevel: browserViewModel.listeningServerID == server.id ? browserViewModel.icecastPeakLevel : 0,
                            onListen: { browserViewModel.toggleListening(for: server) },
                            onConnect: {
                                // Fill form from public server
                                connectionSettings.serverName = server.host
                                connectionSettings.port = server.port
                                connectionSettings.password = ""
                            },
                            onJoin: {
                                browserViewModel.stopAutoRefresh()
                                handleJoinServer(server)
                            }
                        )
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        if server.id != browserViewModel.sortedServers.last?.id {
                            Divider()
                        }
                    }
                }
                #if os(macOS)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                #else
                .background(Color(uiColor: .secondarySystemBackground))
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Actions

    private func handleConnect() {
        guard !connectionSettings.serverName.isEmpty,
              !connectionSettings.port.isEmpty,
              let portNumber = UInt16(connectionSettings.port),
              !connectionSettings.username.isEmpty else { return }

        connectionSettings.save()
        browserViewModel.stopListening()

        ninjamClient.connect(
            host: connectionSettings.serverName,
            port: portNumber,
            username: connectionSettings.username,
            password: connectionSettings.password
        )
    }

    private func handleJoinServer(_ server: NINJAMServerEntry) {
        guard !ninjamClient.isConnected else { return }
        let username = connectionSettings.username.isEmpty ? "jamauv3-user" : connectionSettings.username

        browserViewModel.stopListening()

        ninjamClient.connect(host: server.host, port: server.portNumber,
                             username: username, password: "")
    }
}
