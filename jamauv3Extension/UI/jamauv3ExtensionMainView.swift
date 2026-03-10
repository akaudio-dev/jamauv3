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
        case connection, serverBrowser, about
        var id: Self { self }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var chatInput = ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Main content
                mainContent

                // Inline overlays (sheets don't work in out-of-process AUv3)
                if activeSheet == .connection {
                    connectionOverlay(availableWidth: geo.size.width)
                } else if activeSheet == .about {
                    AboutView(onDismiss: { activeSheet = nil })
                } else if activeSheet == .serverBrowser {
                    ServerBrowserView(
                        connectionSettings: connectionSettings,
                        onSelectServer: { server in
                            connectionSettings.serverName = server.host
                            connectionSettings.port = server.port
                            connectionSettings.password = ""  // clear — public servers don't need passwords
                            activeSheet = .connection
                        },
                        onJoinServer: { server in
                            handleJoinServer(server)
                        },
                        onDismiss: {
                            activeSheet = nil
                        },
                        onListenStart: onListenStart,
                        onListenStop: onListenStop,
                        icecastPeakReader: icecastPeakReader
                    )
                    #if os(macOS)
                    .background(Color(nsColor: .windowBackgroundColor))
                    #else
                    .background(Color(uiColor: .systemBackground))
                    #endif
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: ninjamClient.isConnected) { _, connected in
                if connected && activeSheet == .connection {
                    activeSheet = nil
                }
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top bar
            if ninjamClient.isConnected && ninjamClient.bpm > 0 {
                // Connected: transport row + server row
                HStack(spacing: 6) {
                    Text("\(ninjamClient.bpm)/\(ninjamClient.bpi)")
                        .font(.callout.monospacedDigit().bold())
                        .foregroundColor(ninjamClient.isBPMMismatch ? .orange : .primary)
                        .fixedSize()

                    ProgressView(value: ninjamClient.intervalProgress)
                        .tint(.green)

                    Text("\(ninjamClient.currentBeat + 1)/\(ninjamClient.bpi)")
                        .font(.callout.monospacedDigit().bold())
                        .fixedSize()

                    Button(action: { connectionSettings.metronomeEnabled.toggle() }) {
                        Image(systemName: connectionSettings.metronomeEnabled
                              ? "metronome.fill" : "metronome")
                            .font(.callout)
                            .foregroundColor(connectionSettings.metronomeEnabled ? .primary : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .contextMenu {
                        Button {
                            connectionSettings.metronomeBeat1Only = false
                        } label: {
                            Label("All Beats", systemImage: connectionSettings.metronomeBeat1Only ? "" : "checkmark")
                        }
                        Button {
                            connectionSettings.metronomeBeat1Only = true
                        } label: {
                            Label("Beat 1 Only", systemImage: connectionSettings.metronomeBeat1Only ? "checkmark" : "")
                        }
                    }

                    Spacer(minLength: 4)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)

                    Text(connectionSettings.serverName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Button(action: { ninjamClient.disconnect() }) {
                        Image(systemName: "network.slash")
                            .font(.callout)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)

                    Button(action: { activeSheet = .about }) {
                        Image(systemName: "info.circle")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                // Disconnected: single row
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)

                    Text(ninjamClient.connectionStatus)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button(action: { activeSheet = .serverBrowser }) {
                        Image(systemName: "globe")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    Button(action: { activeSheet = .connection }) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    Button(action: { activeSheet = .about }) {
                        Image(systemName: "info.circle")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            // BPM mismatch warning
            if ninjamClient.isBPMMismatch && ninjamClient.hostBPM > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("DAW tempo \(ninjamClient.hostBPM, specifier: "%.0f") BPM ≠ server \(ninjamClient.bpm) BPM")
                }
                .font(.footnote)
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            Divider()

            // User gain faders strip (compact, only when connected)
            if ninjamClient.isConnected {
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
                .frame(height: 180)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)

                Divider()
            }

            // Chat terminal
            chatTerminal
        }
    }

    // MARK: - Chat Terminal

    private var chatTerminal: some View {
        VStack(spacing: 0) {
            // Server topic bar
            if ninjamClient.isConnected && !ninjamClient.serverTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(ninjamClient.serverTopic.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.footnote)
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
                .onChange(of: ninjamClient.chatMessages.count) { _, _ in
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
                        .font(.callout)
                        .onSubmit { sendMessage() }

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.callout)
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

    private func connectionOverlay(availableWidth: CGFloat) -> some View {
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

                    TextField("Username", text: $connectionSettings.username)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    SecureField("Password", text: $connectionSettings.password)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Stereo", isOn: $connectionSettings.stereo)
                }

                if let error = ninjamClient.lastError {
                    Text(error)
                        .font(.callout)
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
            .frame(maxWidth: min(360, availableWidth - 32))
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
                Text("\(from): ").font(.callout).bold()
                Text(text).font(.callout)
            }
        case .join(let username):
            Text("* \(username) joined").font(.callout).foregroundColor(.green)
        case .part(let username):
            Text("* \(username) left").font(.callout).foregroundColor(.red)
        case .topic(let text):
            Text("Topic: \(text)").font(.callout).italic().foregroundColor(.secondary)
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
            // Overlay stays open until connection succeeds (dismissed by onChange below)
        }
    }

    private func handleJoinServer(_ server: NINJAMServerEntry) {
        guard !ninjamClient.isConnected else { return }
        let username = connectionSettings.username.isEmpty ? "jamauv3-user" : connectionSettings.username

        onListenStop?()

        // Connect with empty password (triggers "anonymous:" prefix for public servers)
        // Don't modify connectionSettings — private server credentials stay intact for auto-reconnect
        ninjamClient.connect(host: server.host, port: server.portNumber,
                             username: username, password: "")
        activeSheet = nil
    }
}
