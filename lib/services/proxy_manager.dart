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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dskplay/main.dart';
import 'package:dskplay/models/proxy_model.dart';
import 'package:dskplay/services/newpipe.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class _ProxyResources {
  _ProxyResources(this.httpClient, this.ioClient);

  final HttpClient httpClient;
  final IOClient ioClient;

  void close() {
    try {
      ioClient.close();
    } catch (_) {}
    try {
      httpClient.close(force: true);
    } catch (_) {}
  }
}

class ProxyManager {
  // Singleton
  factory ProxyManager() => _instance;
  ProxyManager._internal() {
    if (useProxy.value) {
      _initSharedProxyClient();
    }
    useProxy.addListener(() async {
      if (useProxy.value) {
        await _initSharedProxyClient();
      } else {
        await _setNativeProxy(null);
        _closeAllProxyResources();
      }
    });
  }
  // Timeout constants
  static const int _validateDirectTimeout = 5;
  static const int _proxyRefreshIntervalMinutes = 60;

  // Regex patterns (compiled once)
  static final RegExp _spysRegex = RegExp(
    r'(?<ip>\d+\.\d+\.\d+\.\d+):(?<port>\d+)\s(?<country>[A-Z]{2})-(?<anon>[HNA!]{1,2})(?:\s|-)(?<ssl>[\sS!]*)',
  );
  static final RegExp _openProxyRegex = RegExp(
    r'(.)\s(?<ip>\d+\.\d+\.\d+\.\d+):(?<port>\d+)\s(?:(?<responsetime>\d+)(?:ms))\s(?<country>[A-Z]{2})\s(?<isp>.+)$',
  );

  static final ProxyManager _instance = ProxyManager._internal();

  Future<void>? _fetchingProxiesFuture;
  Completer<void>? _initializationCompletion;
  bool _hasFetched = false;
  final Map<String, List<ProxyInfo>> _proxiesByCountry = {};
  final Set<ProxyInfo> _workingProxies = {};

  /// Maps proxy addresses to the time they were blocked (TTL-aware blocklist)
  final Map<String, DateTime> _blockedProxyAddresses = {};
  final _random = Random();
  DateTime _lastFetched = DateTime.now();
  DateTime _lastProxyCleanup = DateTime.now();
  static const int _proxyCleanupIntervalMinutes = 120;
  static const int _maxProxyResourcePoolSize = 50;
  static const int _blockedProxyTtlMinutes = 30;
  static const int _maxBlockedProxiesSize = 200;

  final Map<String, _ProxyResources> _proxyResources = {};

  String? _sharedProxyAddress;

