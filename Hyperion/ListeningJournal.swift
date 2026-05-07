import SwiftUI
import Foundation

// MARK: - Model

enum JournalMood: String, Codable, CaseIterable, Identifiable {
    case focused    = "Focused"
    case relaxed    = "Relaxed"
    case energized  = "Energized"
    case melancholic = "Melancholic"

    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .focused:     return "🎯"
        case .relaxed:     return "🌿"
        case .energized:   return "⚡️"
        case .melancholic: return "🌧"
        }
    }
}

struct JournalEntry: Codable, Identifiable {
    var id: UUID = UUID()
    let trackID: Int?
    let albumID: Int?
    let trackTitle: String
    let albumTitle: String
    let artist: String
    let coverid: String?
    var note: String
    var rating: Int          // 1–5; 0 = unrated
    var mood: JournalMood?
    let createdAt: Date
}

// MARK: - Store

@MainActor
final class JournalStore: ObservableObject {
    static let shared = JournalStore()

    @Published private(set) var entries: [JournalEntry] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    private init() { load() }

    func addEntry(_ entry: JournalEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func update(_ entry: JournalEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        save()
    }

    func delete(_ entry: JournalEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    // MARK: Persistence

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hyperion_journal.json")
    }

    private func save() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomicWrite)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode([JournalEntry].self, from: data) else { return }
        entries = decoded
    }
}

// MARK: - Post-track note card

/// Shown as a sheet from NowPlayingView after a track finishes.
struct JournalEntrySheet: View {
    let track: Track
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var note: String = ""
    @State private var rating: Int = 0
    @State private var mood: JournalMood? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Track identity header
                    HStack(spacing: 14) {
                        ArtworkView(coverid: track.coverid, size: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.roonBody(15, weight: .semibold))
                                .foregroundColor(.roonPrimary)
                                .lineLimit(2)
                            if let artist = track.trackartist ?? track.albumartist {
                                Text(artist)
                                    .font(.roonBody(13))
                                    .foregroundColor(.roonSecondary)
                                    .lineLimit(1)
                            }
                            if let album = track.album {
                                Text(album)
                                    .font(.roonBody(12))
                                    .foregroundColor(.roonTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                    Divider().background(Color.roonBorder).padding(.horizontal, 20)

                    // Star rating
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rating")
                            .font(.roonBody(13, weight: .semibold))
                            .foregroundColor(.roonSecondary)
                        HStack(spacing: 10) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    Haptics.light()
                                    rating = (rating == star) ? 0 : star
                                } label: {
                                    Image(systemName: star <= rating ? "star.fill" : "star")
                                        .font(.system(size: 28))
                                        .foregroundColor(star <= rating ? .roonAccent : .roonTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Mood
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mood")
                            .font(.roonBody(13, weight: .semibold))
                            .foregroundColor(.roonSecondary)
                        HStack(spacing: 8) {
                            ForEach(JournalMood.allCases) { m in
                                Button {
                                    Haptics.light()
                                    mood = (mood == m) ? nil : m
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(m.emoji)
                                        Text(m.rawValue)
                                            .font(.roonBody(12, weight: .medium))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(mood == m ? Color.roonAccent : Color.roonSurface)
                                    .foregroundColor(mood == m ? .white : .roonPrimary)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().strokeBorder(mood == m ? Color.clear : Color.roonBorder, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Note text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Note")
                            .font(.roonBody(13, weight: .semibold))
                            .foregroundColor(.roonSecondary)
                        TextField("Write a thought about this track…", text: $note, axis: .vertical)
                            .font(.roonBody(14))
                            .foregroundColor(.roonPrimary)
                            .lineLimit(4...8)
                            .padding(12)
                            .background(Color.roonSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.roonBorder, lineWidth: 1))
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 32)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Add Journal Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        onDismiss?()
                        dismiss()
                    }
                    .foregroundColor(.roonSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEntry()
                        onDismiss?()
                        dismiss()
                    }
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonAccent)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == 0 && mood == nil)
                }
            }
        }
    }

    private func saveEntry() {
        let entry = JournalEntry(
            trackID:    track.id,
            albumID:    track.albumID,
            trackTitle: track.title,
            albumTitle: track.album ?? "",
            artist:     track.trackartist ?? track.albumartist ?? "",
            coverid:    track.coverid,
            note:       note.trimmingCharacters(in: .whitespacesAndNewlines),
            rating:     rating,
            mood:       mood,
            createdAt:  Date()
        )
        JournalStore.shared.addEntry(entry)
        Haptics.medium()
    }
}

