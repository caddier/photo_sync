import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:async';
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

  AssetData(this.id, this.path, this.mimeType, this.type);
}

// Packet types for media sync
class MediaSyncPacketType {
  static const int photo = 1;
  static const int video = 2;
  static const int syncComplete = 3;
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
    final file = await asset.file;
    if (file == null) {
      throw Exception('Could not get file for asset ${asset.id}');
    }
    return AssetData(asset.id, file.path, asset.mimeType, asset.type);
  }

  /// Process asset in isolate - this is the isolate entry point
  static Future<PacketEnc> processAssetInIsolate(AssetData data) async {
    // Read file bytes directly using path
    final file = File(data.path);
    final bytes = await file.readAsBytes();
    print('Reading file at path: ${data.path}, bytes length: ${file.lengthSync()}');
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
      //type 3 is sync complete ack
      if (responsePacket.type == 3 && responseStr.contains('OK:$fileId')) {
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