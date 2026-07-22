<div align="center">
  <img src="assets/logo.png" alt="DSK Play logo" width="120" />

  # DSK Play

  **Stream, go offline, browse your own files, sing along, and never lose your library — all in one clean Flutter app.**

  ![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white)
  ![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=for-the-badge&logo=dart&logoColor=white)
  ![Android](https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
  ![Firebase](https://img.shields.io/badge/Firebase-FFCA28?style=for-the-badge&logo=firebase&logoColor=black)
  ![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg?style=for-the-badge)

  [![Sync YouTube libs](https://github.com/dskmusic/DSKplay/actions/workflows/youtube_sync.yml/badge.svg)](https://github.com/dskmusic/DSKplay/actions/workflows/youtube_sync.yml)
</div>

---

DSK Play is a mobile music player built with Flutter. It streams music on demand, plays your own local audio files, keeps a full offline library, and backs everything up — playlists, favorites, stats and settings — locally or to the cloud, so switching phones or clearing app data never means starting from zero.

## 📑 Table of contents

- [✨ Features](#-features)
  - [🎧 Streaming & search](#-streaming--search)
  - [📃 Playlists & library](#-playlists--library)
  - [📻 Radio stations](#-radio-stations)
  - [📂 Local files](#-local-files)
  - [🎤 Karaoke & lyrics](#-karaoke--lyrics)
  - [⬇️ Offline](#️-offline)
  - [☁️ Backup & restore](#️-backup--restore)
  - [📊 Listening stats](#-listening-stats)
  - [🎨 Personalization](#-personalization)
  - [🔊 Audio](#-audio)
  - [🌍 Languages](#-languages)
  - [🔗 Sharing & integration](#-sharing--integration)
- [🛠️ Built with](#️-built-with)
- [🏗️ Building](#️-building)
- [📄 License](#-license)
- [🙏 Acknowledgments](#-acknowledgments)

## ✨ Features

### 🎧 Streaming & search

- Stream music on demand, powered by YouTube Music
- One search box for songs, artists, albums, playlists and radio stations
- Search history and external song recommendations
- Dedicated artist pages

### 📃 Playlists & library

- Create and organize playlists, including folders to group them
- Like songs, playlists and albums, plus a recently-played history
- Save the current queue as a new playlist on the spot
- Import/export playlists
- Share a playlist with another DSK Play install via a link

### 📻 Radio stations

- Built-in radio stations, ready to play
- Add your own custom stations
- Favorite the ones you like, hide the ones you don't

### 📂 Local files

- Browse your device's folders and play your own audio files
- Multi-select to play, queue or add a batch to a playlist at once
- Global search across folders and songs, with live feedback while it scans so it never looks frozen
- Favorite folders for one-tap access from the header

### 🎤 Karaoke & lyrics

- Synced, karaoke-style lyrics with customizable highlight colors
- Fullscreen karaoke mode
- Plain-lyrics fallback with a manual result picker when synced lyrics aren't available

### ⬇️ Offline

- Download songs for offline listening
- Offline mode to only show what's already downloaded
- Export downloaded tracks to your device's storage as MP3 or M4A

### ☁️ Backup & restore

- One-file local backup and restore, with a "last backup" date always in view
- Anonymous cloud backup (no name, email or personal data collected), with automatic backup on changes, on a timer, and on app exit - plus a manual option
- A recovery code lets you restore your cloud backup on another device, or after clearing the app's data

### 📊 Listening stats

- Automatic listening stats: play counts, time listened, top songs
- Monthly and yearly recap cards ("Time Machine") you can export and share as an image

### 🎨 Personalization

- Light and dark themes, with an optional true-black dark mode
- Material You dynamic color support
- Custom accent color
- Predictive back gesture support

### 🔊 Audio

- Built-in equalizer
- Selectable audio quality
- SponsorBlock integration to auto-skip sponsor segments
- Sleep timer
- Playback keeps going even if the app is swiped away from recents

### 🌍 Languages

- Available in 21 languages, from the community-driven Musify translations this project builds on

### 🔗 Sharing & integration

- Open or share an audio file from any other app straight into DSK Play, which plays it and expands the player automatically
- Save a song's cover art straight to your device

## 🛠️ Built with

- [Flutter](https://flutter.dev) & [Dart](https://dart.dev)
- [Firebase](https://firebase.google.com) (Authentication + Cloud Firestore) for cloud backup
- [Hive](https://pub.dev/packages/hive) for local storage
- [just_audio](https://pub.dev/packages/just_audio) & [audio_service](https://pub.dev/packages/audio_service) for playback

## 🏗️ Building

This is a standard Flutter project.

```bash
flutter pub get
flutter build apk --release
```

> Cloud backup requires a Firebase project of your own (Cloud Firestore + Anonymous Authentication) and its `google-services.json` placed in `android/app/`. Everything else builds and runs without it.

## 📄 License

DSK Play is free software, licensed under the [GNU General Public License v3.0](LICENSE).

## 🙏 Acknowledgments

Built on top of the open-source [Musify](https://github.com/gokadzev/Musify) project by Valeri Gokadze.
