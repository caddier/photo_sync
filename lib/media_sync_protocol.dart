import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/packet_enc.dart';
import 'package:photo_sync/server_conn.dart';

// Data class for passing asset info to isolate
class AssetData {
  final String id;
  final String path;
  final String? mimeType;
  final AssetType type;
  final Uint8List? bytes; // Add bytes field for iOS compatibility

  AssetData(this.id, this.path, this.mimeType, this.type, {this.bytes});
}

// Packet types for media sync
class MediaSyncPacketType {
  static const int photo = 1;
  static const int video = 2;
  static const int syncComplete = 3;
  static const int syncStart = 4; // client sync start request , set client phone name as data
  static const int getMediaCount = 5; // get total media count request
  static const int mediaCountRsp = 6; // response with total media count
  static const int mediaThumbList = 7; // request for media thumbnail list, there is a page index and page size in data
  static const int mediaThumbData = 8; // response with media thumbnail data
  static const int mediaDelList = 9; // request for media deletion list
  static const int mediaDelAck = 10; // acknowledgment for media deletion request
  static const int mediaDownloadList = 11; // request for media download
  static const int mediaDownloadAck = 12; // acknowledgment for media download request
}

class MediaPacket {
  final String id;
  final String data;  // base64 encoded data
  final String media; // media type string (jpg/png/mp4/etc)

  MediaPacket(this.id, this.data, this.media);

  Map<String, dynamic> toJson() => {
    'id': id,
    'data': data,
    'media': media,
  };

  static MediaPacket fromJson(Map<String, dynamic> json) {
    return MediaPacket(
      json['id'] as String,
      json['data'] as String,
      (json['media'] as String?) ?? 'bin',
    );
  }
}

class MediaSyncProtocol {
  /// Convert asset to packet - wrapper that handles isolate preparation
  static Future<PacketEnc> assetToPacket(AssetEntity asset) async {
    // First get the file path and prepare data for isolate
    final assetData = await prepareAssetData(asset);
    // Process in isolate
    return compute(processAssetInIsolate, assetData);
  }

  /// Prepare asset data for isolate
  static Future<AssetData> prepareAssetData(AssetEntity asset) async {
    // On iOS, asset.file returns internal .bin paths that can't be read directly
    // Use originBytes instead which works on both platforms
    final bytes = await asset.originBytes;
    if (bytes == null) {
      throw Exception('Could not get bytes for asset ${asset.id}');
    }
    
    // Get the filename with extension for proper file type identification
    // On iOS, try multiple methods to get the proper filename
    String filename = '';
    
    // Try 1: Use title (original filename)
    if (asset.title != null && asset.title!.isNotEmpty) {
      filename = asset.title!;
    }
    
    // Try 2: If title is empty, try getting file and extracting filename
    if (filename.isEmpty) {
      try {
        final file = await asset.file;
        if (file != null && file.path.isNotEmpty) {
          // Extract just the filename from the path
          final pathParts = file.path.split('/');
          final filenamePart = pathParts.last;
          // On iOS, even if it's .bin, we can at least get the structure
          if (filenamePart.isNotEmpty && !filenamePart.endsWith('.bin')) {
            filename = filenamePart;
          }
        }
      } catch (e) {
        // File access failed, continue to next method
      }
    }
    
    // Try 3: Derive filename from mimeType and asset properties
    if (filename.isEmpty) {
      // Determine extension from mimeType or use default based on asset type
      String extension;
      if (asset.mimeType != null) {
        extension = _extensionFromMime(asset.mimeType) ?? (asset.type == AssetType.image ? 'jpg' : 'mp4');
      } else {
        extension = asset.type == AssetType.image ? 'jpg' : 'mp4';
      }
      
      // Use asset type and ID to make a meaningful name
      final typePrefix = asset.type == AssetType.image ? 'IMG' : 'VID';
      filename = '${typePrefix}_${asset.id}.$extension';
    }
    
    return AssetData(asset.id, filename, asset.mimeType, asset.type, bytes: bytes);
  }

