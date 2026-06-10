import Foundation
import SwiftUI

// MARK: - Data models

struct DownloadedTrack: Identifiable, Codable, Hashable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let coverid: String?
    let localFilename: String
    let downloadedAt: Date
}

struct DownloadProgress {
    enum State { case pending, downloading, failed }
    var state: State
    var progress: Double
}

// MARK: - Manager

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let backgroundSessionID = "com.sarpedon.hyperion.downloads"

    @Published private(set) var downloadedTracks: [DownloadedTrack] = []
    @Published private(set) var downloads: [Int: DownloadProgress]  = [:]
    /// Titles of in-progress downloads, captured when the download starts so the
    /// UI can label rows without consulting the (lazily-loaded) song library.
    @Published private(set) var pendingTitles: [Int: String]        = [:]

    /// Set by AppDelegate when the system wakes the app for a background session event.
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    private var taskToTrackID: [Int: Int]              = [:]
    private var trackToTask: [Int: URLSessionDownloadTask] = [:]
    /// In-memory cache of full Track metadata for in-progress downloads. Used
    /// by handleFinishedDownload to build a DownloadedTrack record without
    /// touching LibraryViewModel.songs (which is lazily paginated).
    private var pendingTracks: [Int: Track]            = [:]

    private let manifestFilename = "hyperion_downloads.json"

    static var downloadsDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary       = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        loadManifest()
        // Reconnect tasks that survived an app relaunch so progress is tracked.
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in downloadTasks {
                    if let trackID = task.taskDescription.flatMap(Int.init) {
                        self.taskToTrackID[task.taskIdentifier] = trackID
                        self.trackToTask[trackID]               = task
                        self.downloads[trackID] = DownloadProgress(state: .downloading, progress: 0)
                    }
                }
            }
        }
    }

    // MARK: - Public API

    func download(_ track: Track) {
        guard downloads[track.id] == nil, !isDownloaded(trackID: track.id) else { return }
        // Use the first non-file remote candidate so we don't try to "download" a local file.
        guard let remoteURL = LyrionAPI.shared.streamURLs(for: track)
                .first(where: { $0.scheme != "file" }) else { return }

        var request = URLRequest(url: remoteURL)
        for (k, v) in LyrionAPI.shared.httpHeaders() { request.setValue(v, forHTTPHeaderField: k) }

        let task = session.downloadTask(with: request)
        task.taskDescription = String(track.id)
        taskToTrackID[task.taskIdentifier] = track.id
        trackToTask[track.id]              = task
        // Cache the full track so handleFinishedDownload can build a
        // DownloadedTrack without reading library.songs (which is lazily
        // paginated and may be empty when the download finishes — especially
        // for background completions after relaunch).
        pendingTracks[track.id] = track
        pendingTitles[track.id] = track.title
        downloads[track.id] = DownloadProgress(state: .pending, progress: 0)
        task.resume()
    }

    func cancelDownload(trackID: Int) {
        trackToTask[trackID]?.cancel()
        trackToTask[trackID] = nil
        downloads[trackID]   = nil
        pendingTracks[trackID] = nil
        pendingTitles[trackID] = nil
    }

    func cancelDownload(for track: Track) { cancelDownload(trackID: track.id) }

    /// Download every track in an album that isn't already downloaded or in-progress.
    func downloadAlbum(_ tracks: [Track]) {
        for track in tracks {
            guard downloads[track.id] == nil, !isDownloaded(trackID: track.id) else { continue }
            download(track)
        }
    }

    /// Download every track in a local playlist.
    func downloadPlaylist(_ playlist: LocalPlaylist) {
        downloadAlbum(playlist.tracks)
    }

    /// True when every track in the list is downloaded.
    func isAlbumDownloaded(_ tracks: [Track]) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { isDownloaded(trackID: $0.id) }
    }

    /// Count of already-downloaded tracks out of the supplied list.
    func downloadedCount(in tracks: [Track]) -> Int {
        tracks.filter { isDownloaded(trackID: $0.id) }.count
    }

    func removeDownload(_ downloaded: DownloadedTrack) {
        let fileURL = Self.downloadsDir.appendingPathComponent(downloaded.localFilename)
        try? FileManager.default.removeItem(at: fileURL)
        downloadedTracks.removeAll { $0.id == downloaded.id }
        saveManifest()
    }

    func localURL(for track: Track) -> URL? {
        guard let entry = downloadedTracks.first(where: { $0.id == track.id }) else { return nil }
        let url = Self.downloadsDir.appendingPathComponent(entry.localFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Build a playable `Track` from a downloaded manifest entry. Preferred
    /// over filtering `LibraryViewModel.songs` (which may be empty cold) so
    /// downloaded items always remain playable, including offline.
    func playableTrack(for downloaded: DownloadedTrack) -> Track {
        // Use any richer in-memory metadata when available (genres, work tags,
        // etc.), but fall back to the manifest fields so playback never blocks.
        if let live = LibraryViewModel.shared.songs.first(where: { $0.id == downloaded.id }) {
            return live
        }
        return Track(
            id:          downloaded.id,
            title:       downloaded.title,
            album:       downloaded.album.isEmpty ? nil : downloaded.album,
            albumID:     nil,
            albumartist: downloaded.artist.isEmpty ? nil : downloaded.artist,
            composer:    nil,
            trackartist: downloaded.artist.isEmpty ? nil : downloaded.artist,
            work:        nil,
            duration:    downloaded.duration,
            tracknum:    nil,
            discnum:     nil,
            year:        nil,
            coverid:     downloaded.coverid,
            url:         nil,
            genres:      nil,
            isClassical: nil
        )
    }

    func isDownloaded(trackID: Int) -> Bool {
        guard let entry = downloadedTracks.first(where: { $0.id == trackID }) else { return false }
        let url = Self.downloadsDir.appendingPathComponent(entry.localFilename)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Private

    private func handleFinishedDownload(task: URLSessionDownloadTask, tempURL: URL) async {
        guard let trackID = taskToTrackID[task.taskIdentifier] else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        taskToTrackID[task.taskIdentifier] = nil
        trackToTask[trackID]               = nil
        downloads[trackID]                 = nil

        let ext = task.originalRequest?.url?.pathExtension
        let filename = "\(trackID).\(ext.flatMap { $0.isEmpty ? nil : $0 } ?? "audio")"
        let destURL  = Self.downloadsDir.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Resolve metadata for the manifest record. Order of preference:
        //   1. Track captured at download start (always available for
        //      foreground downloads in this session).
        //   2. In-memory library (paginated subset).
        //   3. Server fetch via getSong(id:) — required for background
        //      completions that fire after a relaunch, when neither (1)
        //      nor (2) is populated.
        // The audio file is already on disk; metadata fallback never blocks
        // playback, only the manifest entry / row label.
        let cached  = pendingTracks[trackID]
        let library = LibraryViewModel.shared.songs.first { $0.id == trackID }
        var resolved: Track? = cached ?? library
        if resolved == nil {
            resolved = try? await LyrionAPI.shared.getSong(id: trackID)
        }

        let title:  String
        let artist: String
        let album:  String
        let duration: Double?
        let coverid:  String?
        if let track = resolved {
            title    = track.title
            artist   = track.trackartist ?? track.albumartist ?? ""
            album    = track.album ?? ""
            duration = track.duration
            coverid  = track.coverid
        } else {
            // Last-resort placeholder so a successful file download is not
            // dropped from the manifest just because metadata is unknown.
            title    = "Track \(trackID)"
            artist   = ""
            album    = ""
            duration = nil
            coverid  = nil
        }

        let record = DownloadedTrack(
            id:            trackID,
            title:         title,
            artist:        artist,
            album:         album,
            duration:      duration,
            coverid:       coverid,
            localFilename: filename,
            downloadedAt:  Date()
        )
        downloadedTracks.removeAll { $0.id == trackID }
        downloadedTracks.insert(record, at: 0)
        saveManifest()
        pendingTracks[trackID] = nil
        pendingTitles[trackID] = nil
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: AppFiles.url(for: manifestFilename)) else { return }
        downloadedTracks = (try? JSONDecoder().decode([DownloadedTrack].self, from: data)) ?? []
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(downloadedTracks) {
            try? data.write(to: AppFiles.url(for: manifestFilename), options: .atomic)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy the file synchronously before URLSession deletes it after this method returns.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: location, to: tempCopy)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleFinishedDownload(task: downloadTask, tempURL: tempCopy)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            guard let self,
                  let trackID = self.taskToTrackID[downloadTask.taskIdentifier] else { return }
            self.downloads[trackID] = DownloadProgress(state: .downloading, progress: progress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let trackID = self.taskToTrackID[task.taskIdentifier] else { return }
            self.downloads[trackID] = DownloadProgress(state: .failed, progress: 0)
            self.taskToTrackID[task.taskIdentifier] = nil
            self.trackToTask[trackID]               = nil
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
