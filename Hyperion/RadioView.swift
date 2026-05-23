import SwiftUI

// MARK: - Radio tab root

struct RadioView: View {

    @StateObject private var vm = RadioViewModel()
    @ObservedObject private var player = PlayerViewModel.shared

    private var isSearching: Bool {
        !vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Radio")
                        .font(.roonTitle(34))
                        .foregroundColor(.roonPrimary)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    searchField
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    if isSearching {
                        searchResultsSection
                    } else {
                        featuredSection
                        genreSection
                        browseResultsSection
                    }

                    Spacer(minLength: 40)
                }
            }
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if player.isPlayingRadio { nowPlayingBar }
            }
            .onChange(of: vm.searchText) { _, q in vm.search(query: q) }
            .task { await vm.loadFeaturedStations() }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.roonTertiary)
                .font(.system(size: 16))
            TextField("Search stations…", text: $vm.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundColor(.roonPrimary)
                .font(.roonBody(16))
                .submitLabel(.search)
            if !vm.searchText.isEmpty {
                Button { vm.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.roonTertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Featured

    @ViewBuilder
    private var featuredSection: some View {
        if !vm.featuredStations.isEmpty {
            sectionHeader(label: "FEATURED", title: "Always available")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(vm.featuredStations) { station in
                        Button {
                            Haptics.medium()
                            Task { await vm.play(station: station) }
                        } label: {
                            FeaturedStationCard(
                                station: station,
                                isPlaying: vm.isPlaying(station)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: - Genre chips

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(label: "BROWSE", title: "Genres")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RadioViewModel.RadioGenre.allCases) { genre in
                        genreChip(genre)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .padding(.bottom, vm.selectedGenreFilter == nil ? 16 : 4)
    }

    private func genreChip(_ genre: RadioViewModel.RadioGenre) -> some View {
        let selected = vm.selectedGenreFilter == genre
        return Button {
            Haptics.light()
            Task { await vm.browseGenre(genre) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: genre.icon).font(.system(size: 11))
                Text(genre.displayName)
                    .font(.roonBody(12, weight: selected ? .semibold : .regular))
            }
            .foregroundColor(selected ? .roonBase : .roonSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.roonAccent : Color.roonElevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Browse / Search results

    @ViewBuilder
    private var browseResultsSection: some View {
        if vm.selectedGenreFilter != nil {
            if vm.isLoading && vm.browseResults.isEmpty {
                loadingRow
            } else if vm.browseResults.isEmpty {
                emptyResultsRow(text: "No stations found for this genre.")
            } else {
                stationList(vm.browseResults)
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if vm.isLoading && vm.searchResults.isEmpty {
            loadingRow
        } else if vm.searchResults.isEmpty {
            emptyResultsRow(text: "No stations match “\(vm.searchText)”.")
        } else {
            stationList(vm.searchResults)
        }
    }

    private func stationList(_ stations: [RadioStation]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(stations) { station in
                Button {
                    Haptics.medium()
                    Task { await vm.play(station: station) }
                } label: {
                    StationRow(station: station, isPlaying: vm.isPlaying(station))
                }
                .buttonStyle(.plain)
                if station.id != stations.last?.id {
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                }
            }
        }
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var loadingRow: some View {
        HStack { Spacer(); ProgressView().tint(.roonAccent); Spacer() }
            .padding(.vertical, 30)
    }

    private func emptyResultsRow(text: String) -> some View {
        Text(text)
            .font(.roonBody(13))
            .foregroundColor(.roonTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }

    // MARK: - Now-playing bar

    private var nowPlayingBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.roonAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentRadioStation?.name ?? "Radio")
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text("LIVE")
                    .font(.roonBody(9, weight: .bold))
                    .foregroundColor(.red)
            }
            Spacer()
            Button {
                Haptics.light()
                vm.stop()
            } label: {
                Text("Stop")
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.roonAccent.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.roonSurface)
        .overlay(alignment: .top) { Color.roonBorder.frame(height: 0.5) }
    }

    // MARK: - Helpers

    private func sectionHeader(label: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(.roonAccent)
                .kerning(1.4)
            Text(title)
                .font(.roonTitle(22))
                .foregroundColor(.roonPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

// MARK: - Featured station card

private struct FeaturedStationCard: View {
    let station: RadioStation
    let isPlaying: Bool

    private var brandColor: Color {
        if let hex = FeaturedRadioStations.brandHex(for: station.name) {
            return Color(hex: hex)
        }
        return .roonElevated
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            brandColor
            // Logo overlay (top trailing) if available.
            if station.logoURL != nil {
                RadioLogoImage(url: station.logoURL, size: 44, fallbackInitials: station.initials)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.roonBody(14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                if let genre = station.genre {
                    Text(genre)
                        .font(.roonBody(9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Capsule())
                }
            }
            .padding(10)
        }
        .frame(width: 160, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isPlaying ? Color.roonAccent : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

// MARK: - Station row

private struct StationRow: View {
    let station: RadioStation
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            RadioLogoImage(url: station.logoURL, size: 40, fallbackInitials: station.initials)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(isPlaying ? .roonAccent : .roonPrimary)
                    .lineLimit(1)
                if !station.detailLine.isEmpty {
                    Text(station.detailLine)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let q = station.qualityLabel {
                Text(q)
                    .font(.roonBody(9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.roonAccent.opacity(0.8))
                    .clipShape(Capsule())
            }

            if isPlaying {
                Image(systemName: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.roonAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Logo image (ArtworkCache-backed)

struct RadioLogoImage: View {
    let url: URL?
    let size: CGFloat
    let fallbackInitials: String

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.roonElevated
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(.roonAccent)
                }
            }
        }
        .task(id: url?.absoluteString) {
            guard let url else { image = nil; return }
            image = await ArtworkCache.shared.loadImage(
                url: url,
                targetPoints: size,
                scale: UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2
            )
        }
    }
}
