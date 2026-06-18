import Foundation

struct StreamSource: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case video
        case audio
    }

    var id: UUID
    var name: String
    var url: String
    var kind: Kind
    var userAgent: String
    var isBuiltIn: Bool

    static let defaults: [StreamSource] = [
        StreamSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            name: "TSN-4K",
            url: "http://89.187.179.148:826/anto.j/c9yJDcXyPe/119333",
            kind: .video,
            userAgent: "",
            isBuiltIn: true
        ),
        StreamSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001080")!,
            name: "TSN-1080P",
            url: "http://wickediptv.xyz/Randall123/Randall321/53805",
            kind: .video,
            userAgent: "",
            isBuiltIn: true
        ),
        StreamSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            name: "咪咕解说",
            url: "http://101.35.240.114:88/live.php?id=CCTV5",
            kind: .audio,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            isBuiltIn: true
        ),
        StreamSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            name: "央视解说",
            url: "http://114.96.132.221:8888/rtp/238.1.78.171:7240",
            kind: .audio,
            userAgent: "",
            isBuiltIn: true
        )
    ]
}

struct SourceStore {
    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AptvMerge", isDirectory: true)
    }

    private var sourcesURL: URL {
        supportDirectory.appendingPathComponent("sources.json")
    }

    func loadSources() -> [StreamSource] {
        guard let data = try? Data(contentsOf: sourcesURL),
              let decoded = try? JSONDecoder().decode([StreamSource].self, from: data)
        else {
            saveSources(StreamSource.defaults)
            return StreamSource.defaults
        }

        return decoded
    }

    func saveSources(_ sources: [StreamSource]) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: sourcesURL, options: .atomic)
        }
    }

    func loadSelectedID(key: String) -> UUID? {
        guard let value = UserDefaults.standard.string(forKey: key) else { return nil }
        return UUID(uuidString: value)
    }

    func saveSelectedID(_ id: UUID?, key: String) {
        UserDefaults.standard.set(id?.uuidString, forKey: key)
    }
}
