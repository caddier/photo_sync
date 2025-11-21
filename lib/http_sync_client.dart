import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:photo_manager/photo_manager.dart';

/// HTTP-based media sync client for uploading photos and videos
///
/// This client uses standard HTTP multipart/form-data for uploads,
/// making it compatible with common web servers and frameworks.
class HttpSyncClient {
  final String serverHost;
  final int serverPort;
  final http.Client _httpClient;

  /// Optional rate limit for video uploads (bytes per second). Null = unlimited.
  int? videoUploadRateLimitBytesPerSecond;

  /// Optional rate limit for photo uploads (bytes per second). Null = unlimited.
  int? photoUploadRateLimitBytesPerSecond;

  /// Device name provided directly (no explicit start/end session calls).
  final String? deviceName;

  String get baseUrl => 'http://$serverHost:$serverPort';

  HttpSyncClient({
    required this.serverHost,
    required this.serverPort,
    http.Client? httpClient,
    this.videoUploadRateLimitBytesPerSecond,
    this.photoUploadRateLimitBytesPerSecond,
    this.deviceName,
  }) : _httpClient = httpClient ?? http.Client();

  /// Get formatted timestamp for logging
  static String _timestamp() {
    final now = DateTime.now();
    return '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond ~/ 10).toString().padLeft(2, '0')}]';
  }

  /// Close the HTTP client and release resources
  void close() {
    _httpClient.close();
  }

  /// Test connection to server
  ///
  /// Returns true if server is reachable and responding
  Future<bool> testConnection() async {
    try {
      final response = await _httpClient.get(Uri.parse('$baseUrl/api/ping')).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      print('${_timestamp()} Connection test failed: $e');
      return false;
    }
  }

  // startSyncSession/endSyncSession removed; deviceName now passed via constructor.

