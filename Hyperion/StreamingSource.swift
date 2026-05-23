// StreamingSource.swift
// Hyperion — Streaming Integration
// Shared protocol and models for Deezer + Qobuz

import Foundation

// MARK: - Source Type

enum StreamSourceType: String, Codable {
    case local
    case deezer
    case qobuz
}

// MARK: - Models

struct StreamTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumID: String
    let duration: TimeInterval
    let artworkURL: URL?
    let source: StreamSourceType
    let isrc: String?

    // Classical fields
    let composer: String?
    let work: String?
    let conductor: String?

    // Quality (Qobuz only)
    var qualityLabel: String?

    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(source) }
    static func == (l: StreamTrack, r: StreamTrack) -> Bool { l.id == r.id && l.source == r.source }
}

struct StreamAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let year: Int?
    let source: StreamSourceType
    let trackCount: Int?

    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(source) }
    static func == (l: StreamAlbum, r: StreamAlbum) -> Bool { l.id == r.id && l.source == r.source }
}

// MARK: - Protocol

protocol StreamingSource {
    var name: String { get }
    var sourceType: StreamSourceType { get }
    var isAvailable: Bool { get async }

    func search(query: String) async -> [StreamTrack]
    func searchAlbums(query: String) async -> [StreamAlbum]
    func getStreamURL(for track: StreamTrack) async throws -> URL
    func getAlbum(id: String) async throws -> StreamAlbum
    func getAlbumTracks(albumID: String) async -> [StreamTrack]
    func getUserFavorites() async -> [StreamTrack]
    func getUserFavoriteAlbums() async -> [StreamAlbum]
}

// MARK: - Errors

enum StreamingError: LocalizedError {
    case noSourceAvailable
    case authenticationFailed
    case trackNotFound
    case networkError(Error)
    case adminRequired

    var errorDescription: String? {
        switch self {
        case .noSourceAvailable:    return "Track not available on any streaming source"
        case .authenticationFailed: return "Streaming authentication failed"
        case .trackNotFound:        return "Track not found"
        case .networkError(let e):  return "Network error: \(e.localizedDescription)"
        case .adminRequired:        return "Streaming requires admin access"
        }
    }
}
