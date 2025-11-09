import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/packet_enc.dart';
import 'package:photo_sync/server_conn.dart';

// Data class for passing asset info to isolate
class AssetData {
  final String id; // filename will be used as id
  final String path;
  final AssetType type;
  final Uint8List? bytes; // Add bytes field for iOS compatibility

  AssetData(this.id, this.path, this.type, {this.bytes});
}

//the over packet format is type(1byte) len(4bytes) data
//type are the following.

// Packet types for media sync
class MediaSyncPacketType {
  /// Type 1: Photo packet - client sends photo data to server
  /// Format: { "id": "IMG_123.jpg", "data": "base64_encoded_photo_data", "media": "jpg" }
  /// Server responds with syncComplete (type 3) containing "OK:IMG_123.jpg"
  static const int photo = 1;
  
  /// Type 2: Video packet - client sends video data to server
  /// Format: { "id": "VID_456.mp4", "data": "base64_encoded_video_data", "media": "mp4" }
  /// Server responds with syncComplete (type 3) containing "OK:VID_456.mp4"
  static const int video = 2;
  
  /// Type 3: Sync complete / acknowledgment
  /// Format (as response): "OK:filename" (e.g., "OK:IMG_123.jpg")
  /// Format (as final signal): empty data (Uint8List(0))
  static const int syncComplete = 3;
  
  /// Type 4: Sync start - client initiates sync session with device name
  /// Format: "device_name_string" (e.g., "John's iPhone")
  /// No server response expected
  static const int syncStart = 4;
  
  /// Type 5: Get media count request - client requests total media count from server
  /// Format: empty data (Uint8List(0))
  /// Server responds with mediaCountRsp (type 6)
  static const int getMediaCount = 5;
  
  /// Type 6: Media count response - server sends total media count
  /// Format: 4-byte or 8-byte big-endian integer (e.g., 0x00000042 for count=66)
  /// Fallback: UTF-8 string representation (e.g., "42")
  static const int mediaCountRsp = 6;
  
  /// Type 7: Media thumbnail list request - client requests page of thumbnails
  /// Format: { "pageIndex": 0, "pageSize": 12 }
  /// Server responds with mediaThumbData (type 8)
  static const int mediaThumbList = 7;
  
  /// Type 8: Media thumbnail data response - server sends thumbnail page
  /// Format: { "photos": [ { "id": "IMG_123.jpg", "media": "jpg", "data": "base64_thumb" }, ... ] }
  static const int mediaThumbData = 8;
  
  /// Type 9: Media deletion list - client sends list of media to delete
  /// Format: [ "IMG_123.jpg", "VID_456.mp4", ... ]
  /// Server responds with mediaDelAck (type 10)
  static const int mediaDelList = 9;
  
  /// Type 10: Media deletion acknowledgment - server confirms deletion
  /// Format: "OK" or error message
  static const int mediaDelAck = 10;
  
  /// Type 11: Media download list - client requests list of media to download
  /// Format: [ "IMG_123.jpg", "VID_456.mp4", ... ]
  /// Server responds with mediaDownloadAck (type 12)
  static const int mediaDownloadList = 11;
  
  /// Type 12: Media download acknowledgment - server sends requested media
  /// Format: media file data or error message
  static const int mediaDownloadAck = 12;
  
  /// Type 13: Chunked video start - client initiates chunked video transfer
  /// Format: { "id": "VID_456.mp4", "media": "mp4", "totalSize": 1234567890, "chunkSize": 10485760, "totalChunks": 118 }
  /// Server responds with syncComplete (type 3) containing "OK:START"
  static const int chunkedVideoStart = 13;
  
  /// Type 14: Chunked video data - client sends one chunk of video data
  /// Format: { "id": "VID_456.mp4", "chunkIndex": 0, "data": "base64_chunk_data" }
  /// Server responds with syncComplete (type 3) containing "OK:CHUNK:0"
  static const int chunkedVideoData = 14;
  