// MARK: - Journal browse screen

struct JournalView: View {
    @ObservedObject private var store  = JournalStore.shared
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var editingEntry: JournalEntry? = nil
    @State private var searchText: String = ""

    private var filtered: [JournalEntry] {
        guard !searchText.isEmpty else { return store.entries }
        let q = searchText.lowercased()
        return store.entries.filter {
            $0.trackTitle.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.albumTitle.lowercased().contains(q) ||
            $0.note.lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 48))
                        .foregroundColor(.roonTertiary)
                    Text("Your Journal")
                        .font(.roonTitle(22))
                        .foregroundColor(.roonPrimary)
                    Text("After tracks finish, you can write notes, rate, and tag your listening mood. Entries appear here.")
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { entry in
                        JournalEntryRow(entry: entry) {
                            editingEntry = entry
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .listRowBackground(Color.roonSurface)
                        .listRowSeparatorTint(Color.roonBorder)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Listening Journal")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(text: $searchText, prompt: "Search journal")
        .sheet(item: $editingEntry) { entry in
            JournalEditSheet(entry: entry)
        }
    }
}

private struct JournalEntryRow: View {
    let entry: JournalEntry
    let onTap: () -> Void

    private var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: entry.createdAt)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(coverid: entry.coverid, size: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.trackTitle)
                            .font(.roonBody(14, weight: .medium))
                            .foregroundColor(.roonPrimary)
                            .lineLimit(1)
                        Spacer()
                        if entry.rating > 0 {
                            HStack(spacing: 1) {
                                ForEach(1...entry.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(.roonAccent)
                                }
                            }
                        }
                    }
                    if !entry.artist.isEmpty {
                        Text(entry.artist)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.roonBody(12))
                            .foregroundColor(.roonTertiary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let mood = entry.mood {
                            Text("\(mood.emoji) \(mood.rawValue)")
                                .font(.roonBody(11))
                                .foregroundColor(.roonTertiary)
                        }
                        Text(dateString)
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Journal edit sheet

struct JournalEditSheet: View {
    let entry: JournalEntry
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var rating: Int
    @State private var mood: JournalMood?

    init(entry: JournalEntry) {
        self.entry = entry
        _note   = State(initialValue: entry.note)
        _rating = State(initialValue: entry.rating)
        _mood   = State(initialValue: entry.mood)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rating") {
                    HStack(spacing: 10) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                Haptics.light()
                                rating = (rating == star) ? 0 : star
                            } label: {
                                Image(systemName: star <= rating ? "star.fill" : "star")
                                    .font(.system(size: 24))
                                    .foregroundColor(star <= rating ? .roonAccent : .roonTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowBackground(Color.roonSurface)

                Section("Mood") {
                    ForEach(JournalMood.allCases) { m in
                        Button {
                            Haptics.light()
                            mood = (mood == m) ? nil : m
                        } label: {
                            HStack {
                                Text(m.emoji + " " + m.rawValue)
                                    .foregroundColor(.roonPrimary)
                                Spacer()
                                if mood == m {
                                    Image(systemName: "checkmark").foregroundColor(.roonAccent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.roonSurface)
                    }
                }

                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(4...10)
                        .foregroundColor(.roonPrimary)
                        .listRowBackground(Color.roonSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle(entry.trackTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = entry
                        updated.note   = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.rating = rating
                        updated.mood   = mood
                        JournalStore.shared.update(updated)
                        Haptics.medium()
                        dismiss()
                    }
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonAccent)
                }
            }
        }
    }
}
