// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  ServerBrowserTests.swift
//  jamauv3Tests
//
//  Tests for NINJAM server browser API JSON decoding.
//

import Testing
import Foundation

// MARK: - Mirror of ServerBrowser data model for testing
// These mirror the Decodable types in jamauv3Extension/UI/ServerBrowser.swift
// to verify the JSON contract with the ninbot.com API.

private struct ServerListResponse: Decodable {
    let servers: [ServerEntry]
}

private struct ServerEntry: Decodable {
    let host: String
    let port: String
    let bpi: Int
    let bpm: Int
    let name: String
    let pri: Int?
    let sslStream: String?
    let stream: String?
    let userCount: FlexInt?
    let userLimit: FlexInt?
    let userMax: FlexInt?
    let users: [ServerUser]

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

private struct ServerUser: Decodable {
    let name: String
    let co: String?
    let country: String?
    let city: String?
}

private struct FlexInt: Decodable {
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

// MARK: - Tests

@Suite("Server Browser")
struct ServerBrowserTests {

    // Realistic JSON matching the live ninbot.com API response format.
    static let sampleJSON = """
    {
      "servers": [
        {
          "_id": "abc123",
          "host": "ninbot.com",
          "port": "2049",
          "bpi": 16,
          "bpm": 120,
          "name": "ninbot.com:2049",
          "pri": 10,
          "ssl_stream": "https://ninbot.com/radio/2049",
          "stream": "http://ninbot.com:15000/jambot1",
          "user_count": "3",
          "user_limit": "8",
          "user_max": 8,
          "users": [
            {
              "name": "qulf",
              "ip": "86.11.28.x",
              "lat": "53",
              "lon": "-1.3",
              "country": "United Kingdom",
              "co": "GB",
              "city": "Heanor",
              "region": "England",
              "flag": "gb.png",
              "avatar": "files/pictures/picture-3053.jpg",
              "uid": 3053
            },
            {
              "name": "drummer42",
              "co": "US",
              "country": "United States"
            }
          ]
        },
        {
          "host": "ninjamer.com",
          "port": "2050",
          "bpi": 32,
          "bpm": 110,
          "name": "ninjamer.com:2050",
          "ssl_stream": null,
          "stream": null,
          "user_count": 0,
          "user_max": "NaN",
          "users": []
        }
      ]
    }
    """.data(using: .utf8)!

    @Test("Decodes server list from API JSON")
    func decodesServerList() throws {
        let response = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON)
        #expect(response.servers.count == 2)
    }

    @Test("Parses server fields correctly")
    func parsesServerFields() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[0]
        #expect(server.host == "ninbot.com")
        #expect(server.port == "2049")
        #expect(server.portNumber == 2049)
        #expect(server.bpm == 120)
        #expect(server.bpi == 16)
        #expect(server.name == "ninbot.com:2049")
        #expect(server.pri == 10)
    }

    @Test("Parses user list")
    func parsesUsers() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[0]
        #expect(server.users.count == 2)
        #expect(server.users[0].name == "qulf")
        #expect(server.users[0].co == "GB")
        #expect(server.users[0].country == "United Kingdom")
        #expect(server.users[0].city == "Heanor")
        #expect(server.users[1].name == "drummer42")
    }

    @Test("FlexInt handles string user_count")
    func flexIntString() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[0]
        #expect(server.userCountValue == 3)
        #expect(server.maxUsers == 8)
    }

    @Test("FlexInt handles integer user_count")
    func flexIntInteger() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[1]
        #expect(server.userCountValue == 0)
    }

    @Test("FlexInt handles NaN as zero")
    func flexIntNaN() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[1]
        // user_max: "NaN" should decode to 0
        #expect(server.userMax?.value == 0)
    }

    @Test("Prefers ssl_stream over stream for streamURL")
    func prefersSSLStream() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[0]
        #expect(server.streamURL == URL(string: "https://ninbot.com/radio/2049"))
    }

    @Test("Handles null stream URLs")
    func handlesNullStreams() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[1]
        #expect(server.streamURL == nil)
    }

    @Test("Handles missing optional fields gracefully")
    func handlesMissingFields() throws {
        let server = try JSONDecoder().decode(ServerListResponse.self, from: Self.sampleJSON).servers[1]
        #expect(server.pri == nil)
        #expect(server.userLimit == nil)
    }

    @Test("userCountValue falls back to users.count when user_count missing")
    func userCountFallback() throws {
        let json = """
        {"servers":[{"host":"test.com","port":"2049","bpi":16,"bpm":120,"name":"test.com:2049","users":[{"name":"a"},{"name":"b"}]}]}
        """.data(using: .utf8)!
        let server = try JSONDecoder().decode(ServerListResponse.self, from: json).servers[0]
        #expect(server.userCountValue == 2)
    }

    @Test("Live API returns valid JSON", .enabled(if: ProcessInfo.processInfo.environment["NINJAM_TEST_HOST"] != nil))
    func liveAPIFetch() async throws {
        let url = URL(string: "https://ninbot.com/app/servers.php")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)

        let result = try JSONDecoder().decode(ServerListResponse.self, from: data)
        #expect(!result.servers.isEmpty)

        // Every server should have required fields
        for server in result.servers {
            #expect(!server.host.isEmpty)
            #expect(!server.port.isEmpty)
            #expect(server.portNumber > 0)
            #expect(server.bpm > 0)
            #expect(server.bpi > 0)
        }
    }
}
