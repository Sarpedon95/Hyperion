import Foundation

// MARK: - Ensemble (BAND / role_id:4)

struct Ensemble: Identifiable, Hashable {
    let id: Int           // LMS contributor ID
    let name: String      // full canonical name
    var albumCount: Int
}

// MARK: - Conductor (role_id:3)

struct Conductor: Identifiable, Hashable {
    let id: Int
    let name: String
    var albumCount: Int
}

// MARK: - Soloist (ClassicalTags plugin)

struct SoloistEntry: Identifiable, Hashable {
    let id: String        // canonical name doubles as ID
    let name: String
    var trackCount: Int

    init(name: String, trackCount: Int) {
        self.id = name
        self.name = name
        self.trackCount = trackCount
    }
}

// MARK: - Classical work (LMS WORK tag)
//
// NOTE on naming:
//   Stage 3's spec calls this `WorkGroup`, but `WorkGroup` already exists in
//   Models.swift as the playback-side model (drives PlayerViewModel.currentWorkGroup,
//   playWork, queue groupings, NowPlayingView, etc). Renaming the playback type
//   would force a cross-cutting refactor of Stages 1–2. To avoid that, the
//   browse-side type is named `ClassicalWork`. Methods that return collections
//   of these use `-> [ClassicalWork]`.

struct ClassicalWork: Identifiable, Hashable {
    let id: Int               // LMS work_id
    let title: String         // canonical work title
    var workID_slug: String?  // disambiguation slug from the ClassicalTags plugin
    var tracks: [Track]       // movements in disc/track order
    var performanceCount: Int // distinct recordings of this work in the library
}
