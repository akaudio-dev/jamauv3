//
//  ConnectionSettings.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation
import Combine

@MainActor
class ConnectionSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    
    // Keys for UserDefaults
    private enum Keys {
        static let serverName = "jamauv3.connection.serverName"
        static let port = "jamauv3.connection.port"
        static let username = "jamauv3.connection.username"
        static let password = "jamauv3.connection.password"
    }
    
    @Published var serverName: String {
        didSet {
            defaults.set(serverName, forKey: Keys.serverName)
        }
    }
    
    @Published var port: String {
        didSet {
            defaults.set(port, forKey: Keys.port)
        }
    }
    
    @Published var username: String {
        didSet {
            defaults.set(username, forKey: Keys.username)
        }
    }
    
    @Published var password: String {
        didSet {
            defaults.set(password, forKey: Keys.password)
        }
    }
    
    init() {
        // Load saved values or use defaults
        self.serverName = defaults.string(forKey: Keys.serverName) ?? ""
        self.port = defaults.string(forKey: Keys.port) ?? ""
        self.username = defaults.string(forKey: Keys.username) ?? ""
        self.password = defaults.string(forKey: Keys.password) ?? ""
    }
    
    /// Save all settings explicitly (called when Connect is pressed)
    func save() {
        defaults.set(serverName, forKey: Keys.serverName)
        defaults.set(port, forKey: Keys.port)
        defaults.set(username, forKey: Keys.username)
        defaults.set(password, forKey: Keys.password)
        defaults.synchronize()
    }
    
    /// Clear all saved settings
    func clear() {
        defaults.removeObject(forKey: Keys.serverName)
        defaults.removeObject(forKey: Keys.port)
        defaults.removeObject(forKey: Keys.username)
        defaults.removeObject(forKey: Keys.password)
        defaults.synchronize()
        
        serverName = ""
        port = ""
        username = ""
        password = ""
    }
}
