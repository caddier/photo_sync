import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:photo_sync/device_finder.dart';
import 'package:photo_sync/http_sync_client.dart' as http_api;
import 'package:photo_sync/sync_history.dart';
import 'package:photo_sync/local_media_cache.dart';
import 'package:photo_sync/utils.dart';

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
  final LocalMediaCache _mediaCache = LocalMediaCache(); // Singleton cache instance

  // selectedServer is now provided via the widget constructor from MainTabPage

  // dispose is implemented at the end to also remove lifecycle observer

  Future<void> _refreshGallery() async {
    if (_loading) return;
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }

    try {
      // Use selected server passed from parent
      final server = widget.selectedServer;

      if (server == null) {
        print('${timestamp()} no server selected');
        // No server selected, show empty gallery
        if (!mounted) return;
        setState(() {
          _mediaItems = [];
          _totalMediaCount = 0;
          _loading = false;
          _currentPage = 0;
        });
        return;
      }

      print('${timestamp()} ServerTab: Connecting to server ${server.deviceName}...');
      print('${timestamp()} ServerTab: Requesting media count via HTTP...');

      // Request media count via HTTP
      int count = 0;
      try {
        String phoneName = await DeviceManager.getLocalDeviceName();
        final httpClient = http_api.HttpSyncClient(serverHost: server.ipAddress ?? '', serverPort: 8080, deviceName: phoneName);
        count = await httpClient.getMediaCount();
        httpClient.close();
      } catch (e) {
        print('${timestamp()} HTTP getMediaCount failed: $e');
      }
      print('${timestamp()} ServerTab: Received media count: $count');

      if (!mounted) return;

      // Update the UI with the count
      setState(() {
        _totalMediaCount = count;
      });

      // 3. Request media thumbnail list for the current page (via HTTP)
      if (count > 0) {
        print('${timestamp()} ServerTab: Requesting thumbnail list (HTTP) for page $_currentPage...');
        List<http_api.MediaThumbItem> thumbList = const [];
        try {
          String phoneName = await DeviceManager.getLocalDeviceName();
          final httpClient = http_api.HttpSyncClient(serverHost: server.ipAddress ?? '', serverPort: 8080, deviceName: phoneName);
          thumbList = await httpClient.getMediaThumbnails(pageIndex: _currentPage, pageSize: _itemsPerPage);
          httpClient.close();
        } catch (e) {
          print('${timestamp()} HTTP getMediaThumbnails failed: $e');
          thumbList = const [];
        }
        print('${timestamp()} ServerTab: Received ${thumbList.length} thumbnails (HTTP)');

        if (!mounted) return;
        // Update the UI with the thumbnail data
        setState(() {
          _mediaItems = thumbList.map((thumb) => ServerMediaItem(id: thumb.id, thumbData: thumb.thumbData, isVideo: thumb.isVideo)).toList();
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
      print('${timestamp()} Error refreshing gallery: $e');
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

    setState(() {
      _loading = true;
    });

    try {
      // Use selected server passed from parent
      final server = widget.selectedServer;

      if (server == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
        });
        return;
      }

      // Request media thumbnail list for the specified page via HTTP
      List<http_api.MediaThumbItem> thumbList = const [];
      try {
        String phoneName = await DeviceManager.getLocalDeviceName();
        final httpClient = http_api.HttpSyncClient(serverHost: server.ipAddress ?? '', serverPort: 8080, deviceName: phoneName);
        thumbList = await httpClient.getMediaThumbnails(pageIndex: pageIndex, pageSize: _itemsPerPage);
        httpClient.close();
      } catch (e) {
        print('${timestamp()} HTTP getMediaThumbnails (page) failed: $e');
        thumbList = const [];
      }

      if (!mounted) return;

      // Update the UI with the thumbnail data for this page
      setState(() {
        _mediaItems = thumbList.map((thumb) => ServerMediaItem(id: thumb.id, thumbData: thumb.thumbData, isVideo: thumb.isVideo)).toList();
        _currentPage = pageIndex;
        _loading = false;
      });
    } catch (e) {
      print('${timestamp()} Error loading page: $e');
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

    setState(() {
      _loading = true;
    });

    try {
      _showMessage('Syncing database with server...');

      // Get device name
      String phoneName = await DeviceManager.getLocalDeviceName();

      // Create HTTP client
      final httpClient = http_api.HttpSyncClient(serverHost: server.ipAddress ?? '', serverPort: 8080, deviceName: phoneName);

      // Get all file IDs from server
      final serverFileIds = await httpClient.getAllServerFileIds();
      httpClient.close();

      // Sync local database with server data
      final history = SyncHistory();
      await history.syncWithServer(serverFileIds);

      if (!mounted) return;

      _showMessage('Database synced: ${serverFileIds.length} files on server');

      // Refresh the gallery after sync
      await _refreshGallery();
    } catch (e) {
      print('${timestamp()} Error syncing database: $e');
      if (!mounted) return;
      _showMessage('Error syncing database: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  /// Load local media filenames in background using cache
  void _loadLocalMediaFilenames() {
    // Load asynchronously without blocking UI
    _mediaCache
        .getLocalMediaFilenames()
        .then((_) {
          if (mounted) {
            setState(() {}); // Trigger rebuild to show green checkmarks
          }
        })
        .catchError((e) {
          print('${timestamp()} Error loading local media filenames: $e');
        });
  }

  /// Check if a server file exists in local library by comparing filenames without extensions
  bool _isMediaInLocalLibrary(String serverFileId) {
    // Extract filename without extension from server file ID
    String filenameWithoutExt = serverFileId;
    final lastDot = serverFileId.lastIndexOf('.');
    if (lastDot > 0) {
      filenameWithoutExt = serverFileId.substring(0, lastDot);
    }

    return _mediaCache.contains(filenameWithoutExt);
  }

  Widget _buildMediaWidget(ServerMediaItem item) {
    // If we have thumbData (base64), decode and display it
    if (item.thumbData != null && item.thumbData!.isNotEmpty) {
      try {
        final bytes = base64Decode(item.thumbData!);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (c, e, s) => Container(color: Colors.grey[300], child: const Center(child: Icon(Icons.broken_image))),
        );
      } catch (e) {
        print('${timestamp()} Error decoding thumbnail: $e');
        return Container(color: Colors.grey[300], child: const Center(child: Icon(Icons.broken_image)));
      }
    }

    // Fallback to URL if available
    if (item.url != null && item.url!.isNotEmpty) {
      return Image.network(
        item.url!,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => Container(color: Colors.grey[300], child: const Center(child: Icon(Icons.broken_image))),
      );
    }

    // Default placeholder
    return Container(color: Colors.grey[300], child: const Center(child: Icon(Icons.image, color: Colors.black45)));
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
    // When app resumes, refresh to reload current page
    if (state == AppLifecycleState.resumed) {
      // Delay slightly to let UI settle
      Future.microtask(() {
        if (mounted) {
          // Try to reload the current page
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
    // If the selected server changed, refresh
    if (oldWidget.selectedServer?.deviceName != widget.selectedServer?.deviceName) {
      _refreshGallery();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
                    if (_selectedIndexes.isNotEmpty) const SizedBox(width: 6),
                    ElevatedButton.icon(
                      onPressed: _loading ? null : _refreshGallery,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(minimumSize: const Size(80, 28), padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8)),
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
                        items: List.generate(pageCount, (i) => DropdownMenuItem(value: i, child: Text('Page ${i + 1}', style: const TextStyle(fontSize: 12)))),
                        onChanged:
                            _loading
                                ? null
                                : (int? selected) {
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
                  child: Text('Total: $_totalMediaCount items', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ),
            ],
          ),
        ),
        Expanded(
          child:
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _mediaItems.isEmpty
                  ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text('No media on server', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                        const SizedBox(height: 8),
                        Text('Select a server and tap Refresh', style: TextStyle(fontSize: 13, color: Colors.grey[500])),
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
                        onTap:
                            (!isInLibrary && !_loading)
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
                            Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _buildMediaWidget(item))),
                            if (item.isVideo)
                              Positioned(
                                right: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(12)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: const [
                                      Icon(Icons.videocam, color: Colors.white, size: 14),
                                      SizedBox(width: 4),
                                      Text('VIDEO', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
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
                                  decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                                  child: const Icon(Icons.check, color: Colors.white, size: 16),
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
                                  child: const Center(child: Icon(Icons.check_circle, color: Colors.blue, size: 32)),
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
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: _loading || _currentPage <= 0 ? null : () => _loadPage(_currentPage - 1)),
                Text('Page ${_currentPage + 1} / $pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _loading || _currentPage >= pageCount - 1 ? null : () => _loadPage(_currentPage + 1),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Download selected items - TODO: Implement HTTP download endpoint
  Future<void> _downloadSelected() async {
    if (_selectedIndexes.isEmpty || _loading) return;

    _showMessage('Download feature not yet implemented via HTTP');

    // TODO: Implement HTTP-based download when server supports it
    // For now, just show a message
    setState(() {
      _selectedIndexes.clear();
    });
  }
}

class ServerMediaItem {
  final String? id;
  final String? url;
  final String? thumbData; // base64 encoded thumbnail data
  final bool isVideo;

  ServerMediaItem({this.id, this.url, this.thumbData, required this.isVideo});
}
