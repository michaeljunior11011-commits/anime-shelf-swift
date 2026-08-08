import Foundation

enum AppConfiguration {
    static let animeBaseURL = URL(string: "https://anslayer.com/anime/public/")!
    static let clientID = "ios-app2"
    static let clientSecret = "a7024f16e0c896475c2f82c66a8f6d9d85380e63"
    static let clientVersion = "1.7"
    static let videoResolverSecret = "tryud-dy6534-Osah7j2-rukVDdfuZK"
    static let commentsURL = URL(string: "https://animecloudapp.com/aanimeApp65/")!
}

extension URLRequest {
    mutating func addAnimeClientHeaders() {
        setValue(AppConfiguration.clientID, forHTTPHeaderField: "Client-Id")
        setValue(AppConfiguration.clientSecret, forHTTPHeaderField: "Client-Secret")
        setValue(AppConfiguration.clientVersion, forHTTPHeaderField: "ios-client-version")
        setValue("application/json", forHTTPHeaderField: "Accept")
    }
}

extension Dictionary where Key == String, Value == String {
    var formEncoded: Data? {
        var components = URLComponents()
        components.queryItems = map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

