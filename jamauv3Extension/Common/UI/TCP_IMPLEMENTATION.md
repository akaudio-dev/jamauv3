# TCP Long-Lived Connection Implementation Guide

## Overview
Your Audio Unit now has a **long-lived TCP connection** capability with proper threading, error handling, and keepalive support.

## Files Modified

### Core Files:
1. **UDPNetworkManager.swift** → Now **TCPNetworkManager** - Core TCP networking class
2. **UDPNetworkManager+Examples.swift** → Now **TCPNetworkManager+Examples** - Usage examples
3. **AudioUnitViewController.swift** - Uses `tcpManager` instead of `udpManager`
4. **jamauv3ExtensionMainView.swift** - UI updated for TCP

## TCP vs UDP: What Changed

### ✅ TCP Advantages (Long-Lived Connection)
- **Reliable**: Guaranteed delivery and order
- **Connection-oriented**: Actual handshake with server
- **Stream-based**: Perfect for continuous data flow
- **Error detection**: Built-in checksums and retransmission
- **Flow control**: Prevents overwhelming the receiver

### 🔧 TCP-Specific Features Implemented
- **TCP Keepalive**: Maintains connection during idle periods
  - Keepalive starts after 60 seconds of idle time
  - Probes sent every 30 seconds
  - Closes after 5 failed probes
- **Connection timeout**: 30 seconds to establish connection
- **Proper connection state**: `.ready` means actual TCP handshake complete
- **Stream receiving**: Continuous data reception from server
- **Graceful handling**: Detects when server closes connection

## Required: Entitlements Setup

⚠️ **IMPORTANT**: You must add network entitlements!

### For macOS:
1. Select your **extension target** in Xcode
2. Go to "Signing & Capabilities"
3. Click "+ Capability" and add "App Sandbox"
4. Under "Network", enable:
   - ☑️ **Outgoing Connections (Client)** ← Required!

### For iOS:
Network access is generally allowed, but add to Info.plist:
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This audio unit connects to a server to stream audio data.</string>
```

## Usage

### Basic Connection (Already Implemented in UI)
```swift
// User fills in server/port and clicks "Connect"
tcpManager.connect(to: "192.168.1.100", port: "8000")

// Connection establishes with proper TCP handshake
// Status indicator turns green when .ready

// To disconnect
tcpManager.disconnect()
```

### Sending Data
```swift
// Send a text message
tcpManager.send("Hello, Server!") { error in
    if let error = error {
        print("Send failed: \(error)")
    }
}

// Send binary data
let audioData = Data(/* your audio data */)
tcpManager.send(audioData)

// Send with newline (common text protocol pattern)
tcpManager.sendLine("COMMAND param1 param2")
```

### Receiving Data
The TCP manager automatically starts receiving when connected. To customize:

```swift
tcpManager.startReceiving { data in
    // Handle received data
    if let message = String(data: data, encoding: .utf8) {
        print("Received: \(message)")
    }
}
```

## TCP Connection Lifecycle

1. **Setup** → Creating connection object
2. **Preparing** → Resolving DNS, finding route
3. **Waiting** → Network unavailable, will retry
4. **Ready** ✅ → TCP handshake complete, can send/receive
5. **Failed** ❌ → Connection failed (server down, wrong address, etc.)
6. **Cancelled** → User disconnected

## Important Notes

### ⚠️ Audio Thread Safety
**NEVER** call network functions from the audio render callback!

```swift
// ❌ WRONG - Will cause audio dropouts!
func internalRenderBlock(...) {
    tcpManager.send(data) // DON'T DO THIS!
}

// ✅ CORRECT - Use a separate queue
private let networkQueue = DispatchQueue(label: "audio.network", qos: .utility)

func processAudioSafely(buffer: AVAudioPCMBuffer) {
    networkQueue.async {
        let data = convertBufferToData(buffer)
        self.tcpManager.send(data)
    }
}
```

### 🔄 Long-Lived Connection Features

The TCP connection is designed to stay open:
- **Keepalive enabled**: Prevents idle disconnection
- **Automatic reconnection**: You can add retry logic if needed
- **Server detection**: Knows when server closes the connection
- **Stream mode**: Continuous bidirectional communication

### 📊 Connection States in UI

- **Gray dot** + "Not connected" → No connection
- **Gray dot** + "Connecting..." → TCP handshake in progress
- **Green dot** + "Connected" → Fully established, can send/receive
- **Gray dot** + "Failed" + error → Connection problem
- **Gray dot** + "Waiting to connect..." → Network issue, will retry

### 🔒 Security Notes

- **No encryption by default**: Data sent in plain text
- **Add TLS**: Change `NWParameters(tls: nil, ...)` to use TLS options
- **Passwords**: Still stored in UserDefaults (consider Keychain)
- **Authentication**: Username/password ready for your protocol

## Testing

### Simple TCP Server (Python)
```python
import socket

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(('0.0.0.0', 8000))
server.listen(1)
print("Listening on port 8000...")

while True:
    client, addr = server.accept()
    print(f"Connection from {addr}")
    while True:
        data = client.recv(1024)
        if not data:
            break
        print(f"Received: {data}")
        client.send(b"ACK\n")
```

### Using netcat
```bash
# Listen on port 8000
nc -l 8000

# Type messages, press Enter to send back to the AU
```

## Common Patterns

### Line-Based Protocol
```swift
// Send commands with newline delimiter
tcpManager.sendLine("LOGIN username password")
tcpManager.sendLine("START_STREAM")
```

### Binary Protocol with Length Prefix
```swift
// Send 4-byte length, then data
var length = UInt32(audioData.count).bigEndian
var packet = Data(bytes: &length, count: 4)
packet.append(audioData)
tcpManager.send(packet)
```

### JSON-Based Protocol
```swift
struct Command: Codable {
    let action: String
    let params: [String: String]
}

let cmd = Command(action: "start", params: ["format": "pcm"])
tcpManager.sendJSON(cmd)
```

## Next Steps

You now have a production-ready long-lived TCP connection! You can:

1. **Implement your protocol**: Text-based, binary, JSON, etc.
2. **Stream audio continuously**: Send buffers as they're processed
3. **Receive commands**: Server can send control messages
4. **Add authentication**: Use the username/password fields
5. **Add TLS/SSL**: Encrypt the connection
6. **Implement reconnection**: Auto-reconnect on failure

## Connection Stability

The TCP connection will:
- ✅ Stay open indefinitely with keepalive
- ✅ Survive short network interruptions
- ✅ Detect server disconnect automatically
- ✅ Handle large data streams efficiently
- ✅ Maintain order and reliability

Perfect for audio streaming, remote control, and real-time communication! 🎵🔗
