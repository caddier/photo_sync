import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/http_sync_client.dart';

/// Common interface for media transport clients used by sync flow.
abstract class MediaTransportClient {
  Future<bool> testConnection();
  Future<bool> startSyncSession(String deviceName);
  Future<void> endSyncSession();
  void close();
  Future<bool> uploadPhoto({
    required AssetEntity asset,
    bool Function()? shouldCancel,
  });
  Future<bool> uploadVideo({
    required AssetEntity asset,
    bool Function()? shouldCancel,
    void Function(int sent, int total)? onProgress,
  });
}

/// Utility to derive a filename from an asset similar to previous logic.
String deriveFileId(AssetEntity asset) {
  final typePrefix = asset.type == AssetType.image ? 'IMG' : 'VID';
  final defaultExt = asset.type == AssetType.image ? 'jpg' : 'mp4';
  final normalizedId = asset.id.replaceAll('/', '_');
  return '${typePrefix}_${normalizedId}.$defaultExt';
}

class HttpTransportClient implements MediaTransportClient {
  final HttpSyncClient inner;
  HttpTransportClient(this.inner);
  @override
  Future<bool> testConnection() => inner.testConnection();
  @override
  Future<bool> startSyncSession(String deviceName) =>
      inner.startSyncSession(deviceName);
  @override
  Future<void> endSyncSession() => inner.endSyncSession();
  @override
  void close() => inner.close();
  @override
  Future<bool> uploadPhoto({
    required AssetEntity asset,
    bool Function()? shouldCancel,
  }) async {
    if (shouldCancel != null && shouldCancel()) return false;
    final fileId = deriveFileId(asset);
    final bytes = await asset.originBytes;
    if (bytes == null) return false;
    String mediaType = 'jpg';
    final dotIndex = fileId.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex < fileId.length - 1) {
      mediaType = fileId.substring(dotIndex + 1).toLowerCase();
    }
    return inner.uploadPhoto(
      fileId: fileId,
      imageBytes: bytes,
      mediaType: mediaType,
      shouldCancel: shouldCancel,
    );
  }

  @override
  Future<bool> uploadVideo({
    required AssetEntity asset,
    bool Function()? shouldCancel,
    void Function(int sent, int total)? onProgress,
  }) async {
    final fileId = deriveFileId(asset);
    String mediaType = 'mp4';
    final dotIndex = fileId.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex < fileId.length - 1) {
      mediaType = fileId.substring(dotIndex + 1).toLowerCase();
    }
    return inner.uploadVideo(
      asset: asset,
      fileId: fileId,
      mediaType: mediaType,
      shouldCancel: shouldCancel,
      onProgress: onProgress,
    );
  }
}
