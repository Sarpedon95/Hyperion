# Streaming Service Badge Integration Guide

This guide explains how to apply the streaming service badge overlay to album art throughout the Hyperion app. The infrastructure is in place; these are the UI integration points.

## Overview

- **Badge Component**: `StreamingServiceBadge` (shows brand-colored label in bottom-left corner)
- **Overlay Modifier**: `.withServiceBadge(_:size:)` applies badge to any view
- **Service Detection**: `Track.detectedService` property auto-detects from URL
- **Colors**: Tidal/Squid = black, Qobuz = #002B5C, Deezer = #A238FF
- **Badge Size**: ~22% of thumbnail width, proportional with shadow

## Integration Points

### 1. Album List Grid Views
**Files**: `LibraryView.swift`, `HomeView.swift`

```swift
// Wrap album artwork AsyncImage with badge overlay
ZStack(alignment: .bottomLeading) {
    AsyncImage(url: artworkURL) { image in
        image.resizable().scaledToFill()
    } placeholder: {
        Color.gray
    }
    .frame(height: 160)
    .clipped()
    
    // Add badge for streaming albums
    if let track = album.artwork_track_id,
       let detectedService = tracks.first(where: { $0.coverid == coverid })?.detectedService,
       detectedService != .local {
        StreamingServiceBadge(service: detectedService, size: 160 * 0.22)
            .padding(160 * 0.05)
    }
}
```

### 2. Recent Activity / History Rows
**Files**: `HomeView.swift`, `HistoryView.swift`

```swift
// In album/track rows showing recent plays:
HStack {
    ZStack(alignment: .bottomLeading) {
        // Artwork image
        AsyncImage(url: artworkURL)
            .frame(width: 60, height: 60)
        
        // Badge overlay
        if let service = track.detectedService, service != .local {
            StreamingServiceBadge(service: service, size: 60 * 0.22)
                .padding(60 * 0.03)
        }
    }
    
    // Track info
    VStack(alignment: .leading) { ... }
}
```

### 3. Now Playing Artwork
**File**: `NowPlayingView.swift`

```swift
// Large artwork display with badge
ZStack(alignment: .bottomLeading) {
    AsyncImage(url: artworkURL)
        .scaledToFill()
        .frame(height: 300)
    
    if let service = currentTrack.detectedService, service != .local {
        StreamingServiceBadge(service: service, size: 300 * 0.18)
            .padding(300 * 0.04)
    }
}
```

### 4. Search Results
**File**: `SearchAndSettingsView.swift`

```swift
// Track/album search result rows
ForEach(searchResults) { result in
    HStack {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: result.artworkURL)
                .frame(width: 44, height: 44)
            
            if let service = result.track.detectedService, service != .local {
                StreamingServiceBadge(service: service, size: 44 * 0.22)
                    .padding(2)
            }
        }
        
        VStack(alignment: .leading) {
            Text(result.title)
            Text(result.artist).font(.caption)
        }
    }
}
```

### 5. Classical Tab Album Displays
**File**: `ClassicalBrowserView.swift`

```swift
// Classical tab album grid
Grid {
    ForEach(albums) { album in
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: artworkURL)
                .frame(height: 150)
            
            // Show badge if albums contain streaming tracks
            if let firstTrack = tracksForAlbum(album),
               let service = firstTrack.detectedService,
               service != .local {
                StreamingServiceBadge(service: service, size: 150 * 0.22)
                    .padding(150 * 0.05)
            }
        }
    }
}
```

### 6. Playlist Views
**File**: `PlaylistViews.swift`

```swift
// Local playlist thumbnails (if showing album art)
ForEach(playlistItems) { item in
    ZStack(alignment: .bottomLeading) {
        CachedAsyncImage(url: item.track.artworkURL)
            .frame(width: 80, height: 80)
        
        if let service = item.track.detectedService, service != .local {
            StreamingServiceBadge(service: service, size: 80 * 0.2)
                .padding(80 * 0.04)
        }
    }
}
```

## Badge Size Calculation

Use this formula for proportional sizing:
```swift
let badgeSize = thumbnailWidth * 0.22  // ~22% of thumbnail
```

For common sizes:
- **44pt thumbnail**: badge = 10pt
- **60pt thumbnail**: badge = 13pt  
- **80pt thumbnail**: badge = 18pt
- **150pt thumbnail**: badge = 33pt
- **300pt thumbnail**: badge = 66pt

## Service Detection

The system automatically detects streaming sources from track URLs:

```swift
let service = track.detectedService  // StreamSourceType
if track.isStreamingSource { ... }   // Convenience boolean
```

Detection handles:
- URL pattern matching (qobuz.com, deezer.com, tidal.com)
- LMS streaming service prefixes
- Fallback to .local for local library

## Styling Notes

- **Shadow**: subtle shadow (0.3 alpha, 8-10% offset) ensures badge reads on any album art
- **Padding**: 5% of thumbnail on edges (handles all sizes proportionally)
- **Font**: rounded semi-bold for modern aesthetic
- **Opacity**: solid backgrounds, no transparency

## Testing Checklist

- [ ] Badge appears on all streaming service albums
- [ ] No badge on local library content
- [ ] Badge reads clearly on light/dark artwork
- [ ] Badge size is proportional across different thumbnail sizes
- [ ] Badge position (bottom-left) consistent across all views
- [ ] All three services (Tidal, Qobuz, Deezer) show correct colors
- [ ] Grid views don't shift layout when badge appears

## Implementation Order

1. **Phase 1** (Essential): NowPlayingView, HomeView recent albums
2. **Phase 2** (High priority): LibraryView album grid, search results
3. **Phase 3** (Medium priority): Classical tab, playlist views
4. **Phase 4** (Nice-to-have): Mini artwork displays, widgets

## Playback Verification

While implementing badges, verify these playback paths work for each service:

1. **Tidal tracks**: `/play` command correctly passes extid or stream URL
2. **Qobuz tracks**: Quality metadata preserved through playback chain
3. **Deezer tracks**: Authentication tokens refreshed if expired

Check `PlayerViewModel+PlaybackAPI.swift` for the `play()` method to ensure it handles streaming URLs correctly (don't treat them as local file paths).
