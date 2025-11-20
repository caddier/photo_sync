import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/http_sync_client.dart';

/// HTTP-based media sync protocol adapter
///
/// This class provides the same interface as MediaSyncProtocol
/// but uses HTTP instead of raw TCP sockets for better compatibility
/// and easier server implementation.
class HttpMediaSyncProtocol {
  /// Get formatted timestamp for logging
  static String _timestamp() {
    final now = DateTime.now();
    return '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond ~/ 10).toString().padLeft(2, '0')}]';
  }

  /// Get filename for an asset without loading the full file data
  static Future<String> getAssetFilename(AssetEntity asset) async {
    final typePrefix = asset.type == AssetType.image ? 'IMG' : 'VID';
    final defaultExt = asset.type == AssetType.image ? 'heic' : 'mov';

    // Normalize asset ID by replacing / with _
    final normalizedId = asset.id.replaceAll('/', '_');
    final filename = '${typePrefix}_${normalizedId}.$defaultExt';

    return filename;
  }

  /// Upload a photo using HTTP
  static Future<bool> uploadPhoto({
    required HttpSyncClient client,
    required AssetEntity asset,
    required String fileId,
    bool Function()? shouldCancel,
  }) async {
    // Check for cancellation before starting
    if (shouldCancel != null && shouldCancel()) {
      print('${_timestamp()} Upload cancelled before start: $fileId');
      return false;
    }

    try {
      // Get image bytes
      Uint8List? imageBytes = await asset.originBytes;

      if (imageBytes == null || imageBytes.isEmpty) {
        print('${_timestamp()} ❌ Failed to get image bytes: $fileId');
        return false;
      }

      // Extract media type from filename
      String mediaType = 'jpg';
      final dotIndex = fileId.lastIndexOf('.');
      if (dotIndex != -1 && dotIndex < fileId.length - 1) {
        mediaType = fileId.substring(dotIndex + 1).toLowerCase();
      }

      // Upload via HTTP
      final success = await client.uploadPhoto(
        fileId: fileId,
        imageBytes: imageBytes,
        mediaType: mediaType,
      );

      return success;
    } catch (e) {
      print('${_timestamp()} Error uploading photo $fileId: $e');
      return false;
    }
  }

  /// Upload a video using HTTP with chunked upload
  static Future<bool> uploadVideo({
    required HttpSyncClient client,
    required AssetEntity asset,
    required String fileId,
    bool Function()? shouldCancel,
    void Function(int current, int total)? onProgress,
  }) async {
    // Check for cancellation before starting
    if (shouldCancel != null && shouldCancel()) {
      print('${_timestamp()} Upload cancelled before start: $fileId');
      return false;
    }

    try {
      // Extract media type from filename
      String mediaType = 'mp4';
      final dotIndex = fileId.lastIndexOf('.');
      if (dotIndex != -1 && dotIndex < fileId.length - 1) {
        mediaType = fileId.substring(dotIndex + 1).toLowerCase();
      }

      // Upload via HTTP with chunked upload
      final success = await client.uploadVideo(
        asset: asset,
        fileId: fileId,
        mediaType: mediaType,
        shouldCancel: shouldCancel,
        onProgress: onProgress,
      );

      return success;
    } catch (e) {
      print('${_timestamp()} Error uploading video $fileId: $e');
      return false;
    }
  }

  /// Upload media asset (automatically determines if photo or video)
  static Future<bool> uploadAsset({
    required HttpSyncClient client,
    required AssetEntity asset,
    bool Function()? shouldCancel,
    void Function(int current, int total)? onProgress,
  }) async {
    // Get filename
    final fileId = await getAssetFilename(asset);

    if (asset.type == AssetType.image) {
      return await uploadPhoto(
        client: client,
        asset: asset,
        fileId: fileId,
        shouldCancel: shouldCancel,
      );
    } else if (asset.type == AssetType.video) {
      return await uploadVideo(
        client: client,
        asset: asset,
        fileId: fileId,
        shouldCancel: shouldCancel,
        onProgress: onProgress,
      );
    } else {
      print('${_timestamp()} ❌ Unsupported asset type: ${asset.type}');
      return false;
    }
  }

  /// Batch upload multiple assets
  ///
  /// [assets] - List of assets to upload
  /// [concurrency] - Number of concurrent uploads (default: 3)
  /// [shouldCancel] - Callback to check if upload should be cancelled
  /// [onAssetComplete] - Callback when each asset completes
  /// [onProgress] - Overall progress callback
  static Future<UploadResult> uploadAssets({
    required HttpSyncClient client,
    required List<AssetEntity> assets,
    int concurrency = 3,
    bool Function()? shouldCancel,
    void Function(AssetEntity asset, bool success)? onAssetComplete,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (assets.isEmpty) {
      return UploadResult(successful: 0, failed: 0, cancelled: false);
    }

    print(
      '${_timestamp()} Starting batch upload of ${assets.length} assets (concurrency: $concurrency)',
    );

    int successful = 0;
    int failed = 0;
    bool cancelled = false;

    // Process assets with limited concurrency
    final pending = <Future<void>>[];
    int index = 0;

    while (index < assets.length || pending.isNotEmpty) {
      // Check for cancellation
      if (shouldCancel != null && shouldCancel()) {
        print('${_timestamp()} Batch upload cancelled');
        cancelled = true;
        break;
      }

      // Start new uploads up to concurrency limit
      while (pending.length < concurrency && index < assets.length) {
        final asset = assets[index];
        index++;

        final future = uploadAsset(
          client: client,
          asset: asset,
          shouldCancel: shouldCancel,
        ).then((success) {
          if (success) {
            successful++;
          } else {
            failed++;
          }

          if (onAssetComplete != null) {
            onAssetComplete(asset, success);
          }

          if (onProgress != null) {
            onProgress(successful + failed, assets.length);
          }
        });

        pending.add(future);
      }

      // Wait for at least one to complete
      if (pending.isNotEmpty) {
        await Future.any(pending);
        pending.removeWhere((future) => future.isCompleted);
      }
    }

    // Wait for remaining uploads to complete
    if (pending.isNotEmpty) {
      await Future.wait(pending);
    }

    print(
      '${_timestamp()} Batch upload complete: $successful successful, $failed failed, cancelled: $cancelled',
    );

    return UploadResult(
      successful: successful,
      failed: failed,
      cancelled: cancelled,
    );
  }
}

/// Result of batch upload operation
class UploadResult {
  final int successful;
  final int failed;
  final bool cancelled;

  UploadResult({
    required this.successful,
    required this.failed,
    required this.cancelled,
  });

  int get total => successful + failed;

  bool get allSuccessful => failed == 0 && !cancelled;

  @override
  String toString() {
    return 'UploadResult(successful: $successful, failed: $failed, cancelled: $cancelled)';
  }
}

/// Extension to check if a Future has completed
extension FutureExtension<T> on Future<T> {
  bool get isCompleted {
    bool completed = false;
    then((_) => completed = true).catchError((_) => completed = true);
    return completed;
  }
}
