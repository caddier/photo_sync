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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sync_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            file_type VARCHAR(10) NULL,
            synced_time TEXT  NULL
          )
        ''');
      },
    );
  }

  /// Check if a file has been synced
  Future<bool> isFileSynced(String fileId) async {
    final db = await database;
    final result = await db.query(
      'sync_history',
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  /// Record a successful sync
  Future<void> recordSync(String fileId, String fileType) async {
    final db = await database;
    await db.insert(
      'sync_history',
      {
        'file_id': fileId,
        'file_type': fileType,
        'synced_time': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all records
  Future<List<Map<String, dynamic>>> getAllRecords() async {
    final db = await database;
    return await db.query('sync_history', orderBy: 'id DESC');
  }

  /// Delete a record by id
  Future<int> deleteRecord(int id) async {
    final db = await database;
    return await db.delete('sync_history', where: 'id = ?', whereArgs: [id]);
  }

  /// Delete all records
  Future<int> clearHistory() async {
    final db = await database;
    return await db.delete('sync_history');
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

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
