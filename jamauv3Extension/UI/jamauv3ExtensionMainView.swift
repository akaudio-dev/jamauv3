//
//  jamauv3ExtensionMainView.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import SwiftUI

struct jamauv3ExtensionMainView: View {
    var parameterTree: ObservableAUParameterGroup

    @ObservedObject var connectionSettings: ConnectionSettings
    @ObservedObject var ninjamClient: NINJAMClient

    var onListenStart: ((URL) -> Void)?
    var onListenStop: (() -> Void)?
    var icecastPeakReader: (() -> Float)?

    enum ActiveSheet: Identifiable {
        case connection, serverBrowser
        var id: Self { self }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var chatInput = ""

    var body: some View {
        ZStack {
            // Main content
            mainContent

            // Inline overlays (sheets don't work in out-of-process AUv3)
            if activeSheet == .connection {
                connectionOverlay
            } else if activeSheet == .serverBrowser {
                ServerBrowserView(
                    connectionSettings: connectionSettings,
                    onSelectServer: { server in
                        connectionSettings.serverName = server.host
                        connectionSettings.port = server.port
                        activeSheet = .connection
                    },
                    onDismiss: {
                        activeSheet = nil
                    },
                    onListenStart: onListenStart,
                    onListenStop: onListenStop,
                    icecastPeakReader: icecastPeakReader
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(macOS)
                .background(Color(nsColor: .windowBackgroundColor))
                #else
                .background(Color(uiColor: .systemBackground))
                #endif
            }
        }
        .frame(minWidth: 300, minHeight: 400)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top bar: (BPM/BPI)(progress)(beat/bpi) ... (connection)(button)
            HStack(spacing: 6) {
                if ninjamClient.isConnected && ninjamClient.bpm > 0 {
                    Text("\(ninjamClient.bpm)/\(ninjamClient.bpi)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundColor(ninjamClient.isBPMMismatch ? .orange : .primary)
                        .fixedSize()

                    ProgressView(value: ninjamClient.intervalProgress)
                        .tint(.green)

                    Text("\(ninjamClient.currentBeat + 1)/\(ninjamClient.bpi)")
                        .font(.caption.monospacedDigit().bold())
                        .fixedSize()
                }

                Spacer(minLength: 8)

                Circle()
                    .fill(ninjamClient.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                if ninjamClient.isConnected {
                    Text("\(connectionSettings.serverName):\(connectionSettings.port)")
                        .font(.caption)
                        .lineLimit(1)
                    Button(action: { ninjamClient.disconnect() }) {
                        Image(systemName: "network.slash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(ninjamClient.connectionStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button(action: { activeSheet = .serverBrowser }) {
                        Image(systemName: "globe")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Button(action: { activeSheet = .connection }) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // BPM mismatch warning
            if ninjamClient.isBPMMismatch && ninjamClient.hostBPM > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("DAW tempo \(ninjamClient.hostBPM, specifier: "%.0f") BPM ≠ server \(ninjamClient.bpm) BPM")
                }
                .font(.caption2)
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            Divider()

            // Chat terminal (fills available space)
            chatTerminal

            Divider()

            // User gains (fixed height at bottom)
            HStack(spacing: 0) {
                let usersGroup: ObservableAUParameterGroup = parameterTree.users
                ForEach(0..<usersGroup.parameters.count, id: \.self) { index in
                    VerticalGainSlider(
                        param: usersGroup.parameters[index],
                        peakLevel: ninjamClient.userPeaks[index],
                        username: ninjamClient.slotUsernames[index]
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Chat Terminal

    private var chatTerminal: some View {
        VStack(spacing: 0) {
            // Server topic bar
            if ninjamClient.isConnected && !ninjamClient.serverTopic.isEmpty {
                Text(ninjamClient.serverTopic)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
            }

            // Messages scroll area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(ninjamClient.chatMessages) { entry in
                            chatEntryView(entry)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .onChange(of: ninjamClient.chatMessages.count) { _ in
                    if let last = ninjamClient.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input field
            if ninjamClient.isConnected {
                HStack(spacing: 6) {
                    TextField("Message...", text: $chatInput)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit { sendMessage() }

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
            }
        }
    }

    // MARK: - Connection Overlay

    private var connectionOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Text("Connect to Server")
                    .font(.headline)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Server", text: $connectionSettings.serverName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", text: $connectionSettings.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    TextField("Username", text: $connectionSettings.username)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $connectionSettings.password)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Stereo", isOn: $connectionSettings.stereo)
                }

                if let error = ninjamClient.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        activeSheet = nil
                    }
                    .buttonStyle(.bordered)

                    Button(action: handleConnectionToggle) {
                        HStack {
                            Image(systemName: "network")
                            Text("Connect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom)
            }
            .padding(.horizontal)
            .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(uiColor: .systemBackground))
        #endif
    }

    // MARK: - Helpers

    @ViewBuilder
    private func chatEntryView(_ entry: ChatEntry) -> some View {
        switch entry.type {
        case .message(let from, let text):
            HStack(spacing: 0) {
                Text("\(from): ").font(.caption).bold()
                Text(text).font(.caption)
            }
        case .join(let username):
            Text("* \(username) joined").font(.caption).foregroundColor(.green)
        case .part(let username):
            Text("* \(username) left").font(.caption).foregroundColor(.red)
        case .topic(let text):
            Text("Topic: \(text)").font(.caption).italic().foregroundColor(.secondary)
        }
    }

    private func sendMessage() {
        let text = chatInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        ninjamClient.sendChat(text)
        chatInput = ""
    }

    private func handleConnectionToggle() {
        if ninjamClient.isConnected {
            ninjamClient.disconnect()
        } else {
            guard !connectionSettings.serverName.isEmpty else { return }
            guard !connectionSettings.port.isEmpty,
                  let portNumber = UInt16(connectionSettings.port) else { return }
            guard !connectionSettings.username.isEmpty else { return }

            connectionSettings.save()

            ninjamClient.connect(
                host: connectionSettings.serverName,
                port: portNumber,
                username: connectionSettings.username,
                password: connectionSettings.password
            )
            activeSheet = nil
        }
    }
}
