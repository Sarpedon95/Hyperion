# Hyperion

iOS app for Lyrion Music Server.

## Repository structure

```
Hyperion/              ← All Swift source files + Info.plist go here
  HyperionApp.swift
  ContentView.swift
  HomeView.swift
  LibraryView.swift
  LibraryViewModel.swift
  PlayerViewModel.swift
  ConnectionManager.swift
  LyrionAPI.swift
  Models.swift
  DesignSystem.swift
  NowPlayingView.swift
  QueueView.swift
  SearchAndSettingsView.swift
  Info.plist
project.yml            ← XcodeGen config (generates the .xcodeproj)
.github/
  workflows/
    build.yml          ← GitHub Actions CI
```

## Before building

1. Open `project.yml` and replace:
   - `com.yourname` → your reverse-domain (e.g. `com.jsmith`)
   - `DEVELOPMENT_TEAM: ""` → your Apple Team ID (found at developer.apple.com)

2. Register bundle ID `com.yourname.hyperion` at developer.apple.com

## Building locally (if you ever get Mac access)

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open Hyperion.xcodeproj
```

## Publishing via Codemagic

1. Push this repo to GitHub
2. Sign up at codemagic.io and connect your GitHub
3. Add your Apple Developer credentials in Codemagic settings
4. Codemagic will run XcodeGen automatically, then build + sign + upload to TestFlight
# Hyperion for Lyrion
