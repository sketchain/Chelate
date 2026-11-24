import Foundation

/// Wire format of PVE's `termproxy` (pve-xtermjs `termproxy/src/main.rs` and `xterm.js/src/main.js`).
///
/// Client → server, after the WebSocket is open:
/// - Auth line, exactly once, first: `<authid>:<vncticket>\n`
/// - Data:   `0:<byte length>:<bytes>`
/// - Resize: `1:<cols>:<rows>:`
/// - Ping:   `2` (sent every 30 s by xterm.js; ignored by termproxy, keeps proxies alive)
///
/// Server → client: the literal `OK` once authentication succeeded, then raw terminal output.
public enum TermProxyCodec {
    public static let okPrefix: [UInt8] = [0x4F, 0x4B] // "OK"
    public static let pingInterval: TimeInterval = 30

    public static func authLine(user: String, ticket: String) -> Data {
        Data("\(user):\(ticket)\n".utf8)
    }

    public static func data(_ bytes: some Collection<UInt8>) -> Data {
        var frame = Data("0:\(bytes.count):".utf8)
        frame.append(contentsOf: bytes)
        return frame
    }

    public static func data(_ string: String) -> Data {
        data(Array(string.utf8))
    }

    public static func resize(cols: Int, rows: Int) -> Data {
        Data("1:\(cols):\(rows):".utf8)
    }

    public static func ping() -> Data {
        Data("2".utf8)
    }
}

/// Decoder for client → server frames, mirroring `process_queue` in termproxy. Used to verify the
/// encoder in tests (and handy for debugging captured traffic).
public struct TermProxyFrameDecoder: Sendable {
    public enum Frame: Sendable, Hashable {
        case data([UInt8])
        case resize(cols: Int, rows: Int)
        case ping
    }

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Frame] {
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        while let frame = next() {
            frames.append(frame)
        }
        return frames
    }

    private mutating func next() -> Frame? {
        while let first = buffer.first {
            switch first {
            case UInt8(ascii: "0"):
                guard buffer.count >= 2, let (length, headerSize) = number(from: 2),
                      buffer.count >= headerSize + length else { return nil }
                let payload = Array(buffer[headerSize..<(headerSize + length)])
                buffer.removeFirst(headerSize + length)
                return .data(payload)
            case UInt8(ascii: "1"):
                guard buffer.count >= 2, let (cols, afterCols) = number(from: 2),
                      let (rows, afterRows) = number(from: afterCols) else { return nil }
                buffer.removeFirst(afterRows)
                return .resize(cols: cols, rows: rows)
            case UInt8(ascii: "2"):
                buffer.removeFirst(1)
                return .ping
            default:
                // termproxy skips unknown bytes one at a time.
                buffer.removeFirst(1)
            }
        }
        return nil
    }

    /// Parses `<digits>:` starting at `offset`; returns the value and the index after the colon.
    private func number(from offset: Int) -> (Int, Int)? {
        guard offset <= buffer.count else { return nil }
        guard let colon = buffer[offset...].firstIndex(of: UInt8(ascii: ":")) else { return nil }
        guard let text = String(bytes: buffer[offset..<colon], encoding: .ascii), let value = Int(text) else {
            return nil
        }
        return (value, colon + 1)
    }
}

/// Client-side termproxy session state machine, independent of the WebSocket implementation.
public struct TermProxyProtocol: Sendable {
    public enum State: Sendable, Hashable {
        case idle
        case authenticating
        case connected
        case failed
    }

    public enum Event: Sendable, Hashable {
        /// Bytes to feed into the terminal.
        case output(Data)
        /// Authentication succeeded; contains output that followed `OK` (may be empty) and frames
        /// to send now (pending resize).
        case authenticated(output: Data, send: [Data])
        /// The server did not answer `OK`.
        case authenticationFailed
        case none
    }

    public private(set) var state: State = .idle
    private let user: String
    private let ticket: String
    private var pendingSize: (cols: Int, rows: Int)?
    private var lastSentSize: (cols: Int, rows: Int)?
    private var authBuffer = Data()

    public init(user: String, ticket: String) {
        self.user = user
        self.ticket = ticket
    }

    /// Call when the WebSocket opened; returns the auth line to send.
    public mutating func didOpen() -> Data {
        state = .authenticating
        authBuffer.removeAll()
        return TermProxyCodec.authLine(user: user, ticket: ticket)
    }

    public mutating func receive(_ data: Data) -> Event {
        switch state {
        case .connected:
            return .output(data)
        case .authenticating:
            authBuffer.append(data)
            if authBuffer.count < 2 {
                return .none
            }
            let bytes = [UInt8](authBuffer)
            guard bytes[0] == TermProxyCodec.okPrefix[0], bytes[1] == TermProxyCodec.okPrefix[1] else {
                state = .failed
                return .authenticationFailed
            }
            state = .connected
            let rest = Data(bytes.dropFirst(2))
            authBuffer.removeAll()
            var send: [Data] = []
            if let size = pendingSize {
                send.append(TermProxyCodec.resize(cols: size.cols, rows: size.rows))
                lastSentSize = size
                pendingSize = nil
            }
            return .authenticated(output: rest, send: send)
        case .idle, .failed:
            return .none
        }
    }

    /// Keyboard input; nil until authenticated (input before `OK` would corrupt the auth line).
    public func encodeInput(_ bytes: some Collection<UInt8>) -> Data? {
        guard state == .connected, !bytes.isEmpty else { return nil }
        return TermProxyCodec.data(bytes)
    }

    /// Terminal size change; buffered until authenticated, deduplicated afterwards.
    public mutating func encodeResize(cols: Int, rows: Int) -> Data? {
        guard cols > 0, rows > 0 else { return nil }
        guard state == .connected else {
            pendingSize = (cols, rows)
            return nil
        }
        if let last = lastSentSize, last.cols == cols, last.rows == rows {
            return nil
        }
        lastSentSize = (cols, rows)
        return TermProxyCodec.resize(cols: cols, rows: rows)
    }

    public func encodePing() -> Data? {
        state == .connected ? TermProxyCodec.ping() : nil
    }
}
