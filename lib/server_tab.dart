import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:photo_sync/device_finder.dart';
import 'package:photo_sync/server_conn.dart';
import 'package:photo_sync/media_sync_protocol.dart';
import 'package:photo_sync/sync_history.dart';
import 'package:photo_sync/media_eumerator.dart';
import 'package:photo_sync/packet_enc.dart';

class ServerTab extends StatefulWidget {
  final DeviceInfo? selectedServer;

  const ServerTab({super.key, this.selectedServer});

  @override
  State<ServerTab> createState() => _ServerTabState();
}

class _ServerTabState extends State<ServerTab> with WidgetsBindingObserver {
  int _currentPage = 0;
  static const int _itemsPerPage = 12;
  List<ServerMediaItem> _mediaItems = [];
  Set<int> _selectedIndexes = {}; // Indexes of selected items
  bool _loading = false;
  int _totalMediaCount = 0;
  ServerConnection? _connection; // Persistent connection
  Set<String> _localMediaFilenames = {}; // Cache of local media filenames (without extensions)
  bool _localMediaLoaded = false;

  // selectedServer is now provided via the widget constructor from MainTabPage

  // dispose is implemented at the end to also remove lifecycle observer

  void _closeConnection() {
    if (_connection != null) {
      try {
        _connection!.disconnect();
      } catch (e) {
        print('Error closing connection: $e');
      }
      _connection = null;
    }
  }

  Future<ServerConnection> _ensureConnection() async {
    final server = widget.selectedServer;
    if (server == null) {
      throw Exception('No server selected');
    }

    // If connection exists and is connected, reuse it
    if (_connection != null) {
      // Check if connection is still alive (you may want to add a ping/check method)
      print('ServerTab: Reusing existing connection');
      return _connection!;
    }

    print('ServerTab: Creating new connection to ${server.ipAddress}:9922');
    // Create new connection
    _connection = ServerConnection(server.ipAddress ?? '', 9922);
    await _connection!.connect();
    print('ServerTab: Connected successfully');

    // Send phone name (sync start) for new connections
    // Get device name (will use saved name from database or fallback to system name)
    String phoneName = await DeviceManager.getLocalDeviceName();
    
    print('Sending sync start with device name: $phoneName');
    await MediaSyncProtocol.sendSyncStart(_connection!, phoneName);
    print('ServerTab: Sync start sent successfully');

    return _connection!;
  }

  Future<void> _refreshGallery() async {
    if (_loading) return;
    if (mounted) {
      setState(() { _loading = true; });
    }

    try {
      // Use selected server passed from parent
      final server = widget.selectedServer;

      if (server == null) {
        print('no server selected');
        // No server selected, show empty gallery and close any existing connection
        _closeConnection();
        if (!mounted) return;
        setState(() {
          _mediaItems = [];
          _totalMediaCount = 0;
          _loading = false;
          _currentPage = 0;
        });
        return;
      }

      print('ServerTab: Connecting to server ${server.deviceName}...');
      // Get or create connection
      final conn = await _ensureConnection();
      print('ServerTab: Connection established, requesting media count...');

      // 2. Request media count
      final count = await MediaSyncProtocol.getMediaCount(conn);
      print('ServerTab: Received media count: $count');

      if (!mounted) return;
      
      // Update the UI with the count
      setState(() {
        _totalMediaCount = count;
      });

      // 3. Request media thumbnail list for the current page
      if (count > 0) {
        print('ServerTab: Requesting thumbnail list for page $_currentPage...');
        final thumbList = await MediaSyncProtocol.getMediaThumbList(
          conn, 
          _currentPage, // refresh current page
          _itemsPerPage
        );
        print('ServerTab: Received ${thumbList.length} thumbnails');

        if (!mounted) return;
        // Update the UI with the thumbnail data
        setState(() {
          _mediaItems = thumbList.map((thumb) => ServerMediaItem(
            id: thumb.id,
            thumbData: thumb.thumbData,
            isVideo: thumb.isVideo,
          )).toList();
          // Do not reset _currentPage here
          _loading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _mediaItems = [];
          _loading = false;
        });
      }

      // Keep connection open for pagination
    } catch (e) {
      print('Error refreshing gallery: $e');
      _closeConnection(); // Close connection on error
      if (!mounted) return;
      setState(() {
        _mediaItems = [];
        _totalMediaCount = 0;
        _loading = false;
      });
    }
  }

