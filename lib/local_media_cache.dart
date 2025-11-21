import 'package:photo_sync/media_eumerator.dart';
import 'package:photo_sync/http_media_sync_protocol.dart';
import 'package:photo_sync/utils.dart';

/// Singleton cache for local media filenames to avoid expensive reloading
class LocalMediaCache {
  static final LocalMediaCache _instance = LocalMediaCache._internal();

  factory LocalMediaCache() {
    return _instance;
  }

  LocalMediaCache._internal();

  Set<String> _localMediaFilenames = {};
  bool _isLoaded = false;
  bool _isLoading = false;
  DateTime? _lastLoadTime;

  /// Cache validity duration (5 minutes)
  static const Duration _cacheValidityDuration = Duration(minutes: 5);

  /// Get cached filenames or load if not available/stale
  Future<Set<String>> getLocalMediaFilenames({bool forceReload = false}) async {
    // Check if cache is valid
    final now = DateTime.now();
    final isStale = _lastLoadTime == null || now.difference(_lastLoadTime!) > _cacheValidityDuration;

    if (!forceReload && _isLoaded && !isStale) {
      print('${timestamp()} LocalMediaCache: Using cached filenames (${_localMediaFilenames.length} items)');
      return _localMediaFilenames;
    }

    // If already loading, wait for it to complete
    if (_isLoading) {
      print('${timestamp()} LocalMediaCache: Already loading, waiting...');
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _localMediaFilenames;
    }

    // Load filenames
    return await _loadFilenames();
  }

  Future<Set<String>> _loadFilenames() async {
    _isLoading = true;

    try {
      print('${timestamp()} LocalMediaCache: Loading local media filenames...');
      final assets = await MediaEnumerator.getAllLocalAssets();
      final Set<String> filenames = {};

      // Use HttpMediaSyncProtocol.getAssetFilename for consistent filenames
      for (var asset in assets) {
        try {
          final filename = await HttpMediaSyncProtocol.getAssetFilename(asset);
          // Remove extension for comparison
          final lastDot = filename.lastIndexOf('.');
          if (lastDot > 0) {
            final filenameWithoutExt = filename.substring(0, lastDot);
            filenames.add(filenameWithoutExt);
          }
        } catch (e) {
          print('${timestamp()} LocalMediaCache: Error getting filename for asset: $e');
        }
      }

      _localMediaFilenames = filenames;
      _isLoaded = true;
      _lastLoadTime = DateTime.now();
      _isLoading = false;

      print('${timestamp()} LocalMediaCache: Loaded ${filenames.length} local media filenames');
      return _localMediaFilenames;
    } catch (e) {
      print('${timestamp()} LocalMediaCache: Error loading filenames: $e');
      _isLoading = false;
      rethrow;
    }
  }

  /// Add a filename to the cache (e.g., after download)
  void addFilename(String filenameWithoutExt) {
    _localMediaFilenames.add(filenameWithoutExt);
  }

  /// Check if a filename exists in cache
  bool contains(String filenameWithoutExt) {
    return _localMediaFilenames.contains(filenameWithoutExt);
  }

  /// Force reload of cache
  Future<Set<String>> reload() async {
    return await getLocalMediaFilenames(forceReload: true);
  }

  /// Clear cache
  void clear() {
    _localMediaFilenames.clear();
    _isLoaded = false;
    _lastLoadTime = null;
  }
}
