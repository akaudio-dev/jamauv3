//
//  ConnectionSettings.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation
import Combine

/// A recently-used server connection, stored for quick reconnect.
struct RecentServer: Codable, Identifiable, Equatable {
    var id: String { "\(host):\(port)" }
    let host: String
    let port: String
    let username: String
    let password: String

    /// One-line display label for the dropdown.
    var displayLabel: String {
        let addr = port == "2049" ? host : "\(host):\(port)"
        return "\(addr) (\(username))"
    }
}

@MainActor
class ConnectionSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // Keys for UserDefaults
    private enum Keys {
        static let serverName = "jamauv3.connection.serverName"
        static let port = "jamauv3.connection.port"
        static let username = "jamauv3.connection.username"
        static let password = "jamauv3.connection.password"
        static let stereo = "jamauv3.connection.stereo"
        static let recentServers = "jamauv3.connection.recentServers"
    }

    static let maxRecentServers = 5
    
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

    @Published var stereo: Bool {
        didSet {
            defaults.set(stereo, forKey: Keys.stereo)
        }
    }

    @Published var metronomeEnabled: Bool = false
    @Published var metronomeBeat1Only: Bool = false

    @Published var recentServers: [RecentServer] = []

    init() {
        // Load saved values or use defaults
        self.serverName = defaults.string(forKey: Keys.serverName) ?? ""
        self.port = defaults.string(forKey: Keys.port) ?? ""
        self.username = defaults.string(forKey: Keys.username) ?? ""
        self.password = defaults.string(forKey: Keys.password) ?? ""
        self.stereo = defaults.bool(forKey: Keys.stereo)
        self.recentServers = Self.loadRecentServers(from: defaults)
    }

    private static func loadRecentServers(from defaults: UserDefaults) -> [RecentServer] {
        guard let data = defaults.data(forKey: Keys.recentServers) else { return [] }
        return (try? JSONDecoder().decode([RecentServer].self, from: data)) ?? []
    }

    /// Push the current connection to the top of the recent servers list.
    func pushToRecent() {
        guard !serverName.isEmpty, !username.isEmpty else { return }
        let entry = RecentServer(host: serverName, port: port, username: username, password: password)
        // Remove existing duplicate, then prepend
        var list = recentServers.filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        if list.count > Self.maxRecentServers { list = Array(list.prefix(Self.maxRecentServers)) }
        recentServers = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.recentServers)
        }
    }

    /// Remove a recent server entry.
    func removeRecent(_ server: RecentServer) {
        recentServers.removeAll { $0.id == server.id }
        if let data = try? JSONEncoder().encode(recentServers) {
            defaults.set(data, forKey: Keys.recentServers)
        }
    }

    /// Fill the connection fields from a recent server entry.
    func applyRecent(_ server: RecentServer) {
        serverName = server.host
        port = server.port
        username = server.username
        password = server.password
    }
    
    /// Save all settings explicitly (called when Connect is pressed)
    func save() {
        defaults.set(serverName, forKey: Keys.serverName)
        defaults.set(port, forKey: Keys.port)
        defaults.set(username, forKey: Keys.username)
        defaults.set(password, forKey: Keys.password)
        defaults.set(stereo, forKey: Keys.stereo)
        defaults.synchronize()
    }

    /// Clear all saved settings
    func clear() {
        defaults.removeObject(forKey: Keys.serverName)
        defaults.removeObject(forKey: Keys.port)
        defaults.removeObject(forKey: Keys.username)
        defaults.removeObject(forKey: Keys.password)
        defaults.removeObject(forKey: Keys.stereo)
        defaults.synchronize()

        serverName = ""
        port = ""
        username = ""
        password = ""
        stereo = false
        metronomeEnabled = false
        metronomeBeat1Only = false
    }
}
