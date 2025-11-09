import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/sync_history.dart';
import 'package:photo_sync/media_sync_protocol.dart';

class PhoneTab extends StatefulWidget {
  const PhoneTab({super.key});

  @override
  State<PhoneTab> createState() => _PhoneTabState();
}

class _PhoneTabState extends State<PhoneTab> with SingleTickerProviderStateMixin {
  final SyncHistory _history = SyncHistory();
  late TabController _tabController;

  // Photo Data
  final Map<String, Future<Uint8List?>> _photoThumbCache = {};
  final Set<String> _selectedPhotos = <String>{};
  final Set<String> _syncedPhotos = <String>{};
  final Set<String> _deletePhotos = <String>{};
  final int _itemsPerPage = 12;

  List<AssetEntity> _allPhotos = <AssetEntity>[];
  List<AssetEntity> _displayedPhotos = <AssetEntity>[];
  bool _loadingPhotos = false;
  int _currentPhotoPage = 0;

  // Video Data
  final Map<String, Future<Uint8List?>> _videoThumbCache = {};
  final Set<String> _selectedVideos = <String>{};
  final Set<String> _syncedVideos = <String>{};
  final Set<String> _deleteVideos = <String>{};

  List<AssetEntity> _allVideos = <AssetEntity>[];
  List<AssetEntity> _displayedVideos = <AssetEntity>[];
  bool _loadingVideos = false;
  int _currentVideoPage = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadPhotos();
    _loadVideos();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPhotos() async {
    if (_loadingPhotos) return;
    setState(() => _loadingPhotos = true);

    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permission denied. Cannot load photos.')),
        );
        setState(() => _loadingPhotos = false);
        return;
      }

      // Load images
      final photos = await PhotoManager.getAssetListPaged(
        type: RequestType.image,
        page: 0,
        pageCount: 100000, // effectively all
      );

      if (!mounted) return;
      setState(() {
        _allPhotos = photos;
        _currentPhotoPage = 0;
        _updateDisplayedPhotos();
        _loadingPhotos = false;
      });

      await _loadPhotoSyncedStatus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingPhotos = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load photos: $e')),
      );
    }
  }

  Future<void> _loadVideos() async {
    if (_loadingVideos) return;
    setState(() => _loadingVideos = true);

    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        if (!mounted) return;
        setState(() => _loadingVideos = false);
        return;
      }

      // Load videos
      final videos = await PhotoManager.getAssetListPaged(
        type: RequestType.video,
        page: 0,
        pageCount: 100000, // effectively all
      );

      if (!mounted) return;
      setState(() {
        _allVideos = videos;
        _currentVideoPage = 0;
        _updateDisplayedVideos();
        _loadingVideos = false;
      });

      await _loadVideoSyncedStatus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingVideos = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load videos: $e')),
      );
    }
  }

  Future<void> _loadPhotoSyncedStatus() async {
    final syncedIds = <String>{};
    // Only check the currently displayed photos instead of all photos
    for (final a in _displayedPhotos) {
      // Get the filename for this asset (same way as sync process)
      final assetFilename = await MediaSyncProtocol.getAssetFilename(a);
      
      // Pass the full filename WITH extension (same as sync process)
      final isSynced = await _history.isFileSynced(assetFilename);
      if (isSynced) {
        syncedIds.add(a.id);
      }
    }
    if (!mounted) return;
    setState(() {
      // Only update the synced status for displayed photos, preserve others
      for (final id in syncedIds) {
        _syncedPhotos.add(id);
      }
    });
  }

  Future<void> _loadVideoSyncedStatus() async {
    final syncedIds = <String>{};
    // Only check the currently displayed videos instead of all videos
    for (final a in _displayedVideos) {
      // Get the filename for this asset (same way as sync process)
      final assetFilename = await MediaSyncProtocol.getAssetFilename(a);
      
      // Pass the full filename WITH extension (same as sync process)
      final isSynced = await _history.isFileSynced(assetFilename);
      if (isSynced) {
        syncedIds.add(a.id);
      }
    }
    if (!mounted) return;
    setState(() {
      // Only update the synced status for displayed videos, preserve others
      for (final id in syncedIds) {
        _syncedVideos.add(id);
      }
    });
  }

  void _updateDisplayedPhotos() {
    final start = _currentPhotoPage * _itemsPerPage;
    final end = (start + _itemsPerPage).clamp(0, _allPhotos.length);
    _displayedPhotos = _allPhotos.sublist(start, end);
  }

  void _updateDisplayedVideos() {
    final start = _currentVideoPage * _itemsPerPage;
    final end = (start + _itemsPerPage).clamp(0, _allVideos.length);
    _displayedVideos = _allVideos.sublist(start, end);
  }

  Future<Uint8List?> _getPhotoThumb(AssetEntity a) {
    return _photoThumbCache[a.id] ??= a.thumbnailDataWithSize(
      const ThumbnailSize.square(200),
    );
  }

  Future<Uint8List?> _getVideoThumb(AssetEntity a) {
    return _videoThumbCache[a.id] ??= a.thumbnailDataWithSize(
      const ThumbnailSize.square(200),
    );
  }

  // Photo toggle methods
  void _togglePhotoSelection(String id) {
    setState(() {
      if (_selectedPhotos.contains(id)) {
        _selectedPhotos.remove(id);
      } else {
        _selectedPhotos.add(id);
      }
    });
  }

  void _togglePhotoDeleteMode(String id) {
    setState(() {
      if (_deletePhotos.contains(id)) {
        _deletePhotos.remove(id);
      } else {
        _deletePhotos.add(id);
      }
    });
  }

  // Video toggle methods
  void _toggleVideoSelection(String id) {
    setState(() {
      if (_selectedVideos.contains(id)) {
        _selectedVideos.remove(id);
      } else {
        _selectedVideos.add(id);
      }
    });
  }

  void _toggleVideoDeleteMode(String id) {
    setState(() {
      if (_deleteVideos.contains(id)) {
        _deleteVideos.remove(id);
      } else {
        _deleteVideos.add(id);
      }
    });
  }

  Future<void> _deleteSelectedPhotos() async {
    final toDelete = <String>{..._selectedPhotos, ..._deletePhotos};
    if (toDelete.isEmpty) return;
    final count = toDelete.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Selected'),
        content: Text('Delete $count selected photo${count > 1 ? 's' : ''}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final ids = toDelete.toList();
      final deletedIds = await PhotoManager.editor.deleteWithIds(ids);

      for (final id in deletedIds) {
        _syncedPhotos.remove(id);
        _deletePhotos.remove(id);
        _selectedPhotos.remove(id);
        _photoThumbCache.remove(id);
      }

      await _loadPhotos();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted ${deletedIds.length} photo${deletedIds.length == 1 ? '' : 's'}'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _deleteSelectedVideos() async {
    final toDelete = <String>{..._selectedVideos, ..._deleteVideos};
    if (toDelete.isEmpty) return;
    final count = toDelete.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Selected'),
        content: Text('Delete $count selected video${count > 1 ? 's' : ''}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final ids = toDelete.toList();
      final deletedIds = await PhotoManager.editor.deleteWithIds(ids);

      for (final id in deletedIds) {
        _syncedVideos.remove(id);
        _deleteVideos.remove(id);
        _selectedVideos.remove(id);
        _videoThumbCache.remove(id);
      }

      await _loadVideos();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted ${deletedIds.length} video${deletedIds.length == 1 ? '' : 's'}'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _goToPhotoPage(int index) {
    setState(() {
      _currentPhotoPage = index;
      _updateDisplayedPhotos();
    });
    // Load sync status for the new page
    _loadPhotoSyncedStatus();
  }

  void _goToVideoPage(int index) {
    setState(() {
      _currentVideoPage = index;
      _updateDisplayedVideos();
    });
    // Load sync status for the new page
    _loadVideoSyncedStatus();
  }

  Widget _buildAssetTile({
    required AssetEntity asset,
    required bool isSelected,
    required bool isSynced,
    required bool inDeleteMode,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
    required Future<Uint8List?> Function(AssetEntity) getThumb,
    bool isVideo = false,
  }) {
    return RepaintBoundary(
      key: ValueKey(asset.id),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          children: [
            // Thumbnail
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FutureBuilder<Uint8List?>(
                  future: getThumb(asset),
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data != null) {
                      return Image.memory(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      );
                    }
                    return Container(
                      color: Colors.grey[300],
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  },
                ),
              ),
            ),

            // Video indicator
            if (isVideo)
              const Positioned(
                bottom: 4,
                right: 4,
                child: Icon(Icons.play_circle_filled, color: Colors.white, size: 24),
              ),

            // Synced overlay (green tint)
            if (isSynced && !inDeleteMode)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.green.withOpacity(0.2),
                    border: Border.all(color: Colors.green, width: 2),
                  ),
                ),
              ),

            // Selection overlay
            if (isSelected)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.blue.withOpacity(0.25),
                    border: Border.all(color: Colors.blue, width: 3),
                  ),
                ),
              ),

            // Delete overlay
            if (inDeleteMode)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.black.withOpacity(0.5),
                  ),
                  child: Center(
                    child: GestureDetector(
                      onTap: onTap,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                        child: const Icon(Icons.delete, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
              ),

            // Synced indicator (top-left, keep the check icon)
            if (isSynced && !inDeleteMode)
              const Positioned(
                top: 4,
                left: 4,
                child: Icon(Icons.check_circle, color: Colors.green, size: 20),
              ),

            // Selection checkbox (top-right)
            if (!inDeleteMode)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: isSelected ? Colors.blue : Colors.white,
                  size: 24,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoGallery() {
    final pageCount = (_allPhotos.length / _itemsPerPage).ceil();

    if (_loadingPhotos) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${_selectedPhotos.length} selected', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              if (_allPhotos.isNotEmpty)
                Text('Total: ${_allPhotos.length}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              if (_selectedPhotos.isNotEmpty || _deletePhotos.isNotEmpty)
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _selectedPhotos.clear();
                          _deletePhotos.clear();
                        });
                      },
                      child: const Text('Clear', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _deleteSelectedPhotos,
                      child: Text(
                        'Delete (${_selectedPhotos.length + _deletePhotos.length})',
                        style: const TextStyle(fontSize: 13, color: Colors.red),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),

        // Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _displayedPhotos.length,
            itemBuilder: (context, index) {
              final asset = _displayedPhotos[index];
              final isSelected = _selectedPhotos.contains(asset.id);
              final isSynced = _syncedPhotos.contains(asset.id);
              final inDeleteMode = _deletePhotos.contains(asset.id);

              return _buildAssetTile(
                asset: asset,
                isSelected: isSelected,
                isSynced: isSynced,
                inDeleteMode: inDeleteMode,
                onTap: () => inDeleteMode ? _togglePhotoDeleteMode(asset.id) : _togglePhotoSelection(asset.id),
                onLongPress: () => _togglePhotoDeleteMode(asset.id),
                getThumb: _getPhotoThumb,
              );
            },
          ),
        ),

        // Pagination
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _currentPhotoPage > 0 ? () => _goToPhotoPage(_currentPhotoPage - 1) : null,
                ),
                Text('Page ${_currentPhotoPage + 1} / $pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _currentPhotoPage < pageCount - 1 ? () => _goToPhotoPage(_currentPhotoPage + 1) : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildVideoGallery() {
    final pageCount = (_allVideos.length / _itemsPerPage).ceil();

    if (_loadingVideos) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${_selectedVideos.length} selected', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              if (_allVideos.isNotEmpty)
                Text('Total: ${_allVideos.length}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              if (_selectedVideos.isNotEmpty || _deleteVideos.isNotEmpty)
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _selectedVideos.clear();
                          _deleteVideos.clear();
                        });
                      },
                      child: const Text('Clear', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _deleteSelectedVideos,
                      child: Text(
                        'Delete (${_selectedVideos.length + _deleteVideos.length})',
                        style: const TextStyle(fontSize: 13, color: Colors.red),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),

        // Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _displayedVideos.length,
            itemBuilder: (context, index) {
              final asset = _displayedVideos[index];
              final isSelected = _selectedVideos.contains(asset.id);
              final isSynced = _syncedVideos.contains(asset.id);
              final inDeleteMode = _deleteVideos.contains(asset.id);

              return _buildAssetTile(
                asset: asset,
                isSelected: isSelected,
                isSynced: isSynced,
                inDeleteMode: inDeleteMode,
                onTap: () => inDeleteMode ? _toggleVideoDeleteMode(asset.id) : _toggleVideoSelection(asset.id),
                onLongPress: () => _toggleVideoDeleteMode(asset.id),
                getThumb: _getVideoThumb,
                isVideo: true,
              );
            },
          ),
        ),

        // Pagination
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _currentVideoPage > 0 ? () => _goToVideoPage(_currentVideoPage - 1) : null,
                ),
                Text('Page ${_currentVideoPage + 1} / $pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _currentVideoPage < pageCount - 1 ? () => _goToVideoPage(_currentVideoPage + 1) : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Photos', icon: Icon(Icons.photo)),
            Tab(text: 'Videos', icon: Icon(Icons.video_library)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildPhotoGallery(),
              _buildVideoGallery(),
            ],
          ),
        ),
      ],
    );
  }
}
