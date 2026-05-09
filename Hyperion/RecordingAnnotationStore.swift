import Foundation
import SwiftUI

// Persists user ratings (1–5 stars) and free-text notes for specific album
// recordings, keyed by LMS album ID. Stored in
// Documents/recording_annotations.json.

struct RecordingAnnotation: Codable, Identifiable {
    let albumID: Int
    var rating: Int?      // 1–5, nil means unrated
    var notes: String?

    var id: Int { albumID }
}

@MainActor
final class RecordingAnnotationStore: ObservableObject {

    static let shared = RecordingAnnotationStore()
    private init() { load() }

    @Published private(set) var annotations: [Int: RecordingAnnotation] = [:]

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recording_annotations.json")
    }

    func annotation(forAlbumID id: Int) -> RecordingAnnotation? {
        annotations[id]
    }

    func setRating(_ rating: Int?, forAlbumID id: Int) {
        var a = annotations[id] ?? RecordingAnnotation(albumID: id)
        a.rating = rating.map { max(1, min(5, $0)) }
        annotations[id] = a
        save()
    }

    func setNotes(_ notes: String?, forAlbumID id: Int) {
        var a = annotations[id] ?? RecordingAnnotation(albumID: id)
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        a.notes = trimmed?.isEmpty == true ? nil : trimmed
        annotations[id] = a
        save()
    }

    func remove(albumID: Int) {
        annotations.removeValue(forKey: albumID)
        save()
    }

    private func load() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let url = await self.fileURL
            guard let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([RecordingAnnotation].self, from: data)
            else { return }
            let dict = Dictionary(uniqueKeysWithValues: list.map { ($0.albumID, $0) })
            await MainActor.run { self.annotations = dict }
        }
    }

    private func save() {
        let list = Array(annotations.values)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let url = await self.fileURL
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Annotation edit sheet

struct RecordingAnnotationSheet: View {

    let albumID: Int
    let albumTitle: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RecordingAnnotationStore.shared

    @State private var draft: RecordingAnnotation

    init(albumID: Int, albumTitle: String) {
        self.albumID = albumID
        self.albumTitle = albumTitle
        let existing = RecordingAnnotationStore.shared.annotation(forAlbumID: albumID)
        _draft = State(initialValue: existing ?? RecordingAnnotation(albumID: albumID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rating") {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: (draft.rating ?? 0) >= star ? "star.fill" : "star")
                                .font(.system(size: 28))
                                .foregroundColor((draft.rating ?? 0) >= star ? .yellow : .roonTertiary)
                                .onTapGesture {
                                    if draft.rating == star {
                                        draft.rating = nil
                                    } else {
                                        draft.rating = star
                                    }
                                }
                        }
                        Spacer()
                        if draft.rating != nil {
                            Button("Clear") { draft.rating = nil }
                                .font(.roonBody(13))
                                .foregroundColor(.roonAccent)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.roonSurface)

                Section("Notes") {
                    TextField("Your thoughts on this recording…",
                              text: Binding(
                                get: { draft.notes ?? "" },
                                set: { draft.notes = $0.isEmpty ? nil : $0 }
                              ),
                              axis: .vertical)
                        .lineLimit(4...8)
                        .foregroundColor(.roonPrimary)
                        .font(.roonBody(15))
                }
                .listRowBackground(Color.roonSurface)

                if store.annotation(forAlbumID: albumID) != nil {
                    Section {
                        Button("Remove annotation", role: .destructive) {
                            store.remove(albumID: albumID)
                            dismiss()
                        }
                    }
                    .listRowBackground(Color.roonSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle(albumTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setRating(draft.rating, forAlbumID: albumID)
                        store.setNotes(draft.notes, forAlbumID: albumID)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Star display (read-only)

struct StarRatingView: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: rating >= star ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(rating >= star ? .yellow : .roonTertiary.opacity(0.4))
            }
        }
    }
}