  /// Type 15: Chunked video complete - client signals all chunks sent
  /// Format: { "id": "VID_456.mp4", "totalChunks": 118 }
  /// Server responds with syncComplete (type 3) containing "OK:VID_456.mp4"
  static const int chunkedVideoComplete = 15;
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
  /// Get filename for an asset without loading the full file data
  /// This is useful for checking sync history before expensive file operations
  static Future<String> getAssetFilename(AssetEntity asset) async {
    String filename = '';
    String? filenameBase;
    
    // Try getting file and extracting filename
    try {
      final file = await asset.file;
      if (file != null && file.path.isNotEmpty) {
        // Extract just the filename from the path
        final pathParts = file.path.split('/');
        final filenamePart = pathParts.last;
        // Extract base name without extension
        if (filenamePart.isNotEmpty) {
          final dotIndex = filenamePart.lastIndexOf('.');
          if (dotIndex != -1) {
            filenameBase = filenamePart.substring(0, dotIndex);
          } else {
            filenameBase = filenamePart;
          }
        }
      }
    } catch (e) {
      print('Error accessing file for filename: $e');
    }
    
    // If we got a filename base, we need to detect extension from a small sample
    if (filenameBase != null && filenameBase.isNotEmpty) {
      // Normalize by replacing / with _ (for asset IDs like IMG_1234/L0/001)
      filenameBase = filenameBase.replaceAll('/', '_');
      
      // For videos, replace IMG prefix with VID if present
      if (asset.type == AssetType.video) {
        // Check if filename contains IMG_ and replace with VID_
        if (filenameBase.contains('IMG_')) {
          filenameBase = filenameBase.replaceAll('IMG_', 'VID_');
        } else if (filenameBase.toUpperCase().contains('IMG_')) {
          // Handle case-insensitive replacement
          filenameBase = filenameBase.replaceAllMapped(
            RegExp(r'IMG_', caseSensitive: false),
            (match) => 'VID_',
          );
        }
      }
      
      // Load only first 12 bytes for format detection
      Uint8List? sampleBytes;
      try {
        final file = await asset.file;
        if (file != null && file.existsSync()) {
          final fileBytes = await file.readAsBytes();
          sampleBytes = Uint8List.fromList(fileBytes.take(12).toList());
        }
      } catch (e) {
        print('Failed to read file sample for extension detection: $e');
      }
      
      if (sampleBytes == null || sampleBytes.isEmpty) {
        final originBytes = await asset.originBytes;
        if (originBytes != null && originBytes.isNotEmpty) {
          sampleBytes = Uint8List.fromList(originBytes.take(12).toList());
        }
      }
      
      if (sampleBytes != null && sampleBytes.isNotEmpty) {
        final detectedExtension = _detectImageExtension(sampleBytes, asset.type);
        filename = '$filenameBase.$detectedExtension';
      }
    }
    
    // Fallback: Generate filename from asset ID if previous method failed
    if (filename.isEmpty) {
      final typePrefix = asset.type == AssetType.image ? 'IMG' : 'VID';
      // Use a default extension based on type
      final defaultExt = asset.type == AssetType.image ? 'jpg' : 'mp4';
      // Normalize asset ID by replacing / with _
      final normalizedId = asset.id.replaceAll('/', '_');
      filename = '${typePrefix}_${normalizedId}.$defaultExt';
    }
    
    return filename;
  }

  /// Convert asset to packet - wrapper that handles isolate preparation
  static Future<PacketEnc> assetToPacket(AssetEntity asset) async {
    // First get the file path and prepare data for isolate
    final assetData = await prepareAssetData(asset);
    
    // For videos, process in main isolate to avoid passing large data
    // For images, use compute for better performance
    if (asset.type == AssetType.video) {
      return await _processVideoAsset(asset, assetData);
    } else {
      // Process images in isolate
      return compute(processAssetInIsolate, assetData);
    }
  }
  
  /// Process video asset in main isolate with chunked upload for large files
  /// Files over 50MB are sent in chunks to avoid memory issues
  static Future<PacketEnc> _processVideoAsset(AssetEntity asset, AssetData assetData) async {
    print('Processing video asset: ${assetData.id}');
    
    // This method now returns a dummy packet - actual upload is handled by sendVideoWithChunks
    // Extract media type from filename extension
    String mediaType = 'mp4';
    final dotIndex = assetData.id.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex < assetData.id.length - 1) {
      mediaType = assetData.id.substring(dotIndex + 1).toLowerCase();
    }
    
    // Return a minimal packet with metadata - the actual sending is handled separately
    final metadata = {
      'id': assetData.id,
      'media': mediaType,
      'chunked': true, // Flag to indicate this needs chunked upload
    };
    final jsonStr = jsonEncode(metadata);
    final jsonBytes = utf8.encode(jsonStr);
    