  /// Get total media count from server
  Future<int> getMediaCount() async {
    try {
      Uri uri = Uri.parse('$baseUrl/api/media/count');
      if (deviceName != null && deviceName!.isNotEmpty) {
        uri = uri.replace(queryParameters: {'deviceName': deviceName!});
      }
      final response = await _httpClient.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final count = data['count'] as int? ?? 0;
        print('${_timestamp()} Server media count: $count');
        return count;
      }
      return 0;
    } catch (e) {
      print('${_timestamp()} Error getting media count: $e');
      return 0;
    }
  }

  /// Get list of media thumbnails from server
  ///
  /// [pageIndex] - Zero-based page number
  /// [pageSize] - Number of items per page
  Future<List<MediaThumbItem>> getMediaThumbnails({required int pageIndex, required int pageSize}) async {
    try {
      final params = {
        'page': pageIndex.toString(),
        'pageSize': pageSize.toString(),
        if (deviceName != null && deviceName!.isNotEmpty) 'deviceName': deviceName!,
      };
      final uri = Uri.parse('$baseUrl/api/media/thumbnails').replace(queryParameters: params);

      final response = await _httpClient.get(uri).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final photos = data['photos'] as List<dynamic>? ?? [];

        return photos.map((item) => MediaThumbItem.fromJson(item as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('${_timestamp()} Error getting thumbnails: $e');
      return [];
    }
  }

  /// Get all file IDs from server by fetching all pages
  Future<List<String>> getAllServerFileIds() async {
    try {
      final totalCount = await getMediaCount();
      if (totalCount == 0) return [];

      print('${_timestamp()} Fetching all server file IDs (total: $totalCount)...');

      const pageSize = 100;
      final totalPages = (totalCount / pageSize).ceil();
      final allFileIds = <String>[];

      for (int page = 0; page < totalPages; page++) {
        print('${_timestamp()} Fetching page ${page + 1}/$totalPages...');
        final thumbList = await getMediaThumbnails(pageIndex: page, pageSize: pageSize);
        allFileIds.addAll(thumbList.map((item) => item.id));
      }

      print('${_timestamp()} Retrieved ${allFileIds.length} file IDs from server');
      return allFileIds;
    } catch (e) {
      print('${_timestamp()} Error getting all server file IDs: $e');
      return [];
    }
  }

  /// Upload a photo to the server
  ///
  /// [fileId] - Unique identifier for the file (e.g., IMG_123.jpg)
  /// [imageBytes] - Raw image data
  /// [mediaType] - File extension (jpg, png, heic, etc.)
  /// [shouldCancel] - Callback to check if upload should be cancelled
  Future<bool> uploadPhoto({
    required String fileId,
    required Uint8List imageBytes,
    required String mediaType,
    bool Function()? shouldCancel,
    void Function(int sent, int total)? onProgress,
  }) async {
    // Check for cancellation before starting
    if (shouldCancel != null && shouldCancel()) {
      print('${_timestamp()} Photo upload cancelled before start: $fileId');
      return false;
    }

    // Chunk + throttle image bytes in a cancellable stream to support mid-flight cancel & rate limiting
    final total = imageBytes.length;
    final limit = photoUploadRateLimitBytesPerSecond;
    const int chunkSize = 64 * 1024; // 64KB chunks for smoother progress & throttling
    int offset = 0;
    int bytesSent = 0;
    final start = DateTime.now();
    final chunkCount = (total / chunkSize).ceil();
    final chunks = List<List<int>>.generate(chunkCount, (index) {
      final remaining = total - offset;
      final size = remaining < chunkSize ? remaining : chunkSize;
      final chunk = imageBytes.sublist(offset, offset + size);
      offset += size;
      return chunk;
    });
    final cancellable = Stream<List<int>>.fromIterable(chunks).asyncMap((chunk) async {
      if (shouldCancel != null && shouldCancel()) {
        throw const _UploadCancelled();
      }
      bytesSent += chunk.length;
      onProgress?.call(bytesSent, total);
      if (limit != null && limit > 0) {
        final elapsedMs = DateTime.now().difference(start).inMilliseconds;
        final expectedMs = (bytesSent / limit) * 1000;
        final delayMs = expectedMs - elapsedMs;
        if (delayMs > 5) {
          int remaining = delayMs.round();
          while (remaining > 0) {
            final slice = remaining > 500 ? 500 : remaining;
            if (shouldCancel != null && shouldCancel()) {
              throw const _UploadCancelled();
            }
            await Future.delayed(Duration(milliseconds: slice));
            remaining -= slice;
          }
        }
      }
      return chunk;
    });

    final ioClient = IOClient(HttpClient());
    try {
      print('${_timestamp()} Uploading photo: $fileId (${(imageBytes.length / 1024).toStringAsFixed(2)} KB)');

      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/media/upload/photo'));

      // Add file as streaming multipart to allow cancellation
      request.files.add(http.MultipartFile('file', cancellable, total, filename: fileId));

      // Add metadata
      request.fields['fileId'] = fileId;
      request.fields['mediaType'] = mediaType;
      if (deviceName != null && deviceName!.isNotEmpty) {
        request.fields['deviceName'] = deviceName!;
      }

      // Send with timeout using a dedicated client we can close on cancel
      // Adjust timeout when throttling is active
      Duration timeout = const Duration(seconds: 60);
      if (limit != null && limit > 0) {
        final expectedSeconds = (total / limit).ceil();
        timeout = Duration(seconds: expectedSeconds + 30); // cushion
      }
      final streamedResponse = await ioClient.send(request).timeout(timeout);

      final response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final success = data['success'] as bool? ?? false;
        if (success) {
          onProgress?.call(total, total);
          print('${_timestamp()} Photo uploaded successfully: $fileId');
          return true;
        } else {
          print('${_timestamp()} Server rejected photo: ${data['message']}');
          return false;
        }
      }
      print('${_timestamp()} Upload failed with status: ${response.statusCode}');
      return false;
    } on _UploadCancelled {
      // Aborted by user
      try {
        ioClient.close();
      } catch (_) {}
      print('${_timestamp()} Photo upload cancelled mid-flight: $fileId');
      return false;
    } catch (e) {
      // If user requested cancel, treat as cancelled
      if (shouldCancel != null && shouldCancel()) {
        try {
          ioClient.close();
        } catch (_) {}
        print('${_timestamp()} Photo upload cancelled (socket closed): $fileId');
        return false;
      }
      print('${_timestamp()} Error uploading photo: $e');
      return false;
    } finally {
      try {
        ioClient.close();
      } catch (_) {}
    }
  }

  /// Upload a video to the server using chunked upload
  ///
  /// [asset] - The video asset to upload
  /// [fileId] - Unique identifier for the file (e.g., VID_456.mp4)
  /// [mediaType] - File extension (mp4, mov, etc.)
  /// [shouldCancel] - Callback to check if upload should be cancelled
  /// [onProgress] - Progress callback (current bytes, total bytes)
  Future<bool> uploadVideo({
    required AssetEntity asset,
    required String fileId,
    required String mediaType,
    bool Function()? shouldCancel,
    void Function(int current, int total)? onProgress,
    int? maxBytesPerSecond,
  }) async {
    // Get video file
    File? file;
    try {
      file = await asset.file;
    } catch (e) {
      print('${_timestamp()} ❌ Cannot access video file (may be in iCloud): $fileId');
      print('${_timestamp()}    Error: $e');
      return false;
    }

    if (file == null || !file.existsSync()) {
      print('${_timestamp()} ❌ Video file not found: $fileId');
      return false;
    }

    int fileSize;
    try {
      fileSize = await file.length();
    } catch (e) {
      print('${_timestamp()} ❌ Cannot read video file size: $fileId');
      return false;
    }

    print('${_timestamp()} Starting video upload: $fileId (${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB)');

    // For small videos (< 10MB), use simple upload
    if (fileSize < 10 * 1024 * 1024) {
      return await _uploadSmallVideo(
        file: file,
        fileId: fileId,
        mediaType: mediaType,
        fileSize: fileSize,
        onProgress: onProgress,
        maxBytesPerSecond: maxBytesPerSecond,
      );
    }

    // For large videos, use chunked upload
    return await _uploadLargeVideo(
      file: file,
      fileId: fileId,
      mediaType: mediaType,
      fileSize: fileSize,
      shouldCancel: shouldCancel,
      onProgress: onProgress,
      maxBytesPerSecond: maxBytesPerSecond,
    );
  }

  /// Upload small video in one request
  Future<bool> _uploadSmallVideo({
    required File file,
    required String fileId,
    required String mediaType,
    required int fileSize,
    void Function(int current, int total)? onProgress,
    int? maxBytesPerSecond,
  }) async {
    // Stream the small video too, to support cancellation and avoid buffering all bytes
    final ioClient = IOClient(HttpClient());
    int sent = 0;
    final start = DateTime.now();
    final limit = maxBytesPerSecond ?? videoUploadRateLimitBytesPerSecond;
    final stream = file.openRead().asyncMap((chunk) async {
      sent += chunk.length;
      onProgress?.call(sent, fileSize);
      // Throttle if limit set
      if (limit != null && limit > 0) {
        final elapsedMs = DateTime.now().difference(start).inMilliseconds;
        final expectedMs = (sent / limit) * 1000;
        final delayMs = expectedMs - elapsedMs;
        if (delayMs > 5) {
          // only delay if meaningful
          if (delayMs > 2000) {
            // Cap delay to avoid extremely long sleeps per chunk
            await Future.delayed(const Duration(milliseconds: 2000));
          } else {
            await Future.delayed(Duration(milliseconds: delayMs.round()));
          }
        }
      }
      return chunk;
    });
    try {
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/media/upload/video'));
      request.files.add(http.MultipartFile('file', stream, fileSize, filename: fileId));
      request.fields['fileId'] = fileId;
      request.fields['mediaType'] = mediaType;

      // Adjust timeout based on rate limit if present
      Duration timeout = const Duration(seconds: 120);
      if (limit != null && limit > 0) {
        final expectedSeconds = (fileSize / limit).ceil();
        timeout = Duration(seconds: expectedSeconds + 60); // add cushion
      }
      final resp = await ioClient.send(request).timeout(timeout);
      final response = await http.Response.fromStream(resp);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final success = data['success'] as bool? ?? false;
        if (success) {
          onProgress?.call(fileSize, fileSize);
          print('${_timestamp()} Video uploaded successfully: $fileId');
          return true;
        }
      }
      print('${_timestamp()} Video upload failed: ${response.statusCode}');
      return false;
    } catch (e) {
      print('${_timestamp()} Error uploading small video: $e');
      return false;
    } finally {
      try {
        ioClient.close();
      } catch (_) {}
    }
  }

  /// Upload large video using standard HTTP multipart streaming
  Future<bool> _uploadLargeVideo({
    required File file,
    required String fileId,
    required String mediaType,
    required int fileSize,
    bool Function()? shouldCancel,
    void Function(int current, int total)? onProgress,
    int? maxBytesPerSecond,
  }) async {
    final ioClient = IOClient(HttpClient());
    try {
      // Create multipart request
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/media/upload/video'));

      // Add metadata fields
      request.fields['fileId'] = fileId;
      request.fields['mediaType'] = mediaType;
      request.fields['fileSize'] = fileSize.toString();
      if (deviceName != null && deviceName!.isNotEmpty) {
        request.fields['deviceName'] = deviceName!;
      }

      // Add file as streaming multipart with cancellation + progress
      int sent = 0;
      final start = DateTime.now();
      final limit = maxBytesPerSecond ?? videoUploadRateLimitBytesPerSecond;
      final fileStream = file.openRead().asyncMap((chunk) async {
        if (shouldCancel != null && shouldCancel()) {
          throw const _UploadCancelled();
        }
        sent += chunk.length;
        onProgress?.call(sent, fileSize);
        // Throttle to maintain target bytes/sec
        if (limit != null && limit > 0) {
          final elapsedMs = DateTime.now().difference(start).inMilliseconds;
          final expectedMs = (sent / limit) * 1000;
          // If we've sent more quickly than allowed, sleep the difference.
          final delayMs = expectedMs - elapsedMs;
          if (delayMs > 5) {
            // Avoid giant single delays; break into smaller slices if huge
            int remaining = delayMs.round();
            while (remaining > 0) {
              final slice = remaining > 500 ? 500 : remaining;
              if (shouldCancel != null && shouldCancel()) {
                throw const _UploadCancelled();
              }
              await Future.delayed(Duration(milliseconds: slice));
              remaining -= slice;
            }
          }
        }
        return chunk;
      });
      request.files.add(http.MultipartFile('file', fileStream, fileSize, filename: fileId));

      print('${_timestamp()} Uploading large video via HTTP streaming...');

      // Send request with extended timeout for large files
      int timeoutSeconds = 60 + (fileSize / (1024 * 1024)).ceil();
      if (limit != null && limit > 0) {
        final expectedSeconds = (fileSize / limit).ceil();
        // Add generous cushion beyond expected throttled duration
        timeoutSeconds = expectedSeconds + 120;
      }
      final streamedResponse = await ioClient.send(request).timeout(Duration(seconds: timeoutSeconds));

      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final success = data['success'] as bool? ?? false;
        if (success) {
          onProgress?.call(fileSize, fileSize);
          print('${_timestamp()} Large video uploaded successfully: $fileId');
          return true;
        } else {
          print('${_timestamp()} Server rejected video: ${data['message'] ?? 'Unknown error'}');
          return false;
        }
      } else {
        print('${_timestamp()} Upload failed with status: ${response.statusCode}');
        return false;
      }
    } on _UploadCancelled {
      try {
        ioClient.close();
      } catch (_) {}
      print('${_timestamp()} Large video upload cancelled mid-flight: $fileId');
      return false;
    } catch (e) {
      if (shouldCancel != null && shouldCancel()) {
        try {
          ioClient.close();
        } catch (_) {}
        print('${_timestamp()} Large video upload cancelled (socket closed): $fileId');
        return false;
      }
      print('${_timestamp()} Error uploading large video: $e');
      return false;
    } finally {
      try {
        ioClient.close();
      } catch (_) {}
    }
  }

  /// Delete media files from server
  ///
  /// [fileIds] - List of file IDs to delete
  Future<bool> deleteMedia(List<String> fileIds) async {
    if (fileIds.isEmpty) return true;

    try {
      final response = await _httpClient
          .post(Uri.parse('$baseUrl/api/media/delete'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'fileIds': fileIds}))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final success = data['success'] as bool? ?? false;

        if (success) {
          print('${_timestamp()} Deleted ${fileIds.length} files from server');
          return true;
        }
      }

      print('${_timestamp()} Delete operation failed: ${response.statusCode}');
      return false;
    } catch (e) {
      print('${_timestamp()} Error deleting media: $e');
      return false;
    }
  }
}

/// Internal marker exception to signal user-cancelled uploads.
class _UploadCancelled implements Exception {
  const _UploadCancelled();
  @override
  String toString() => 'Upload cancelled';
}

/// Media thumbnail item from server
class MediaThumbItem {
  final String id;
  final String thumbData; // base64 encoded thumbnail
  final String media; // file extension
  final bool isVideo;

  MediaThumbItem({required this.id, required this.thumbData, required this.media, required this.isVideo});

  factory MediaThumbItem.fromJson(Map<String, dynamic> json) {
    final mediaType = json['media'] as String? ?? '';
    final isVideo = _isVideoMediaType(mediaType);

    return MediaThumbItem(id: json['id'] as String, thumbData: json['data'] as String? ?? '', media: mediaType, isVideo: isVideo);
  }

  Map<String, dynamic> toJson() => {'id': id, 'data': thumbData, 'media': media};

  static bool _isVideoMediaType(String media) {
    const videoTypes = {'mp4', 'mov', 'avi', 'wmv', '3gp', '3g2', 'mkv', 'webm', 'flv', 'video'};
    return videoTypes.contains(media.toLowerCase());
  }
}