  /// Process asset in isolate - this is the isolate entry point
  static Future<PacketEnc> processAssetInIsolate(AssetData data) async {
    // Use the bytes directly (already loaded from originBytes)
    final bytes = data.bytes!;
    print('Processing asset: ${data.id}, bytes length: ${bytes.length}');
    // Convert to base64
    final base64Data = base64Encode(bytes);
    

    // Determine media type (extension) from mimeType when available
    String mediaType = _extensionFromMime(data.mimeType) ?? 'bin';

    // Create media packet
    final mediaPacket = MediaPacket(data.id, base64Data, mediaType);
    
    // Convert to JSON
    final jsonStr = jsonEncode(mediaPacket.toJson());

    
    // Convert to bytes and compress with LZMA
    final jsonBytes = utf8.encode(jsonStr);
    
    
    // Create packet with appropriate type
    final packetType = data.type == AssetType.image 
        ? MediaSyncPacketType.photo 
        : MediaSyncPacketType.video;
        
    return PacketEnc(packetType, jsonBytes);
  }

  /// Send packet and wait for acknowledgment
  static Future<bool> sendPacketWithAck(ServerConnection conn, PacketEnc packet, String fileId) async {
    final encoded = packet.encode();
    await conn.sendData(encoded);

    // Wait for server response
    try {
      final responsePacket = await _waitForResponse(conn);
      print('response msg $responsePacket');
      final responseStr = utf8.decode(responsePacket.data);
      // syncComplete is used as the ack type
      if (responsePacket.type == MediaSyncPacketType.syncComplete && responseStr.contains('OK:$fileId')) {
        // Sync complete ack
        return true;
      }
      
      return false;
    } catch (e) {
      print('Error waiting for ack: $e');
      return false;
    }
  }

  /// Wait for a response packet from the server
  static Future<PacketEnc> _waitForResponse(ServerConnection conn) async {
    final completer = Completer<PacketEnc>();

    // Buffer to accumulate incoming data
    List<int> buffer = [];
    late StreamSubscription subscription;

    subscription = conn.onData.listen((List<int> data) {
      try {
        buffer.addAll(data);
        final packet = PacketEnc.decode(Uint8List.fromList(buffer));
        if (packet != null) {
          subscription.cancel();
          completer.complete(packet);
        }
      } catch (e) {
        subscription.cancel();
        completer.completeError(e);
      }
    }, onError: (error) {
      subscription.cancel();
      if (!completer.isCompleted) completer.completeError(error);
    });

    // Add timeout
    Future.delayed(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        subscription.cancel();
        completer.completeError('Timeout waiting for server response');
      }
    });

    return completer.future;
  }

  /// Send complete signal
  static Future<void> sendSyncComplete(ServerConnection conn) async {
    final packet = PacketEnc(MediaSyncPacketType.syncComplete, Uint8List(0));
    await sendPacketWithAck(conn, packet, "sync_complete");
  }

  /// Send client sync start request
  static Future<void> sendSyncStart(ServerConnection conn, String phoneName) async {
    // Use syncStart for sync start, data is phone name
    final startPacket = PacketEnc(MediaSyncPacketType.syncStart, utf8.encode(phoneName));
    await conn.sendData(startPacket.encode());
  }

  /// Request total media count from server
  static Future<int> getMediaCount(ServerConnection conn) async {
    // Send getMediaCount request with no data
    final packet = PacketEnc(MediaSyncPacketType.getMediaCount, Uint8List(0));
    await conn.sendData(packet.encode());

    // Wait for server response
    try {
      final responsePacket = await _waitForResponse(conn);
      // Expect a binary integer (big-endian) in data
      if (responsePacket.type == MediaSyncPacketType.mediaCountRsp) {
        final data = responsePacket.data;
        if (data.isEmpty) return 0;

        try {
          // Prefer 64-bit if server sends 8 bytes, else fallback to 32-bit (first 4 bytes)
          final bd = ByteData.sublistView(data);
          if (data.length >= 8) {
            final v = bd.getUint64(0, Endian.big);
            // Dart int is arbitrary precision; ensure it fits typical ranges
            return v > 0x7fffffff ? v.clamp(0, 0x7fffffff).toInt() : v.toInt();
          } else if (data.length >= 4) {
            return bd.getUint32(0, Endian.big);
          }
        } catch (e) {
          // Fall through to string parse fallback below
          print('Error decoding binary media count: $e');
        }
      } else {
        print('Unexpected packet type for media count: ${responsePacket.type}');
      }

      // Fallback: some servers may still send count as UTF-8 string
      try {
        final responseStr = utf8.decode(responsePacket.data);
        return int.parse(responseStr);
      } catch (_) {
        // ignore
      }
      return 0;
    } catch (e) {
      print('Error getting media count: $e');
      return 0;
    }
  }

  /// Request media thumbnail list from server
  /// [pageIndex] is the page number (0-based)
  /// [pageSize] is the number of items per page
  /// Returns a list of thumbnail data as MediaThumbItem
  static Future<List<MediaThumbItem>> getMediaThumbList(
    ServerConnection conn, 
    int pageIndex, 
    int pageSize
  ) async {
    // Create request data with page index and page size
    final requestData = jsonEncode({
      'pageIndex': pageIndex,
      'pageSize': pageSize,
    });
    
    final packet = PacketEnc(
      MediaSyncPacketType.mediaThumbList, 
      utf8.encode(requestData)
    );
    await conn.sendData(packet.encode());

    // Wait for server response
    try {
      final responsePacket = await _waitForResponse(conn);
      if (responsePacket.type != MediaSyncPacketType.mediaThumbData) {
        print('Unexpected response type: ${responsePacket.type}');
        return [];
      }

      // Parse the response data
      final responseStr = utf8.decode(responsePacket.data);
      final responseJson = jsonDecode(responseStr) as Map<String, dynamic>;
      
      // Expected format: { "photos": [ { "id": "...", "media": "jpg", "data": "base64..." }, ... ] }
      final photosList = responseJson['photos'] as List<dynamic>?;
      if (photosList == null) return [];

      return photosList.map((item) => MediaThumbItem.fromJson(item as Map<String, dynamic>)).toList();
    } catch (e) {
      print('Error getting media thumb list: $e');
      return [];
    }
  }
}

