// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  ConnectionSettings.swift
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

import Foundation
import Combine

/// A recently-used server connection, stored for quick reconnect.
/// The password is NOT part of the persisted JSON — it lives in the Keychain
/// keyed by `id`. The optional field only exists to decode (and migrate)
/// entries written by older versions that embedded plaintext passwords.
struct RecentServer: Codable, Identifiable, Equatable {
    var id: String { "\(host):\(port)" }
    let host: String
    let port: String
    let username: String
    var password: String?

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
        static let password = "jamauv3.connection.password"  // legacy — migrated to Keychain
        static let stereo = "jamauv3.connection.stereo"
        static let recentServers = "jamauv3.connection.recentServers"
    }

    /// Keychain account for the current connection form's password.
    private static let currentPasswordAccount = "current"

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

    /// Persisted to the Keychain in save() (on Connect), never to UserDefaults.
    @Published var password: String

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
        self.stereo = defaults.bool(forKey: Keys.stereo)

        // Migrate a legacy plaintext password out of UserDefaults.
        if let legacy = defaults.string(forKey: Keys.password) {
            KeychainStore.setPassword(legacy, account: Self.currentPasswordAccount)
            defaults.removeObject(forKey: Keys.password)
        }
        self.password = KeychainStore.password(account: Self.currentPasswordAccount) ?? ""

        self.recentServers = Self.migrateAndLoadRecentServers(from: defaults)
    }

    /// Load recents; move any legacy embedded plaintext passwords to the
    /// Keychain and rewrite the JSON without them.
    private static func migrateAndLoadRecentServers(from defaults: UserDefaults) -> [RecentServer] {
        guard let data = defaults.data(forKey: Keys.recentServers) else { return [] }
        var list = (try? JSONDecoder().decode([RecentServer].self, from: data)) ?? []
        var migrated = false
        for index in list.indices where !(list[index].password ?? "").isEmpty {
            KeychainStore.setPassword(list[index].password!, account: list[index].id)
            list[index].password = nil
            migrated = true
        }
        if migrated, let cleaned = try? JSONEncoder().encode(list) {
            defaults.set(cleaned, forKey: Keys.recentServers)
        }
        return list
    }

    /// Push the current connection to the top of the recent servers list.
    /// The password goes to the Keychain, keyed by host:port.
    func pushToRecent() {
        guard !serverName.isEmpty, !username.isEmpty else { return }
        let entry = RecentServer(host: serverName, port: port, username: username, password: nil)
        KeychainStore.setPassword(password, account: entry.id)
        // Remove existing duplicate, then prepend
        var list = recentServers.filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        if list.count > Self.maxRecentServers { list = Array(list.prefix(Self.maxRecentServers)) }
        recentServers = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.recentServers)
        }
    }

    /// Remove a recent server entry (and its Keychain password).
    func removeRecent(_ server: RecentServer) {
        KeychainStore.deletePassword(account: server.id)
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
        password = KeychainStore.password(account: server.id) ?? server.password ?? ""
    }

    /// Save all settings explicitly (called when Connect is pressed)
    func save() {
        defaults.set(serverName, forKey: Keys.serverName)
        defaults.set(port, forKey: Keys.port)
        defaults.set(username, forKey: Keys.username)
        defaults.set(stereo, forKey: Keys.stereo)
        KeychainStore.setPassword(password, account: Self.currentPasswordAccount)
    }

    /// Clear all saved settings
    func clear() {
        defaults.removeObject(forKey: Keys.serverName)
        defaults.removeObject(forKey: Keys.port)
        defaults.removeObject(forKey: Keys.username)
        defaults.removeObject(forKey: Keys.password)
        defaults.removeObject(forKey: Keys.stereo)
        KeychainStore.deletePassword(account: Self.currentPasswordAccount)

        serverName = ""
        port = ""
        username = ""
        password = ""
        stereo = false
        metronomeEnabled = false
        metronomeBeat1Only = false
    }
}
