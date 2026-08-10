import Foundation

extension KeyedDecodingContainer {
    func flexibleStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            if value.rounded() == value { return String(Int(value)) }
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func flexibleURLIfPresent(forKey key: Key) -> URL? {
        guard let raw = flexibleStringIfPresent(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: "\\", with: "%5C")
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    func flexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        return flexibleStringIfPresent(forKey: key).flatMap(Int.init)
    }
}

enum FlexibleJSON {
    static func decodedData(from data: Data) -> Data {
        var value = data
        if value.starts(with: [0xEF, 0xBB, 0xBF]) { value.removeFirst(3) }
        guard let object = try? JSONSerialization.jsonObject(with: value),
              let nested = object as? String,
              let nestedData = nested.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: nestedData)) != nil else { return value }
        return nestedData
    }

    static func strings(in object: Any) -> [String] {
        if let value = object as? String { return [value] }
        if let values = object as? [Any] { return values.flatMap(strings) }
        if let values = object as? [String: Any] { return values.values.flatMap(strings) }
        return []
    }
}

struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lossyArray<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> [Value] {
        ((try? decodeIfPresent([LossyDecodable<Value>].self, forKey: key)) ?? [])
            .compactMap(\.value)
    }
}