    return PacketEnc(MediaSyncPacketType.video, jsonBytes);
  }
  
  /// Send video file using chunked upload for large files
  /// This avoids loading the entire file into memory at once
  static Future<bool> sendVideoWithChunks(
    ServerConnection conn,
    AssetEntity asset,
    String fileId,
    String mediaType, {
    bool Function()? shouldCancel,
    void Function(int current, int total)? onProgress,
  }) async {
    // Chunk size: 10MB per chunk (balance between memory and network efficiency)
    const int chunkSize = 10 * 1024 * 1024; // 10MB
    
    // Get file handle
    final file = await asset.file;
    if (file == null || !file.existsSync()) {
      print('Video file not found for chunked upload: $fileId');
      return false;
    }
    
    final fileSize = await file.length();
    final totalChunks = (fileSize / chunkSize).ceil();
    
    print('Starting chunked upload for $fileId: ${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB in $totalChunks chunks');
    
    // Step 1: Send start packet
    final startPacket = PacketEnc(
      MediaSyncPacketType.chunkedVideoStart,
      utf8.encode(jsonEncode({
        'id': fileId,
        'media': mediaType,
        'totalSize': fileSize,
        'chunkSize': chunkSize,
        'totalChunks': totalChunks,
      })),
    );
    
    try {
      final encoded = startPacket.encode();
      await conn.sendData(encoded);
      
      // Wait for start acknowledgment
      final startResponse = await _waitForResponse(conn, timeout: const Duration(seconds: 10), shouldCancel: shouldCancel);
      final startResponseStr = utf8.decode(startResponse.data);
      if (!startResponseStr.contains('OK:START')) {
        print('Server did not acknowledge chunked upload start');
        return false;
      }
      print('Server acknowledged chunked upload start');
    } catch (e) {
      print('Error sending chunked upload start: $e');
      return false;
    }
    
    // Step 2: Send chunks
    final fileHandle = await file.open();
    try {
      for (int chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        // Check for cancellation
        if (shouldCancel != null && shouldCancel()) {
          print('Chunked upload cancelled at chunk $chunkIndex');
          await fileHandle.close();
          return false;
        }
        
        // Calculate chunk bounds
        final startByte = chunkIndex * chunkSize;
        final endByte = ((chunkIndex + 1) * chunkSize).clamp(0, fileSize);
        final currentChunkSize = endByte - startByte;
        
        // Read chunk from file
        await fileHandle.setPosition(startByte);
        final chunkBytes = await fileHandle.read(currentChunkSize);
        
        // Encode chunk to base64
        final base64Chunk = base64Encode(chunkBytes);
        
        // Create chunk packet
        final chunkPacket = PacketEnc(
          MediaSyncPacketType.chunkedVideoData,
          utf8.encode(jsonEncode({
            'id': fileId,
            'chunkIndex': chunkIndex,
            'data': base64Chunk,
          })),
        );
        
        print('Sending chunk $chunkIndex/${totalChunks - 1} (${(currentChunkSize / 1024).toStringAsFixed(1)} KB)');
        
        // Send chunk and wait for ACK
        try {
          final encodedChunk = chunkPacket.encode();
          await conn.sendData(encodedChunk);
          
          // Calculate timeout based on chunk size (1.5s per MB)
          final chunkSizeMB = currentChunkSize / (1024 * 1024);
          final timeoutSeconds = (10 + chunkSizeMB * 1.5).ceil().clamp(10, 60);
          final timeout = Duration(seconds: timeoutSeconds);
          
          final chunkResponse = await _waitForResponse(conn, timeout: timeout, shouldCancel: shouldCancel);
          final chunkResponseStr = utf8.decode(chunkResponse.data);
          if (!chunkResponseStr.contains('OK:CHUNK:$chunkIndex')) {
            print('Server did not acknowledge chunk $chunkIndex');
            await fileHandle.close();
            return false;
          }
          
          // Progress update
          final progress = ((chunkIndex + 1) / totalChunks * 100).toStringAsFixed(1);
          print('Chunk $chunkIndex ACK received - Progress: $progress%');
          
          // Notify progress callback
          if (onProgress != null) {
            onProgress(chunkIndex + 1, totalChunks);
          }
        } catch (e) {
          print('Error sending chunk $chunkIndex: $e');
          await fileHandle.close();
          return false;
        }
        
        // Small delay between chunks to allow GC
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      await fileHandle.close();
    }
    
    // Step 3: Send complete packet
    final completePacket = PacketEnc(
      MediaSyncPacketType.chunkedVideoComplete,
      utf8.encode(jsonEncode({
        'id': fileId,
        'totalChunks': totalChunks,
      })),
    );
    
    try {
      final encoded = completePacket.encode();
      await conn.sendData(encoded);
      
      // Wait for final acknowledgment
      final completeResponse = await _waitForResponse(conn, timeout: const Duration(seconds: 30), shouldCancel: shouldCancel);
      final completeResponseStr = utf8.decode(completeResponse.data);
      if (completeResponse.type == MediaSyncPacketType.syncComplete && completeResponseStr.contains('OK:$fileId')) {
        print('Chunked upload completed successfully for $fileId');
        return true;
      } else {
        print('Server did not acknowledge chunked upload completion');
        return false;
      }
    } catch (e) {
      print('Error sending chunked upload complete: $e');
      return false;
    }
  }

  /// Prepare asset data for isolate
  static Future<AssetData> prepareAssetData(AssetEntity asset) async {
    Uint8List? bytes;
    
    if (asset.type == AssetType.video) {
      // For videos, only load first 12 bytes for format detection to avoid OOM
      // We'll load the full video later in a streaming fashion
      try {
        final file = await asset.file;
        if (file != null && file.existsSync()) {
          final fileBytes = await file.readAsBytes();
          // Only keep first 12 bytes for format detection
          bytes = Uint8List.fromList(fileBytes.take(12).toList());
          print('Video format detection: loaded ${bytes.length} bytes from file');
        }
      } catch (e) {
        print('Failed to read video file for format detection: $e');
      }
      
      // Fallback: try originBytes but only take first 12 bytes
      if (bytes == null || bytes.isEmpty) {
        final originBytes = await asset.originBytes;
        if (originBytes != null && originBytes.isNotEmpty) {
          bytes = Uint8List.fromList(originBytes.take(12).toList());
          print('Video format detection: loaded ${bytes.length} bytes from originBytes');
        }
      }
    } else {
      // For images, load full bytes (they're typically much smaller)
      bytes = await asset.originBytes;
    }
    
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Could not get bytes for asset ${asset.id}');
    }
    
    // Use the centralized filename generation function
    final filename = await getAssetFilename(asset);
    print('Prepared filename for asset: $filename asset.type=${asset.type}');
    
    // For videos, don't pass the bytes to isolate (just filename info)
    // For images, pass the full bytes
    return AssetData(filename, filename, asset.type, 
      bytes: asset.type == AssetType.image ? bytes : null);
  }

  /// Detect image/video extension from file bytes
  static String _detectImageExtension(Uint8List bytes, AssetType type) {
    if (type == AssetType.video) {
      // Check video signatures
      if (bytes.length >= 12) {
        // MP4/MOV (ftyp box)
        if (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
          // Check specific brand
          final brand = String.fromCharCodes(bytes.sublist(8, 12));
          if (brand.startsWith('qt') || brand.startsWith('mov')) {
            return 'mov';
          }
          return 'mp4';
        }
      }
      return 'mp4'; // default for videos
    }
    
    // Check image signatures
    if (bytes.length >= 12) {
      // JPEG (FF D8 FF)
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return 'jpg';
      }
      
      // PNG (89 50 4E 47)
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
        return 'png';
      }
      
      // GIF (47 49 46 38)
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
        return 'gif';
      }
      
      // WebP (RIFF ... WEBP)
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
          bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
        return 'webp';
      }
      
      // HEIC/HEIF (ftyp box with heic/mif1/msf1 brand)
      if (bytes.length >= 12 &&
          bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
        final brand = String.fromCharCodes(bytes.sublist(8, 12));
        if (brand == 'heic' || brand == 'heix' || brand == 'hevc' || 
            brand == 'heim' || brand == 'heis' || brand == 'hevm' ||
            brand == 'mif1' || brand == 'msf1') {
          return 'heic';
        }
      }
      
      // BMP (42 4D)
      if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
        return 'bmp';
      }
    }
    
    // Default fallback
    return 'jpg';
  }

  /// Process asset in isolate - this is the isolate entry point (used for images only)
  static Future<PacketEnc> processAssetInIsolate(AssetData data) async {
    // This should only be called for images now
    if (data.bytes == null) {
      throw Exception('No bytes provided for asset ${data.id}');
    }
    
    final bytes = data.bytes!;
    print('Processing asset: ${data.id}, bytes length: ${bytes.length}');
    // Convert to base64
    final base64Data = base64Encode(bytes);
    
    // Extract media type from filename extension
    String mediaType = 'bin';
    final dotIndex = data.id.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex < data.id.length - 1) {
      mediaType = data.id.substring(dotIndex + 1).toLowerCase();
    }

    // Create media packet
    final mediaPacket = MediaPacket(data.id, base64Data, mediaType);
    
    // Convert to JSON
    final jsonStr = jsonEncode(mediaPacket.toJson());

    
    // Convert to bytes and compress with LZMA
    final jsonBytes = utf8.encode(jsonStr);
    
    
    // Create packet with appropriate type (should always be photo for this method)
    final packetType = data.type == AssetType.image 
        ? MediaSyncPacketType.photo 
        : MediaSyncPacketType.video;
        
    return PacketEnc(packetType, jsonBytes);
  }

  /// Send packet and wait for acknowledgment
  static Future<bool> sendPacketWithAck(ServerConnection conn, PacketEnc packet, [String? fileId, bool Function()? shouldCancel]) async {
    // If fileId is not provided, extract it from the packet data
    String actualFileId = fileId ?? '';
    if (actualFileId.isEmpty) {
      try {
        final jsonStr = utf8.decode(packet.data);
        final jsonData = jsonDecode(jsonStr) as Map<String, dynamic>;
        actualFileId = jsonData['id'] as String? ?? '';
      } catch (e) {
        print('Failed to extract fileId from packet: $e');
      }
    }
    
    // Calculate timeout based on packet size
    // Assume upload speed of 1MB/s (conservative for mobile networks)
    // Add base timeout of 10 seconds for processing
    final packetSizeBytes = packet.data.length;
    final packetSizeMB = packetSizeBytes / (1024 * 1024);
    final baseTimeoutSeconds = 10;
    final uploadTimeSeconds = (packetSizeMB * 1.5).ceil(); // 1.5s per MB to be conservative
    final timeoutSeconds = baseTimeoutSeconds + uploadTimeSeconds;
    final timeout = Duration(seconds: timeoutSeconds.clamp(10, 300)); // Min 10s, max 5 minutes
    
    print('Sending packet (${(packetSizeMB).toStringAsFixed(2)} MB), timeout: ${timeout.inSeconds}s');
    
    final encoded = packet.encode();
    await conn.sendData(encoded);

    // Wait for server response with calculated timeout and cancel support
    try {
      final responsePacket = await _waitForResponse(conn, timeout: timeout, shouldCancel: shouldCancel);
      print('response msg $responsePacket');
      final responseStr = utf8.decode(responsePacket.data);
      // syncComplete is used as the ack type
      if (responsePacket.type == MediaSyncPacketType.syncComplete && responseStr.contains('OK:$actualFileId')) {
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
  static Future<PacketEnc> _waitForResponse(ServerConnection conn, {Duration timeout = const Duration(seconds: 10), bool Function()? shouldCancel}) async {
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

    // Periodically check for cancel flag (every 100ms)
    Timer? cancelCheckTimer;
    if (shouldCancel != null) {
      cancelCheckTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (shouldCancel()) {
          timer.cancel();
          subscription.cancel();
          if (!completer.isCompleted) {
            completer.completeError('Operation cancelled by user');
          }
        }
      });
    }

    // Add timeout with configurable duration
    Timer? timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        subscription.cancel();
        cancelCheckTimer?.cancel();
        completer.completeError('Timeout waiting for server response after ${timeout.inSeconds}s');
      }
    });

    // Clean up timers when future completes
    completer.future.whenComplete(() {
      timeoutTimer.cancel();
      cancelCheckTimer?.cancel();
    });

    return completer.future;
  }

  /// Send complete signal
  static Future<void> sendSyncComplete(ServerConnection conn) async {
    final packet = PacketEnc(MediaSyncPacketType.syncComplete, Uint8List(0));
    await sendPacketWithAck(conn, packet, "sync_complete", null); // No cancel check for sync complete
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

  /// Get all file IDs from server by fetching all pages
  /// This is useful for syncing local database with server state
  static Future<List<String>> getAllServerFileIds(ServerConnection conn) async {
    try {
      // First get total count
      final totalCount = await getMediaCount(conn);
      if (totalCount == 0) {
        return [];
      }

      print('Fetching all server file IDs (total: $totalCount)...');
      
      // Fetch all pages with larger page size for efficiency
      const pageSize = 100;
      final totalPages = (totalCount / pageSize).ceil();
      final allFileIds = <String>[];

      for (int page = 0; page < totalPages; page++) {
        print('Fetching page ${page + 1}/$totalPages...');
        final thumbList = await getMediaThumbList(conn, page, pageSize);
        allFileIds.addAll(thumbList.map((item) => item.id));
      }

      print('Retrieved ${allFileIds.length} file IDs from server');
      return allFileIds;
    } catch (e) {
      print('Error getting all server file IDs: $e');
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