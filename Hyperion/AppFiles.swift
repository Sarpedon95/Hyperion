import Foundation

enum AppFiles {
    static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func url(for name: String) -> URL {
        appSupportDir.appendingPathComponent(name)
    }
}
