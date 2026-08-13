// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

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
    var icecastIsAlive: (() -> Bool)?

    @State private var chatInput = ""
    @State private var showAbout = false
    @State private var hiddenGrouping: Int?  // Dismiss one meter in dual mode

    var body: some View {
        Group {
            if ninjamClient.isConnected && ninjamClient.bpm > 0 {
                sessionScreen
            } else {
                ConnectionScreen(
                    connectionSettings: connectionSettings,
                    ninjamClient: ninjamClient,
                    onListenStart: onListenStart,
                    onListenStop: onListenStop,
                    icecastPeakReader: icecastPeakReader,
                    icecastIsAlive: icecastIsAlive
                )
            }
        }
        .onChange(of: ninjamClient.isConnected) { _, connected in
            if connected {
                connectionSettings.pushToRecent()
            }
        }
    }

    // MARK: - Session Screen (connected state)

    private var sessionScreen: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top bar: transport info
                topBar

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

                // Chat terminal (primary interaction area)
                chatTerminal

                // Prominent divider between chat and faders
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 3)
                    .shadow(color: Color.primary.opacity(0.08), radius: 1, y: 1)

                // User gain faders (at the bottom)
                faderStrip
            }

            if showAbout {
                AboutView(onDismiss: { showAbout = false })
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 4) {
            // Row 1: Status strip — BPM, metronome, BPI, server, disconnect
            statusRow

            // Row 2+: Beat progress bar(s)
            beatBars
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: ninjamClient.bpi) { _, _ in
            hiddenGrouping = nil  // Reset dismissed meter when BPI changes
        }
    }

    /// Count of active (non-empty) user slots.
    private var activeUserCount: Int {
        ninjamClient.slotUsernames.filter { !$0.isEmpty }.count
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            // Metronome icon as BPM label + toggle
            Button(action: { connectionSettings.metronomeEnabled.toggle() }) {
                Label {
                    Text("\(ninjamClient.bpm)")
                        .font(.callout.monospacedDigit().bold())
                        .foregroundColor(ninjamClient.isBPMMismatch ? .orange : .primary)
                } icon: {
                    Image(systemName: connectionSettings.metronomeEnabled
                          ? "metronome.fill" : "metronome")
                        .foregroundColor(connectionSettings.metronomeEnabled ? .primary : .secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
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

            Text("\(ninjamClient.bpi) BPI")
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()

            // Active user count
            Label("\(activeUserCount)", systemImage: "person.2")
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()

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
        }
    }

    private var beatBars: some View {
        let grouping = MeterGrouping.forBPI(ninjamClient.bpi)

        return VStack(spacing: 3) {
            switch grouping {
            case .single(let bpm):
                beatBarRow(beatsPerMeasure: bpm, showDismiss: false)

            case .dual(let primary, let secondary):
                if hiddenGrouping != primary {
                    beatBarRow(beatsPerMeasure: primary,
                               showDismiss: hiddenGrouping == nil)
                }
                if hiddenGrouping != secondary {
                    beatBarRow(beatsPerMeasure: secondary,
                               showDismiss: hiddenGrouping == nil)
                }
            }
        }
    }

    private func beatBarRow(beatsPerMeasure: Int, showDismiss: Bool) -> some View {
        HStack(spacing: 4) {
            BeatProgressBar(
                currentBeat: ninjamClient.currentBeat,
                bpi: ninjamClient.bpi,
                beatsPerMeasure: beatsPerMeasure
            )
            .frame(height: 14)

            Text("\(ninjamClient.currentBeat + 1)/\(ninjamClient.bpi)")
                .font(.callout.monospacedDigit().bold())
                .foregroundColor(.primary)
                .fixedSize()

            if showDismiss {
                Button(action: { hiddenGrouping = beatsPerMeasure }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Fader Strip

    private var faderStrip: some View {
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
    }

    // MARK: - Chat Terminal

    private var chatTerminal: some View {
        VStack(spacing: 0) {
            // Server topic bar
            if !ninjamClient.serverTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
}
