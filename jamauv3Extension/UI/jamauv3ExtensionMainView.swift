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

    var body: some View {
        VStack(spacing: 16) {
            // Connection settings section
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection Settings")
                    .font(.headline)
                
                // Server and Port
                HStack(spacing: 8) {
                    TextField("Server", text: $connectionSettings.serverName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(ninjamClient.isConnected)
                    
                    TextField("Port", text: $connectionSettings.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(ninjamClient.isConnected)
                }
                
                // Username
                TextField("Username", text: $connectionSettings.username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(ninjamClient.isConnected)
                
                // Password
                SecureField("Password", text: $connectionSettings.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(ninjamClient.isConnected)
                
                // Connect/Disconnect button
                Button(action: handleConnectionToggle) {
                    HStack {
                        Image(systemName: ninjamClient.isConnected ? "network.slash" : "network")
                        Text(ninjamClient.isConnected ? "Disconnect" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ninjamClient.isConnected ? .red : .blue)
                
                // Connection status
                HStack {
                    Circle()
                        .fill(ninjamClient.isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(ninjamClient.connectionStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                
                // Error message if any
                if let error = ninjamClient.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.vertical, 4)
                }
            }
            .padding()
            
            // Interval timing section (visible when connected)
            if ninjamClient.isConnected && ninjamClient.bpm > 0 {
                Divider()

                VStack(spacing: 8) {
                    // BPM / BPI display
                    HStack {
                        Text("\(ninjamClient.bpm) BPM, \(ninjamClient.bpi) BPI")
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        Text("\(ninjamClient.currentBeat + 1)/\(ninjamClient.bpi)")
                            .font(.subheadline.monospacedDigit().bold())
                    }

                    // Interval progress bar
                    ProgressView(value: ninjamClient.intervalProgress)
                        .tint(.green)
                }
                .padding(.horizontal)
            }

            Divider()

            // User gains mixer section
            VStack(alignment: .leading, spacing: 8) {
                Text("User Gains")
                    .font(.headline)

                HStack(spacing: 8) {
                    let usersGroup: ObservableAUParameterGroup = parameterTree.users
                    ForEach(0..<usersGroup.parameters.count, id: \.self) { index in
                        VerticalGainSlider(param: usersGroup.parameters[index])
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            
            Spacer()
        }
        .frame(minWidth: 300, minHeight: 400)
    }
    
    private func handleConnectionToggle() {
        if ninjamClient.isConnected {
            // Disconnect
            ninjamClient.disconnect()
        } else {
            // Validate inputs
            guard !connectionSettings.serverName.isEmpty else {
                return
            }
            guard !connectionSettings.port.isEmpty,
                  let portNumber = UInt16(connectionSettings.port) else {
                return
            }
            guard !connectionSettings.username.isEmpty else {
                return
            }

            // Save settings when connecting
            connectionSettings.save()

            // Connect to NINJAM server
            ninjamClient.connect(
                host: connectionSettings.serverName,
                port: portNumber,
                username: connectionSettings.username,
                password: connectionSettings.password
            )
        }
    }
}