/// Data class for media thumbnail item
class MediaThumbItem {
  final String id;
  final String thumbData; // base64 encoded thumbnail data
  final String media; // media type (jpg, png, mp4, etc.)
  final bool isVideo;

  MediaThumbItem({
    required this.id,
    required this.thumbData,
    required this.media,
    required this.isVideo,
  });

  factory MediaThumbItem.fromJson(Map<String, dynamic> json) {
    final mediaType = json['media'] as String? ?? '';
    final data = json['data'] as String? ?? '';
    
    // Determine if it's a video based on media type
    final isVideo = _isVideoMediaType(mediaType);
    
    return MediaThumbItem(
      id: json['id'] as String,
      thumbData: data,
      media: mediaType,
      isVideo: isVideo,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'data': thumbData,
    'media': media,
  };

  static bool _isVideoMediaType(String media) {
    const videoTypes = {'mp4', 'mov', 'avi', 'wmv', '3gp', '3g2', 'mkv', 'webm', 'flv', 'video'};
    return videoTypes.contains(media.toLowerCase());
  }
}

// Helper: derive a short file extension-like media string from a mime type
String? _extensionFromMime(String? mime) {
  if (mime == null) return null;
  // mime may include parameters like 'image/jpeg; charset=UTF-8'
  final primary = mime.split(';').first.trim();
  final parts = primary.split('/');
  if (parts.length != 2) return null;
  var subtype = parts[1].toLowerCase();

  // common mappings
  const mapping = {
    'jpeg': 'jpg',
    'jpg': 'jpg',
    'png': 'png',
    'webp': 'webp',
    'mp4': 'mp4',
    'quicktime': 'mov',
    'x-msvideo': 'avi',
    'x-ms-wmv': 'wmv',
    'gif': 'gif',
    'heic': 'heic',
    'heif': 'heif',
    '3gpp': '3gp',
    '3gpp2': '3g2',
  };

  return mapping[subtype] ?? subtype;
}