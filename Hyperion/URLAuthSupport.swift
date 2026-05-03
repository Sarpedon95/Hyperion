import Foundation

enum HyperionURLAuth {

    static func authorizationHeader(from rawURL: String) -> String? {
        guard let url = URL(string: rawURL) else { return nil }
        return authorizationHeader(from: url)
    }

    static func authorizationHeader(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let user = components.user,
              !user.isEmpty else {
            return nil
        }
        let password = components.password ?? ""
        let token = "\(user):\(password)"
        guard let data = token.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    static func addAuthorizationHeader(to request: inout URLRequest, baseURL: String) {
        guard let header = authorizationHeader(from: baseURL) else { return }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }
}
