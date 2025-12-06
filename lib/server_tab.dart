import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/device_finder.dart';
import 'package:photo_sync/http_sync_client.dart' as http_api;
import 'package:photo_sync/utils.dart';

class ServerTab extends StatefulWidget {
  final DeviceInfo? selectedServer;

  const ServerTab({super.key, this.selectedServer});

  @override
  State<ServerTab> createState() => _ServerTabState();
}

class _ServerTabState extends State<ServerTab> with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  int _currentPage = 0;
  static const int _itemsPerPage = 12;
  List<ServerMediaItem> _mediaItems = [];
  Set<String> _selectedIds = {}; // IDs of selected items (not indexes)
  bool _loading = false;
  int _totalMediaCount = 0;

  @override
  bool get wantKeepAlive => true;

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
          // Don't reset _currentPage to preserve page state when switching tabs
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

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
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
    _refreshGallery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When app resumes, reload current page
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
    
    // If the selected server changed, refresh but preserve page if same server
    if (oldWidget.selectedServer?.deviceName != widget.selectedServer?.deviceName || oldWidget.selectedServer?.ipAddress != widget.selectedServer?.ipAddress) {
      // Server actually changed, reset to page 0 and refresh
      _currentPage = 0;
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
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    
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
                    if (_selectedIds.isNotEmpty)
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
                    if (_selectedIds.isNotEmpty) const SizedBox(width: 6),
                    ElevatedButton.icon(
                      onPressed: _loading ? null : _refreshGallery,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(minimumSize: const Size(80, 28), padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8)),
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
                      final isSelected = item.id != null && _selectedIds.contains(item.id);
                      return GestureDetector(
                        onTap:
                            (item.id != null && !_loading)
                                ? () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedIds.remove(item.id);
                                    } else {
                                      _selectedIds.add(item.id!);
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

  // Download selected items from server
  Future<void> _downloadSelected() async {
    if (_selectedIds.isEmpty || _loading) return;

    final server = widget.selectedServer;
    if (server == null || server.ipAddress == null) {
      _showMessage('No server selected');
      return;
    }

    setState(() {
      _loading = true;
    });

    int successCount = 0;
    int failCount = 0;
    final totalCount = _selectedIds.length;

    try {
      // Get device name (folder name on server)
      final deviceName = await DeviceManager.getLocalDeviceName();
      final baseUrl = 'http://${server.ipAddress}:8080';

      for (final itemId in _selectedIds.toList()) {
        // Extract filename without extension
        String filenameWithoutExt = itemId;
        final lastDot = itemId.lastIndexOf('.');
        if (lastDot > 0) {
          filenameWithoutExt = itemId.substring(0, lastDot);
        }

        try {
          // Download file from server: /download/{foldername}/{filename}
          final downloadUrl = '$baseUrl/download/${Uri.encodeComponent(deviceName)}/${Uri.encodeComponent(filenameWithoutExt)}';
          print('${timestamp()} Downloading from: $downloadUrl');

          final response = await http.get(Uri.parse(downloadUrl)).timeout(const Duration(minutes: 5));

          if (response.statusCode == 200) {
            final bytes = response.bodyBytes;
            
            // Get file type and extension from Content-Type header
            final contentType = response.headers['content-type'] ?? '';
            final isVideo = contentType.startsWith('video/');
            final extension = _getExtensionFromContentType(contentType);
            
            // Get temp directory and save file
            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/$filenameWithoutExt.$extension');
            await tempFile.writeAsBytes(bytes);

            // Save to photo library
            if (isVideo) {
              await PhotoManager.editor.saveVideo(tempFile, title: filenameWithoutExt);
            } else {
              await PhotoManager.editor.saveImageWithPath(tempFile.path, title: filenameWithoutExt);
            }

            // Clean up temp file
            try {
              await tempFile.delete();
            } catch (_) {}

            successCount++;
            print('${timestamp()} Downloaded and saved: $filenameWithoutExt');
          } else {
            failCount++;
            print('${timestamp()} Download failed with status ${response.statusCode}: $filenameWithoutExt');
          }
        } catch (e) {
          failCount++;
          print('${timestamp()} Error downloading $filenameWithoutExt: $e');
        }

        // Update progress
        if (mounted) {
          setState(() {});
        }
      }
    } catch (e) {
      print('${timestamp()} Error in download process: $e');
      _showMessage('Error downloading files: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _selectedIds.clear();
        });
      }
    }

    // Show result message
    if (successCount > 0 || failCount > 0) {
      String message = 'Downloaded $successCount of $totalCount files';
      if (failCount > 0) {
        message += ' ($failCount failed)';
      }
      _showMessage(message);
    }
  }

  /// Get file extension from Content-Type header (e.g., "image/jpeg" -> "jpg", "video/mp4" -> "mp4")
  String _getExtensionFromContentType(String contentType) {
    // Parse mime type (e.g., "image/jpeg; charset=utf-8" -> "image/jpeg")
    final mimeType = contentType.split(';').first.trim().toLowerCase();
    
    // Map common mime types to extensions
    const mimeToExt = {
      // Images
      'image/jpeg': 'jpg',
      'image/jpg': 'jpg',
      'image/png': 'png',
      'image/heic': 'heic',
      'image/heif': 'heif',
      'image/gif': 'gif',
      'image/webp': 'webp',
      'image/tiff': 'tiff',
      'image/bmp': 'bmp',
      // Videos
      'video/mp4': 'mp4',
      'video/quicktime': 'mov',
      'video/x-msvideo': 'avi',
      'video/x-ms-wmv': 'wmv',
      'video/webm': 'webm',
      'video/3gpp': '3gp',
      'video/x-matroska': 'mkv',
      'video/mpeg': 'mpg',
    };
    
    if (mimeToExt.containsKey(mimeType)) {
      return mimeToExt[mimeType]!;
    }
    
    // Fallback: try to extract from mime type (e.g., "video/mp4" -> "mp4")
    final parts = mimeType.split('/');
    if (parts.length == 2) {
      final subtype = parts[1];
      // Handle special cases
      if (subtype == 'quicktime') return 'mov';
      if (subtype == 'jpeg') return 'jpg';
      return subtype;
    }
    
    // Default fallback
    return mimeType.startsWith('video') ? 'mp4' : 'jpg';
  }
}

class ServerMediaItem {
  final String? id;
  final String? url;
  final String? thumbData; // base64 encoded thumbnail data
  final bool isVideo;

  ServerMediaItem({this.id, this.url, this.thumbData, required this.isVideo});
}
