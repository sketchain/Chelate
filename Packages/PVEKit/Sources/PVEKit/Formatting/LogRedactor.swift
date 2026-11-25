import Foundation

/// Removes credentials from log text before it leaves the device (Settings › 导出日志):
/// API token secrets, tickets (`PVE:…`, `PVEVNC:…`, `PVETFA:…`, `PVEAuthCookie`), CSRF tokens
/// and passwords. Applied to the whole export, in addition to the app never logging these on
/// purpose.
public enum LogRedactor {
    public static let placeholder = "<redacted>"

    private static let rules: [(NSRegularExpression, String)] = {
        func rule(_ pattern: String, _ template: String) -> (NSRegularExpression, String) {
            // The patterns are constants; a typo is a programming error caught by the tests.
            (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), template)
        }
        let p = placeholder
        return [
            // Authorization: PVEAPIToken=user@realm!tokenid=SECRET  (keep the token id)
            rule(#"(PVEAPIToken[= ]\s*[^\s=!]+![^\s=]+)[=:]\s*[^\s,;"']+"#, "$1=\(p)"),
            // Cookie: PVEAuthCookie=TICKET
            rule(#"(PVEAuthCookie\s*[=:]\s*)[^\s;,"']+"#, "$1\(p)"),
            // Tickets anywhere: PVE:user@realm:HEX::SIG, PVEVNC:…, PVETFA:…, PVEQEMU:…
            rule(#"\bPVE(?:VNC|TFA|QEMU|TERM)?:[^\s"',;&]{6,}"#, p),
            // CSRFPreventionToken: HEX:SIG
            rule(#"(CSRFPreventionToken["']?\s*[=:]\s*["']?)[^\s"',;&]+"#, "$1\(p)"),
            // "key": "value" (JSON, value may contain spaces)
            rule(#"("(?:password|passwd|secret|token[-_]?secret|ticket|vncticket|tfa-challenge|CSRFPreventionToken)"\s*:\s*")(?:[^"\\]|\\.)*""#, "$1\(p)\""),
            // key=value / key: value for secret-ish keys
            rule(#"((?:password|passwd|secret|token[-_]?secret|ticket|vncticket|tfa-challenge|otp|recovery)["']?\s*[=:]\s*["']?)[^\s"',;&]+"#, "$1\(p)"),
            // Bare UUID token secrets after an "!tokenid=" fragment are covered above; also catch
            // "user@realm!tokenid=UUID" without the PVEAPIToken prefix.
            rule(#"(\S+@\S+![A-Za-z0-9._-]+=)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, "$1\(p)"),
        ]
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }
}
