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
    @ObservedObject var connectionManager: ConnectionManager

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
                        .disabled(connectionManager.isConnected)
                    
                    TextField("Port", text: $connectionSettings.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(connectionManager.isConnected)
                }
                
                // Username
                TextField("Username", text: $connectionSettings.username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(connectionManager.isConnected)
                
                // Password
                SecureField("Password", text: $connectionSettings.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(connectionManager.isConnected)
                
                // Connect/Disconnect button
                Button(action: handleConnectionToggle) {
                    HStack {
                        Image(systemName: connectionManager.isConnected ? "network.slash" : "network")
                        Text(connectionManager.isConnected ? "Disconnect" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(connectionManager.isConnected ? .red : .blue)
                
                // Connection status
                HStack {
                    Circle()
                        .fill(connectionManager.isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(connectionManager.connectionStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                
                // Error message if any
                if let error = connectionManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.vertical, 4)
                }
            }
            .padding()
            
            Divider()
            
            // Audio parameters section
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Parameters")
                    .font(.headline)
                
                ParameterSlider(param: parameterTree.global.gain)
            }
            .padding()
            
            Spacer()
        }
        .frame(minWidth: 300, minHeight: 400)
    }
    
    private func handleConnectionToggle() {
        if connectionManager.isConnected {
            // Disconnect
            connectionManager.disconnect()
        } else {
            // Validate inputs
            guard !connectionSettings.serverName.isEmpty else {
                return
            }
            guard !connectionSettings.port.isEmpty else {
                return
            }
            
            // Save settings when connecting
            connectionSettings.save()
            
            // Establish TCP connection
            connectionManager.connect(to: connectionSettings.serverName, port: connectionSettings.port)
        }
    }
}
