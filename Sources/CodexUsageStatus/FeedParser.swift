import Foundation

struct ParsedFeed {
    let title: String?
    let link: URL?
    let posts: [FeedPost]
}

final class FeedParser: NSObject, XMLParserDelegate {
    private let feedURL: URL
    private let firstSeenAt: Date
    private var feedTitle: String?
    private var feedLink: URL?
    private var posts: [FeedPost] = []
    private var currentElement = ""
    private var elementStack: [String] = []
    private var text = ""
    private var textBuffers: [String] = []
    private var isItem = false
    private var itemValues: [String: String] = [:]
    private var itemAttributes: [String: String] = [:]

    init(feedURL: URL, firstSeenAt: Date = Date()) {
        self.feedURL = feedURL
        self.firstSeenAt = firstSeenAt
    }

    static func parse(data: Data, feedURL: URL, firstSeenAt: Date = Date()) throws -> ParsedFeed {
        let parser = FeedParser(feedURL: feedURL, firstSeenAt: firstSeenAt)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldResolveExternalEntities = false
        guard xml.parse() else { throw xml.parserError ?? FeedParserError.malformedXML }
        return ParsedFeed(title: parser.feedTitle, link: parser.feedLink, posts: parser.posts)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let local = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        currentElement = local.lowercased()
        elementStack.append(currentElement)
        textBuffers.append("")
        text = ""
        if ["item", "entry"].contains(currentElement) {
            isItem = true; itemValues = [:]; itemAttributes = attributeDict
        }
        if currentElement == "link", isItem, let href = attributeDict["href"] { itemAttributes["link"] = href }
        if currentElement == "link", !isItem, let href = attributeDict["href"], let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { feedLink = url }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string; if !textBuffers.isEmpty { textBuffers[textBuffers.count - 1] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { let value = String(decoding: CDATABlock, as: UTF8.self); text += value; if !textBuffers.isEmpty { textBuffers[textBuffers.count - 1] += value } }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let ended = (qName ?? elementName).split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        let value = (textBuffers.popLast() ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !textBuffers.isEmpty { textBuffers[textBuffers.count - 1] += value }
        if isItem {
            if ["item", "entry"].contains(ended) {
                finishItem(); isItem = false
            } else if !value.isEmpty {
                let key: String
                switch ended {
                case "title": key = "title"
                case "description", "summary", "content", "encoded": key = "content"
                case "pubdate", "published", "issued", "date": key = "published"
                case "updated", "modified": key = "updated"
                case "id", "guid": key = "id"
                case "link": key = "link"
                default: key = ended
                }
                if key == "content" { itemValues[key] = (itemValues[key] ?? "") + value } else { itemValues[key] = value }
            }
        } else if !value.isEmpty {
            switch ended { case "title": feedTitle = value; case "link": feedLink = URL(string: value); default: break }
        }
        text = ""
        _ = elementStack.popLast()
        currentElement = elementStack.last ?? ""
    }

    private func finishItem() {
        let title = itemValues["title"] ?? ""
        let rawContent = itemValues["content"] ?? ""
        let snippet = Self.plainText(rawContent).prefix(500).description
        let published = Self.parseDate(itemValues["published"])
        let updated = Self.parseDate(itemValues["updated"])
        let candidateURL = URL(string: itemValues["link"] ?? itemAttributes["link"] ?? "")
        let canonical = candidateURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let guid = itemValues["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (guid?.isEmpty == false ? guid! : nil) ?? canonical?.absoluteString ?? FeedStableID.fallback(title: title, snippet: snippet, publishedAt: published, updatedAt: updated, feedURL: feedURL)
        posts.append(FeedPost(id: id, canonicalURL: canonical, publishedAt: published, updatedAt: updated, firstSeenAt: firstSeenAt, title: Self.plainText(title), plainTextSnippet: snippet, feedURL: feedURL))
    }

    static func plainText(_ input: String) -> String {
        var result = input.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (key, value) in entities { result = result.replacingOccurrences(of: key, with: value) }
        result = decodeNumericEntities(result, pattern: "&#x([0-9A-Fa-f]+);", radix: 16)
        result = decodeNumericEntities(result, pattern: "&#([0-9]+);", radix: 10)
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func decodeNumericEntities(_ input: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        var output = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: input),
                  let value = Int(input[tokenRange], radix: radix),
                  let scalar = UnicodeScalar(value),
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: String(scalar))
        }
        return output
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd"]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats { formatter.dateFormat = format; if let date = formatter.date(from: value) { return date } }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum FeedParserError: Error, Equatable { case malformedXML }