  Future<void> _fetchProxies() async {
    if (!useProxy.value) return;
    try {
      // Clear existing candidates to avoid duplicates and stale proxies
      _proxiesByCountry.clear();

      final fetchTasks = <Future>[]
        ..add(_fetchProxyScrape())
        ..add(_fetchGeonode())
        ..add(_fetchOpenProxyList())
        ..add(_fetchSpysMe());
      _fetchingProxiesFuture = Future.wait(fetchTasks);
      await _fetchingProxiesFuture?.whenComplete(() {
        _hasFetched = true;
        _lastFetched = DateTime.now();
        _pruneStaleProxyResources();
      });
    } catch (e, stackTrace) {
      logger.log(
        'ProxyManager: Error fetching proxies',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isBlockedProxyAddress(String address) {
    final blockedAt = _blockedProxyAddresses[address];
    if (blockedAt == null) return false;

    // Check if TTL has expired
    if (DateTime.now().difference(blockedAt).inMinutes >
        _blockedProxyTtlMinutes) {
      _blockedProxyAddresses.remove(address);
      return false;
    }
    return true;
  }

  void _pruneExpiredBlockedProxies() {
    final now = DateTime.now();
    _blockedProxyAddresses.removeWhere(
      (_, blockedAt) =>
          now.difference(blockedAt).inMinutes > _blockedProxyTtlMinutes,
    );
  }

  void _enforceBlockedProxiesLimit() {
    if (_blockedProxyAddresses.length <= _maxBlockedProxiesSize) return;

    // Remove oldest entries when exceeding limit
    final entries = _blockedProxyAddresses.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final toKeep = entries.take(_maxBlockedProxiesSize ~/ 2).toList();
    _blockedProxyAddresses.clear();
    for (final entry in toKeep) {
      _blockedProxyAddresses[entry.key] = entry.value;
    }
  }

  void _addProxyCandidate({
    required String source,
    required String address,
    required String country,
    bool? isSsl,
  }) {
    if (_isBlockedProxyAddress(address)) return;

    final countryProxies = _proxiesByCountry.putIfAbsent(country, () => []);
    if (countryProxies.any((candidate) => candidate.address == address)) {
      return;
    }

    countryProxies.add(
      ProxyInfo(
        source: source,
        address: address,
        country: country,
        isSsl: isSsl,
      ),
    );
  }

  /// Point the native extractor at a working proxy.
  Future<void> _initSharedProxyClient({int timeoutSeconds = 5}) async {
    if (_initializationCompletion != null) {
      return _initializationCompletion!.future;
    }

    _initializationCompletion = Completer<void>();
    try {
      if (!_hasFetched) await _fetchProxies();
      if (_proxiesByCountry.isEmpty) await _fetchProxies();

      do {
        final proxy = await _getRandomProxy();
        if (proxy == null) break;
        try {
          // Sigue haciendo falta para getProxiedResponse (SponsorBlock y
          // demas), que se queda en Dart.
          _ensureProxyResources(proxy, timeoutSeconds: timeoutSeconds);
          await _setNativeProxy(proxy.address);
          _workingProxies.add(proxy);
          break;
        } catch (e, stackTrace) {
          logger.log(
            'ProxyManager: failed to init shared proxy client for ${proxy.address}',
            error: e,
            stackTrace: stackTrace,
          );
          _discardProxy(proxy, reason: 'shared client init failed');
          continue;
        }
      } while (true);
    } catch (e, stackTrace) {
      logger.log(
        'Error initializing proxy client',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _initializationCompletion?.complete();
      _initializationCompletion = null;
    }
  }

  /// El proxy del extractor nativo es estado global del proceso, asi que hay
  /// un unico proxy activo a la vez, igual que antes habia un unico
  /// _sharedYt.
  Future<void> _setNativeProxy(String? address) async {
    if (_sharedProxyAddress == address) return;
    await NewPipe.setProxy(address);
    _sharedProxyAddress = address;
  }

  Future<List<AudioStreamInfo>?> _validateDirect(
    String songId,
    int timeoutSeconds,
  ) async {
    try {
      await _setNativeProxy(null);
      final streams = await NewPipe.streams(
        songId,
      ).timeout(Duration(seconds: timeoutSeconds));
      return streams.audioOnly.isEmpty ? null : streams.audioOnly;
    } catch (e) {
      return null;
    }
  }

  Future<List<AudioStreamInfo>?> _validateProxy(
    ProxyInfo proxy,
    String songId,
    int timeoutSeconds,
  ) async {
    if (!useProxy.value) return null;
    try {
      _ensureProxyResources(proxy, timeoutSeconds: timeoutSeconds);
      await _setNativeProxy(proxy.address);
      final streams = await NewPipe.streams(
        songId,
      ).timeout(Duration(seconds: timeoutSeconds));
      if (streams.audioOnly.isEmpty) return null;
      _workingProxies.add(proxy);
      return streams.audioOnly;
    } catch (e, stackTrace) {
      logger.log(
        'ProxyManager: failed to validate proxy ${proxy.address}',
        error: e,
        stackTrace: stackTrace,
      );
      _discardProxy(proxy, reason: 'validation failed', closeResources: false);
      return null;
    }
  }

  /// Periodically clean up old proxies to prevent memory bloat
  void _maybeCleanupProxies() {
    if (DateTime.now().difference(_lastProxyCleanup).inMinutes <
        _proxyCleanupIntervalMinutes) {
      return;
    }
    _lastProxyCleanup = DateTime.now();

    if (DateTime.now().difference(_lastFetched).inMinutes >=
        _proxyCleanupIntervalMinutes) {
      _proxiesByCountry.clear();
      _workingProxies.clear();
      _blockedProxyAddresses.clear();
      _hasFetched = false;
      _closeAllProxyResources();
    } else {
      // Prune expired blocked proxies even if not doing full cleanup
      _pruneExpiredBlockedProxies();
    }
  }

  Future<ProxyInfo?> _getRandomProxy({String? preferredCountry}) async {
    if (!useProxy.value) return null;
    try {
      if (!_hasFetched) await (_fetchingProxiesFuture ?? _fetchProxies());
      if (_hasFetched && _proxiesByCountry.isEmpty) await _fetchProxies();
      if (_proxiesByCountry.isEmpty) return null;

      ProxyInfo proxy;
      String countryCode;
      final workingProxies = _workingProxies
          .where((candidate) => !_isBlockedProxyAddress(candidate.address))
          .toList(growable: false);
      if (workingProxies.isNotEmpty) {
        final idx = workingProxies.length == 1
            ? 0
            : _random.nextInt(workingProxies.length);
        proxy = workingProxies[idx];
        _workingProxies.remove(proxy);
      } else {
        if (preferredCountry != null &&
            _proxiesByCountry.containsKey(preferredCountry)) {
          countryCode = preferredCountry;
        } else {
          final countries = _proxiesByCountry.keys.toList(growable: false);
          countryCode = countries[_random.nextInt(countries.length)];
        }
        final countryProxies = _proxiesByCountry[countryCode]
            ?.where((candidate) => !_isBlockedProxyAddress(candidate.address))
            .toList(growable: false);
        if (countryProxies == null || countryProxies.isEmpty) {
          if (_proxiesByCountry.isEmpty) return null;
          final allProxies = _proxiesByCountry.values
              .expand((x) => x)
              .where((candidate) => !_isBlockedProxyAddress(candidate.address))
              .toList(growable: false);
          if (allProxies.isEmpty) return null;
          proxy = allProxies[_random.nextInt(allProxies.length)];
        } else {
          proxy = countryProxies[_random.nextInt(countryProxies.length)];
        }
      }
      return proxy;
    } catch (e, stackTrace) {
      logger.log(
        'ProxyManager: Error getting random proxy',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  _ProxyResources _ensureProxyResources(
    ProxyInfo proxy, {
    int timeoutSeconds = 5,
  }) {
    final key = proxy.address;
    var res = _proxyResources[key];
    if (res != null) return res;

    final httpClient = HttpClient()
      ..connectionTimeout = Duration(seconds: timeoutSeconds)
      ..findProxy = (_) {
        return 'PROXY ${proxy.address}; DIRECT';
      }
      ..badCertificateCallback = (context, _context, ___) {
        return true;
      };

    final ioClient = IOClient(httpClient);
    res = _ProxyResources(httpClient, ioClient);

    if (_proxyResources.length >= _maxProxyResourcePoolSize) {
      // Skip the entry that backs _sharedYt to avoid closing its IOClient.
      final oldestKey = _proxyResources.keys.firstWhere(
        (k) => k != _sharedProxyAddress,
        orElse: () => '',
      );
      if (oldestKey.isNotEmpty) {
        final oldest = _proxyResources.remove(oldestKey);
        try {
          oldest?.close();
        } catch (e, stackTrace) {
          logger.log(
            'ProxyManager: Error closing proxy resources',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }
    }

    _proxyResources[key] = res;
    return res;
  }

  void _pruneStaleProxyResources() {
    if (_proxyResources.isEmpty) return;

    final activeAddresses = _proxiesByCountry.values
        .expand((x) => x)
        .map((p) => p.address)
        .toSet();

    final staleKeys = _proxyResources.keys
        .where(
          (key) => key != _sharedProxyAddress && !activeAddresses.contains(key),
        )
        .toList();

    for (final key in staleKeys) {
      final stale = _proxyResources.remove(key);
      try {
        stale?.close();
      } catch (e, stackTrace) {
        logger.log(
          'ProxyManager: Error closing stale proxy resources',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _discardProxy(
    ProxyInfo proxy, {
    String? reason,
    bool closeResources = true,
  }) {
    final address = proxy.address;
    _blockedProxyAddresses[address] = DateTime.now();
    _enforceBlockedProxiesLimit();

    _proxiesByCountry.removeWhere((_, proxies) {
      proxies.removeWhere((candidate) => candidate.address == address);
      return proxies.isEmpty;
    });
    _workingProxies.removeWhere((candidate) => candidate.address == address);

    final resources = _proxyResources.remove(address);
    if (resources != null) {
      if (closeResources) {
        try {
          resources.close();
        } catch (e, stackTrace) {
          logger.log(
            'ProxyManager: Error closing discarded proxy resources',
            error: e,
            stackTrace: stackTrace,
          );
        }
      } else {
        // Let timed-out validation requests unwind before closing the client.
        unawaited(
          Future.delayed(const Duration(seconds: 2), () {
            try {
              resources.close();
            } catch (e, stackTrace) {
              logger.log(
                'ProxyManager: Error closing discarded proxy resources',
                error: e,
                stackTrace: stackTrace,
              );
            }
          }),
        );
      }
    }

    if (_sharedProxyAddress == address) {
      unawaited(_setNativeProxy(null));
    }

    logger.log(
      'ProxyManager: discarded proxy $address${reason != null ? ' ($reason)' : ''}',
    );
  }

  /// Audio-only streams for a song, trying direct first and then proxies.
  Future<List<AudioStreamInfo>?> getSongAudioStreams(String songId) async {
    if (!useProxy.value) {
      return _validateDirect(songId, _validateDirectTimeout);
    }
    var streams = await _validateDirect(songId, _validateDirectTimeout);
    if (streams != null) return streams;

    if (DateTime.now().difference(_lastFetched).inMinutes >=
        _proxyRefreshIntervalMinutes) {
      await _fetchProxies();
    }

    _maybeCleanupProxies();

    streams = await _tryProxies(songId);
    return streams;
  }

  Future<List<AudioStreamInfo>?> _tryProxies(String songId) async {
    if (!useProxy.value) return null;
    List<AudioStreamInfo>? streams;
    var attempts = 0;
    const maxAttempts = 5;
    do {
      if (attempts++ >= maxAttempts) break;
      final proxy = await _getRandomProxy();
      if (proxy == null) break;
      streams = await _validateProxy(proxy, songId, 5);
    } while (streams == null);
    return streams;
  }

  /// Performs an HTTP GET request that respects current proxy settings.
  Future<http.Response> getProxiedResponse(
    Uri uri, {
    Map<String, String>? headers,
    int timeoutSeconds = 10,
  }) async {
    if (!useProxy.value || _sharedProxyAddress == null) {
      return http
          .get(uri, headers: headers)
          .timeout(
            Duration(seconds: timeoutSeconds),
            onTimeout: () => http.Response('Timeout', 408),
          );
    }

    final res = _proxyResources[_sharedProxyAddress!];
    if (res == null) {
      return http
          .get(uri, headers: headers)
          .timeout(
            Duration(seconds: timeoutSeconds),
            onTimeout: () => http.Response('Timeout', 408),
          );
    }

    return res.ioClient
        .get(uri, headers: headers)
        .timeout(
          Duration(seconds: timeoutSeconds),
          onTimeout: () => http.Response('Timeout', 408),
        );
  }

  void _closeAllProxyResources() {
    for (final res in _proxyResources.values) {
      try {
        res.close();
      } catch (e, stackTrace) {
        logger.log(
          'ProxyManager: Error closing proxy resources',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
    _proxyResources.clear();
    _sharedProxyAddress = null;
  }

  /// Routes the native extractor through a working proxy for the calls that
  /// follow, returning false when none could be selected.
  ///
  /// Replaces the old per-call proxied YoutubeExplode client: the proxy now
  /// lives in the native OkHttp client, so it stays until something changes
  /// it (there is no client to close).
  Future<bool> useAnyProxy({int timeoutSeconds = 5}) async {
    if (!useProxy.value) return false;
    if (!_hasFetched) await _fetchProxies();

    if (_proxiesByCountry.isEmpty) await _fetchProxies();

    if (_proxiesByCountry.isEmpty) return false;

    do {
      final proxy = await _getRandomProxy();
      if (proxy == null) break;

      try {
        _ensureProxyResources(proxy, timeoutSeconds: timeoutSeconds);
        await _setNativeProxy(proxy.address);
        _workingProxies.add(proxy);
        return true;
      } catch (e, stackTrace) {
        logger.log(
          'ProxyManager: failed to route through proxy ${proxy.address}',
          error: e,
          stackTrace: stackTrace,
        );
        _discardProxy(proxy, reason: 'native proxy switch failed');
        continue;
      }
    } while (true);

    return false;
  }

  Future<void> _fetchSpysMe() async {
    if (!useProxy.value) return;
    try {
      const url = 'https://spys.me/proxy.txt';
      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => http.Response('', 408),
          );

      if (response.statusCode != 200) {
        _logProxyFetchError('spys.me', 'Status code: ${response.statusCode}');
        return;
      }

      if (response.body.isEmpty) return;

      response.body.split('\n').forEach((line) {
        if (line.trim().isEmpty || line.startsWith(';'))
          return; // Skip comments/empty lines

        // Use pre-compiled regex (constant)
        final match = _spysRegex.firstMatch(line);
        if (match != null) {
          final country = match.namedGroup('country') ?? '';
          if (country.isNotEmpty) {
            _addProxyCandidate(
              source: 'spys.me',
              address: '${match.namedGroup('ip')}:${match.namedGroup('port')}',
              country: country,
              isSsl: (match.namedGroup('ssl') ?? '').trim().isNotEmpty,
            );
          }
        }
      });
    } catch (e) {
      _logProxyFetchError('spys.me', e);
    }
  }

  void _logProxyFetchError(String source, dynamic error) {
    logger.log(
      'ProxyManager: Error fetching proxies from $source: $error',
      error: error,
    );
  }

  Future<void> _fetchProxyScrape() async {
    if (!useProxy.value) return;
    try {
      const url =
          'https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&proxy_format=protocolipport&format=json&protocol=http&ssl=yes';
      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => http.Response('', 408),
          );
      if (response.statusCode != 200) return;

      Map<String, dynamic> result;
      try {
        result = jsonDecode(response.body);
      } catch (e) {
        _logProxyFetchError('proxyscrape.com', e);
        return; // Invalid JSON
      }

      if (result['proxies'] is! List) return;

      for (final proxyData in (result['proxies'] as List)) {
        if (proxyData is! Map) continue;

        if (proxyData['ip_data'] != null &&
            (proxyData['alive'] ?? false) &&
            proxyData['ip_data']['countryCode'] != null) {
          final country = proxyData['ip_data']['countryCode'];
          _addProxyCandidate(
            source: 'proxyscrape.com',
            address: '${proxyData['ip']}:${proxyData['port']}',
            country: country,
            isSsl: true,
          );
        }
      }
    } catch (e) {
      _logProxyFetchError('proxyscrape.com', e);
    }
  }

  Future<void> _fetchOpenProxyList() async {
    if (!useProxy.value) return;
    try {
      const url =
          'https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS.txt';
      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => http.Response('', 408),
          );
      if (response.statusCode != 200) return;
      response.body.split('\n').forEach((line) {
        // Use pre-compiled regex (constant)
        final match = _openProxyRegex.firstMatch(line);
        if (match != null) {
          final country = match.namedGroup('country') ?? '';
          if (country.isNotEmpty) {
            _addProxyCandidate(
              source: 'openproxylist',
              address: '${match.namedGroup('ip')}:${match.namedGroup('port')}',
              country: country,
              isSsl: true,
            );
          }
        }
      });
    } catch (e) {
      _logProxyFetchError('openproxylist', e);
    }
  }

  Future<void> _fetchGeonode() async {
    if (!useProxy.value) return;
    try {
      const url =
          'https://proxylist.geonode.com/api/proxy-list?limit=50&page=1&sort_by=lastChecked&sort_type=desc&protocols=http%2Chttps';
      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => http.Response('', 408),
          );
      if (response.statusCode != 200) return;

      final result = jsonDecode(response.body);
      final data = result['data'];
      if (data is! List) return;

      for (final item in data) {
        if (item is! Map) continue;
        final ip = item['ip'];
        final port = item['port'];
        final country = item['country'];

        if (ip != null && port != null && country != null) {
          _addProxyCandidate(
            source: 'geonode',
            address: '$ip:$port',
            country: country,
            isSsl: true,
          );
        }
      }
    } catch (e) {
      _logProxyFetchError('geonode', e);
    }
  }
}