  Future<void> _loadPage(int pageIndex) async {
    if (_loading) return;
    
    setState(() { _loading = true; });

    try {
      // Use selected server passed from parent
      final server = widget.selectedServer;

      if (server == null) {
        if (!mounted) return;
        setState(() { _loading = false; });
        return;
      }

      // Reuse existing connection
      final conn = await _ensureConnection();

      // Request media thumbnail list for the specified page
      final thumbList = await MediaSyncProtocol.getMediaThumbList(
        conn, 
        pageIndex,
        _itemsPerPage
      );

      if (!mounted) return;
      
      // Update the UI with the thumbnail data for this page
      setState(() {
        _mediaItems = thumbList.map((thumb) => ServerMediaItem(
          id: thumb.id,
          thumbData: thumb.thumbData,
          isVideo: thumb.isVideo,
        )).toList();
        _currentPage = pageIndex;
        _loading = false;
      });
    } catch (e) {
      print('Error loading page: $e');
      _closeConnection(); // Close connection on error and will reconnect next time
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _syncDatabaseWithServer() async {
    if (_loading) return;

    final server = widget.selectedServer;
    if (server == null) {
      _showMessage('Please select a server first');
      return;
    }

    setState(() { _loading = true; });

    try {
      _showMessage('Syncing database with server...');
      
      // Get connection
      final conn = await _ensureConnection();
      
      // Get all file IDs from server
      final serverFileIds = await MediaSyncProtocol.getAllServerFileIds(conn);
      
      // Sync local database with server data
      final history = SyncHistory();
      await history.syncWithServer(serverFileIds);
      
      if (!mounted) return;
      
      _showMessage('Database synced: ${serverFileIds.length} files on server');
      
      // Refresh the gallery after sync
      await _refreshGallery();
    } catch (e) {
      print('Error syncing database: $e');
      if (!mounted) return;
      _showMessage('Error syncing database: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() { _loading = false; });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Load all local media filenames using MediaSyncProtocol.getAssetFilename
  Future<void> _loadLocalMediaFilenames() async {
    if (_localMediaLoaded) return; // Already loaded
    
    try {
      print('Loading local media filenames using getAssetFilename...');
      final assets = await MediaEnumerator.getAllLocalAssets();
      final Set<String> filenames = {};
      
      // Use MediaSyncProtocol.getAssetFilename to get consistent filenames
      for (var asset in assets) {
        try {
          final filename = await MediaSyncProtocol.getAssetFilename(asset);
          // Remove extension for comparison
          final lastDot = filename.lastIndexOf('.');
          if (lastDot > 0) {
            final filenameWithoutExt = filename.substring(0, lastDot);
            filenames.add(filenameWithoutExt);
          }
        } catch (e) {
          print('Error getting filename for asset: $e');
        }
      }
      
      if (mounted) {
        setState(() {
          _localMediaFilenames = filenames;
          _localMediaLoaded = true;
        });
        print('Loaded ${filenames.length} local media filenames');
      }
    } catch (e) {
      print('Error loading local media filenames: $e');
    }
  }

  /// Check if a server file exists in local library by comparing filenames without extensions
  bool _isMediaInLocalLibrary(String serverFileId) {
    // Extract filename without extension from server file ID
    String filenameWithoutExt = serverFileId;
    final lastDot = serverFileId.lastIndexOf('.');
    if (lastDot > 0) {
      filenameWithoutExt = serverFileId.substring(0, lastDot);
    }
    
    return _localMediaFilenames.contains(filenameWithoutExt);
  }

  Widget _buildMediaWidget(ServerMediaItem item) {
    // If we have thumbData (base64), decode and display it
    if (item.thumbData != null && item.thumbData!.isNotEmpty) {
      try {
        final bytes = base64Decode(item.thumbData!);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (c, e, s) => Container(
            color: Colors.grey[300],
            child: const Center(child: Icon(Icons.broken_image)),
          ),
        );
      } catch (e) {
        print('Error decoding thumbnail: $e');
        return Container(
          color: Colors.grey[300],
          child: const Center(child: Icon(Icons.broken_image)),
        );
      }
    }
    
    // Fallback to URL if available
    if (item.url != null && item.url!.isNotEmpty) {
      return Image.network(
        item.url!,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => Container(
          color: Colors.grey[300],
          child: const Center(child: Icon(Icons.broken_image)),
        ),
      );
    }
    
    // Default placeholder
    return Container(
      color: Colors.grey[300],
      child: const Center(child: Icon(Icons.image, color: Colors.black45)),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLocalMediaFilenames(); // Load local media filenames in background
    _refreshGallery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When app goes to background, close the connection to avoid stale sockets
    // When app resumes, refresh to recreate connection and reload current page
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _closeConnection();
    } else if (state == AppLifecycleState.resumed) {
      // Delay slightly to let UI settle
      Future.microtask(() {
        if (mounted) {
          // Try to reload the current page using a fresh connection
          if (_totalMediaCount > 0) {
            _loadPage(_currentPage);
          } else {
            _refreshGallery();
          }
        }
      });
    }
  }

  @override
  void didUpdateWidget(ServerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the selected server changed, close the old connection and refresh
    if (oldWidget.selectedServer?.deviceName != widget.selectedServer?.deviceName) {
      _closeConnection();
      _refreshGallery();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closeConnection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Calculate total number of pages based on total media count from server
    final pageCount = (_totalMediaCount / _itemsPerPage).ceil();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_selectedIndexes.isNotEmpty)
                      ElevatedButton.icon(
                        onPressed: _loading ? null : _downloadSelected,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Download', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(80, 28),
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    if (_selectedIndexes.isNotEmpty)
                      const SizedBox(width: 6),
                    ElevatedButton.icon(
                      onPressed: _loading ? null : _refreshGallery,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(80, 28),
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton.icon(
                      onPressed: _loading ? null : _syncDatabaseWithServer,
                      icon: const Icon(Icons.sync, size: 16),
                      label: const Text('Sync DB', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(80, 28),
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    if (pageCount > 1) ...[
                      const SizedBox(width: 10),
                      DropdownButton<int>(
                        value: _currentPage,
                        items: List.generate(pageCount, (i) => DropdownMenuItem(
                          value: i,
                          child: Text('Page ${i + 1}', style: const TextStyle(fontSize: 12)),
                        )),
                        onChanged: _loading ? null : (int? selected) {
                          if (selected != null && selected != _currentPage) {
                            _loadPage(selected);
                          }
                        },
                        underline: Container(),
                        style: const TextStyle(fontSize: 12, color: Colors.black),
                        isDense: true,
                      ),
                    ],
                  ],
                ),
              ),
              if (_totalMediaCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Total: $_totalMediaCount items',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _mediaItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            'No media on server',
                            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Select a server and tap Refresh',
                            style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: _mediaItems.length,
                  itemBuilder: (context, idx) {
                    final item = _mediaItems[idx];
                    final isInLibrary = item.id != null && _isMediaInLocalLibrary(item.id!);
                    final isSelected = _selectedIndexes.contains(idx);
                    return GestureDetector(
                      onTap: (!isInLibrary && !_loading)
                          ? () {
                              setState(() {
                                if (isSelected) {
                                  _selectedIndexes.remove(idx);
                                } else {
                                  _selectedIndexes.add(idx);
                                }
                              });
                            }
                          : null,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _buildMediaWidget(item),
                            ),
                          ),
                          if (item.isVideo)
                            Positioned(
                              right: 4,
                              bottom: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.videocam, color: Colors.white, size: 14),
                                    SizedBox(width: 4),
                                    Text(
                                      'VIDEO',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          // Green checkmark for media that exists in local library
                          if (isInLibrary)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                child: const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          // Selection overlay for selected items
                          if (isSelected)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.blue, width: 2),
                                ),
                                child: const Center(
                                  child: Icon(Icons.check_circle, color: Colors.blue, size: 32),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                    onPressed: _loading || _currentPage <= 0
                        ? null
                        : () => _loadPage(_currentPage - 1),
                ),
                Text('Page ${_currentPage + 1} / $pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _loading || _currentPage >= pageCount - 1 
                      ? null 
                      : () => _loadPage(_currentPage + 1),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Download selected items (stub)
  Future<void> _downloadSelected() async {
    if (_selectedIndexes.isEmpty || _loading) return;
    setState(() { _loading = true; });
    try {
      final conn = await _ensureConnection();
      final idx = _selectedIndexes.first;
      final item = _mediaItems[idx];
      if (item.id == null) {
        _showMessage('Invalid file id');
        setState(() { _loading = false; });
        return;
      }
      final fileId = item.id!;
      final isVideo = item.isVideo;
      _showMessage('Downloading ${isVideo ? "video" : "photo"}: $fileId');

      // Send mediaDownloadList request (single file)
      final requestList = jsonEncode([fileId]);
      final packet = PacketEnc(MediaSyncPacketType.mediaDownloadList, utf8.encode(requestList));
      await conn.sendData(packet.encode());

      // Wait for server response
      final responsePacket = await MediaSyncProtocol.waitForResponse(conn);
      bool downloadSuccess = false;
      if (!isVideo && responsePacket.type == MediaSyncPacketType.mediaDownloadAck) {
        // Photo download: response is a JSON list of MediaPacket
        final responseStr = utf8.decode(responsePacket.data);
        final photoList = jsonDecode(responseStr) as List<dynamic>;
        if (photoList.isNotEmpty && photoList[0] is Map<String, dynamic>) {
          final photoMap = photoList[0] as Map<String, dynamic>;
          final base64Data = photoMap[fileId] as String?;
          if (base64Data != null) {
            // final bytes = base64Decode(base64Data); // Uncomment and use if saving to file
            // TODO: Save photo bytes to gallery or file system
            _showMessage('Photo downloaded: $fileId');
            downloadSuccess = true;
          } else {
            _showMessage('Photo data not found in response');
          }
        } else {
          _showMessage('Invalid photo response format');
        }
      } else if (isVideo && responsePacket.type == MediaSyncPacketType.chunkedVideoStart) {
        // Video download: handle chunked transfer
        final startInfo = jsonDecode(utf8.decode(responsePacket.data)) as Map<String, dynamic>;
        final totalChunks = startInfo['totalChunks'] as int? ?? 0;
        final videoId = startInfo['id'] as String? ?? fileId;
        List<int> videoBytes = [];
        for (int chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
          final chunkPacket = await MediaSyncProtocol.waitForResponse(conn);
          if (chunkPacket.type != MediaSyncPacketType.chunkedVideoData) {
            _showMessage('Unexpected packet type during video download');
            break;
          }
          final chunkInfo = jsonDecode(utf8.decode(chunkPacket.data)) as Map<String, dynamic>;
          final base64Chunk = chunkInfo['data'] as String?;
          if (base64Chunk != null) {
            videoBytes.addAll(base64Decode(base64Chunk));
          }
          _showMessage('Downloaded chunk ${chunkIndex + 1}/$totalChunks');
        }
        // Wait for chunkedVideoComplete
        final completePacket = await MediaSyncProtocol.waitForResponse(conn);
        if (completePacket.type == MediaSyncPacketType.chunkedVideoComplete) {
          // TODO: Save videoBytes to file system
          _showMessage('Video downloaded: $videoId');
          downloadSuccess = true;
        } else {
          _showMessage('Video download did not complete correctly');
        }
      } else {
        _showMessage('Unexpected response type: ${responsePacket.type}');
      }
      // If download succeeded, add green marker by updating local media filenames
      if (downloadSuccess && item.id != null) {
        final lastDot = item.id!.lastIndexOf('.');
        String filenameWithoutExt = lastDot > 0 ? item.id!.substring(0, lastDot) : item.id!;
        setState(() {
          _localMediaFilenames.add(filenameWithoutExt);
        });
      }
    } catch (e) {
      _showMessage('Download error: $e');
    } finally {
      setState(() {
        _selectedIndexes.clear();
        _loading = false;
      });
    }
  }
}

class ServerMediaItem {
  final String? id;
  final String? url;
  final String? thumbData; // base64 encoded thumbnail data
  final bool isVideo;
  
  ServerMediaItem({
    this.id,
    this.url, 
    this.thumbData,
    required this.isVideo
  });
}
