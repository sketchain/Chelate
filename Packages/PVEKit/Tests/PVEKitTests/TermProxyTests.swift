import Foundation
import Testing
@testable import PVEKit

@Suite("termproxy protocol")
struct TermProxyTests {
    @Test func encoding() {
        #expect(String(decoding: TermProxyCodec.authLine(user: "root@pam", ticket: "PVEVNC:abc"), as: UTF8.self) == "root@pam:PVEVNC:abc\n")
        #expect(String(decoding: TermProxyCodec.data("ls\r"), as: UTF8.self) == "0:3:ls\r")
        // Length is in bytes, not characters (xterm.js: unescape(encodeURIComponent(data)).length).
        #expect(String(decoding: TermProxyCodec.data("é中"), as: UTF8.self) == "0:5:é中")
        #expect(String(decoding: TermProxyCodec.resize(cols: 120, rows: 40), as: UTF8.self) == "1:120:40:")
        #expect(TermProxyCodec.ping() == Data("2".utf8))
    }

    @Test func roundTripThroughServerDecoder() {
        var decoder = TermProxyFrameDecoder()
        var stream = Data()
        stream.append(TermProxyCodec.data([0x1B, 0x5B, 0x41])) // ESC [ A
        stream.append(TermProxyCodec.resize(cols: 80, rows: 24))
        stream.append(TermProxyCodec.ping())
        stream.append(TermProxyCodec.data("0:1:x")) // payload looking like a frame
        stream.append(TermProxyCodec.data("中文"))
        let frames = decoder.feed(stream)
        #expect(frames == [
            .data([0x1B, 0x5B, 0x41]),
            .resize(cols: 80, rows: 24),
            .ping,
            .data(Array("0:1:x".utf8)),
            .data(Array("中文".utf8)),
        ])
    }

    @Test func decoderHandlesSplitFrames() {
        var decoder = TermProxyFrameDecoder()
        let frame = [UInt8](TermProxyCodec.data("hello"))
        #expect(decoder.feed(frame[0..<3]).isEmpty)
        #expect(decoder.feed(frame[3..<6]).isEmpty)
        #expect(decoder.feed(frame[6...]) == [.data(Array("hello".utf8))])
        #expect(decoder.feed(Array("1:10:".utf8)).isEmpty)
        #expect(decoder.feed(Array("5:".utf8)) == [.resize(cols: 10, rows: 5)])
        // Garbage is skipped byte by byte, like termproxy.
        #expect(decoder.feed(Array("xx2".utf8)) == [.ping])
    }

    @Test func handshake() {
        var proto = TermProxyProtocol(user: "root@pam!chelate", ticket: "PVEVNC:t")
        #expect(proto.state == .idle)
        #expect(proto.encodeInput(Array("a".utf8)) == nil)
        // Resize before auth is buffered.
        #expect(proto.encodeResize(cols: 100, rows: 30) == nil)

        let auth = proto.didOpen()
        #expect(auth == Data("root@pam!chelate:PVEVNC:t\n".utf8))
        #expect(proto.state == .authenticating)
        #expect(proto.encodeInput(Array("a".utf8)) == nil)

        // "OK" may arrive split and followed by output.
        #expect(proto.receive(Data("O".utf8)) == .none)
        let event = proto.receive(Data("Klogin: ".utf8))
        #expect(event == .authenticated(output: Data("login: ".utf8), send: [Data("1:100:30:".utf8)]))
        #expect(proto.state == .connected)

        #expect(proto.receive(Data("OKAY".utf8)) == .output(Data("OKAY".utf8)))
        #expect(proto.encodeInput(Array("ls\r".utf8)) == Data("0:3:ls\r".utf8))
        #expect(proto.encodeInput([UInt8]()) == nil)
        // Same size again is suppressed.
        #expect(proto.encodeResize(cols: 100, rows: 30) == nil)
        #expect(proto.encodeResize(cols: 101, rows: 30) == Data("1:101:30:".utf8))
        #expect(proto.encodeResize(cols: 0, rows: 30) == nil)
        #expect(proto.encodePing() == Data("2".utf8))
    }

    @Test func authenticationFailure() {
        var proto = TermProxyProtocol(user: "root@pam", ticket: "bad")
        _ = proto.didOpen()
        #expect(proto.receive(Data("no".utf8)) == .authenticationFailed)
        #expect(proto.state == .failed)
        #expect(proto.encodePing() == nil)
        #expect(proto.receive(Data("OK".utf8)) == .none)
    }

    @Test func reconnectResetsState() {
        var proto = TermProxyProtocol(user: "u", ticket: "t")
        _ = proto.didOpen()
        _ = proto.receive(Data("OK".utf8))
        // A new protocol instance per connection is the expected usage; didOpen on a fresh one
        // starts authenticating again.
        var fresh = TermProxyProtocol(user: "u", ticket: "t2")
        #expect(fresh.didOpen() == Data("u:t2\n".utf8))
        #expect(fresh.state == .authenticating)
    }
}

@Suite("Certificate trust")
struct TrustTests {
    let fp = CertificateFingerprint(string: "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89")!
    let other = CertificateFingerprint(bytes: Array(repeating: 0x11, count: 32))

    func info(_ fingerprint: CertificateFingerprint) -> CertificateInfo {
        CertificateInfo(fingerprint: fingerprint, subjectSummary: "pve1.local", host: "pve1.local")
    }

    @Test func fingerprintParsingAndFormatting() {
        #expect(fp.bytes.count == 32)
        #expect(fp.description.hasPrefix("AB:CD:EF:01"))
        #expect(CertificateFingerprint(string: fp.description.lowercased().replacingOccurrences(of: ":", with: "")) == fp)
        #expect(CertificateFingerprint(string: "AB:CD") == nil)
        #expect(CertificateFingerprint(string: String(repeating: "zz", count: 32)) == nil)
        #expect(CertificateFingerprint(bytes: [0x0A]).description == "0A")
    }

    @Test func fingerprintCodable() throws {
        let data = try JSONEncoder().encode(fp)
        #expect(try JSONDecoder().decode(CertificateFingerprint.self, from: data) == fp)
    }

    @Test func policy() {
        #expect(TrustPolicy.evaluate(systemTrusted: true, presented: info(fp), pinned: nil) == .accept)
        #expect(TrustPolicy.evaluate(systemTrusted: false, presented: info(fp), pinned: nil) == .reject(.untrusted(info(fp))))
        #expect(TrustPolicy.evaluate(systemTrusted: false, presented: info(fp), pinned: fp) == .accept)
        // Pinned + different certificate is always an alarm, even if the system would trust it.
        #expect(TrustPolicy.evaluate(systemTrusted: true, presented: info(other), pinned: fp)
            == .reject(.fingerprintMismatch(expected: fp, presented: info(other))))
    }

    @Test func evaluatorRecordsFailures() {
        let evaluator = TrustEvaluator(pinned: nil)
        #expect(evaluator.evaluate(systemTrusted: false, presented: info(fp)) == false)
        #expect(evaluator.takeLastFailure() == .untrusted(info(fp)))
        #expect(evaluator.takeLastFailure() == nil)
        evaluator.pinned = fp
        #expect(evaluator.evaluate(systemTrusted: false, presented: info(fp)))
        #expect(evaluator.takeLastFailure() == nil)
        #expect(evaluator.evaluate(systemTrusted: true, presented: info(other)) == false)
        #expect(evaluator.takeLastFailure() == .fingerprintMismatch(expected: fp, presented: info(other)))
    }
}
