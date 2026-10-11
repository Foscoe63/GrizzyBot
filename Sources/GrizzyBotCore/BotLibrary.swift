import Foundation

/// One thing a bot handed you: an artifact it made, a file it wrote, or a link it shared.
public struct SharedItem: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case artifact, file, link

        public var label: String {
            switch self {
            case .artifact: return "Artifacts"
            case .file: return "Files"
            case .link: return "Links"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var date: Date
    /// Artifact id for `.artifact`, a path for `.file`, a URL string for `.link`.
    public var target: String

    public init(id: String, kind: Kind, title: String, detail: String, date: Date, target: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
        self.target = target
    }
}

/// Grok Bot's per-bot Library tab: everything the bot shared, newest first, grouped by day.
public enum BotLibrary {
    public static func items(in thread: ThreadData) -> [SharedItem] {
        var out: [SharedItem] = []
        var seen = Set<String>()
        func add(_ item: SharedItem) {
            guard seen.insert(item.kind.rawValue + item.target).inserted else { return }
            out.append(item)
        }
        for message in thread.messages where message.role == .bot {
            for (index, block) in message.blocks.enumerated() {
                switch block {
                case .artifact(let id, let title, let kind, let summary, let deleted):
                    guard !deleted else { continue }
                    add(SharedItem(id: "\(message.id)#\(index)", kind: .artifact, title: title, detail: "\(kind.rawValue) · \(summary)", date: message.createdAt, target: id))
                case .card(let lines):
                    for line in lines where line.k == "wrote" || line.k == "saved" || line.k == "exported" {
                        let path = line.v.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else { continue }
                        add(SharedItem(id: "\(message.id)#\(index)#\(path)", kind: .file, title: (path as NSString).lastPathComponent, detail: path, date: message.createdAt, target: path))
                    }
                case .text(let text):
                    for url in links(in: text) {
                        add(SharedItem(id: "\(message.id)#\(url)", kind: .link, title: URL(string: url)?.host ?? url, detail: url, date: message.createdAt, target: url))
                    }
                default:
                    continue
                }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url.absoluteString
        }
    }

    public enum Bucket: String, Sendable, CaseIterable {
        case today = "Today", thisWeek = "This week", older = "Older"
    }

    public static func grouped(_ items: [SharedItem], now: Date = .now, calendar: Calendar = .current) -> [(bucket: Bucket, items: [SharedItem])] {
        var buckets: [Bucket: [SharedItem]] = [:]
        for item in items {
            let bucket: Bucket
            if calendar.isDate(item.date, inSameDayAs: now) {
                bucket = .today
            } else if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(item.date) {
                bucket = .thisWeek
            } else {
                bucket = .older
            }
            buckets[bucket, default: []].append(item)
        }
        return Bucket.allCases.compactMap { bucket in
            guard let list = buckets[bucket], !list.isEmpty else { return nil }
            return (bucket, list)
        }
    }
}
