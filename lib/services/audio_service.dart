/*
 *     Copyright (C) 2026 Víctor Castilla
 *
 *     DSK Play is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     DSK Play is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about DSK Play, including how to contribute,
 *     please visit: https://dskmusic.com or https://github.com/dskmusic
 */

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/models/position_data.dart';
import 'package:dskplay/services/cast_service.dart';
import 'package:dskplay/services/cloud_backup_service.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/download_foreground_service.dart';
import 'package:dskplay/services/listening_stats_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/map_utils.dart';
import 'package:dskplay/utilities/mediaitem.dart';
import 'package:dskplay/utilities/queue_entry_utils.dart';
import 'package:flutter/cupertino.dart' show WidgetsBindingObserver;
import 'package:flutter/material.dart' show WidgetsBindingObserver;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show WidgetsBindingObserver;
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

class DskPlayAudioHandler extends BaseAudioHandler {
  DskPlayAudioHandler() {
    _androidEqualizer = AndroidEqualizer();
    _androidLoudnessEnhancer = AndroidLoudnessEnhancer();
    unawaited(
      _androidLoudnessEnhancer.setTargetGain(_normalizationTargetGainDb),
    );
    unawaited(_applyVolumeNormalizationSetting());
    volumeNormalizationEnabled.addListener(_applyVolumeNormalizationSetting);
    audioPlayer = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [_androidEqualizer, _androidLoudnessEnhancer],
      ),
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          maxBufferDuration: Duration(seconds: 60),
          bufferForPlaybackDuration: Duration(milliseconds: 500),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
        ),
      ),
    );

    _setupEventSubscriptions();
    _setupCastCallbacks();
    _updatePlaybackState();

    audioPlayer.setAndroidAudioAttributes(
      const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
    );

    _initialize();
  }

  late final AndroidEqualizer _androidEqualizer;
  late final AndroidLoudnessEnhancer _androidLoudnessEnhancer;
  // ponytail: fixed boost rather than true per-track loudness analysis
  // (ReplayGain-style), which would need decoding/analyzing audio upfront.
  // Reasonable default that noticeably lifts quiet tracks without clipping.
  static const double _normalizationTargetGainDb = 6;
  late final AudioPlayer audioPlayer;

  bool _equalizerInitialized = false;
  Future<bool>? _equalizerInitFuture;
  DateTime _equalizerRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _sleepTimer;
  int _sleepTimerGeneration = 0;
  Timer? _debounceTimer;
  bool sleepTimerExpired = false;
  bool sleepTimerEndOfSong = false;

  // Armed whenever playback transitions into paused (with something still
  // loaded), cleared on resume/stop - fires the same backup-then-exit as a
  // real stop if the user leaves it paused for the configured duration
  // instead of ever coming back to it.
  Timer? _idleAutoCloseTimer;

  // Only a backgrounded process can actually be frozen (see
  // _armNativeIdleClose's doc comment below), so the native keep-alive
  // service - and the notification Android requires for it - has no reason
  // to exist while the app is still in the foreground. Without this, simply
  // pausing a song while looking at the app shows that notification
  // immediately even though nothing is at risk of being frozen yet.
  bool _isAppInForeground = true;

  // Native fallback for the timer above: audio_service tears down the
  // FlutterEngine (and every Dart Timer with it) almost as soon as the app
  // is backgrounded with nothing playing, well before this timer would
  // otherwise fire - leaving the process orphaned with nothing left to
  // close it. App.kt keeps this armed independently of the Dart engine.
  static const _idleCloseChannel = MethodChannel('dskplay/download_service');

  void _armNativeIdleClose(int minutes) {
    if (!Platform.isAndroid || !nativeIdleCloseBackupEnabled.value) return;
    unawaited(
      _idleCloseChannel
          .invokeMethod('armIdleClose', {'minutes': minutes})
          .catchError((_) {}),
    );
  }

  void _cancelNativeIdleClose() {
    if (!Platform.isAndroid) return;
    unawaited(
      _idleCloseChannel.invokeMethod('cancelIdleClose').catchError((_) {}),
    );
  }

  /// Called by main.dart's [WidgetsBindingObserver] when the app leaves/
  /// re-enters the foreground, so the native keep-alive - and its visible
  /// notification - only ever runs while it's actually needed.
  void handleAppBackgrounded() {
    _isAppInForeground = false;
    if (_idleAutoCloseTimer != null && !DownloadForegroundService.isActive) {
      _armNativeIdleClose(autoCloseAfterPauseMinutes.value);
    }
  }

  void handleAppForegrounded() {
    _isAppInForeground = true;
    if (_idleAutoCloseTimer != null) _cancelNativeIdleClose();
  }

  // Fire-and-forget: dispatching this platform channel call doesn't depend
  // on this isolate surviving afterwards, unlike everything after it in
  // _exitIfIdle. If exit(0) below succeeds first the whole process (this
  // watchdog included) dies with it anyway, so there's nothing to cancel.
  void _scheduleNativeHardExit() {
    if (!Platform.isAndroid || !nativeIdleCloseBackupEnabled.value) return;
    unawaited(
      _idleCloseChannel
          .invokeMethod('scheduleHardExit', {'delayMs': 15000})
          .catchError((_) {}),
    );
  }

  // Set around stop() calls that should just halt playback and leave the
  // app open - the user closing the player from within the app, or giving
  // up after repeated playback errors - as opposed to every other caller
  // (sleep timer, queue running out, the notification/lock-screen stop
  // button), where nothing being left to play means the idle process
  // should be freed instead of lingering in the background.
  bool _keepAppOpenOnStop = false;

  final List<Map> _queueList = [];
  final List<Map> _originalQueueList = [];
  final List<Map> _historyList = [];
  final BehaviorSubject<List<Map>> _queueMapStream =
      BehaviorSubject<List<Map>>.seeded([]);
  final QueueEntryIdManager _queueEntryIds = QueueEntryIdManager();
  int _currentQueueIndex = 0;
  int _currentLoadingIndex = -1;
  int _currentLoadingTransitionId = -1;
  bool _isUpdatingState = false;
  bool _pendingPlaybackStateUpdate = false;
  int _songTransitionCounter = 0;

  bool _completionEventPending = false;
  bool _completionHandlerLoadStarted = false;

  String? _lastError;
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 3;

  // Below this much time left, a saved podcast position is treated as
  // "finished" rather than resumable (see [_restoreLastPlayedForDisplay]).
  static const Duration _podcastNearEndThreshold = Duration(minutes: 2);

  // Set by [_restoreLastPlayedForDisplay] when a podcast episode - rather
  // than a regular song - is what should resume on the next play() tap;
  // consumed and cleared there.
  ({
    PodcastEpisode episode,
    String podcastTitle,
    String? localPath,
    Duration position,
  })?
  _pendingPodcastResume;

  /// A podcast episode restored from a cold start that hasn't resumed
  /// playback yet - used by the in-app play button to ask the user whether
  /// to resume from [Duration] or start over, instead of silently seeking.
  ({
    PodcastEpisode episode,
    String podcastTitle,
    String? localPath,
    Duration position,
  })?
  get pendingPodcastResume => _pendingPodcastResume;

  // The podcast episode currently loaded (if any), kept so the throttled
  // position listener can persist progress without re-reading Hive on every
  // tick. Cleared whenever a non-podcast source starts playing.
  ({PodcastEpisode episode, String podcastTitle, String? localPath})?
  _currentPlayingPodcast;

  /// The podcast episode currently loaded, if the current media item is a
  /// podcast episode rather than a regular song - used by the full player's
  /// "download MP3" button to download the actual episode file instead of
  /// treating the episode id as a YouTube video id.
  ({PodcastEpisode episode, String podcastTitle, String? localPath})?
  get currentPlayingPodcast => _currentPlayingPodcast;

  static const int _maxHistorySize = 50;
  static const int _queueLookahead = 3;
  static const int _maxConcurrentPreloads = 2;
  static const Duration _errorRetryDelay = Duration(seconds: 2);
  static const Duration _songTransitionTimeout = Duration(seconds: 30);
  static const Duration _debounceInterval = Duration(milliseconds: 150);
  static const Duration _positionDataThreshold = Duration(milliseconds: 250);
  static const Duration _playbackStateHeartbeat = Duration(seconds: 1);

  static const String _recentMediaIdPrefix = 'recent:';

  int _activePreloadCount = 0;
  final Set<String> _preloadingYtIds = <String>{};
  final Set<String> _preloadedYtIds = <String>{};

  late final Stream<PositionData> _positionDataStream =
      Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
            audioPlayer.positionStream,
            audioPlayer.bufferedPositionStream,
            audioPlayer.durationStream,
            (position, bufferedPosition, duration) => PositionData(
              position,
              bufferedPosition,
              duration ?? Duration.zero,
            ),
          )
          .distinct((prev, curr) {
            return (prev.position - curr.position).abs() <
                    _positionDataThreshold &&
                prev.duration == curr.duration &&
                (prev.bufferedPosition - curr.bufferedPosition).abs() <
                    _positionDataThreshold;
          })
          // Mientras suena en la tele el reloj lo lleva el receptor: el reproductor
          // local esta parado y lo que emita aqui solo estorbaria.
          .where((_) => !castService.isCasting)
          .mergeWith([castService.positionStream])
          .asBroadcastStream();

  Stream<PositionData> get positionDataStream => _positionDataStream;

  late final Stream<PlaybackState> _playbackStateStream = playbackState
      .distinct((prev, curr) {
        final prevPositionBucket =
            prev.updatePosition.inMilliseconds ~/
            _positionDataThreshold.inMilliseconds;
        final currPositionBucket =
            curr.updatePosition.inMilliseconds ~/
            _positionDataThreshold.inMilliseconds;
        return prev.playing == curr.playing &&
            prev.processingState == curr.processingState &&
            prev.queueIndex == curr.queueIndex &&
            prev.speed == curr.speed &&
            prevPositionBucket == currPositionBucket;
      })
      .asBroadcastStream();

  Stream<PlaybackState> get playbackStateStream => _playbackStateStream;

  List<MediaControl> _controls(bool playing) {
    final hasMultipleTracks = _queueList.length > 1;

    return [
      if (hasMultipleTracks)
        MediaControl.skipToPrevious
      else
        MediaControl.rewind,
      if (playing) MediaControl.pause else MediaControl.play,
      if (hasMultipleTracks)
        MediaControl.skipToNext
      else
        MediaControl.fastForward,
      // Renders as the notification/lock-screen "X" close button; wired to
      // the shared stop() below, which now closes the app outright.
      MediaControl.stop,
    ];
  }

  final _processingStateMap = {
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void _logStreamError(String message, Object error, StackTrace stackTrace) {
    logger.log(message, error: error, stackTrace: stackTrace);
  }

  void _setupEventSubscriptions() {
    audioPlayer.playbackEventStream
        .throttleTime(const Duration(milliseconds: 100))
        .listen(
          (event) {
            _updatePlaybackState();
          },
          onError: (error, stackTrace) {
            _logStreamError('Playback event stream error', error, stackTrace);
          },
        );

    audioPlayer.processingStateStream.distinct().listen(
      _handleProcessingStateChange,
      onError: (error, stackTrace) {
        _logStreamError('Processing state stream error', error, stackTrace);
      },
    );

    // Un unico punto de verdad para la marca de "sonando": todos los caminos
    // de reproduccion acaban publicando en mediaItem.
    // El origen se guarda igual que la cola: al volver a abrir la app, el
    // enlace del reproductor y la marca de la lista siguen ahi.
    nowPlayingSource.addListener(() {
      unawaited(
        addOrUpdateData('user', 'nowPlayingSource', nowPlayingSource.value),
      );
    });

    mediaItem.listen((item) {
      final ytid = item?.extras?['ytid']?.toString() ?? item?.id ?? '';
      nowPlayingYtid.value = ytid;
      // Aqui pasan tambien los saltos de cancion, no solo el primer play:
      // asi la lista recuerda por donde iba de verdad.
      rememberPlaylistProgress(
        nowPlayingSource.value?['ytid']?.toString(),
        ytid,
      );
    });

    audioPlayer.durationStream.listen(
      (duration) {
        if (_currentQueueIndex < _queueList.length && duration != null) {
          _updateCurrentMediaItemWithDuration(duration);
        }
      },
      onError: (error, stackTrace) {
        _logStreamError('Duration stream error', error, stackTrace);
      },
    );

    audioPlayer.playerStateStream
        .distinct()
        .throttleTime(const Duration(milliseconds: 100))
        .listen(
          (state) {
            listeningStatsService.handlePlayerStateForListeningStats(
              state,
              currentSong: currentSong,
            );
            if (state.processingState == ProcessingState.idle &&
                !state.playing &&
                _lastError != null) {
              Future.microtask(_handlePlaybackError);
            }
            _debouncedStateUpdate();
          },
          onError: (error, stackTrace) {
            _logStreamError('Player state stream error', error, stackTrace);
          },
        );

    Rx.combineLatest2(
          audioPlayer.currentIndexStream.distinct(),
          audioPlayer.sequenceStateStream.distinct(),
          (index, sequence) => {'index': index, 'sequence': sequence},
        )
        .throttleTime(const Duration(milliseconds: 100))
        .listen(
          (_) => _debouncedStateUpdate(),
          onError: (error, stackTrace) {
            _logStreamError('Current index stream error', error, stackTrace);
          },
        );

    // Podcasts don't go through _queueList/_persistQueueState, so their
    // resume position is saved separately here, throttled to avoid hammering
    // Hive on every position tick.
    audioPlayer.positionStream
        .throttleTime(const Duration(seconds: 5))
        .listen(
          (position) => unawaited(_persistPodcastPositionIfNeeded(position)),
          onError: (error, stackTrace) {
            _logStreamError('Position stream error', error, stackTrace);
          },
        );
  }

  void _debouncedStateUpdate() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceInterval, () {
      if (!_isUpdatingState) {
        _updatePlaybackState();
      }
    });
  }

  void _hydrateQueueEntryIds() {
    _queueEntryIds
      ..ensureIds(_queueList)
      ..ensureIds(_originalQueueList);
  }

  MediaItem _getMediaItemForQueue(Map song) {
    return mapToMediaItem(song).copyWith(id: _queueEntryIds.ensureId(song));
  }

  /// Pushes [updatedSong]'s metadata (title/artist/artwork) into the
  /// currently-playing item and/or queue slot matching [ytid], if any -
  /// used after a local file's tags are edited in place, so the mini
  /// player/now playing screen/queue reflect the change immediately
  /// instead of only after the song is reloaded or the app restarts.
  void refreshSongMetadata(String ytid, Map updatedSong) {
    try {
      final currentItem = mediaItem.valueOrNull;
      if (currentItem != null &&
          currentItem.extras?['ytid']?.toString() == ytid) {
        mediaItem.add(
          _getMediaItemForQueue(
            updatedSong,
          ).copyWith(id: currentItem.id, duration: currentItem.duration),
        );
      }

      final existingQueue = queue.valueOrNull;
      if (existingQueue != null) {
        final index = existingQueue.indexWhere(
          (item) => item.extras?['ytid']?.toString() == ytid,
        );
        if (index != -1) {
          final updatedQueue = List<MediaItem>.from(existingQueue);
          updatedQueue[index] = _getMediaItemForQueue(updatedSong).copyWith(
            id: existingQueue[index].id,
            duration: existingQueue[index].duration,
          );
          queue.add(updatedQueue);
        }
      }

      for (var i = 0; i < _queueList.length; i++) {
        if (_queueList[i]['ytid']?.toString() == ytid) {
          _queueList[i] = Map<String, dynamic>.from(updatedSong);
        }
      }
      for (var i = 0; i < _originalQueueList.length; i++) {
        if (_originalQueueList[i]['ytid']?.toString() == ytid) {
          _originalQueueList[i] = Map<String, dynamic>.from(updatedSong);
        }
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error refreshing song metadata',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  List<MediaItem> _buildQueueMediaItems() =>
      _queueList.map(_getMediaItemForQueue).toList(growable: false);

  bool _shouldUpdateDuration(Duration? currentDuration, Duration nextDuration) {
    return currentDuration == null ||
        !durationEquals(currentDuration, nextDuration);
  }

  bool _isCurrentMediaItemMatchingSong(
    MediaItem? currentItem,
    MediaItem currentQueueMediaItem,
    String? currentSongYtid,
  ) {
    if (currentItem == null) return false;

    if (currentItem.id == currentQueueMediaItem.id) {
      return true;
    }

    return currentSongYtid != null &&
        currentSongYtid.isNotEmpty &&
        currentItem.extras?['ytid']?.toString() == currentSongYtid;
  }

  void _updateCurrentMediaItemWithDuration(Duration duration) {
    try {
      // Podcast episodes (and other out-of-queue playback) set mediaItem/
      // queue directly without touching _queueList/_currentQueueIndex, so
      // those two are stale leftovers from whatever played before. Falling
      // through to the _queueList-based logic below would "resync" the
      // duration against that stale entry and clobber the episode's own
      // mediaItem the moment its real duration becomes known - unlike radio
      // (duration always null), a podcast episode has a real duration, so
      // it's the one out-of-queue case that actually reaches this listener.
      final activeItem = mediaItem.valueOrNull;
      if (activeItem != null &&
          activeItem.extras?['isPodcastEpisode'] == true) {
        if (_shouldUpdateDuration(activeItem.duration, duration)) {
          final updated = activeItem.copyWith(duration: duration);
          mediaItem.add(updated);
          final existingQueue = queue.valueOrNull;
          if (existingQueue != null && existingQueue.isNotEmpty) {
            queue.add([updated, ...existingQueue.skip(1)]);
          }
        }
        return;
      }

      final queueIndex = _currentQueueIndex;
      if (queueIndex < 0 || queueIndex >= _queueList.length) return;

      final currentSong = _queueList[queueIndex];
      final currentMediaItem = _getMediaItemForQueue(currentSong);
      final currentSongYtid = currentSong['ytid']?.toString();
      final currentItem = mediaItem.valueOrNull;
      final isMatchingCurrentItem = _isCurrentMediaItemMatchingSong(
        currentItem,
        currentMediaItem,
        currentSongYtid,
      );

      if (currentItem != null &&
          isMatchingCurrentItem &&
          _shouldUpdateDuration(currentItem.duration, duration)) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      } else if (!isMatchingCurrentItem) {
        mediaItem.add(currentMediaItem.copyWith(duration: duration));
      }

      listeningStatsService.updateListeningSessionDuration(
        currentSongYtid,
        duration,
      );

      final existingQueue = queue.valueOrNull;
      if (existingQueue != null && queueIndex < existingQueue.length) {
        final queueItem = existingQueue[queueIndex];
        if (_shouldUpdateDuration(queueItem.duration, duration)) {
          final updatedQueue = List<MediaItem>.from(existingQueue);
          updatedQueue[queueIndex] = queueItem.copyWith(duration: duration);
          queue.add(updatedQueue);
        }
        return;
      }

      final rebuiltQueue = _buildQueueMediaItems();
      if (queueIndex < rebuiltQueue.length) {
        rebuiltQueue[queueIndex] = rebuiltQueue[queueIndex].copyWith(
          duration: duration,
        );
      }
      queue.add(rebuiltQueue);
    } catch (e, stackTrace) {
      logger.log(
        'Error updating media item with duration',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void resetListeningStatsSession({
    bool countCurrentTick = false,
    bool flushStats = true,
  }) {
    listeningStatsService.finishListeningSession(
      countCurrentTick: countCurrentTick,
      flushStats: flushStats,
    );
  }

  void startListeningStatsSessionIfNeeded() {
    listeningStatsService.startListeningSessionIfNeeded(
      currentSong: currentSong,
      isPlaying: audioPlayer.playing,
    );
  }

  Future<void> _initialize() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Always set loop mode to off - we handle all repeating through _handleSongCompletion
      // This ensures ProcessingState.completed is always fired for song transitions
      await audioPlayer.setLoopMode(LoopMode.off);

      // Apply stored shuffle mode to audio player
      await audioPlayer.setShuffleModeEnabled(shuffleNotifier.value);

      // Initialize equalizer once at startup
      unawaited(_ensureEqualizerConfigured());

      _restoreLastPlayedForDisplay();
    } catch (e, stackTrace) {
      logger.log(
        'Error initializing audio session',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Shows the last played song (local, playlist or online) in the mini
  /// player on a cold start, without loading or starting audio - so the user
  /// can resume with a tap instead of searching for it again. A share/open-with
  /// intent naturally overrides this: it calls playSong/playPlaylistSong,
  /// which replace this seeded state with the real, actually-playing song.
  void _restoreLastPlayedForDisplay() {
    try {
      if (mediaItem.valueOrNull != null) return;
      if (!rememberLastPlayback.value) return;

      final persisted = _loadPersistedQueueState();
      final persistedPodcast = _loadPersistedPodcastState();

      if (persistedPodcast != null &&
          (persisted == null ||
              persistedPodcast.savedAt >= persisted.savedAt)) {
        // Don't offer to resume an episode the user likely already
        // finished - e.g. stopped during the outro thinking it was over,
        // with a minute or two left - and don't fall back to whatever
        // song was playing before it either: that's not what the user was
        // last listening to, so show no mini player at all.
        final durationSeconds = persistedPodcast.episode.durationSeconds;
        if (durationSeconds != null &&
            Duration(seconds: durationSeconds) - persistedPodcast.position <=
                _podcastNearEndThreshold) {
          return;
        }

        _pendingPodcastResume = (
          episode: persistedPodcast.episode,
          podcastTitle: persistedPodcast.podcastTitle,
          localPath: persistedPodcast.localPath,
          position: persistedPodcast.position,
        );

        final episodeSong = {
          'id': persistedPodcast.episode.key,
          'ytid': persistedPodcast.episode.key,
          'title': persistedPodcast.episode.title,
          'artist': persistedPodcast.podcastTitle,
          'album': persistedPodcast.podcastTitle,
          'highResImage': persistedPodcast.episode.image,
          'lowResImage': persistedPodcast.episode.image,
          'duration': persistedPodcast.episode.durationSeconds,
          'isLive': false,
          'isPodcastEpisode': true,
          'description': persistedPodcast.episode.description,
        };
        final item = mapToMediaItem(episodeSong);
        mediaItem.add(item);
        queue.add([item]);
        playbackState.add(
          PlaybackState(
            controls: _controls(false),
            systemActions: const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            androidCompactActionIndices: const [0, 1, 2],
            processingState: AudioProcessingState.ready,
            queueIndex: 0,
            updatePosition: persistedPodcast.position,
            updateTime: DateTime.now(),
          ),
        );
        return;
      }

      if (persisted != null) {
        _queueList
          ..clear()
          ..addAll(persisted.queue);
        _originalQueueList
          ..clear()
          ..addAll(persisted.originalQueue);
        _currentQueueIndex = persisted.index;
        _hydrateQueueEntryIds();

        final mediaItems = _buildQueueMediaItems();
        queue.add(mediaItems);
        _queueMapStream.add(List.unmodifiable(_queueList));

        if (_currentQueueIndex >= mediaItems.length) return;
        mediaItem.add(mediaItems[_currentQueueIndex]);
        playbackState.add(
          PlaybackState(
            controls: _controls(false),
            systemActions: const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            androidCompactActionIndices: const [0, 1, 2],
            processingState: AudioProcessingState.ready,
            queueIndex: _currentQueueIndex,
            updateTime: DateTime.now(),
          ),
        );
        return;
      }

      // Deliberately doesn't fall back to _latestResumableSong() here (used
      // elsewhere for "play something" media-button/assistant intents) -
      // this is a passive cold-start display, so once both persisted keys
      // are gone (e.g. the notification/full-player "X" cleared them) there
      // should be nothing to show, not an arbitrary recently-played song.
    } catch (e, stackTrace) {
      logger.log(
        'Error restoring last played song for display',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _ensureEqualizerConfigured({bool force = false}) async {
    if (_equalizerInitialized) return true;

    final now = DateTime.now();
    if (!force && now.isBefore(_equalizerRetryNotBefore)) {
      return false;
    }

    if (!force && audioPlayer.audioSource == null) {
      return false;
    }

    final inFlight = _equalizerInitFuture;
    if (inFlight != null) {
      return inFlight;
    }

    _equalizerInitFuture = _configureEqualizer();
    try {
      return await _equalizerInitFuture!;
    } finally {
      _equalizerInitFuture = null;
    }
  }

  Future<bool> _configureEqualizer() async {
    try {
      final params = await _androidEqualizer.parameters.timeout(
        const Duration(seconds: 3),
      );

      final savedGains = equalizerBandGains.value;
      if (savedGains.isNotEmpty) {
        for (var i = 0; i < params.bands.length && i < savedGains.length; i++) {
          final clamped = savedGains[i].clamp(
            params.minDecibels,
            params.maxDecibels,
          );
          await params.bands[i].setGain(clamped);
        }
      }

      await _androidEqualizer.setEnabled(equalizerEnabled.value);
      _equalizerInitialized = true;
      _equalizerRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);
      return true;
    } catch (e, stackTrace) {
      _equalizerRetryNotBefore = DateTime.now().add(
        const Duration(seconds: 10),
      );
      logger.log(
        'Equalizer initialization deferred',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _applyVolumeNormalizationSetting() async {
    try {
      await _androidLoudnessEnhancer.setEnabled(
        volumeNormalizationEnabled.value,
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to apply volume normalization setting',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<AndroidEqualizerParameters?> getEqualizerParameters() async {
    final initialized = await _ensureEqualizerConfigured();
    if (!initialized) return null;
    try {
      return await _androidEqualizer.parameters.timeout(
        const Duration(seconds: 2),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to get equalizer parameters',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    final initialized = await _ensureEqualizerConfigured(force: true);
    if (!initialized) return;
    try {
      await _androidEqualizer.setEnabled(enabled);
      equalizerEnabled.value = enabled;
      unawaited(addOrUpdateData<bool>('settings', 'equalizerEnabled', enabled));
    } catch (e, stackTrace) {
      logger.log(
        'Failed to set equalizer enabled state',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> setEqualizerBandGain(int index, double gain) async {
    final initialized = await _ensureEqualizerConfigured(force: true);
    if (!initialized) return;

    try {
      final params = await _androidEqualizer.parameters;
      if (index < 0 || index >= params.bands.length) {
        return;
      }

      final clamped = gain.clamp(params.minDecibels, params.maxDecibels);
      await params.bands[index].setGain(clamped);

      final gains = params.bands.map((band) => band.gain).toList();
      equalizerBandGains.value = gains;
      unawaited(
        addOrUpdateData<List<double>>('settings', 'equalizerBandGains', gains),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to set equalizer band gain',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> resetEqualizerBands() async {
    final initialized = await _ensureEqualizerConfigured(force: true);
    if (!initialized) return;

    try {
      final params = await _androidEqualizer.parameters;
      for (final band in params.bands) {
        await band.setGain(0);
      }
      final gains = List<double>.filled(params.bands.length, 0);
      equalizerBandGains.value = gains;
      unawaited(
        addOrUpdateData<List<double>>('settings', 'equalizerBandGains', gains),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to reset equalizer bands',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _hasSignificantPositionChange(
    Duration currentPosition,
    Duration lastUpdatePosition,
    DateTime lastUpdateTime,
    DateTime now,
    double speed,
  ) {
    final expectedPosition =
        lastUpdatePosition + (now.difference(lastUpdateTime)) * speed;
    return (currentPosition - expectedPosition).abs() >
        const Duration(milliseconds: 500);
  }

  void _updatePlaybackState() {
    if (castService.isCasting) {
      _updateCastPlaybackState();
      return;
    }
    if (_isUpdatingState) {
      _pendingPlaybackStateUpdate = true;
      return;
    }

    _isUpdatingState = true;

    try {
      final now = DateTime.now();
      final currentPosition = audioPlayer.position;
      final isPlaying = audioPlayer.playing;
      final currentState = playbackState.valueOrNull;
      final newProcessingState =
          _processingStateMap[audioPlayer.processingState] ??
          AudioProcessingState.idle;
      final bufferedPosition = audioPlayer.bufferedPosition;

      if (isPlaying) {
        _idleAutoCloseTimer?.cancel();
        _cancelNativeIdleClose();
      } else if (currentState == null ||
          (currentState.playing &&
              newProcessingState != AudioProcessingState.idle)) {
        // Just went idle - either a genuine playing-to-paused transition,
        // or the very first state emitted at cold start with nothing ever
        // played. Arm once here; this event fires repeatedly (just_audio
        // polls position every ~100-800ms even while paused), so re-arming
        // unconditionally on every tick would keep resetting the countdown
        // and the timer would never actually elapse.
        _scheduleIdleAutoClose();
      }

      final shouldEmitProgressTick =
          currentState != null &&
          isPlaying &&
          now.difference(currentState.updateTime) >= _playbackStateHeartbeat;
      final hasBufferedPositionChange =
          currentState == null ||
          (bufferedPosition - currentState.bufferedPosition).abs() >=
              const Duration(seconds: 1);

      final shouldUpdate =
          currentState == null ||
          currentState.playing != isPlaying ||
          currentState.processingState != newProcessingState ||
          currentState.queueIndex != _currentQueueIndex ||
          currentState.speed != audioPlayer.speed ||
          shouldEmitProgressTick ||
          hasBufferedPositionChange ||
          (_hasSignificantPositionChange(
            currentPosition,
            currentState.updatePosition,
            currentState.updateTime,
            now,
            currentState.speed,
          ));

      if (shouldUpdate) {
        playbackState.add(
          PlaybackState(
            controls: _controls(isPlaying),
            systemActions: const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            androidCompactActionIndices: const [0, 1, 2],
            processingState: newProcessingState,
            playing: isPlaying,
            updatePosition: currentPosition,
            bufferedPosition: bufferedPosition,
            speed: audioPlayer.speed,
            queueIndex:
                _currentQueueIndex >= 0 &&
                    _currentQueueIndex < _queueList.length
                ? _currentQueueIndex
                : null,
            updateTime: now,
          ),
        );
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error updating playback state',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _isUpdatingState = false;
      if (_pendingPlaybackStateUpdate) {
        _pendingPlaybackStateUpdate = false;
        _updatePlaybackState();
      }
    }
  }

  Future<void> _handleProcessingStateChange(ProcessingState state) async {
    try {
      if (state == ProcessingState.completed) {
        if (sleepTimerEndOfSong) {
          sleepTimerExpired = true;
          sleepTimerEndOfSong = false;
          // stop() itself now ends the listening session and closes the
          // app outright, whether it's foregrounded or only alive via the
          // notification in the background.
          await stop();
          sleepTimerNotifier.value = null;
          return;
        }

        listeningStatsService.finishListeningSession(
          countCurrentTick: true,
          wasPlaying: true,
        );

        if (!sleepTimerExpired && !_completionEventPending) {
          _completionEventPending = true;

          Future.microtask(() async {
            try {
              if (!sleepTimerExpired && _completionEventPending) {
                await _handleSongCompletion();
              }
            } finally {
              // Only reset if still marked as pending (another event didn't override)
              if (_completionEventPending) {
                _completionEventPending = false;
                _completionHandlerLoadStarted = false;
              }
              // else {
              //   logger.log(
              //     '[COMPLETION] Flag already false in finally block (was overridden)',
              //     null,
              //     null,
              //   );
              // }
            }
          });
        }
      } else if (state == ProcessingState.ready) {
        _completionEventPending = false;
        _completionHandlerLoadStarted = false;

        // Clear the expired flag so future song completions are not
        // blocked after a sleep timer fired in a previous session.
        // Do NOT touch sleepTimerEndOfSong here — 'ready' fires not
        // only for new songs but also on buffering recovery within the
        // same song, which would cancel an active "end of song" timer.
        sleepTimerExpired = false;
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error handling processing state change',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _canRetryPlayback() =>
      hasNext ||
      (repeatNotifier.value == AudioServiceRepeatMode.all &&
          _queueList.isNotEmpty) ||
      playNextSongAutomatically.value;

  void _handlePlaybackError() {
    _consecutiveErrors++;
    logger.log(
      'Playback error occurred. Consecutive errors: $_consecutiveErrors',
      error: _lastError,
    );

    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      logger.log('Max consecutive errors reached. Stopping playback.');
      unawaited(_stopWithoutClosingApp());
      return;
    }

    if (_canRetryPlayback()) {
      Future.delayed(_errorRetryDelay, skipToNext);
    } else {
      _lastError = null;
    }
  }

  Future<void> _handleSongCompletion() async {
    try {
      final isPodcastEpisode =
          _currentQueueIndex >= 0 &&
          _currentQueueIndex < _queueList.length &&
          _queueList[_currentQueueIndex]['isPodcastEpisode'] == true;

      if (isPodcastEpisode) {
        // Reaching `completed` means the episode played through in full -
        // mark it listened here (awaited) instead of solely relying on the
        // position-stream 90% heuristic (podcast_manager.dart's
        // attachAutoMarkListened), which can lose its race against the app
        // closing itself right below when nothing is queued after it.
        final episodeKey = _queueList[_currentQueueIndex]['ytid']?.toString();
        if (episodeKey != null && episodeKey.isNotEmpty) {
          await podcastManager.setListened(episodeKey, listened: true);
        }

        // Podcast episodes now live in the real _queueList too, so advance
        // through it exactly like a song queue - but skip the
        // autoplay/recommendation fallback _canRetryPlayback offers songs,
        // since podcasts are never auto-added: "nothing left queued" always
        // means stop here, regardless of playNextSongAutomatically.
        if (repeatNotifier.value == AudioServiceRepeatMode.one) {
          await playAgain();
        } else if (hasNext ||
            (repeatNotifier.value == AudioServiceRepeatMode.all &&
                _queueList.isNotEmpty)) {
          await skipToNext();
        } else {
          // Nothing left in the podcast queue: stop playback and dismiss
          // the notification, but keep the app itself open rather than
          // closing it outright - the user's configured "close after N
          // minutes idle" timer (see _scheduleIdleAutoClose) takes over
          // from here, same as any other in-app stop.
          await _stopWithoutClosingApp();
        }
        return;
      }

      if (_currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length) {
        _addToHistory(_queueList[_currentQueueIndex]);
      }

      // Determine what to play next based on queue position and repeat mode
      if (repeatNotifier.value == AudioServiceRepeatMode.one) {
        // Repeat single song - play current song again
        await playAgain();
      } else if (!_canRetryPlayback()) {
        // Last song of a playlist/queue (or a standalone song with nothing
        // queued after it) with no repeat-all and no autoplay - same
        // situation as a podcast finishing with nothing left, so close the
        // notification and free the process the same way (stop() itself
        // handles both).
        await stop();
      } else {
        // For all other cases (next song, repeat all, auto-play), skipToNext handles it
        await skipToNext();
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error handling song completion',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _backgroundAddSongsToQueue() async {
    // Fire and forget - this runs as a background task without blocking playback
    if (offlineMode.value) return;

    // Use microtask to avoid blocking the current operation
    unawaited(
      Future.microtask(() async {
        try {
          // Only add songs if we're still playing
          if (!audioPlayer.playing) {
            return;
          }

          final baseSong = _getCurrentSongForRecommendations();
          if (baseSong == null) {
            return;
          }

          // Sin lo que ya esta en la cola ni lo que acaba de sonar: los
          // relacionados de un tema se repiten mucho entre si y la autoplay
          // acababa dando vueltas sobre las mismas dos o tres canciones.
          final exclude = <String>{
            for (final song in [..._queueList, ..._historyList])
              if (song['ytid'] != null) song['ytid'].toString(),
          };

          // Fetch similar songs silently in the background
          final songToAdd =
              await getSimilarSong(baseSong['ytid'], exclude: exclude).timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  logger.log('Background song fetch timed out');
                  return null;
                },
              );

          // If we got a recommendation, add it to the queue
          // But only if still playing (user might have paused during fetch)
          if (!audioPlayer.playing) {
            return;
          }

          if (songToAdd != null) {
            await _insertRecommendedSong(songToAdd);
          }
        } catch (e, stackTrace) {
          logger.log(
            'Error in background song addition',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }),
    );
  }

  Map? _getCurrentSongForRecommendations() {
    final currentMediaItem = mediaItem.valueOrNull;

    if (currentMediaItem == null || currentMediaItem.id.isEmpty) {
      logger.log('No current media item available');
      return null;
    }

    return mediaItemToMap(currentMediaItem);
  }

  void _addToHistory(Map song) {
    try {
      _historyList.insert(0, cloneMap(song));

      if (_historyList.length > _maxHistorySize) {
        _historyList.removeRange(_maxHistorySize, _historyList.length);
      }
    } catch (e, stackTrace) {
      logger.log('Error adding to history', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> addToQueue(Map song, {bool playNext = false}) async {
    try {
      if (song['ytid'] == null || song['ytid'].toString().isEmpty) {
        logger.log('Invalid song data for queue');
        return;
      }

      int insertIndex;

      if (playNext) {
        insertIndex = _currentQueueIndex + 1;
        if (insertIndex < 0) insertIndex = 0;
        if (insertIndex > _queueList.length) {
          insertIndex = _queueList.length;
        }
      } else {
        insertIndex = _queueList.length;
      }

      final queueSong = _queueEntryIds.createSong(song);
      queueSong['isManuallyAdded'] = true;
      _queueList.insert(insertIndex, queueSong);

      if (_currentQueueIndex < 0) {
        _currentQueueIndex = 0;
      }

      _updateQueueMediaItems();
      _cleanupOldPreloadedSongs();

      if (!audioPlayer.playing && _queueList.length == 1) {
        await _playFromQueue(0);
      }
    } catch (e, stackTrace) {
      logger.log('Error adding to queue', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> _insertRecommendedSong(Map song) async {
    try {
      if (song['ytid'] == null || song['ytid'].toString().isEmpty) {
        logger.log('Invalid recommended song data for queue');
        return;
      }

      final insertIndex = _queueList.length;
      final shouldPlayInsertedSong =
          playNextSongAutomatically.value &&
          !sleepTimerExpired &&
          _currentLoadingIndex == -1 &&
          audioPlayer.processingState == ProcessingState.completed &&
          _queueList.isNotEmpty &&
          _currentQueueIndex == _queueList.length - 1;
      final queueSong = _queueEntryIds.createSong(song);
      queueSong['isAutoPicked'] = true;
      _queueList.insert(insertIndex, queueSong);

      if (_currentQueueIndex < 0) {
        _currentQueueIndex = 0;
      }

      _updateQueueMediaItems();
      _cleanupOldPreloadedSongs();

      if (shouldPlayInsertedSong) {
        await _playFromQueue(insertIndex);
      } else if (!audioPlayer.playing && _queueList.length == 1) {
        await _playFromQueue(0);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error inserting recommended song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void _cleanupOldPreloadedSongs() {
    Future.microtask(() async {
      try {
        final queueYtIds = _queueList
            .map((song) => song['ytid']?.toString())
            .where((ytid) => ytid != null)
            .toSet();

        final oldPreloadedSongs = _preloadedYtIds
            .where((ytid) => !queueYtIds.contains(ytid))
            .toList();

        for (final ytid in oldPreloadedSongs) {
          _preloadedYtIds.remove(ytid);
        }

        final stalePreloadingEntries = _preloadingYtIds
            .where((ytid) => !queueYtIds.contains(ytid))
            .toList();

        for (final ytid in stalePreloadingEntries) {
          _preloadingYtIds.remove(ytid);
        }

        if (oldPreloadedSongs.isNotEmpty || stalePreloadingEntries.isNotEmpty) {
          logger.log(
            'Cleaned up ${oldPreloadedSongs.length + stalePreloadingEntries.length} old preload entries',
          );
        }
      } catch (e, stackTrace) {
        logger.log(
          'Error cleaning up preloaded songs',
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> addPlaylistToQueue(
    List<Map> songs, {
    bool replace = false,
    int? startIndex,
    Map? source,
    bool keepManuallyAddedSongs = true,
  }) async {
    try {
      final manuallyAddedSongs = replace && keepManuallyAddedSongs
          ? _getUnplayedManualSongs()
          : <Map>[];
      if (replace) {
        // El origen se fija aqui, antes de que empiece a sonar nada: si se
        // dejaba para despues del await, la marca de "sonando" en listas y
        // carpetas se quedaba un paso por detras.
        nowPlayingSource.value = source;
        _queueList.clear();
        _originalQueueList.clear();
        _currentQueueIndex = 0;
        _currentLoadingIndex = -1;
        _currentLoadingTransitionId = -1;
        _resetPreloadingState();
        shuffleNotifier.value = false;
        unawaited(Hive.box('settings').put('shuffleEnabled', false));
        await audioPlayer.setShuffleModeEnabled(false);
      }

      int? targetQueueIndex;

      for (var i = 0; i < songs.length; i++) {
        final song = songs[i];
        if (song['ytid'] != null && song['ytid'].toString().isNotEmpty) {
          _queueList.add(_queueEntryIds.createSong(song));

          if (replace && startIndex == i) {
            targetQueueIndex = _queueList.length - 1;
          }
        }
      }

      if (replace && manuallyAddedSongs.isNotEmpty) {
        // Always insert after the starting song index
        final insertIndex = (targetQueueIndex ?? 0) + 1;
        final safeInsertIndex = insertIndex > _queueList.length
            ? _queueList.length
            : insertIndex;
        _queueList.insertAll(safeInsertIndex, manuallyAddedSongs);
      }

      _hydrateQueueEntryIds();
      _updateQueueMediaItems();

      if (targetQueueIndex != null) {
        await _playFromQueue(targetQueueIndex);
      } else if (startIndex != null &&
          startIndex < _queueList.length &&
          !replace) {
        await _playFromQueue(startIndex);
      } else if (replace && _queueList.isNotEmpty) {
        await _playFromQueue(0);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error adding playlist to queue',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Removes a queue entry by its stable [queueEntryId] instead of a raw
  /// index, resolving the current real position fresh - safe to call even
  /// if the caller's own copy of the queue could be stale (e.g. a UI list
  /// snapshotted from a stream a moment before).
  Future<void> removeQueueEntry(String queueEntryId) async {
    final index = _queueList.indexWhere(
      (song) => song['queueEntryId']?.toString() == queueEntryId,
    );
    if (index == -1) return;
    await removeFromQueue(index);
  }

  Future<void> removeFromQueue(int index) async {
    try {
      if (index < 0 || index >= _queueList.length) return;

      final removedSong = _queueList[index];
      final removedQueueEntryId = _queueEntryIds.ensureId(removedSong);
      _queueList.removeAt(index);

      if (shuffleNotifier.value && _originalQueueList.isNotEmpty) {
        _originalQueueList.removeWhere(
          (s) => _queueEntryIds.ensureId(s) == removedQueueEntryId,
        );
      }

      if (index == _currentLoadingIndex) {
        _currentLoadingIndex = -1;
        _currentLoadingTransitionId = -1;
      } else if (index < _currentLoadingIndex) {
        _currentLoadingIndex--;
      }

      if (index < _currentQueueIndex) {
        _currentQueueIndex--;
      } else if (index == _currentQueueIndex) {
        if (_queueList.isEmpty) {
          await _stopWithoutClosingApp();
        } else {
          if (_currentQueueIndex >= _queueList.length) {
            _currentQueueIndex = _queueList.length - 1;
          }
          await _playFromQueue(_currentQueueIndex);
        }
      }

      _hydrateQueueEntryIds();
      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log('Error removing from queue', error: e, stackTrace: stackTrace);
    }
  }

  /// Devuelve una cancion a la cola en su sitio: lo usa el "deshacer" del
  /// borrado por deslizamiento.
  Future<void> insertIntoQueue(Map song, int index) async {
    try {
      final target = index.clamp(0, _queueList.length);
      _queueList.insert(target, _queueEntryIds.createSong(song));
      if (target <= _currentQueueIndex) _currentQueueIndex++;
      if (_currentQueueIndex < 0) _currentQueueIndex = 0;

      _hydrateQueueEntryIds();
      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log(
        'Error inserting into queue',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    try {
      _queueEntryIds.ensureIds(_queueList);

      if (oldIndex < 0 ||
          oldIndex >= _queueList.length ||
          newIndex < 0 ||
          newIndex > _queueList.length - 1) {
        return;
      }

      final song = _queueList.removeAt(oldIndex);
      _queueList.insert(newIndex, song);

      if (oldIndex == _currentQueueIndex) {
        _currentQueueIndex = newIndex;
      } else if (oldIndex < _currentQueueIndex &&
          newIndex >= _currentQueueIndex) {
        _currentQueueIndex--;
      } else if (oldIndex > _currentQueueIndex &&
          newIndex <= _currentQueueIndex) {
        _currentQueueIndex++;
      }

      // Also update _currentLoadingIndex if the currently-loading song is being reordered
      if (oldIndex == _currentLoadingIndex) {
        _currentLoadingIndex = newIndex;
      } else if (oldIndex < _currentLoadingIndex &&
          newIndex >= _currentLoadingIndex) {
        _currentLoadingIndex--;
      } else if (oldIndex > _currentLoadingIndex &&
          newIndex <= _currentLoadingIndex) {
        _currentLoadingIndex++;
      }

      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log('Error reordering queue', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> reorderQueueById(String queueEntryId, int targetIndex) async {
    try {
      _queueEntryIds.ensureIds(_queueList);

      final oldIndex = _queueList.indexWhere(
        (s) => _queueEntryIds.ensureId(s) == queueEntryId,
      );
      if (oldIndex == -1) return;

      // Clamp target index to valid range (allow insert at end)
      if (targetIndex < 0) targetIndex = 0;
      if (targetIndex > _queueList.length) targetIndex = _queueList.length;

      final song = _queueList.removeAt(oldIndex);
      var newIndex = targetIndex;
      if (newIndex > _queueList.length) newIndex = _queueList.length;
      _queueList.insert(newIndex, song);

      if (oldIndex == _currentQueueIndex) {
        _currentQueueIndex = newIndex;
      } else if (oldIndex < _currentQueueIndex &&
          newIndex >= _currentQueueIndex) {
        _currentQueueIndex--;
      } else if (oldIndex > _currentQueueIndex &&
          newIndex <= _currentQueueIndex) {
        _currentQueueIndex++;
      }

      if (oldIndex == _currentLoadingIndex) {
        _currentLoadingIndex = newIndex;
      } else if (oldIndex < _currentLoadingIndex &&
          newIndex >= _currentLoadingIndex) {
        _currentLoadingIndex--;
      } else if (oldIndex > _currentLoadingIndex &&
          newIndex <= _currentLoadingIndex) {
        _currentLoadingIndex++;
      }

      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log(
        'Error reordering queue by id',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void clearQueue() {
    try {
      final currentSong =
          _currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length
          ? cloneMap(_queueList[_currentQueueIndex])
          : null;

      _queueList.clear();
      _originalQueueList.clear();

      if (currentSong != null) {
        _queueList.add(currentSong);
        _originalQueueList.add(cloneMap(currentSong));
      }

      _currentQueueIndex = 0;
      _currentLoadingIndex = -1;
      _currentLoadingTransitionId = -1;
      _resetPreloadingState();
      _updateQueueMediaItems();
      _updatePlaybackState();
    } catch (e, stackTrace) {
      logger.log('Error clearing queue', error: e, stackTrace: stackTrace);
    }
  }

  void _updateQueueMediaItems() {
    try {
      _queueEntryIds.ensureIds(_queueList);

      final mediaItems = _buildQueueMediaItems();
      queue.add(mediaItems);

      _queueMapStream.add(List.unmodifiable(_queueList));

      if (_currentQueueIndex < mediaItems.length) {
        final currentMediaItem = mediaItems[_currentQueueIndex];
        mediaItem.add(currentMediaItem);
      }

      _persistQueueState();
    } catch (e, stackTrace) {
      logger.log(
        'Error updating queue media items',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void _emitOptimisticLoadingState({
    Map? song,
    int? queueIndex,
    bool includeMediaItem = false,
    String? mediaId,
  }) {
    try {
      if (includeMediaItem && song != null) {
        var immediateMediaItem = mapToMediaItem(song);
        if (mediaId != null) {
          immediateMediaItem = immediateMediaItem.copyWith(id: mediaId);
        }
        Future.microtask(() {
          mediaItem.add(immediateMediaItem);
        });
      }

      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            MediaControl.pause,
            MediaControl.skipToNext,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
          androidCompactActionIndices: const [0, 1, 2],
          processingState: AudioProcessingState.loading,
          queueIndex:
              queueIndex ??
              (_currentQueueIndex < _queueList.length
                  ? _currentQueueIndex
                  : null),
          updateTime: DateTime.now(),
        ),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Error emitting optimistic loading state',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _playFromQueue(int index) async {
    if (index < 0 || index >= _queueList.length) {
      logger.log('Invalid queue index: $index');
      return;
    }

    // If already loading any song, skip the request
    // UNLESS we're in the middle of handling a completion event (allow one load attempt)
    if (_currentLoadingIndex == index && !_completionEventPending) {
      return;
    }

    if (_currentLoadingIndex >= 0 &&
        _completionEventPending &&
        !_completionHandlerLoadStarted) {
      _completionHandlerLoadStarted = true;
    } else if (_currentLoadingIndex >= 0 &&
        _completionEventPending &&
        _completionHandlerLoadStarted) {
      return;
    }

    // Start new transition
    _songTransitionCounter++;
    final currentTransitionId = _songTransitionCounter;
    _currentLoadingIndex = index;
    _currentLoadingTransitionId = currentTransitionId;

    try {
      final previousQueueIndex = _currentQueueIndex;
      final previousMediaItem = mediaItem.valueOrNull;
      _currentQueueIndex = index;

      final currentSong = _queueList[_currentQueueIndex];
      final currentMediaItem = _getMediaItemForQueue(currentSong);
      final uniqueId = currentMediaItem.id;

      await Future.microtask(() {
        mediaItem.add(currentMediaItem);
      });

      _emitOptimisticLoadingState(
        queueIndex: _currentQueueIndex,
        mediaId: uniqueId,
      );

      final isPodcastEpisode = currentSong['isPodcastEpisode'] == true;
      final success = isPodcastEpisode
          ? await _playPodcastQueueEntry(currentSong)
          : await playSong(
              _queueList[index],
              mediaId: uniqueId,
              transitionId: currentTransitionId,
            );

      // Only process result if this is still the current transition
      if (currentTransitionId == _currentLoadingTransitionId) {
        if (success) {
          _consecutiveErrors = 0;
          // Podcast episodes stream from their own audioUrl and aren't
          // followed by auto-recommended songs, so neither preloading nor
          // background queue growth applies to them.
          if (!isPodcastEpisode) {
            _preloadUpcomingSongs();
            if (playNextSongAutomatically.value) {
              unawaited(_backgroundAddSongsToQueue());
            }
          }
          _persistQueueState();
        } else {
          _currentQueueIndex = previousQueueIndex;
          if (previousMediaItem != null) {
            mediaItem.add(previousMediaItem);
          }
          _updatePlaybackState();
          _handlePlaybackError();
        }
      }
    } catch (e, stackTrace) {
      logger.log('Error playing from queue', error: e, stackTrace: stackTrace);
      _handlePlaybackError();
    } finally {
      // Only reset if this is still the transition that started it
      if (currentTransitionId == _currentLoadingTransitionId) {
        _currentLoadingIndex = -1;
        _currentLoadingTransitionId = -1;
      }
    }
  }

  void _preloadUpcomingSongs() {
    // Don't attempt to preload while offline mode is enabled
    if (offlineMode.value) return;

    Future.microtask(() async {
      try {
        final songsToPreload = <Map>[];

        for (var i = 1; i <= _queueLookahead; i++) {
          final nextIndex = _currentQueueIndex + i;
          if (nextIndex < _queueList.length) {
            final nextSong = _queueList[nextIndex];
            final ytid = nextSong['ytid'];

            // Podcast episodes stream from their own audioUrl, not a
            // fetchSongStreamUrl(ytid) lookup - preloading would just waste a
            // network call against a fake id.
            if (ytid != null &&
                nextSong['isPodcastEpisode'] != true &&
                !isSongAlreadyOffline(ytid) &&
                !_preloadedYtIds.contains(ytid) &&
                !_preloadingYtIds.contains(ytid)) {
              songsToPreload.add(nextSong);
            }
          }
        }

        await _preloadSongsSequentially(songsToPreload);
      } catch (e, stackTrace) {
        logger.log(
          'Error in _preloadUpcomingSongs',
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> _preloadSongsSequentially(List<Map> songsToPreload) async {
    for (final song in songsToPreload) {
      while (_activePreloadCount >= _maxConcurrentPreloads) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final ytid = song['ytid'];
      if (ytid == null || _preloadingYtIds.contains(ytid)) {
        continue;
      }

      unawaited(_preloadSingleSongControlled(song));
    }
  }

  Future<void> _preloadSingleSongControlled(Map nextSong) async {
    final ytid = nextSong['ytid'];
    if (ytid == null) return;

    _preloadingYtIds.add(ytid);
    _activePreloadCount++;
    String? preloadUrl;

    try {
      // Don't attempt to fetch remote streams while offline mode is enabled
      if (offlineMode.value) {
        logger.log('Offline mode enabled; skipping preload for $ytid');
        preloadUrl = null;
      } else {
        // fetchSongStreamUrl handles caching, freshness checks, and validation
        preloadUrl = await fetchSongStreamUrl(ytid, nextSong['isLive'] ?? false)
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                logger.log('Preload timeout for song $ytid');
                return null;
              },
            );
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error preloading song $ytid',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _preloadingYtIds.remove(ytid);
      if (_activePreloadCount > 0) {
        _activePreloadCount--;
      }
      if (preloadUrl != null && preloadUrl.isNotEmpty) {
        _preloadedYtIds.add(ytid);
      }
    }
  }

  Stream<List<Map>> get queueAsMapStream => _queueMapStream.stream;
  int get currentQueueIndex => _currentQueueIndex;
  Map? get currentSong =>
      _currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length
      ? _queueList[_currentQueueIndex]
      : null;

  bool get hasNext => _currentQueueIndex < _queueList.length - 1;

  bool get hasPrevious => _currentQueueIndex > 0 || _historyList.isNotEmpty;

  String _recentMediaId(String ytid) => '$_recentMediaIdPrefix$ytid';

  String? _ytidFromMediaId(String mediaId) {
    if (mediaId.startsWith(_recentMediaIdPrefix)) {
      return mediaId.substring(_recentMediaIdPrefix.length);
    }
    return mediaId.isEmpty ? null : mediaId;
  }

  String? _songYtid(Map song) {
    final ytid = song['ytid']?.toString();
    return ytid == null || ytid.isEmpty ? null : ytid;
  }

  Map? _firstPlayableSong(Iterable songs) {
    for (final song in songs.whereType<Map>()) {
      // A file opened/shared from another app shouldn't be offered back as
      // "what you were playing" on the next cold start - only genuine
      // in-app listening should seed that.
      if (song['externalShare'] == true) continue;
      if (_songYtid(song) != null) {
        return song;
      }
    }
    return null;
  }

  Map? _findSongInList(Iterable songs, String ytid) {
    for (final song in songs.whereType<Map>()) {
      if (_songYtid(song) == ytid) {
        return song;
      }
    }
    return null;
  }

  Map? _findSongByYtid(String? ytid) {
    if (ytid == null || ytid.isEmpty) return null;

    final activeSong = currentSong;
    if (activeSong?['ytid']?.toString() == ytid) {
      return activeSong;
    }

    for (final source in [
      _queueList,
      userRecentlyPlayed.value,
      userOfflineSongs.value,
      userLikedSongsList.value,
    ]) {
      final song = _findSongInList(source, ytid);
      if (song != null) return song;
    }

    return null;
  }

  static const _lastQueueStateKey = 'lastQueueState';
  static const _lastPodcastStateKey = 'lastPodcastState';

  void _persistQueueState() {
    if (!rememberLastPlayback.value) return;
    try {
      final userBox = Hive.box('user');
      if (_queueList.isEmpty) {
        unawaited(
          userBox.delete(_lastQueueStateKey).then((_) => userBox.flush()),
        );
        return;
      }
      // A file opened/shared from another app (see consumeSharedAudioFile)
      // shouldn't overwrite what a cold start remembers as "what you were
      // playing" - leave whatever was persisted before the share untouched.
      if (currentSong?['externalShare'] == true) return;

      // Podcast queues keep their own resume bookkeeping (_persistPodcastState,
      // driven by _currentPlayingPodcast/_persistPodcastPositionIfNeeded) -
      // don't clobber it here, and don't persist podcast entries as the
      // "regular queue" to restore on a cold start.
      // ponytail: a multi-episode podcast queue itself isn't restored across
      // app restarts (only the currently-playing episode+position is, same
      // as before this queue existed) - add if users ask for it.
      if (_queueList[_currentQueueIndex.clamp(
            0,
            _queueList.length - 1,
          )]['isPodcastEpisode'] ==
          true) {
        return;
      }

      // A regular song is now playing, so it - not whatever podcast episode
      // was last playing, if any - is what a cold start should resume.
      _currentPlayingPodcast = null;
      unawaited(userBox.delete(_lastPodcastStateKey));
      // Hive's box.put only writes into an in-memory buffer, flushed to disk
      // lazily (on close or once ~64KB accumulates) - a force-stop/kill -9
      // (unlike backgrounding, which gives the OS a chance to flush) wipes
      // that buffer, silently reverting to whatever index was last flushed.
      // Explicitly flushing after every write keeps the on-disk queue index
      // durable across an abrupt kill.
      unawaited(
        userBox
            .put(_lastQueueStateKey, {
              'queue': cloneMaps(_queueList),
              'index': _currentQueueIndex,
              'originalQueue': cloneMaps(_originalQueueList),
              'savedAt': DateTime.now().millisecondsSinceEpoch,
            })
            .then((_) => userBox.flush()),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Error persisting queue state',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Returns the persisted queue + index from the previous session, or null
  /// if there's nothing usable (never saved, corrupted, or empty).
  ({List<Map> queue, int index, List<Map> originalQueue, int savedAt})?
  _loadPersistedQueueState() {
    try {
      final raw = Hive.box('user').get(_lastQueueStateKey);
      if (raw is! Map) return null;

      final queueRaw = raw['queue'];
      if (queueRaw is! List) return null;
      final queue = queueRaw
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      if (queue.isEmpty) return null;

      var index = raw['index'] is int ? raw['index'] as int : 0;
      if (index < 0 || index >= queue.length) index = 0;

      final originalQueueRaw = raw['originalQueue'];
      final originalQueue = originalQueueRaw is List
          ? originalQueueRaw
                .whereType<Map>()
                .map(Map<String, dynamic>.from)
                .toList()
          : <Map>[];

      final savedAt = raw['savedAt'] is int ? raw['savedAt'] as int : 0;

      return (
        queue: queue,
        index: index,
        originalQueue: originalQueue,
        savedAt: savedAt,
      );
    } catch (e, stackTrace) {
      logger.log(
        'Error loading persisted queue state',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Saves which podcast episode was last playing and at what position, so a
  /// cold start can offer to resume it - mirrors [_persistQueueState] for
  /// podcasts, which bypass _queueList entirely (see [playPodcastEpisode]).
  // Returns a Future (rather than firing the write off unawaited) so that
  // callers racing against a possible process exit - pause(), onTaskRemoved,
  // onNotificationDeleted - can await it and know the position actually
  // reached disk before anything downstream decides to kill the process.
  // The throttled positionStream autosave is the one caller that doesn't
  // need this and stays fire-and-forget.
  Future<void> _persistPodcastState(
    PodcastEpisode episode,
    String podcastTitle,
    String? localPath,
    Duration position,
  ) async {
    if (!rememberLastPlayback.value) return;
    try {
      final userBox = Hive.box('user');
      unawaited(userBox.delete(_lastQueueStateKey));
      await userBox.put(_lastPodcastStateKey, {
        'episode': episode.toMap(),
        'podcastTitle': podcastTitle,
        'localPath': localPath,
        'positionMs': position.inMilliseconds,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await userBox.flush();
    } catch (e, stackTrace) {
      logger.log(
        'Error persisting podcast state',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _persistPodcastPositionIfNeeded(Duration position) {
    final current = _currentPlayingPodcast;
    if (current == null) return Future.value();
    return _persistPodcastState(
      current.episode,
      current.podcastTitle,
      current.localPath,
      position,
    );
  }

  /// Returns the persisted podcast episode + position from the previous
  /// session, or null if there's nothing usable.
  ({
    PodcastEpisode episode,
    String podcastTitle,
    String? localPath,
    Duration position,
    int savedAt,
  })?
  _loadPersistedPodcastState() {
    try {
      final raw = Hive.box('user').get(_lastPodcastStateKey);
      if (raw is! Map) return null;

      final episodeRaw = raw['episode'];
      if (episodeRaw is! Map) return null;
      final episode = PodcastEpisode.fromMap(
        Map<String, dynamic>.from(episodeRaw),
      );

      final positionMs = raw['positionMs'] is int
          ? raw['positionMs'] as int
          : 0;
      final savedAt = raw['savedAt'] is int ? raw['savedAt'] as int : 0;

      return (
        episode: episode,
        podcastTitle: raw['podcastTitle']?.toString() ?? episode.title,
        localPath: raw['localPath']?.toString(),
        position: Duration(milliseconds: positionMs),
        savedAt: savedAt,
      );
    } catch (e, stackTrace) {
      logger.log(
        'Error loading persisted podcast state',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Returns [_pendingPodcastResume], falling back to a fresh read of the
  /// persisted podcast state - a plain `??` between the two doesn't type
  /// check, since _loadPersistedPodcastState()'s record also carries a
  /// `savedAt` field _pendingPodcastResume doesn't.
  ({
    PodcastEpisode episode,
    String podcastTitle,
    String? localPath,
    Duration position,
  })?
  _resolvePendingPodcast() {
    final pending = _pendingPodcastResume;
    if (pending != null) return pending;
    final persisted = _loadPersistedPodcastState();
    if (persisted == null) return null;
    return (
      episode: persisted.episode,
      podcastTitle: persisted.podcastTitle,
      localPath: persisted.localPath,
      position: persisted.position,
    );
  }

  Map? _latestResumableSong() {
    if (!rememberLastPlayback.value) return null;

    // Checked before anything else, mirroring play()'s priority: a podcast
    // episode never lives in _queueList/mediaItem on a cold start until
    // _restoreLastPlayedForDisplay() has run, so without this a caller that
    // races that (e.g. the system media-resumption query that fires right
    // after a Bluetooth play press restarts the process) falls through to
    // the last regular song instead - resuming the wrong thing entirely.
    final pendingPodcast = _resolvePendingPodcast();
    if (pendingPodcast != null) {
      final durationSeconds = pendingPodcast.episode.durationSeconds;
      final isNearEnd =
          durationSeconds != null &&
          Duration(seconds: durationSeconds) - pendingPodcast.position <=
              _podcastNearEndThreshold;
      if (!isNearEnd) {
        return _buildEpisodeSong(
          pendingPodcast.episode,
          pendingPodcast.podcastTitle,
          pendingPodcast.localPath,
        );
      }
    }

    final activeSong = currentSong;
    if (activeSong != null && _songYtid(activeSong) != null) {
      return activeSong;
    }

    final activeMediaItem = mediaItem.valueOrNull;
    final activeYtid = activeMediaItem?.extras?['ytid']?.toString();
    final activeMediaSong = _findSongByYtid(activeYtid);
    if (activeMediaSong != null) return activeMediaSong;
    if (activeYtid != null &&
        activeYtid.isNotEmpty &&
        activeMediaItem != null) {
      return mediaItemToMap(activeMediaItem);
    }

    final persisted = _loadPersistedQueueState();
    if (persisted != null) return persisted.queue[persisted.index];

    return _firstPlayableSong(userRecentlyPlayed.value) ??
        _firstPlayableSong(userOfflineSongs.value) ??
        _firstPlayableSong(userLikedSongsList.value);
  }

  Map<String, dynamic>? _normaliseResumableSong(Map song) {
    final ytid = _songYtid(song);
    if (ytid == null) return null;

    final normalised = cloneMap(song);
    normalised['id'] = ytid;
    normalised['ytid'] = ytid;
    normalised['highResImage'] ??=
        normalised['image'] ?? normalised['lowResImage'] ?? '';
    normalised['lowResImage'] ??= normalised['highResImage'];
    normalised['isLive'] ??= false;
    return normalised;
  }

  MediaItem? _mediaItemForResumption(Map song) {
    final normalisedSong = _normaliseResumableSong(song);
    if (normalisedSong == null) return null;

    final ytid = normalisedSong['ytid'].toString();
    final artist = normalisedSong['artist']?.toString().trim() ?? '';
    return mapToMediaItem(normalisedSong).copyWith(
      id: _recentMediaId(ytid),
      displayTitle: normalisedSong['title']?.toString(),
      displaySubtitle: artist.isEmpty ? 'DSK Play' : artist,
    );
  }

  Future<void> _playResumableSong(Map song) async {
    // A podcast episode Map from _latestResumableSong() - route it through
    // the podcast resume path instead of playPlaylistSong, which would treat
    // its ytid as a YouTube video id and fail to play it.
    if (song['isPodcastEpisode'] == true) {
      _pendingPodcastResume ??= _resolvePendingPodcast();
      await resumePendingPodcast();
      return;
    }

    final normalisedSong = _normaliseResumableSong(song);
    if (normalisedSong == null) return;

    final persisted = _loadPersistedQueueState();
    if (persisted != null &&
        _songYtid(persisted.queue[persisted.index]) == normalisedSong['ytid']) {
      await playPlaylistSong(
        playlist: {
          'title': 'DSK Play',
          'source': 'system-recent',
          'list': persisted.queue,
        },
        songIndex: persisted.index,
        keepManuallyAddedSongs: false,
      );
      if (persisted.originalQueue.isNotEmpty) {
        _originalQueueList
          ..clear()
          ..addAll(persisted.originalQueue);
      }
      return;
    }

    await playPlaylistSong(
      playlist: {
        'title': 'DSK Play',
        'source': 'system-recent',
        'list': [normalisedSong],
      },
      songIndex: 0,
    );
  }

  static const _rootLiked = 'liked_songs';
  static const _rootOffline = 'offline_songs';
  static const _rootRecent = 'recently_played';
  static const _rootQueue = 'current_queue';

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == AudioService.recentRootId) {
      final recentSong = _latestResumableSong();
      final recentItem = recentSong == null
          ? null
          : _mediaItemForResumption(recentSong);
      return recentItem == null ? [] : [recentItem];
    }

    if (parentMediaId == AudioService.browsableRootId) {
      return [
        const MediaItem(
          id: _rootQueue,
          title: 'Now Playing Queue',
          playable: false,
          extras: {'isBrowsable': true},
        ),
        const MediaItem(
          id: _rootLiked,
          title: 'Liked Songs',
          playable: false,
          extras: {'isBrowsable': true},
        ),
        const MediaItem(
          id: _rootOffline,
          title: 'Downloaded',
          playable: false,
          extras: {'isBrowsable': true},
        ),
        const MediaItem(
          id: _rootRecent,
          title: 'Recently Played',
          playable: false,
          extras: {'isBrowsable': true},
        ),
      ];
    }

    switch (parentMediaId) {
      case _rootQueue:
        return _queueList.map(_getMediaItemForQueue).toList();
      case _rootLiked:
        return userLikedSongsList.value
            .whereType<Map>()
            .map((s) => mapToMediaItem(s).copyWith(playable: true))
            .toList();
      case _rootOffline:
        return userOfflineSongs.value
            .whereType<Map>()
            .map((s) => mapToMediaItem(s).copyWith(playable: true))
            .toList();
      case _rootRecent:
        return userRecentlyPlayed.value
            .whereType<Map>()
            .map((s) => mapToMediaItem(s).copyWith(playable: true))
            .toList();
      default:
        return [];
    }
  }

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (query.trim().isEmpty) {
      // "Play music" with no specifics
      if (_queueList.isNotEmpty) {
        await play();
        return;
      }
      final recentSong = _latestResumableSong();
      if (recentSong != null) await _playResumableSong(recentSong);
      return;
    }

    final q = query.toLowerCase();
    final candidates = [
      ..._queueList,
      ...userLikedSongsList.value.whereType<Map>(),
      ...userOfflineSongs.value.whereType<Map>(),
      ...userRecentlyPlayed.value.whereType<Map>(),
    ];

    final match = candidates.firstWhere((s) {
      final title = s['title']?.toString().toLowerCase() ?? '';
      final artist = s['artist']?.toString().toLowerCase() ?? '';
      return title.contains(q) || artist.contains(q);
    }, orElse: () => const {});

    if (match.isNotEmpty) {
      await _playResumableSong(match);
    } else {
      logger.log('playFromSearch: no local match for "$query"');
    }
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final song = _findSongByYtid(_ytidFromMediaId(mediaId));
    return song == null ? null : _mediaItemForResumption(song);
  }

  @override
  Future<void> prepareFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final item = await getMediaItem(mediaId);
    if (item == null) return;

    mediaItem.add(item);
    queue.add([item]);
    playbackState.add(
      PlaybackState(
        controls: _controls(false),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        queueIndex: 0,
        updateTime: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final song = _findSongByYtid(_ytidFromMediaId(mediaId));
    if (song == null) {
      logger.log('No resumable song found for media id: $mediaId');
      return;
    }
    await _playResumableSong(song);
  }

  @override
  Future<void> onTaskRemoved() async {
    try {
      // Swiping the app away from recents shouldn't cut off playback that's
      // actually in progress - the foreground service + notification are
      // already set up to keep running (androidStopForegroundOnPause:
      // false), matching how other music players behave. Only stop (and
      // release the audio session) when there's nothing playing anyway.
      if (audioPlayer.playing) {
        // The process may later die without ever calling pause()/stop() (OS
        // kills the backgrounded task), leaving the podcast resume position
        // stuck at whatever the throttled positionStream last saved (up to
        // 5s stale) - persist the exact position now, at the last reliable
        // checkpoint before that can happen. Awaited so the process can't
        // be killed (see _exitIfIdle below) before it lands.
        await _persistPodcastPositionIfNeeded(audioPlayer.position);
        return;
      }
      await stop();
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e, stackTrace) {
      logger.log('Error in onTaskRemoved', error: e, stackTrace: stackTrace);
    }
    await super.onTaskRemoved();

    // Nothing playing and no download (individual or batch) in flight -
    // there's no reason to keep the process alive draining battery in the
    // background, so kill it outright instead of leaving it idling in the
    // OS's recent-process cache.
    unawaited(_exitIfIdle());
  }

  // Nothing playing and no download (individual or batch) in flight - no
  // reason to keep the process alive draining battery in the background.
  // Called after anything that stops playback outright rather than just
  // pausing it: the app being swiped away, the notification being
  // dismissed, the sleep timer expiring, or a podcast episode finishing
  // on its own with nothing queued after it.
  Future<void> _exitIfIdle({bool forceStopped = false}) async {
    logger.log(
      'exitIfIdle called '
      '(playing=${audioPlayer.playing}, forceStopped=$forceStopped, '
      'downloadActive=${DownloadForegroundService.isActive})',
    );
    // [forceStopped] skips the (possibly stale) audioPlayer.playing check:
    // just_audio's stop() has been observed to hang without ever flipping
    // that flag back to false (see the timeout comment in stop() below),
    // which used to leave this check reading "still playing" forever and
    // the process alive in the background after the notification/lock-
    // screen "X" was pressed - the caller there already knows a stop was
    // just explicitly requested, so it doesn't need re-confirming here.
    if ((forceStopped || !audioPlayer.playing) &&
        !DownloadForegroundService.isActive) {
      // audio_service can tear down this background FlutterEngine (killing
      // this very isolate) at any point past here - e.g. right after
      // super.stop() as part of the service shutting itself down - which
      // used to silently strand exit(0) below and leave the process alive
      // indefinitely. This native watchdog survives that teardown and
      // guarantees the kill happens regardless.
      _scheduleNativeHardExit();
      // Best-effort only, deliberately NOT awaited: this used to block
      // exit(0) below behind an 8s network round trip, which was exactly
      // the window in which the engine teardown above could strand this
      // whole function before ever reaching exit(0), leaving the process
      // alive with nothing left to kill it. A slow/dead network should
      // delay the kill by exactly zero seconds now; if this finishes before
      // the process actually dies, the backup still goes out, and if not,
      // main.dart's lifecycle listener already fires the same upload
      // earlier, as soon as the app leaves the foreground.
      unawaited(
        cloudBackupService.uploadBackup().timeout(
          const Duration(seconds: 8),
          onTimeout: () => false,
        ),
      );
      // Recently-played/podcast-state writes just above (and elsewhere) are
      // fired off with unawaited() and normally finish within milliseconds -
      // but exit(0) can land before that write ever reaches disk if it's
      // called this soon after (e.g. pause immediately followed by swiping
      // the task away), silently dropping it. flush() waits for every
      // pending write on the box to actually commit.
      try {
        await Hive.box('user').flush();
      } catch (_) {}
      logger.log('exitIfIdle: calling exit(0) now');
      exit(0);
    }
  }

  /// Arms (or re-arms) the configurable "close after N minutes idle" timer
  /// - a value of 0 disables it (user chose "never"). Idle means not
  /// playing; a download in flight still blocks the actual exit (see
  /// [_exitIfIdle]), in which case this just checks again later instead of
  /// giving up, so the process still closes once the download finishes.
  void _scheduleIdleAutoClose() {
    _idleAutoCloseTimer?.cancel();
    final minutes = autoCloseAfterPauseMinutes.value;
    if (minutes <= 0) {
      _cancelNativeIdleClose();
      return;
    }
    logger.log('Idle auto-close armed for $minutes min');
    if (!_isAppInForeground && !DownloadForegroundService.isActive) {
      _armNativeIdleClose(minutes);
    }
    _idleAutoCloseTimer = Timer(Duration(minutes: minutes), () {
      logger.log(
        'Idle auto-close timer fired '
        '(playing=${audioPlayer.playing}, '
        'downloadActive=${DownloadForegroundService.isActive})',
      );
      if (audioPlayer.playing) return;
      if (DownloadForegroundService.isActive) {
        _scheduleIdleAutoClose();
        return;
      }
      unawaited(_exitIfIdle());
    });
  }

  @override
  Future<void> onNotificationDeleted() async {
    try {
      if (audioPlayer.playing) {
        await _persistPodcastPositionIfNeeded(audioPlayer.position);
        return;
      }
      await stop();
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e, stackTrace) {
      logger.log(
        'Error in onNotificationDeleted',
        error: e,
        stackTrace: stackTrace,
      );
    }

    unawaited(_exitIfIdle());
  }

  /// Starts the podcast episode restored from a cold start. Called by default
  /// (headless triggers - notification, lock screen, media button, Android
  /// Auto) from [play] itself, which always resumes; the in-app play button
  /// instead asks the user first and passes [fromStart] true for "start
  /// over", skipping the seek back to the saved position.
  Future<void> resumePendingPodcast({bool fromStart = false}) async {
    final pendingPodcast = _pendingPodcastResume;
    if (pendingPodcast == null) return;
    _pendingPodcastResume = null;
    await playPodcastEpisode(
      pendingPodcast.episode,
      podcastTitle: pendingPodcast.podcastTitle,
      localPath: pendingPodcast.localPath,
      initialPosition: (!fromStart && pendingPodcast.position > Duration.zero)
          ? pendingPodcast.position
          : null,
    );
  }

  @override
  Future<void> play() async {
    try {
      if (castService.isCasting) {
        await castService.play();
        listeningStatsService.resumeListeningSession(currentSong: currentSong);
        _updatePlaybackState();
        return;
      }
      if (audioPlayer.audioSource == null) {
        if (_pendingPodcastResume != null) {
          await resumePendingPodcast();
          return;
        }

        final recentSong = _latestResumableSong();
        if (recentSong != null) {
          await _playResumableSong(recentSong);
          return;
        }
      }
      // Do NOT await play(): its future only completes when playback pauses/
      // stops/finishes (just_audio semantics), which would defer the resume
      // below until the song ended - losing the whole session.
      unawaited(
        audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
          logger.log(
            'Error starting playback',
            error: e,
            stackTrace: stackTrace,
          );
          _lastError = e.toString();
        }),
      );
      listeningStatsService.resumeListeningSession(currentSong: currentSong);
    } catch (e, stackTrace) {
      logger.log('Error in play()', error: e, stackTrace: stackTrace);
      _lastError = e.toString();
    }
  }

  @override
  Future<void> pause() async {
    try {
      if (castService.isCasting) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: castService.remotePlaying,
        );
        unawaited(listeningStatsService.flush());
        await castService.pause();
        await _persistPodcastPositionIfNeeded(
          castService.lastPosition.position,
        );
        _updatePlaybackState();
        return;
      }
      listeningStatsService.recordListeningSessionProgress(
        wasPlaying: audioPlayer.playing,
      );
      unawaited(listeningStatsService.flush());
      await audioPlayer.pause();
      // Awaited: a Bluetooth/notification pause can be followed almost
      // immediately by the app being swiped away and the process exiting -
      // this must land on disk before that can happen.
      await _persistPodcastPositionIfNeeded(audioPlayer.position);
    } catch (e, stackTrace) {
      logger.log('Error in pause()', error: e, stackTrace: stackTrace);
    }
  }

  @override
  Future<void> stop() async {
    // Snapshotted before any await below: _keepAppOpenOnStop is a single
    // shared flag set by _stopWithoutClosingApp for the duration of its own
    // call to this method, but if that call is still in flight (e.g. stuck
    // on a hung await further down) when a second, unrelated stop() comes in
    // - the notification/lock-screen "X", the sleep timer, a song finishing
    // - reading the shared flag fresh at the bottom would let the first
    // caller's intent leak into this one. Each invocation now acts strictly
    // on the intent that was current when it started.
    final keepAppOpen = _keepAppOpenOnStop;
    // Parar es parar del todo: la tele se queda libre en vez de con la ultima
    // cancion congelada en pantalla.
    if (castService.isCasting) await castService.disconnect();
    _debounceTimer?.cancel();
    _idleAutoCloseTimer?.cancel();
    _completionEventPending = false;
    _currentLoadingIndex = -1;
    _currentLoadingTransitionId = -1;
    _lastError = null;
    _consecutiveErrors = 0;
    try {
      listeningStatsService.finishListeningSession(
        countCurrentTick: true,
        wasPlaying: audioPlayer.playing,
      );
      // Bounded: just_audio's stop() has been observed to hang instead of
      // completing when called on an already-paused player, which used to
      // leave the notification/lock-screen "X" stuck doing nothing - fall
      // through to closing the app below regardless.
      await audioPlayer.stop().timeout(const Duration(seconds: 3));
      _resetPreloadingState();
    } catch (e, stackTrace) {
      logger.log('Error in stop()', error: e, stackTrace: stackTrace);
    }
    try {
      // Also bounded, for the same reason as audioPlayer.stop() above: if
      // this hangs instead, _stopWithoutClosingApp's finally block (which
      // resets _keepAppOpenOnStop back to false) would never run either,
      // silently disabling the app-closing path below for every stop() call
      // for the rest of the process's life.
      await super.stop().timeout(const Duration(seconds: 3));
    } catch (e, stackTrace) {
      logger.log('Error in super.stop()', error: e, stackTrace: stackTrace);
    }

    // Nothing left to play - free the idle process instead of leaving it
    // running in the background, unless this stop was just an in-app
    // action that should leave the app open (see _keepAppOpenOnStop).
    if (!keepAppOpen) {
      unawaited(_exitIfIdle(forceStopped: true));
    } else {
      // Staying open on purpose, but still idle now - arm the idle-close
      // timer so it isn't left running forever with nothing playing.
      _scheduleIdleAutoClose();
    }
  }

  /// Stops playback without triggering the auto-exit that a plain [stop]
  /// now does - for in-app callers that just want to halt playback and keep
  /// the app open (as opposed to the sleep timer, queue running out, or the
  /// notification/lock-screen stop button, which mean the app should close).
  Future<void> _stopWithoutClosingApp() async {
    _keepAppOpenOnStop = true;
    try {
      await stop();
    } finally {
      _keepAppOpenOnStop = false;
    }
  }

  /// Stops playback and clears the current song/queue entirely, so the mini
  /// player and full player act as if nothing had ever played - unlike
  /// [stop] alone, which leaves `mediaItem`/`queue` populated with the last
  /// track (by design, so a plain pause/stop can resume where it left off).
  Future<void> stopAndClearNowPlaying() async {
    await _stopWithoutClosingApp();
    _queueList.clear();
    _originalQueueList.clear();
    _currentQueueIndex = 0;
    queue.add([]);
    mediaItem.add(null);
    _pendingPodcastResume = null;
    _currentPlayingPodcast = null;
    // Detener y cerrar deja la app como si no hubiera sonado nada: fuera
    // tambien las marcas de "sonando" de canciones, listas, carpetas y
    // ficheros locales.
    nowPlayingYtid.value = null;
    nowPlayingSource.value = null;
    // Awaited (unlike the fire-and-forget pattern elsewhere in this file):
    // this is a deliberate, final user action, and a common follow-up is
    // closing/killing the app right away - a pending unawaited write can
    // lose the race against process death, leaving the stale queue on disk
    // for the mini player to restore on the next cold start.
    final userBox = Hive.box('user');
    await Future.wait([
      userBox.delete(_lastQueueStateKey),
      userBox.delete(_lastPodcastStateKey),
      userBox.delete('nowPlayingSource'),
    ]);
    await userBox.flush();
  }

  /// Returns unplayed manually added songs after the current queue index.
  List<Map> _getUnplayedManualSongs() {
    return _queueList
        .skip(_currentQueueIndex >= 0 ? _currentQueueIndex + 1 : 0)
        .where(
          (song) =>
              song['isManuallyAdded'] == true && song['isAutoPicked'] != true,
        )
        .toList();
  }

  void _resetPreloadingState() {
    _activePreloadCount = 0;
    _preloadingYtIds.clear();
    _preloadedYtIds.clear();
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      if (castService.isCasting) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: castService.remotePlaying,
        );
        await castService.seek(position);
        unawaited(listeningStatsService.flush());
        _updatePlaybackState();
        return;
      }
      listeningStatsService.recordListeningSessionProgress(
        wasPlaying: audioPlayer.playing,
      );
      await audioPlayer.seek(position);
      unawaited(listeningStatsService.flush());
    } catch (e, stackTrace) {
      logger.log('Error in seek()', error: e, stackTrace: stackTrace);
    }
  }

  @override
  Future<void> fastForward() {
    if (castService.isCasting) {
      final remote = castService.lastPosition;
      final target = remote.position + const Duration(seconds: 15);
      return seek(target > remote.duration ? remote.duration : target);
    }
    final target = audioPlayer.position + const Duration(seconds: 15);
    final trackDuration = audioPlayer.duration;
    final clamped = (trackDuration != null && target > trackDuration)
        ? trackDuration
        : target;
    return seek(clamped);
  }

  @override
  Future<void> rewind() {
    if (castService.isCasting) {
      final target =
          castService.lastPosition.position - const Duration(seconds: 15);
      return seek(target < Duration.zero ? Duration.zero : target);
    }
    final target = audioPlayer.position - const Duration(seconds: 15);
    final clamped = target < Duration.zero ? Duration.zero : target;
    return seek(clamped);
  }

  Future<bool> _resolveOfflineAndSetPaths(Map songData) async {
    try {
      final ytid = songData['ytid']?.toString();
      if (ytid != null && ytid.isNotEmpty) {
        final offlineSong = getOfflineSongByYtid(ytid);
        if (offlineSong.isNotEmpty) {
          final audioPath = offlineSong['audioPath']?.toString();
          if (audioPath != null && audioPath.isNotEmpty) {
            final f = File(audioPath);
            if (await f.exists()) {
              songData['audioPath'] = audioPath;
              if (offlineSong['artworkPath'] != null) {
                songData['artworkPath'] = offlineSong['artworkPath'];
              }
              return true;
            }
          }
        }
      }
    } catch (e, st) {
      logger.log(
        'Error while checking offline songs',
        error: e,
        stackTrace: st,
      );
    }

    // Fallback: prefer an existing local `audioPath` on the passed song
    // object if the file exists.
    try {
      final path = songData['audioPath']?.toString();
      if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (await f.exists()) return true;
      }
    } catch (_) {}

    return false;
  }

  /// Check if the given transitionId is stale (outdated by a newer request).
  bool _isStaleTransition(int? transitionId) {
    return transitionId != null && transitionId != _currentLoadingTransitionId;
  }

  Future<bool> playSong(Map song, {String? mediaId, int? transitionId}) async {
    try {
      final songData = cloneMap(song);

      if (songData['ytid'] == null || songData['ytid'].toString().isEmpty) {
        logger.log('Invalid song data: missing ytid');
        return false;
      }

      _lastError = null;
      if (audioPlayer.playing) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: audioPlayer.playing,
        );
        await audioPlayer.pause();
      }

      final playback = await _resolvePlaybackSource(songData);

      // Abort if a newer song was requested while we were fetching the stream URL.
      // This is the primary guard against the race condition where a slow streaming
      // load overrides a song the user already switched to.
      if (_isStaleTransition(transitionId)) {
        logger.log(
          'Song load superseded by newer request, aborting: ${songData['ytid']}',
        );
        return false;
      }

      if (playback == null) {
        _lastError = 'Failed to get song URL';
        return false;
      }

      _emitOptimisticLoadingState(
        song: songData,
        includeMediaItem: true,
        mediaId: mediaId,
      );

      final audioSource = await buildAudioSource(
        songData,
        playback.songUrl,
        playback.isOffline,
      );

      // Check again after building the audio source (SponsorBlock fetch can also be slow).
      if (_isStaleTransition(transitionId)) {
        logger.log(
          'Song load superseded after building audio source, aborting: ${songData['ytid']}',
        );
        return false;
      }

      if (audioSource == null) {
        logger.log('Failed to build audio source for ${songData['ytid']}');
        _lastError = 'Failed to build audio source';
        return false;
      }

      return await _setAudioSourceAndPlay(
        songData,
        audioSource,
        playback.songUrl,
        playback.isOffline,
        mediaId: mediaId,
        transitionId: transitionId,
      );
    } catch (e, stackTrace) {
      logger.log('Error playing song', error: e, stackTrace: stackTrace);
      _lastError = e.toString();
      return false;
    }
  }

  Future<_PlaybackSource?> _resolvePlaybackSource(Map songData) async {
    final isOffline = await _resolveOfflineAndSetPaths(songData);
    final songUrl = await _getPlaybackUrl(songData, isOffline);

    if (songUrl == null || songUrl.isEmpty) {
      if (!isOffline) {
        logger.log('Failed to get song URL for ${songData['ytid']}');
        return null;
      }

      // If offline mode is enabled, do NOT fall back to online streams.
      // This prevents network requests while the user explicitly requested
      // offline-only operation.
      try {
        if (offlineMode.value) {
          logger.log(
            'Offline mode enabled and offline file missing for ${songData['ytid']}. Not falling back to online.',
          );
          return null;
        }
      } catch (_) {
        // If offlineMode isn't available for some reason, continue with fallback.
      }

      logger.log(
        'Offline file missing for ${songData['ytid']}, switching to online',
      );

      final onlineUrl = await fetchSongStreamUrl(
        songData['ytid'],
        songData['isLive'] ?? false,
      );

      if (onlineUrl == null || onlineUrl.isEmpty) {
        logger.log('Failed to get song URL for ${songData['ytid']}');
        return null;
      }

      return _PlaybackSource(songUrl: onlineUrl, isOffline: false);
    }

    return _PlaybackSource(songUrl: songUrl, isOffline: isOffline);
  }

  Future<String?> _getPlaybackUrl(Map song, bool isOffline) async {
    if (isOffline) {
      return _getOfflineSongUrl(song);
    }

    return fetchSongStreamUrl(song['ytid'], song['isLive'] ?? false);
  }

  Future<String?> _getOfflineSongUrl(Map song) async {
    final audioPath = song['audioPath'];
    if (audioPath == null || audioPath.isEmpty) {
      logger.log('Missing audioPath for offline song: ${song['ytid']}');
      return null;
    }

    final file = File(audioPath);
    if (await file.exists()) {
      return audioPath;
    }

    logger.log('Offline audio file not found: $audioPath');

    final offlineSong = userOfflineSongs.value.firstWhere(
      (s) => s['ytid'] == song['ytid'],
      orElse: () => <String, dynamic>{},
    );

    if (offlineSong.isNotEmpty && offlineSong['audioPath'] != null) {
      final fallbackPath = offlineSong['audioPath'];
      final fallbackFile = File(fallbackPath);
      if (await fallbackFile.exists()) {
        song['audioPath'] = fallbackPath;
        return fallbackPath;
      }
    }

    return null;
  }

  Future<bool> _setAudioSourceAndPlay(
    Map song,
    AudioSource audioSource,
    String songUrl,
    bool isOffline, {
    String? mediaId,
    bool allowOnlineRetry = true,
    int? transitionId,
  }) async {
    try {
      // Final staleness check before we touch the audio player.
      // If another song was requested between the URL fetch and here, abort.
      if (_isStaleTransition(transitionId)) {
        return false;
      }

      // Sonando en una tele, quien reproduce es ella: la cola, el orden y el
      // paso a la siguiente siguen siendo exactamente los de arriba.
      if (castService.isCasting) {
        return _castPlayResolved(
          song,
          songUrl,
          isOffline,
          transitionId: transitionId,
        );
      }

      // Snapshot the pre-swap playing state now: by the time we're committed
      // to this transition (below), audioPlayer.playing reflects the new
      // source, not whatever session we're about to finish.
      final wasPlayingBeforeSwap = audioPlayer.playing;

      _lastResolvedSource = (url: songUrl, isOffline: isOffline, isLive: false);

      await audioPlayer
          .setAudioSource(audioSource)
          .timeout(_songTransitionTimeout);

      // Check once more after the async setAudioSource: a fast offline song
      // could have loaded and started playing while we were buffering/setting up.
      // If so, stop the source we just loaded and yield to the newer song.
      if (_isStaleTransition(transitionId)) {
        unawaited(audioPlayer.stop());
        return false;
      }

      if (audioPlayer.duration != null) {
        _updateCurrentMediaItemWithDuration(audioPlayer.duration!);
      }

      // Finish the old session and start the new one as one atomic pair, only
      // after every abort path above is cleared. Finishing before the staleness
      // re-check let a stale transition kill a newer transition's session.
      // Do this before awaiting play() so Wrapped starts counting from the
      // first moments of the new track, not after the async handoff.
      listeningStatsService
        ..finishListeningSession(
          countCurrentTick: true,
          wasPlaying: wasPlayingBeforeSwap,
        )
        ..startListeningSession(song, duration: audioPlayer.duration);
      await audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
        logger.log('Error starting playback', error: e, stackTrace: stackTrace);
        _lastError = e.toString();
      });
      unawaited(updateRecentlyPlayed(song['ytid'], songFallback: song));

      if (!isOffline) {
        final cacheKey =
            'song_${song['ytid']}_${audioQualitySetting.value}_url';
        unawaited(addOrUpdateData<String>('cache', cacheKey, songUrl));
      }

      _updatePlaybackState();

      Future.delayed(const Duration(seconds: 2), _preloadUpcomingSongs);

      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error setting audio source',
        error: e,
        stackTrace: stackTrace,
      );

      if (isOffline) {
        // If offline mode is explicitly enabled, do not attempt any online
        // fallback — respect the user's offline-only preference.
        try {
          if (offlineMode.value) {
            return false;
          }
        } catch (_) {
          // If offlineMode isn't accessible, fallthrough to attempt fallback.
        }

        return _attemptOfflineFallback(
          song,
          mediaId: mediaId,
          transitionId: transitionId,
        );
      }

      if (allowOnlineRetry) {
        if (offlineMode.value) {
          _lastError = e.toString();
          return false;
        }
        final songId = song['ytid']?.toString();
        if (songId != null && songId.isNotEmpty) {
          final cacheKey = 'song_${songId}_${audioQualitySetting.value}_url';
          await deleteData('cache', cacheKey);

          final refreshedUrl = await fetchSongStreamUrl(
            songId,
            song['isLive'] ?? false,
          );

          if (refreshedUrl != null && refreshedUrl.isNotEmpty) {
            final refreshedSource = await buildAudioSource(
              song,
              refreshedUrl,
              false,
            );

            if (refreshedSource != null) {
              return _setAudioSourceAndPlay(
                song,
                refreshedSource,
                refreshedUrl,
                false,
                mediaId: mediaId,
                allowOnlineRetry: false,
                transitionId: transitionId,
              );
            }
          }
        }
      }

      _lastError = e.toString();
      return false;
    }
  }

  Future<bool> _attemptOfflineFallback(
    Map song, {
    String? mediaId,
    int? transitionId,
  }) async {
    // Do not attempt any network calls when offline mode is enabled.
    if (offlineMode.value) return false;

    final onlineUrl = await fetchSongStreamUrl(
      song['ytid'],
      song['isLive'] ?? false,
    );
    if (onlineUrl != null && onlineUrl.isNotEmpty) {
      final onlineSource = await buildAudioSource(song, onlineUrl, false);
      if (onlineSource != null) {
        return _setAudioSourceAndPlay(
          song,
          onlineSource,
          onlineUrl,
          false,
          mediaId: mediaId,
          transitionId: transitionId,
        );
      }
    }
    return false;
  }

  Future<void> playNext(Map song) async {
    await addToQueue(song, playNext: true);
  }

  Future<void> playPlaylistSong({
    Map<dynamic, dynamic>? playlist,
    required int songIndex,
    bool keepManuallyAddedSongs = true,
  }) async {
    try {
      if (playlist != null && playlist['list'] != null) {
        await addPlaylistToQueue(
          List<Map>.from(playlist['list']),
          replace: true,
          startIndex: songIndex,
          keepManuallyAddedSongs: keepManuallyAddedSongs,
          source: {
            'ytid': playlist['ytid'],
            'title': playlist['title'],
            'source': playlist['source'],
            'isAlbum': playlist['isAlbum'],
            'isArtist': playlist['isArtist'],
            if (playlist['route'] != null) 'route': playlist['route'],
          },
        );
      }
    } catch (e, stackTrace) {
      logger.log('Error playing playlist', error: e, stackTrace: stackTrace);
    }
  }

  /// Play a radio stream directly without queue management
  Future<bool> playRadioStream({
    required String id,
    required String name,
    required String streamUrl,
    required String image,
    String? genre,
  }) async {
    try {
      // Create a song-like map for the radio stream
      final radioSong = {
        'id': id,
        'ytid': id, // Use radio ID as ytid for compatibility
        'title': name,
        'artist': genre ?? 'Radio Station',
        'album': 'Live Stream',
        'highResImage': image,
        'lowResImage': image,
        'duration': null, // Radio streams are live
        'isLive': true,
      };
      // A different source is now playing - stop the throttled position
      // listener from overwriting the podcast episode's saved resume point.
      _currentPlayingPodcast = null;
      nowPlayingSource.value = null;

      _lastError = null;
      if (audioPlayer.playing) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: audioPlayer.playing,
        );
        await audioPlayer.pause();
      }

      // Update media item and queue for mini player visibility
      final mediaItem = mapToMediaItem(radioSong);
      this.mediaItem.add(mediaItem);
      queue.add([mediaItem]);

      if (castService.isCasting) {
        return _castPlayResolved(radioSong, streamUrl, false, isLive: true);
      }

      _lastResolvedSource = (url: streamUrl, isOffline: false, isLive: true);

      // Build audio source from stream URL
      final audioSource = await buildAudioSource(
        radioSong,
        streamUrl,
        false, // Radio streams are always online
      );

      if (audioSource == null) {
        logger.log('Failed to build audio source for radio stream: $id');
        _lastError = 'Failed to load radio stream';
        return false;
      }

      // Play the radio stream
      final wasPlayingBeforeSwap = audioPlayer.playing;

      await audioPlayer
          .setAudioSource(audioSource)
          .timeout(_songTransitionTimeout);

      listeningStatsService
        ..finishListeningSession(
          countCurrentTick: true,
          wasPlaying: wasPlayingBeforeSwap,
        )
        ..startListeningSession(radioSong, duration: Duration.zero);

      await audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
        logger.log(
          'Error starting radio playback',
          error: e,
          stackTrace: stackTrace,
        );
        _lastError = e.toString();
      });

      _updatePlaybackState();
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error playing radio stream',
        error: e,
        stackTrace: stackTrace,
      );
      _lastError = e.toString();
      return false;
    }
  }

  Map<String, dynamic> _buildEpisodeSong(
    PodcastEpisode episode,
    String podcastTitle,
    String? localPath,
  ) {
    return {
      'id': episode.key,
      'ytid': episode.key,
      'title': episode.title,
      'artist': podcastTitle,
      'album': podcastTitle,
      'highResImage': episode.image,
      'lowResImage': episode.image,
      'duration': episode.durationSeconds,
      'isLive': false,
      'isPodcastEpisode': true,
      'description': episode.description,
      // Kept so a Time Machine recap entry, or a later queue entry reached
      // via _playFromQueue, can replay this episode - it needs a real
      // PodcastEpisode, not a fetchSongStreamUrl(ytid) lookup like a song.
      'audioUrl': episode.audioUrl,
      'guid': episode.guid,
      'podcastId': episode.podcastId,
      'isOffline': localPath != null,
      'localPath': localPath,
    };
  }

  /// Reconstructs the [PodcastEpisode] a queue entry map was built from (see
  /// [_buildEpisodeSong]) - needed because [_currentPlayingPodcast] and the
  /// resume/download features want a real episode object, not a plain Map.
  PodcastEpisode _episodeFromQueueSong(Map song) {
    return PodcastEpisode(
      guid: song['guid']?.toString() ?? '',
      podcastId: song['podcastId']?.toString() ?? '',
      title: song['title']?.toString() ?? '',
      audioUrl: song['audioUrl']?.toString() ?? '',
      image: song['highResImage']?.toString() ?? '',
      description: song['description']?.toString() ?? '',
      durationSeconds: song['duration'] as int?,
    );
  }

  /// Plays a podcast episode, online (streamed from [episode.audioUrl]) or
  /// from a [localPath] if it was downloaded. Starts a brand-new,
  /// single-episode queue - use [addPodcastEpisodeToQueue] to append instead,
  /// or [playPodcastEpisodesQueue] to start a queue with several episodes.
  Future<bool> playPodcastEpisode(
    PodcastEpisode episode, {
    required String podcastTitle,
    String? localPath,
    Duration? initialPosition,
  }) async {
    final episodeSong = _buildEpisodeSong(episode, podcastTitle, localPath);

    _queueList
      ..clear()
      ..add(episodeSong);
    _originalQueueList
      ..clear()
      ..add(cloneMap(episodeSong));
    _currentQueueIndex = 0;
    _currentLoadingIndex = -1;
    _currentLoadingTransitionId = -1;
    _resetPreloadingState();
    // Set as soon as the episode's mediaItem is shown, not after playback
    // actually starts: the play call below can await on network I/O, and
    // until it resolves this was left null even though the episode was
    // already visibly "current" - e.g. the full player's "View podcast"
    // button would find nothing during that window.
    _updateQueueMediaItems();

    return _playPodcastQueueEntry(
      episodeSong,
      initialPosition: initialPosition,
    );
  }

  /// Replaces the queue with [episodes] and starts playing at [startIndex] -
  /// used by the podcast multi-selection "play" button so the whole
  /// selection becomes a real, reorderable queue, like [addPlaylistToQueue]
  /// does for songs, instead of only playing the first episode.
  Future<bool> playPodcastEpisodesQueue(
    List<PodcastEpisode> episodes, {
    required String podcastTitle,
    int startIndex = 0,
    Map<String, String>? localPathsByEpisodeKey,
  }) async {
    if (episodes.isEmpty) return false;

    final songs = [
      for (final episode in episodes)
        _buildEpisodeSong(
          episode,
          podcastTitle,
          localPathsByEpisodeKey?[episode.key],
        ),
    ];

    _queueList
      ..clear()
      ..addAll(songs);
    _originalQueueList
      ..clear()
      ..addAll(cloneMaps(songs));
    _currentQueueIndex = startIndex.clamp(0, songs.length - 1);
    _currentLoadingIndex = -1;
    _currentLoadingTransitionId = -1;
    _resetPreloadingState();
    _updateQueueMediaItems();

    return _playPodcastQueueEntry(songs[_currentQueueIndex]);
  }

  /// Appends a single episode to the end of whatever is currently queued
  /// (song or podcast) - used by the "add to queue instead of playing now"
  /// choice when the user taps an episode while something else is playing.
  Future<void> addPodcastEpisodeToQueue(
    PodcastEpisode episode, {
    required String podcastTitle,
    String? localPath,
    bool playNext = false,
  }) {
    return addToQueue(
      _buildEpisodeSong(episode, podcastTitle, localPath),
      playNext: playNext,
    );
  }

  /// Appends several episodes, in order, to the end of whatever is currently
  /// queued - the multi-selection equivalent of [addPodcastEpisodeToQueue].
  Future<void> addPodcastEpisodesToQueue(
    List<PodcastEpisode> episodes, {
    required String podcastTitle,
    Map<String, String>? localPathsByEpisodeKey,
  }) async {
    for (final episode in episodes) {
      await addToQueue(
        _buildEpisodeSong(
          episode,
          podcastTitle,
          localPathsByEpisodeKey?[episode.key],
        ),
      );
    }
  }

  /// Builds the audio source for [episodeSong] and starts playback, updating
  /// [_currentPlayingPodcast] and the listening-stats session - shared by
  /// [playPodcastEpisode]/[playPodcastEpisodesQueue] (the first episode of a
  /// new queue) and [_playFromQueue] (reaching a later podcast entry in an
  /// existing queue), so both behave identically.
  Future<bool> _playPodcastQueueEntry(
    Map episodeSong, {
    Duration? initialPosition,
  }) async {
    try {
      final isOffline = episodeSong['isOffline'] == true;
      final localPath = episodeSong['localPath'] as String?;
      final audioUrl = episodeSong['audioUrl'] as String?;

      _lastError = null;
      if (audioPlayer.playing) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: audioPlayer.playing,
        );
        await audioPlayer.pause();
      }

      _currentPlayingPodcast = (
        episode: _episodeFromQueueSong(episodeSong),
        podcastTitle: episodeSong['artist']?.toString() ?? '',
        localPath: localPath,
      );

      final episodeUrl = isOffline ? (localPath ?? '') : (audioUrl ?? '');

      if (castService.isCasting) {
        return _castPlayResolved(
          episodeSong,
          episodeUrl,
          isOffline,
          startAt: initialPosition ?? Duration.zero,
        );
      }

      _lastResolvedSource = (
        url: episodeUrl,
        isOffline: isOffline,
        isLive: false,
      );

      final audioSource = await buildAudioSource(
        episodeSong,
        episodeUrl,
        isOffline,
      );

      if (audioSource == null) {
        logger.log(
          'Failed to build audio source for podcast episode: ${episodeSong['id']}',
        );
        _lastError = 'Failed to load podcast episode';
        _currentPlayingPodcast = null;
        return false;
      }

      final wasPlayingBeforeSwap = audioPlayer.playing;

      // Passing initialPosition here (rather than a seek() call after play())
      // lets the player seek before playback starts, avoiding a race where a
      // seek issued right after play() on a still-buffering source is
      // dropped and playback silently starts from zero.
      await audioPlayer
          .setAudioSource(audioSource, initialPosition: initialPosition)
          .timeout(_songTransitionTimeout);

      listeningStatsService
        ..finishListeningSession(
          countCurrentTick: true,
          wasPlaying: wasPlayingBeforeSwap,
        )
        ..startListeningSession(
          episodeSong,
          duration: episodeSong['duration'] != null
              ? Duration(seconds: episodeSong['duration'] as int)
              : Duration.zero,
        );

      await audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
        logger.log(
          'Error starting podcast episode playback',
          error: e,
          stackTrace: stackTrace,
        );
        _lastError = e.toString();
      });

      _updatePlaybackState();
      final playingPodcast = _currentPlayingPodcast;
      if (playingPodcast != null) {
        unawaited(
          _persistPodcastState(
            playingPodcast.episode,
            playingPodcast.podcastTitle,
            playingPodcast.localPath,
            initialPosition ?? Duration.zero,
          ),
        );
      }
      unawaited(
        updateRecentlyPlayed(episodeSong['ytid'], songFallback: episodeSong),
      );
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error playing podcast episode',
        error: e,
        stackTrace: stackTrace,
      );
      _lastError = e.toString();
      return false;
    }
  }

  // =======================================================================
  // Cast (Chromecast / Smart TV DLNA)
  //
  // El receptor sustituye al reproductor local, nada mas. La cola, el orden
  // aleatorio, la repeticion, el paso a la siguiente y el temporizador siguen
  // siendo los de siempre: solo cambia quien suena.
  // =======================================================================

  /// Lo ultimo que se mando a reproducir. Se guarda para poder llevarselo a la
  /// tele (o traerlo de vuelta al movil) sin volver a resolver la fuente.
  ({String url, bool isOffline, bool isLive})? _lastResolvedSource;

  bool get isCasting => castService.isCasting;

  /// Suena algo ahora mismo, aqui o en la tele. Lo que hay que mirar
  /// desde fuera: audioPlayer.playing esta a false mientras se castea.
  bool get isPlaying =>
      castService.isCasting ? castService.remotePlaying : audioPlayer.playing;

  void _setupCastCallbacks() {
    castService
      ..onTrackFinished = () {
        unawaited(_handleSongCompletion());
      }
      ..onRemoteStateChanged = _updatePlaybackState
      // La sesion se ha caido sola (tele apagada, desconexion desde el mando,
      // wifi perdido): se retoma en el movil donde iba y en pausa, en vez de
      // dejar la app muda y sin explicacion.
      ..onDisconnected = () {
        unawaited(_resumeLocallyAfterCast(autoplay: false));
      };
  }

  void _updateCastPlaybackState() {
    final remote = castService.lastPosition;
    final playing = castService.remotePlaying;

    if (playing) {
      _idleAutoCloseTimer?.cancel();
      _cancelNativeIdleClose();
    }

    playbackState.add(
      PlaybackState(
        controls: _controls(playing),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        // El receptor no distingue entre bufferear y estar listo; darlo por
        // listo evita que la notificacion parpadee en cada sondeo. Lo unico que
        // se marca como carga es la preparacion del envio, que en DLNA se hace
        // esperar.
        processingState: castService.preparing
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: remote.position,
        bufferedPosition: remote.bufferedPosition,
        speed: 1,
        queueIndex:
            _currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length
            ? _currentQueueIndex
            : null,
        updateTime: DateTime.now(),
      ),
    );
  }

  /// Manda al receptor una pista cuya fuente ya esta resuelta. Es el sustituto
  /// de setAudioSource + play mientras se castea.
  Future<bool> _castPlayResolved(
    Map song,
    String url,
    bool isOffline, {
    Duration startAt = Duration.zero,
    bool isLive = false,
    int? transitionId,
  }) async {
    final device = castService.activeDevice.value;
    if (device == null) return false;

    // Rueda de carga desde ya: resolver, descargar y remuxar puede tardar, y
    // sin senal en pantalla el usuario cree que no va y se pone a pulsar.
    castService.preparing = true;
    _updatePlaybackState();

    var streamUrl = url;
    var localSource = isOffline ? url : null;
    final ytid = song['ytid']?.toString();
    final isSong = !isLive && song['isPodcastEpisode'] != true;

    if (!isOffline && isSong && ytid != null && ytid.isNotEmpty) {
      // La URL que suena en el movil puede ser Opus/WebM, que una Smart TV no
      // toca: se vuelve a resolver prefiriendo AAC (ver fetchCastStreamUrl).
      streamUrl =
          await fetchCastStreamUrl(
            ytid,
            false,
            preferSmall: !device.isChromecast,
          ) ??
          url;
      // Ese AAC viene en un MP4 fragmentado que las teles DLNA leen como si
      // durase 10 s. Se les manda ya remuxado; el Chromecast lo entiende de
      // serie y remuxar para el seria hacerle esperar por gusto.
      if (!device.isChromecast) {
        localSource = await remuxForCast(
          streamUrl,
          ytid,
          isCancelled: () => castService.activeDevice.value != device,
        );
        // Mandarle a la tele el m4a fragmentado es garantia de diez segundos y
        // a otra cosa: si no hay remux, no hay envio.
        if (localSource == null) {
          _lastError = 'No se pudo preparar la cancion para la tele';
          logger.log('Cast: sin remux para $ytid, no se envia');
          return _castPreparationFailed();
        }
      }
    }

    final rawDuration = song['duration'];
    final duration = rawDuration is int
        ? Duration(seconds: rawDuration)
        : Duration.zero;

    final wasPlayingBeforeSwap = castService.remotePlaying;

    // Los archivos del movil no tienen imagen en red: su portada se extrae de
    // las etiquetas a disco, y highResImage se queda en cadena vacia (no null,
    // asi que ?? no salta).
    final artwork =
        [song['highResImage'], song['lowResImage'], song['artworkPath']]
            .map((value) => value?.toString() ?? '')
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');

    // Resolver y remuxar lleva su rato: si mientras tanto se ha pedido otra
    // cancion, esta ya no pinta nada (si no, la tele recibe dos cargas y se
    // queda con trozos de la que perdio la carrera).
    if (_isStaleTransition(transitionId)) {
      logger.log('Cast load superseded, aborting: $ytid');
      return _castPreparationFailed();
    }

    // Y si mientras tanto se ha soltado el receptor, tampoco: asi la tele no
    // arranca la cancion despues de haber pulsado desconectar.
    if (castService.activeDevice.value != device) {
      logger.log('Cast load cancelado: el receptor ya no esta activo');
      return _castPreparationFailed();
    }

    final error = await castService.load(
      device: device,
      url: localSource == null ? streamUrl : null,
      localPath: localSource,
      title: song['title']?.toString() ?? '',
      artist: song['artist']?.toString() ?? '',
      artwork: artwork.isEmpty ? null : artwork,
      isLive: isLive,
      startAt: startAt,
      duration: duration,
    );

    if (error != null) {
      logger.log('Cast load failed: $error');
      _lastError = error;
      return _castPreparationFailed();
    }

    _lastResolvedSource = (url: url, isOffline: isOffline, isLive: isLive);

    if (duration > Duration.zero) {
      _updateCurrentMediaItemWithDuration(duration);
    }

    listeningStatsService
      ..finishListeningSession(
        countCurrentTick: true,
        wasPlaying: wasPlayingBeforeSwap,
      )
      ..startListeningSession(song, duration: duration);

    if (isSong && ytid != null && ytid.isNotEmpty) {
      unawaited(updateRecentlyPlayed(ytid, songFallback: song));
    }

    _updatePlaybackState();
    _prefetchNextCastTrack();
    return true;
  }

  /// Quita la rueda de carga cuando el envio se queda por el camino.
  bool _castPreparationFailed() {
    castService.preparing = false;
    _updatePlaybackState();
    return false;
  }

  /// Deja lista la siguiente pista de la cola mientras suena la actual. A una
  /// tele DLNA hay que descargarle y remuxarle la cancion entera antes de poder
  /// mandarsela, y hacerlo al pulsar "siguiente" es justo lo que se nota; el
  /// Chromecast se baja la URL el solito y no necesita nada de esto.
  void _prefetchNextCastTrack() {
    final device = castService.activeDevice.value;
    if (device == null || device.isChromecast || offlineMode.value) return;

    final nextIndex = _currentQueueIndex + 1;
    if (nextIndex <= 0 || nextIndex >= _queueList.length) return;

    final next = _queueList[nextIndex];
    final ytid = next['ytid']?.toString();
    if (ytid == null ||
        ytid.isEmpty ||
        next['isPodcastEpisode'] == true ||
        isSongAlreadyOffline(ytid)) {
      return;
    }

    unawaited(
      Future.microtask(() async {
        final url = await fetchCastStreamUrl(ytid, false, preferSmall: true);
        if (url == null) return;
        await remuxForCast(
          url,
          ytid,
          isCancelled: () => castService.activeDevice.value != device,
        );
      }),
    );
  }

  /// Pasa la reproduccion a [device]. Devuelve null si fue bien, o el mensaje
  /// de error para ensenarlo.
  Future<String?> startCasting(CastDevice device) async {
    final song = currentSong;
    final position = audioPlayer.position;
    final source = _lastResolvedSource;

    // El reproductor local se para del todo: dejarlo en pausa mantendria el
    // foco de audio y el decodificador ocupados para nada.
    try {
      await audioPlayer.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}

    castService.activeDevice.value = device;
    cancelCastRemux();

    if (song == null || source == null) {
      // No habia nada sonando: el receptor queda elegido y la siguiente
      // cancion que se lance ya sale por ahi.
      _updatePlaybackState();
      return null;
    }

    final ok = await _castPlayResolved(
      song,
      source.url,
      source.isOffline,
      startAt: source.isLive ? Duration.zero : position,
      isLive: source.isLive,
    );

    if (!ok) {
      castService.activeDevice.value = null;
      await _resumeLocallyAfterCast(autoplay: true, position: position);
      return _lastError ?? 'No se pudo conectar con el dispositivo';
    }
    return null;
  }

  /// Devuelve el sonido al movil, desde donde iba la tele.
  Future<void> stopCasting() async {
    final position = castService.lastPosition.position;
    final wasPlaying = castService.remotePlaying;
    cancelCastRemux();
    await castService.disconnect();
    await _resumeLocallyAfterCast(autoplay: wasPlaying, position: position);
  }

  Future<void> _resumeLocallyAfterCast({
    required bool autoplay,
    Duration? position,
  }) async {
    final resumeAt = position ?? castService.lastPosition.position;
    castService.activeDevice.value = null;
    castService.preparing = false;

    final song = currentSong;
    final source = _lastResolvedSource;
    if (song == null || source == null) {
      _updatePlaybackState();
      return;
    }

    try {
      final audioSource = await buildAudioSource(
        song,
        source.url,
        source.isOffline,
      );
      if (audioSource != null) {
        await audioPlayer.setAudioSource(
          audioSource,
          // Un directo no tiene "por donde iba": siempre arranca en vivo.
          initialPosition: source.isLive ? Duration.zero : resumeAt,
        );
        if (autoplay) unawaited(audioPlayer.play());
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error resuming locally after cast',
        error: e,
        stackTrace: stackTrace,
      );
    }
    _updatePlaybackState();
  }

  Future<AudioSource?> buildAudioSource(
    Map song,
    String songUrl,
    bool isOffline,
  ) async {
    try {
      final tag = mapToMediaItem(song);

      if (isOffline) {
        return AudioSource.file(songUrl, tag: tag);
      }

      final uri = Uri.parse(songUrl);
      final audioSource = AudioSource.uri(uri, tag: tag);

      if (!sponsorBlockSupport.value) {
        return audioSource;
      }

      final spbAudioSource = await checkIfSponsorBlockIsAvailable(
        audioSource,
        song['ytid'],
      );
      return spbAudioSource ?? audioSource;
    } catch (e, stackTrace) {
      logger.log(
        'Error building audio source',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<AudioSource?> checkIfSponsorBlockIsAvailable(
    UriAudioSource audioSource,
    String songId,
  ) async {
    try {
      final segments = await getSkipSegments(songId);
      if (segments.isEmpty) return null;

      // Sort segments by start time
      segments.sort((a, b) => (a['start'] ?? 0).compareTo(b['start'] ?? 0));

      final children = <AudioSource>[];
      var lastEnd = 0;

      for (final segment in segments) {
        final start = segment['start'] ?? 0;
        final end = segment['end'] ?? 0;

        // Add the "good" part before this sponsor segment
        if (start > lastEnd) {
          children.add(
            ClippingAudioSource(
              child: audioSource,
              start: Duration(seconds: lastEnd),
              end: Duration(seconds: start),
            ),
          );
        }

        // Advance lastEnd, handling overlapping segments
        if (end > lastEnd) {
          lastEnd = end;
        }
      }

      // Add the final part from the last sponsor segment to the end of the song
      children.add(
        ClippingAudioSource(
          child: audioSource,
          start: Duration(seconds: lastEnd),
          // end: null means play until the end of the file
        ),
      );

      if (children.length == 1) {
        return children.first;
      }

      // ignore: deprecated_member_use
      return ConcatenatingAudioSource(children: children);
    } catch (e, stackTrace) {
      logger.log(
        'Error checking sponsor block',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> skipToSong(int newIndex) async {
    try {
      if (newIndex < 0 || newIndex >= _queueList.length) {
        logger.log('Invalid song index: $newIndex');
        return;
      }
      await _playFromQueue(newIndex);
    } catch (e, stackTrace) {
      logger.log('Error skipping to song', error: e, stackTrace: stackTrace);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => skipToSong(index);

  @override
  Future<void> skipToNext() async {
    try {
      if (_currentQueueIndex < _queueList.length - 1) {
        await _playFromQueue(_currentQueueIndex + 1);
      } else if (repeatNotifier.value == AudioServiceRepeatMode.all &&
          _queueList.isNotEmpty) {
        await _playFromQueue(0);
      } else if (playNextSongAutomatically.value &&
          _currentLoadingIndex == -1) {
        // At end of queue with auto-play enabled - trigger background fetch
        unawaited(_backgroundAddSongsToQueue());
      }

      _cleanupOldPreloadedSongs();
    } catch (e, stackTrace) {
      logger.log(
        'Error skipping to next song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      if (_currentQueueIndex > 0) {
        await _playFromQueue(_currentQueueIndex - 1);
      } else if (_historyList.isNotEmpty) {
        final lastSong = cloneMap(_historyList.removeLast());
        _queueList.insert(0, lastSong);
        _currentQueueIndex = 0;
        _updateQueueMediaItems();
        await _playFromQueue(0);
      }

      _cleanupOldPreloadedSongs();
    } catch (e, stackTrace) {
      logger.log(
        'Error skipping to previous song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> playAgain() async {
    try {
      listeningStatsService.finishListeningSession(
        countCurrentTick: true,
        wasPlaying: castService.isCasting
            ? castService.remotePlaying
            : audioPlayer.playing,
      );
      if (castService.isCasting) {
        await castService.seek(Duration.zero);
        await castService.play();
      } else {
        await audioPlayer.seek(Duration.zero);
      }
      final song = currentSong;
      if (song != null) {
        listeningStatsService.startListeningSession(
          song,
          duration: audioPlayer.duration,
        );
        // Podcast episodes now reach repeat-one through this same method, but
        // "recently played songs" is a music-only feature - don't pollute it
        // with an episode id.
        if (song['isPodcastEpisode'] != true) {
          unawaited(updateRecentlyPlayed(song['ytid'], songFallback: song));
        }
      }
    } catch (e, stackTrace) {
      logger.log('Error playing again', error: e, stackTrace: stackTrace);
    }
  }

  Map<Map, String> _buildIdMap(List<Map> songs) {
    return {for (final song in songs) song: _queueEntryIds.ensureId(song)};
  }

  void _enableShuffle(
    List<Map> unplayedManualSongs,
    Set<String> manualSongIds,
  ) {
    _originalQueueList
      ..clear()
      ..addAll(cloneMaps(_queueList));

    final currentSong = _queueList[_currentQueueIndex];
    final currentQueueEntryId = _queueEntryIds.ensureId(currentSong);

    final queueIdMap = _buildIdMap(_queueList);
    _queueList
      ..removeWhere((song) => manualSongIds.contains(queueIdMap[song]))
      ..shuffle();

    final newCurrentIndex = _queueList.indexWhere(
      (song) => _queueEntryIds.ensureId(song) == currentQueueEntryId,
    );

    if (newCurrentIndex != -1 && newCurrentIndex != 0) {
      _queueList
        ..removeAt(newCurrentIndex)
        ..insert(0, currentSong);
    }

    _queueList.insertAll(_queueList.isNotEmpty ? 1 : 0, unplayedManualSongs);

    _currentQueueIndex = 0;
    _updateQueueMediaItems();
  }

  void _disableShuffle(
    List<Map> unplayedManualSongs,
    Set<String> manualSongIds,
  ) {
    if (_originalQueueList.isEmpty) return;

    final currentSong = _queueList[_currentQueueIndex];
    final currentQueueEntryId = _queueEntryIds.ensureId(currentSong);

    final restoredQueue = cloneMaps(_originalQueueList);
    final restoredQueueIdMap = _buildIdMap(restoredQueue);
    restoredQueue.removeWhere(
      (song) => manualSongIds.contains(restoredQueueIdMap[song]),
    );

    _queueList
      ..clear()
      ..addAll(restoredQueue);

    _currentQueueIndex = _queueList.indexWhere(
      (song) => _queueEntryIds.ensureId(song) == currentQueueEntryId,
    );

    if (_currentQueueIndex == -1) {
      _currentQueueIndex = 0;
    }

    final insertIndex = _currentQueueIndex + 1;
    _queueList.insertAll(insertIndex, unplayedManualSongs);

    _originalQueueList.clear();
    _updateQueueMediaItems();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      final shuffleEnabled = shuffleMode != AudioServiceShuffleMode.none;
      final wasShuffled = shuffleNotifier.value;

      shuffleNotifier.value = shuffleEnabled;
      unawaited(Hive.box('settings').put('shuffleEnabled', shuffleEnabled));
      await audioPlayer.setShuffleModeEnabled(shuffleEnabled);

      if (_queueList.isEmpty) return;

      if (shuffleEnabled && !wasShuffled) {
        _hydrateQueueEntryIds();
        final unplayedManualSongs = _getUnplayedManualSongs();
        final manualSongIds = unplayedManualSongs
            .map(_queueEntryIds.ensureId)
            .toSet();
        _enableShuffle(unplayedManualSongs, manualSongIds);
      } else if (!shuffleEnabled && wasShuffled) {
        _hydrateQueueEntryIds();
        final unplayedManualSongs = _getUnplayedManualSongs();
        final manualSongIds = unplayedManualSongs
            .map(_queueEntryIds.ensureId)
            .toSet();
        _disableShuffle(unplayedManualSongs, manualSongIds);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error setting shuffle mode',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      repeatNotifier.value = repeatMode;
      unawaited(Hive.box('settings').put('repeatMode', repeatMode.index));

      // Always set loop mode to off - we handle all repeating through _handleSongCompletion
      // This ensures ProcessingState.completed is always fired for proper song transitions
      await audioPlayer.setLoopMode(LoopMode.off);
    } catch (e, stackTrace) {
      logger.log('Error setting repeat mode', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> setSleepTimer(Duration duration) async {
    try {
      _sleepTimer?.cancel();
      sleepTimerExpired = false;
      sleepTimerNotifier.value = duration;

      final fade = sleepTimerFadeEnabled.value
          ? Duration(seconds: sleepTimerFadeSeconds.value)
          : Duration.zero;
      // Si el temporizador es mas corto que el desvanecido, se desvanece
      // durante todo el tiempo que queda en vez de no desvanecer nada.
      final untilFade = duration > fade ? duration - fade : Duration.zero;

      // El desvanecido corre ya fuera del Timer, asi que cancelarlo no basta:
      // esta marca dice si el apagado en curso sigue siendo el vigente.
      final generation = ++_sleepTimerGeneration;

      _sleepTimer = Timer(untilFade, () async {
        await _fadeOutVolume(fade, generation);
        if (generation != _sleepTimerGeneration) return;
        sleepTimerExpired = true;
        // stop() itself now ends the listening session and closes the app
        // outright, whether it's foregrounded or only alive via the
        // notification in the background.
        await stop();
        await audioPlayer.setVolume(1);
        sleepTimerNotifier.value = null;
      });
    } catch (e, stackTrace) {
      logger.log('Error setting sleep timer', error: e, stackTrace: stackTrace);
    }
  }

  /// Baja el volumen poco a poco antes de parar. Vuelve a 1 en `cancel` y
  /// tras el `stop`, para no dejar la app muda en la siguiente reproduccion.
  Future<void> _fadeOutVolume(Duration fade, int generation) async {
    if (fade <= Duration.zero) return;
    const steps = 20;
    final stepDelay = fade ~/ steps;
    for (var i = steps - 1; i >= 0; i--) {
      if (!audioPlayer.playing || generation != _sleepTimerGeneration) break;
      await audioPlayer.setVolume(i / steps);
      await Future<void>.delayed(stepDelay);
    }
  }

  void cancelSleepTimer() {
    try {
      _sleepTimer?.cancel();
      _sleepTimerGeneration++;
      unawaited(audioPlayer.setVolume(1));
      _sleepTimer = null;
      sleepTimerExpired = false;
      sleepTimerEndOfSong = false;
      sleepTimerNotifier.value = Duration.zero;
    } catch (e, stackTrace) {
      logger.log(
        'Error canceling sleep timer',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> setSleepTimerEndOfSong() async {
    try {
      _sleepTimer?.cancel();
      sleepTimerExpired = false;
      sleepTimerEndOfSong = true;
      sleepTimerNotifier.value = const Duration(milliseconds: -1);
    } catch (e, stackTrace) {
      logger.log(
        'Error setting sleep timer end of song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    try {
      switch (name) {
        case 'clearQueue':
          clearQueue();
          break;
        case 'addToQueue':
          if (extras?['song'] != null) {
            await addToQueue(
              extras!['song'] as Map,
              playNext: extras['playNext'] ?? false,
            );
          }
          break;
        case 'removeFromQueue':
          if (extras?['index'] != null) {
            await removeFromQueue(extras!['index'] as int);
          }
          break;
        case 'reorderQueue':
          if (extras?['oldIndex'] != null && extras?['newIndex'] != null) {
            await reorderQueue(
              extras!['oldIndex'] as int,
              extras['newIndex'] as int,
            );
          }
          break;
        default:
          await super.customAction(name, extras);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error in customAction: $name',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}

class _PlaybackSource {
  const _PlaybackSource({required this.songUrl, required this.isOffline});

  final String songUrl;
  final bool isOffline;
}
