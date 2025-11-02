import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_sync/sync_history.dart';

class PhoneTab extends StatefulWidget {
  const PhoneTab({super.key});

  @override
  State<PhoneTab> createState() => _PhoneTabState();
}

class _PhoneTabState extends State<PhoneTab> {
  final SyncHistory _history = SyncHistory();

  // Data
  final Map<String, Future<Uint8List?>> _thumbCache = {}; // cache thumbnail futures to avoid flashing
  final Set<String> _selectedAssets = <String>{};
  final Set<String> _syncedAssets = <String>{};
  final Set<String> _deleteMode = <String>{};
  final int _itemsPerPage = 12;

  List<AssetEntity> _allAssets = <AssetEntity>[];
  List<AssetEntity> _displayedAssets = <AssetEntity>[];

  bool _loading = false;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permission denied. Cannot load photos.')),
        );
        setState(() => _loading = false);
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
        _allAssets = photos;
        _currentPage = 0;
        _updateDisplayedAssets();
        _loading = false;
      });

      await _loadSyncedStatus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load photos: $e')),
      );
    }
  }

  Future<void> _loadSyncedStatus() async {
    final syncedIds = <String>{};
    for (final a in _allAssets) {
      if (await _history.isFileSynced(a.id)) {
        syncedIds.add(a.id);
      }
    }
    if (!mounted) return;
    setState(() => _syncedAssets
      ..clear()
      ..addAll(syncedIds));
  }

  void _updateDisplayedAssets() {
    final start = _currentPage * _itemsPerPage;
    final end = (start + _itemsPerPage).clamp(0, _allAssets.length);
    _displayedAssets = _allAssets.sublist(start, end);
  }

  Future<Uint8List?> _getThumb(AssetEntity a) {
    return _thumbCache[a.id] ??= a.thumbnailDataWithSize(
      const ThumbnailSize.square(200),
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedAssets.contains(id)) {
        _selectedAssets.remove(id);
      } else {
        _selectedAssets.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedAssets.clear());
  }

  void _toggleDeleteMode(String id) {
    setState(() {
      if (_deleteMode.contains(id)) {
        _deleteMode.remove(id);
      } else {
        _deleteMode.add(id);
      }
    });
  }

  Future<void> _deletePhoto(AssetEntity asset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Photo'),
        content: const Text('Are you sure you want to delete this photo? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final deletedIds = await PhotoManager.editor.deleteWithIds([asset.id]);
      if (deletedIds.isNotEmpty) {
        _syncedAssets.remove(asset.id);
        await _loadPhotos();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo deleted'), backgroundColor: Colors.green),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete photo'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting photo: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _goToPage(int index) {
    setState(() {
      _currentPage = index;
      _updateDisplayedAssets();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = (_allAssets.length / _itemsPerPage).ceil();

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Header row
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Left: selected count
              Text('${_selectedAssets.length} selected', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),

              // Middle: total count
              if (_allAssets.isNotEmpty)
                Text('Total: ${_allAssets.length}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),

              // Right: clear button if any selected
              if (_selectedAssets.isNotEmpty)
                TextButton(onPressed: _clearSelection, child: const Text('Clear', style: TextStyle(fontSize: 13))),
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
            itemCount: _displayedAssets.length,
            itemBuilder: (context, index) {
              final asset = _displayedAssets[index];
              final isSelected = _selectedAssets.contains(asset.id);
              final isSynced = _syncedAssets.contains(asset.id);
              final inDeleteMode = _deleteMode.contains(asset.id);

              return RepaintBoundary(
                key: ValueKey(asset.id),
                child: GestureDetector(
                  onTap: () => inDeleteMode ? _toggleDeleteMode(asset.id) : _toggleSelection(asset.id),
                  onLongPress: () => _toggleDeleteMode(asset.id),
                  child: Stack(
                    children: [
                      // thumbnail
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: FutureBuilder<Uint8List?>(
                            future: _getThumb(asset),
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

                      // selection overlay
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

                      // delete overlay with icon
                      if (inDeleteMode)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.black.withOpacity(0.5),
                            ),
                            child: Center(
                              child: GestureDetector(
                                onTap: () => _deletePhoto(asset),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                  child: const Icon(Icons.delete, color: Colors.white, size: 24),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // synced indicator (top-left)
                      if (isSynced && !inDeleteMode)
                        const Positioned(
                          top: 4,
                          left: 4,
                          child: Icon(Icons.check_circle, color: Colors.green, size: 20),
                        ),

                      // selection checkbox (top-right)
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
            },
          ),
        ),

        // Pagination controls
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _currentPage > 0 ? () => _goToPage(_currentPage - 1) : null,
                ),
                Text('Page ${_currentPage + 1} / $pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _currentPage < pageCount - 1 ? () => _goToPage(_currentPage + 1) : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
