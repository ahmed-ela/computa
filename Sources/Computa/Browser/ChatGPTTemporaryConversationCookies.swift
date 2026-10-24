import Foundation

/// Conservative identification only. Callers decide whether to quarantine and
/// must preserve an exact private archive before using any cookie-store writes.
enum ChatGPTTemporaryConversationCookies {
    enum Failure: Error { case bounds, ambiguousIdentity, invalidInput }
    struct Selection: Sendable {
        let keyCount: Int
        let markerCount: Int
        let pairedKeyCount: Int
        let protectedKeyCount: Int
        let targetIndices: [Int]
        let pairedMarkerIndices: [Int]
        let targetNameUTF8Bytes: Int
        let targetValueUTF8Bytes: Int
        var unpairedKeyCount: Int { keyCount - pairedKeyCount }
    }

    static func select(_ cookies: [HTTPCookie], now: Date = Date(), protectedIDs: Set<UUID> = []) throws -> Selection {
        guard cookies.count <= 4_096, protectedIDs.count <= 512,
              now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.bounds }
        var scanned = 0, identities = Set<Data>()
        var keys: [(Int, UUID, String)] = [], markers: [String: Int] = [:]
        func count(_ value: String, limit: Int) throws -> Int {
            let bytes = value.utf8.prefix(limit + 1).count
            guard bytes <= limit, scanned <= 1_048_576 - bytes else { throw Failure.bounds }
            scanned += bytes; return bytes
        }
        for (index, cookie) in cookies.enumerated() {
            let domain = cookie.domain, path = cookie.path, name = cookie.name, value = cookie.value
            _ = try count(domain, limit: 2_048); _ = try count(path, limit: 2_048)
            _ = try count(name, limit: 65_536); _ = try count(value, limit: 65_536)
            guard !domain.contains("\0"), !path.contains("\0"), !name.contains("\0") else { throw Failure.invalidInput }
            let identity = Data((domain + "\0" + path + "\0" + name).utf8)
            guard identities.insert(identity).inserted else { throw Failure.ambiguousIdentity }
            guard domain == "chatgpt.com" || domain == ".chatgpt.com", path == "/" else { continue }
            if let expires = cookie.expiresDate {
                guard expires.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidInput }
                if expires <= now { continue }
            }
            if let id = canonicalID(name: name, prefix: "conv_key_") {
                keys.append((index, id, domain))
            } else if let id = canonicalID(name: name, prefix: "history_off_"), value == "1" {
                markers[domain + "/" + id.uuidString.lowercased()] = index
            }
        }
        var targets: [Int] = [], pairedMarkers: [Int] = []
        var paired = 0, protected = 0, nameBytes = 0, valueBytes = 0
        for (index, id, domain) in keys {
            guard let marker = markers[domain + "/" + id.uuidString.lowercased()] else { continue }
            paired += 1
            if protectedIDs.contains(id) { protected += 1; continue }
            guard targets.count < 512 else { throw Failure.bounds }
            targets.append(index); pairedMarkers.append(marker)
            nameBytes += cookies[index].name.utf8.count; valueBytes += cookies[index].value.utf8.count
        }
        return Selection(keyCount: keys.count, markerCount: markers.count, pairedKeyCount: paired,
            protectedKeyCount: protected, targetIndices: targets, pairedMarkerIndices: pairedMarkers,
            targetNameUTF8Bytes: nameBytes, targetValueUTF8Bytes: valueBytes)
    }

    static func canonicalID(name: String, prefix: String) -> UUID? {
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix.utf8.count == 36, let id = UUID(uuidString: suffix), id.uuidString.lowercased() == suffix else { return nil }
        return id
    }
}
