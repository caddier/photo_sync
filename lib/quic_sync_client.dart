/*
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_quic/flutter_quic.dart';
import 'package:photo_manager/photo_manager.dart';

/// QUIC sync client rewritten to follow flutter_quic official example patterns.
/// Uses:
///  - Convenience API (quicClientGet/quicClientPost) for small payloads
///  - Core API (endpointConnect, connectionOpenUni, sendStreamWriteAll, sendStreamFinish) for large video streaming
///
/// SNI Handling:
///  - Client uses the serverHost (IP or hostname) directly as SNI
///  - For IP addresses: server cert MUST include the IP in SAN (e.g., IP:192.168.0.146)
///  - Override SNI via optional `sniOverride` parameter if needed
///  - If curl --http3 works but this fails, check that cert has IP in SAN (not just localhost)
class QuicSyncClient {
  final String serverHost;
  final int serverPort;
  final String? sniOverride; // SNI override for IP address servers
  QuicClient?
  _client; // convenience pooled client (used for legacy JSON upload APIs)
  QuicEndpoint? _endpoint; // core endpoint
  QuicConnection? _connection; // active QUIC connection for streaming
  bool _disposed = false;

  String get baseUrl => 'https://$serverHost:$serverPort';

  /// Returns the SNI to use: override if provided, else just use serverHost.
  /// Note: IP addresses may fail TLS verification unless cert includes IP in SAN.
  String get _effectiveSni {
    if (sniOverride != null) return sniOverride!;
    return serverHost; // Use IP directly - server cert must have IP in SAN
  }

  QuicSyncClient({
    required this.serverHost,
    required this.serverPort,
    this.sniOverride,
  });

  /// Ensure convenience client (for legacy quicClient* JSON endpoints) AND endpoint for core streaming.
  Future<bool> _ensureClient() async {
    if (_disposed) return false;
    if (_client == null) {
      try {
        _client = await quicClientCreate();
      } catch (e) {
        print('[quic] client create error: $e');
        return false;
      }
    }
    _endpoint ??= await createClientEndpoint();
    return true;
  // QUIC support has been removed from this project.
  // This file is retained as a no-op placeholder to avoid build issues when
  // cleaning up references. It intentionally contains no imports or code.

  class QuicSyncClient {
    final String serverHost;
    final int serverPort;
    final String? sniOverride;

    QuicSyncClient({
      required this.serverHost,
      required this.serverPort,
      this.sniOverride,
    });

    Future<bool> testConnection() async => false;
    Future<bool> startSyncSession(String deviceName) async => false;
    Future<void> endSyncSession() async {}
    void close() {}
    Future<bool> uploadPhoto({
      required String fileId,
      required List<int> imageBytes,
      required String mediaType,
      bool Function()? shouldCancel,
    }) async => false;
    Future<bool> uploadVideo({
      required dynamic asset,
      required String fileId,
      bool Function()? shouldCancel,
      void Function(int sent, int total)? onProgress,
    }) async => false;
  }
      print('[quic] uploadPhoto error: $e');
      return false;
    }
  }

  Future<bool> uploadVideo({
    required AssetEntity asset,
    required String fileId,
    bool Function()? shouldCancel,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (shouldCancel?.call() == true) return false;
    File? file;
    try {
      file = await asset.file;
    } catch (e) {
      print('[quic] video file access error: $e');
      return false;
    }
    if (file == null || !file.existsSync()) {
      print('[quic] video file missing');
      return false;
    }
    final size = await file.length();
    // For smaller videos (<8MB) reuse convenience JSON chunk uploads
    if (size < 8 * 1024 * 1024) {
      if (!await _ensureClient()) return false;
      const chunkSize = 512 * 1024;
      int offset = 0;
      int chunkIndex = 0;
      while (offset < size) {
        if (shouldCancel?.call() == true) {
          print('[quic] small-video cancelled at offset $offset');
          return false;
        }
        final remaining = size - offset;
        final readSize = remaining < chunkSize ? remaining : chunkSize;
        final bytes = await file
            .openRead(offset, offset + readSize)
            .fold<BytesBuilder>(BytesBuilder(), (b, data) {
              b.add(data);
              return b;
            })
            .then((b) => b.toBytes());
        final payload = jsonEncode({
          'fileId': fileId,
          'chunkIndex': chunkIndex,
          'totalSize': size,
          'offset': offset,
          'chunkSize': readSize,
          'dataB64': base64Encode(bytes),
          'isLast': offset + readSize >= size,
        });
        final r = await quicClientPost(
          client: _client!,
          url: '$baseUrl/api/media/upload/video',
          data: payload,
        );
        if (!r.$2.contains('success')) {
          print('[quic] small video chunk $chunkIndex failed');
          return false;
        }
        offset += readSize;
        chunkIndex++;
        onProgress?.call(offset, size);
      }
      return true;
    }
    // Large video: core unidirectional stream per official example style
    if (!await _ensureConnection()) return false;
    QuicSendStream sendStream;
    try {
      final uni = await connectionOpenUni(connection: _connection!);
      sendStream = uni.$2;
    } on QuicError catch (e) {
      print('[quic] open uni stream QuicError: $e');
      return false;
    } catch (e) {
      print('[quic] open uni stream error: $e');
      return false;
    }
    final header = jsonEncode({
      'fileId': fileId,
      'totalSize': size,
      'contentType': 'video/mp4',
      'transfer': 'stream',
    });
    try {
      await sendStreamWriteAll(stream: sendStream, data: utf8.encode(header));
      await sendStreamWriteAll(
        stream: sendStream,
        data: [10],
      ); // newline separator
    } catch (e) {
      print('[quic] header write error: $e');
      return false;
    }
    const chunkSize = 1024 * 1024; // 1MB
    int sent = 0;
    final raf = await file.open();
    try {
      while (sent < size) {
        if (shouldCancel?.call() == true) {
          print('[quic] streaming cancelled at $sent/$size');
          return false;
        }
        final remaining = size - sent;
        final readSize = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await raf.read(readSize);
        await sendStreamWriteAll(stream: sendStream, data: chunk);
        sent += readSize;
        onProgress?.call(sent, size);
      }
      await sendStreamFinish(stream: sendStream); // explicit finish
    } on QuicError catch (e) {
      print('[quic] stream write QuicError: $e');
      return false;
    } catch (e) {
      print('[quic] stream write error: $e');
      return false;
    } finally {
      await raf.close();
    }
    print('[quic] large video streamed successfully: $fileId');
    return true;
  }
}

class MediaThumbItem {
  final String id;
  MediaThumbItem(this.id);
  factory MediaThumbItem.fromJson(Map<String, dynamic> json) =>
      MediaThumbItem(json['id'] as String? ?? '');
}
*/

// QUIC support has been removed. This is a no-op placeholder to keep builds green.
class QuicSyncClient {
  final String serverHost;
  final int serverPort;
  final String? sniOverride;

  QuicSyncClient({
    required this.serverHost,
    required this.serverPort,
    this.sniOverride,
  });

  Future<bool> testConnection() async => false;
  Future<bool> startSyncSession(String deviceName) async => false;
  Future<void> endSyncSession() async {}
  void close() {}

  Future<bool> uploadPhoto({
    required String fileId,
    required List<int> imageBytes,
    required String mediaType,
    bool Function()? shouldCancel,
  }) async => false;

  Future<bool> uploadVideo({
    required dynamic asset,
    required String fileId,
    bool Function()? shouldCancel,
    void Function(int sent, int total)? onProgress,
  }) async => false;
}
