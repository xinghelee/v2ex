import Foundation

/// Makes bare URLs inside already-plain text tappable.
///
/// Only needed on the translated side of a Hacker News comment: translation
/// returns a plain string, so whatever `<a>` markup the original carried is
/// gone by then. Untranslated comments keep their real anchors and should go
/// through the HTML parser instead — detection is the fallback, not the rule.
enum HNLinkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var output = AttributedString(text)
        guard let detector, text.contains("://") else { return output }

        let full = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: full) {
            // http(s) only. The detector also volunteers phone numbers, mail
            // addresses and bare hostnames, and turning a stray "3.14" or an
            // author's name into a link is worse than leaving it flat.
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: output),
                  let upper = AttributedString.Index(range.upperBound, within: output)
            else { continue }
            output[lower..<upper].link = url
        }
        return output
    }
}
