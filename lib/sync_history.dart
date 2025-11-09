import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class SyncRecord {
  final String fileId;
  final String mediaType;
  final DateTime syncedTime;

  SyncRecord({
    required this.fileId,
    required this.mediaType,
    required this.syncedTime,
  });

  factory SyncRecord.fromMap(Map<String, dynamic> map) {
    return SyncRecord(
      fileId: map['file_id'] as String,
      mediaType: map['file_type'] as String,
      syncedTime: DateTime.parse(map['synced_time'] as String),
    );
  }
}

class SyncHistory {
  static final SyncHistory _instance = SyncHistory._internal();
  factory SyncHistory() => _instance;

  SyncHistory._internal();

  Database? _db;
  
  // Cache for synced file IDs
  Set<String>? _syncedFileIdsCache;
  Set<String>? _syncedFileIdsWithoutExtCache;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'sync_history.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sync_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            file_type VARCHAR(10) NULL,
            synced_time TEXT  NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE device_info (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_name TEXT NOT NULL,
            updated_time TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE device_info (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              device_name TEXT NOT NULL,
              updated_time TEXT NOT NULL
            )
          ''');
        }
      },
    );
  }

  /// Check if a file has been synced
  /// Matches by filename without extension since server may change thumbnail extensions
  /// Also normalizes / to _ since file paths may contain /L0/001 but DB stores with _
  Future<bool> isFileSynced(String fileId) async {
    final db = await database;
    
    
    // Normalize the fileId by replacing / with _
    final normalizedFileId = fileId.replaceAll('/', '_');
    
    // First try exact match with normalized ID
    final exactResult = await db.query(
      'sync_history',
      where: 'file_id = ?',
      whereArgs: [normalizedFileId],
      limit: 1,
    );
    if (exactResult.isNotEmpty) {
      print('[SyncHistory] Exact match found for normalized: $normalizedFileId');
      return true;
    }
    
    // Also try original fileId for backward compatibility
    final exactResultOriginal = await db.query(
      'sync_history',
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    if (exactResultOriginal.isNotEmpty) {
      print('[SyncHistory] Exact match found for original: $fileId');
      return true;
    }
    
    // If no exact match, try matching by filename without extension (normalized)
    final filenameWithoutExt = _getFilenameWithoutExt(normalizedFileId);
    
    final allRecords = await db.query('sync_history', columns: ['file_id']);
    
    for (final record in allRecords) {
      final recordFileId = record['file_id'] as String;
      final recordFilenameWithoutExt = _getFilenameWithoutExt(recordFileId);
      if (recordFilenameWithoutExt == filenameWithoutExt) {
        print('[SyncHistory] Match found! $normalizedFileId matches DB record $recordFileId');
        return true;
      }
    }

    return false;
  }

  /// Load all synced file IDs into cache (call this once when phone tab loads)
  Future<void> loadSyncedFilesCache() async {
    final db = await database;
    final records = await db.query('sync_history', columns: ['file_id']);
    
    _syncedFileIdsCache = records.map((r) => r['file_id'] as String).toSet();
    _syncedFileIdsWithoutExtCache = records.map((r) {
      final fileId = r['file_id'] as String;
      return _getFilenameWithoutExt(fileId);
    }).toSet();
    
    print('[SyncHistory] Cache loaded: ${_syncedFileIdsCache!.length} files');
  }

  /// Check if a file is synced using cache (much faster than isFileSynced)
  /// Call loadSyncedFilesCache() first to populate the cache
  bool isFileSyncedCached(String fileId) {
    if (_syncedFileIdsCache == null || _syncedFileIdsWithoutExtCache == null) {
      throw StateError('Cache not loaded. Call loadSyncedFilesCache() first.');
    }
    
    // Normalize the fileId by replacing / with _
    final normalizedFileId = fileId.replaceAll('/', '_');
    
    // First try exact match with normalized ID
    if (_syncedFileIdsCache!.contains(normalizedFileId)) {
      return true;
    }
    
    // Also try original fileId for backward compatibility
    if (_syncedFileIdsCache!.contains(fileId)) {
      return true;
    }
    
    // Try matching by filename without extension (normalized)
    final filenameWithoutExt = _getFilenameWithoutExt(normalizedFileId);
    return _syncedFileIdsWithoutExtCache!.contains(filenameWithoutExt);
  }

  /// Clear the cache (call when records are added or deleted)
  void clearCache() {
    _syncedFileIdsCache = null;
    _syncedFileIdsWithoutExtCache = null;
    print('[SyncHistory] Cache cleared');
  }

  /// Record a successful sync
  /// Normalizes fileId by replacing / with _ for consistency
  Future<void> recordSync(String fileId, String fileType) async {
    final db = await database;
    // Normalize fileId by replacing / with _
    final normalizedFileId = fileId.replaceAll('/', '_');
    print('[SyncHistory] Recording sync: $normalizedFileId');
    
    await db.insert(
      'sync_history',
      {
        'file_id': normalizedFileId,
        'file_type': fileType,
        'synced_time': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    // Clear cache since database changed
    clearCache();
  }

  /// Get all records
  Future<List<Map<String, dynamic>>> getAllRecords() async {
    final db = await database;
    return await db.query('sync_history', orderBy: 'id DESC');
  }

  /// Delete a record by id
  Future<int> deleteRecord(int id) async {
    final db = await database;
    final result = await db.delete('sync_history', where: 'id = ?', whereArgs: [id]);
    clearCache();
    return result;
  }

  /// Delete all records
  Future<int> clearHistory() async {
    final db = await database;
    final result = await db.delete('sync_history');
    clearCache();
    return result;
  }

  Future<int> getRecordCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM sync_history');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getCountByFileType(String fileType) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM sync_history WHERE file_type = ?',
      [fileType],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Close database
  /// Get all synced files with their details
  Future<List<SyncRecord>> getAllSyncedFiles() async {
    final db = await database;
    final records = await db.query('sync_history');
    return records.map((record) => SyncRecord.fromMap(record)).toList();
  }

  /// Save device name
  Future<void> saveDeviceName(String deviceName) async {
    try {
      final db = await database;
      // Delete existing device name
      await db.delete('device_info');
      // Insert new device name
      await db.insert('device_info', {
        'device_name': deviceName,
        'updated_time': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print('Error saving device name to database: $e');
      rethrow;
    }
  }

  /// Get saved device name
  Future<String?> getDeviceName() async {
    try {
      final db = await database;
      final result = await db.query('device_info', limit: 1);
      if (result.isEmpty) return null;
      return result.first['device_name'] as String?;
    } catch (e) {
      print('Error getting device name from database: $e');
      return null;
    }
  }

  /// Check if any sync has occurred (i.e., if there are any records in sync_history)
  Future<bool> hasSyncedBefore() async {
    try {
      final db = await database;
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM sync_history LIMIT 1');
      final count = Sqflite.firstIntValue(result) ?? 0;
      return count > 0;
    } catch (e) {
      print('Error checking sync history: $e');
      return false;
    }
  }

  /// Sync database with server - remove records that don't exist on server
  /// and optionally add records for files that exist on server but not in database
  /// Note: Matches by filename without extension since server may change thumbnail extensions
  Future<void> syncWithServer(List<String> serverFileIds) async {
    try {
      final db = await database;
      
      // Get all file IDs from local database
      final localRecords = await db.query('sync_history', columns: ['file_id', 'file_type']);
      final localFileIds = localRecords.map((record) => record['file_id'] as String).toList();
      
      // Server filenames already have no extensions - use them directly as a set
      // Local filenames have extensions - we'll strip them when comparing
      final serverFilenamesSet = serverFileIds.toSet();
      
      print('Sync DB: Server has ${serverFileIds.length} files');
      print('Sync DB: Local DB has ${localFileIds.length} records');
      
      // Count by type
      int localPhotos = 0;
      int localVideos = 0;
      for (var record in localRecords) {
        final fileType = record['file_type'] as String?;
        if (fileType == 'photo') localPhotos++;
        if (fileType == 'video') localVideos++;
      }
      print('Sync DB: Local has $localPhotos photos, $localVideos videos');
      
      // Sample server files
      final serverPhotos = serverFileIds.where((id) => id.contains('IMG_')).length;
      final serverVideos = serverFileIds.where((id) => id.contains('VID_')).length;
      print('Sync DB: Server has $serverPhotos IMG_ files, $serverVideos VID_ files');
      
      // Show sample server video files
      final sampleServerVideos = serverFileIds.where((id) => id.contains('VID_')).take(3).toList();
      if (sampleServerVideos.isNotEmpty) {
        print('Sample server videos: ${sampleServerVideos.join(', ')}');
      }
      
      // Show sample local video files
      final localVideoRecords = localRecords.where((r) => r['file_type'] == 'video').take(3).toList();
      if (localVideoRecords.isNotEmpty) {
        final sampleLocalVideos = localVideoRecords.map((r) => r['file_id'] as String).toList();
        print('Sample local videos: ${sampleLocalVideos.join(', ')}');
        // Show what they look like without extension
        final withoutExt = sampleLocalVideos.map((id) => _getFilenameWithoutExt(id)).join(', ');
        print('Local videos without ext: $withoutExt');
      }
      
      // Find records that exist in database but not on server (need to delete)
      final toDelete = <String>[];
      final matched = <String>[];
      
      for (final localFileId in localFileIds) {
        final localFilenameWithoutExt = _getFilenameWithoutExt(localFileId);
        // Server filenames already have no extension, compare directly
        if (!serverFilenamesSet.contains(localFilenameWithoutExt)) {
          toDelete.add(localFileId);
        } else {
          matched.add(localFileId);
        }
      }
      
      // Count matched files by type
      int matchedPhotos = 0;
      int matchedVideos = 0;
      for (var record in localRecords) {
        final fileId = record['file_id'] as String;
        if (matched.contains(fileId)) {
          final fileType = record['file_type'] as String?;
          if (fileType == 'photo') matchedPhotos++;
          if (fileType == 'video') matchedVideos++;
        }
      }
      print('Sync DB: Matched $matchedPhotos photos, $matchedVideos videos');
      
      if (toDelete.isNotEmpty) {
        print('Removing ${toDelete.length} records that no longer exist on server');
        // Sample what's being deleted
        final sampleDeletes = toDelete.take(5).join(', ');
        print('Sample deletes: $sampleDeletes');
        
        for (final fileId in toDelete) {
          await db.delete('sync_history', where: 'file_id = ?', whereArgs: [fileId]);
        }
      }
      
      print('Database sync complete: removed ${toDelete.length} orphaned records');
      
      // Clear cache since database changed
      if (toDelete.isNotEmpty) {
        clearCache();
      }
    } catch (e) {
      print('Error syncing database with server: $e');
      rethrow;
    }
  }
  
  /// Extract filename without extension for matching
  /// E.g., "IMG_123.jpg" -> "IMG_123", "VID_456.mp4" -> "VID_456"
  String _getFilenameWithoutExt(String fileId) {
    final lastDotIndex = fileId.lastIndexOf('.');
    if (lastDotIndex == -1) {
      print('[SyncHistory] _getFilenameWithoutExt($fileId) -> $fileId (no extension)');
      return fileId;
    }
    final result = fileId.substring(0, lastDotIndex);
    return result;
  }

  /// Get all synced file IDs (for debugging)
  Future<List<String>> getAllSyncedFileIds() async {
    final db = await database;
    final records = await db.query('sync_history', columns: ['file_id']);
    return records.map((r) => r['file_id'] as String).toList();
  }

  /// Remove a specific file from sync history
  Future<void> removeFileRecord(String fileId) async {
    final db = await database;
    await db.delete('sync_history', where: 'file_id = ?', whereArgs: [fileId]);
    clearCache();
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
