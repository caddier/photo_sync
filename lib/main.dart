import 'package:flutter/material.dart';
import 'package:photo_sync/device_finder.dart';
import 'package:photo_sync/server_conn.dart';
import 'package:photo_sync/sync_history.dart';
import 'package:photo_sync/media_eumerator.dart';
import 'package:photo_sync/media_sync_protocol.dart';
import 'package:photo_sync/server_tab.dart';
import 'package:photo_sync/phone_tab.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';
//dart:io will be used if/when we add platform-specific foreground service code
// import 'dart:io' show Platform;

// Optional: foreground service on Android. Native setup required in AndroidManifest.
// import 'package:flutter_foreground_task/flutter_foreground_task.dart';
  
  



void main() {
  runApp(const MainApp());
}


class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: MainTabPage(),
      debugShowCheckedModeBanner: true,
    );
  }
}

class MainTabPage extends StatefulWidget {
  const MainTabPage({super.key});

  @override
  State<MainTabPage> createState() => _MainTabPageState();
}

class _MainTabPageState extends State<MainTabPage> with SingleTickerProviderStateMixin {
  String? _selectedServerName;
  DeviceInfo? _selectedServer;
  late TabController _tabController;
  final GlobalKey<_SyncPageState> _syncPageKey = GlobalKey<_SyncPageState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    // When switching to the Sync tab (index 0), reload the synced counts
    if (_tabController.index == 0) {
      _syncPageKey.currentState?._loadSyncedCounts();
    }
  }

  void _updateServerName(String? serverName) {
    print('DEBUG: _updateServerName called with: $serverName');
    if (mounted) {
      setState(() {
        _selectedServerName = serverName;
      });
      print('DEBUG: _selectedServerName is now: $_selectedServerName');
    }
  }

  void _launchServerInBrowser(String ip) async {
    final url = Uri.parse('http://$ip:8080');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not launch $url')),
      );
    }
  }

  void _onSelectedServerChanged(DeviceInfo? server) {
    if (mounted) {
      setState(() {
        _selectedServer = server;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _selectedServerName == null
            ? const Text('Photo Sync')
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Photo Sync: '),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_queue,
                          size: 16,
                          color: Colors.blue.shade300,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '[ $_selectedServerName ]',
                          style: TextStyle(
                            color: Colors.blue.shade300,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        if (_selectedServer != null && _selectedServer!.ipAddress != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: InkWell(
                              onTap: () => _launchServerInBrowser(_selectedServer!.ipAddress!),
                              child: Text(
                                '[${_selectedServer!.ipAddress!}]',
                                style: const TextStyle(
                                  color: Colors.amberAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
        centerTitle: false,
        toolbarHeight: 70, // Increased height for better visibility
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36), // Reduce tab bar height
          child: TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: 'Sync', icon: Icon(Icons.sync)),
              Tab(text: 'Server', icon: Icon(Icons.dns)),
              Tab(text: 'Phone', icon: Icon(Icons.phone_android)),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          SyncPage(
            key: _syncPageKey,
            onServerSelected: _updateServerName,
            onSelectedServerChanged: _onSelectedServerChanged,
          ),
          ServerTab(selectedServer: _selectedServer),
          const PhoneTab(),
        ],
      ),
    );
  }
}

class SyncPage extends StatefulWidget {
  final void Function(String?)? onServerSelected;
  final void Function(DeviceInfo?)? onSelectedServerChanged;
  
  const SyncPage({super.key, this.onServerSelected, this.onSelectedServerChanged});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

// Export the state type for use in other files (e.g., ServerTab)
typedef SyncPageState = _SyncPageState;

enum SyncMode { none, photos, videos, all }

class _SyncPageState extends State<SyncPage>
  with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  // Media totals
  int totalPhotos = 0;
  int totalVideos = 0;

  // Synced counts
  int syncedPhotos = 0;
  int syncedVideos = 0;

  // Lifecycle-aware sync state
  SyncMode _activeSyncMode = SyncMode.none;
  bool _resumeOnForeground = false;

  // Device name lock state
  bool _deviceNameLocked = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deviceNameController.addListener(() {
      setState(() {});  // Trigger rebuild when device name changes
    });
    _loadSyncCache();  // Load cache first for fast sync status checks
    _loadMediaCounts();
    _loadSyncedCounts();
    _loadDeviceName();
    _checkDeviceNameLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deviceNameController.dispose();
    super.dispose();
  }

  Future<void> _loadSyncCache() async {
    try {
      await history.loadSyncedFilesCache();
      print('Sync cache loaded successfully at app start');
    } catch (e) {
      print('Error loading sync cache: $e');
    }
  }

  Future<void> _loadDeviceName() async {
    final savedName = await history.getDeviceName();
    if (savedName != null && savedName.isNotEmpty) {
      setState(() {
        _deviceNameController.text = savedName;
      });
    } else {
      // Try to get device name from system as default
      try {
        final systemName = await DeviceManager.getLocalDeviceName();
        setState(() {
          _deviceNameController.text = systemName;
        });
      } catch (e) {
        print('Failed to get system device name: $e');
      }
    }
  }

  Future<void> _checkDeviceNameLock() async {
    final hasSynced = await history.hasSyncedBefore();
    setState(() {
      _deviceNameLocked = hasSynced;
    });
  }

  Future<void> _saveDeviceName(String name) async {
    if (name.trim().isEmpty) {
      _showErrorToast(context, 'Device name cannot be empty');
      return;
    }
    await history.saveDeviceName(name.trim());
    _showInfoToast(context, 'Device name saved successfully');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause ongoing sync when app is backgrounded; mark to resume on foreground
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (_isSyncing) {
        // Only mark for resume if user didn't manually cancel
        if (!_userCancelled) {
          _resumeOnForeground = true;
        }
        _cancelSync = true;
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_resumeOnForeground && !_isSyncing && !_userCancelled) {
        _resumeOnForeground = false;
        Future.microtask(() async {
          if (!mounted) return;
          if (selectedServer == null) return;
          switch (_activeSyncMode) {
            case SyncMode.photos:
              await doSyncPhotos();
              break;
            case SyncMode.videos:
              await doSyncVideos();
              break;
            case SyncMode.all:
              await _resumeSyncAll();
              break;
            case SyncMode.none:
              break;
          }
        });
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      // In case of backgrounding during sync, force-close active connection so awaits unblock
      try { _activeConn?.disconnect(); } catch (_) {}
    }
  }

  bool _loadingMediaCounts = false;
  Future<void> _loadMediaCounts() async {
    if (_loadingMediaCounts) return;
    _loadingMediaCounts = true;
    try {
      bool permissionGranted = await MediaEnumerator.requestPermission();
      if (!permissionGranted) {
        // Handle permission denied
        return;
      }

      // Get photos
      final photos = await PhotoManager.getAssetListPaged(
        type: RequestType.image,
        page: 0,
        pageCount: 1000000, // Large number to get all
      );

      // Get videos
      final videos = await PhotoManager.getAssetListPaged(
        type: RequestType.video,
        page: 0,
        pageCount: 1000000, // Large number to get all
      );

      if (!mounted) return;
      setState(() {
        totalPhotos = photos.length;
        totalVideos = videos.length;
      });
    } finally {
      _loadingMediaCounts = false;
    }
  }

  Future<void> _loadSyncedCounts() async {
    // Get all synced records
    final syncedRecords = await history.getAllSyncedFiles();
    int photos = 0;
    int videos = 0;
    // Count photos and videos
    for (var record in syncedRecords) {
      if (record.mediaType == 'photo') {
        photos++;
      } else if (record.mediaType == 'video') {
        videos++;
      }
    }
    if (!mounted) return;
    setState(() {
      syncedPhotos = photos;
      syncedVideos = videos;
    });
  }

  // -----------------------------
  // Server Discovery State
  // -----------------------------
  List<DeviceInfo> discoveredServers = [];
  DeviceInfo? selectedServer;
  final history = SyncHistory();
  bool _isSyncing = false;
  String? _syncStatus;
  bool _cancelSync = false;  // Flag to cancel ongoing sync
  bool _userCancelled = false;  // Flag to track user-initiated cancellation
  ServerConnection? _activeConn; // Currently active connection for sync (to force-cancel)
  
  // Device name state
  final TextEditingController _deviceNameController = TextEditingController();

  // simulate discovery
  Future<void> discoverServers() async {
    // Clear previous results and then listen to discovery stream so
    // devices are added to the UI as soon as responses arrive.
    setState(() {
      discoveredServers = [];
    });

    try {
      final stream = DeviceManager.discoverDevicesStream(timeoutSeconds: 5);
      stream.listen((device) {
        // Avoid duplicates (same name + ip)
        final exists = discoveredServers.any((d) => d.deviceName == device.deviceName && d.ipAddress == device.ipAddress);
        if (!exists) {
          setState(() {
            discoveredServers.add(device);
          });
        }
      }, onError: (e) {
        print('Discovery error: $e');
      }, onDone: () {
        print('Discovery finished');
      });
    } catch (e) {
      print('Error starting discovery: $e');
    }
  }

  void selectServer(DeviceInfo server) {
    print('DEBUG: selectServer called with: ${server.deviceName}');
    setState(() {
      // Toggle selection: if the same server is clicked again, deselect it
      if (selectedServer?.deviceName == server.deviceName) {
        selectedServer = null;
        print('DEBUG: Deselected server, calling callbacks with null');
      } else {
        selectedServer = server;
        print('DEBUG: Selected server: ${server.deviceName}, calling callbacks');
      }
    });
    
    // Call callbacks after setState to ensure state is updated first
    if (selectedServer == null) {
      widget.onServerSelected?.call(null);
      widget.onSelectedServerChanged?.call(null);
    } else {
      widget.onServerSelected?.call(selectedServer!.deviceName);
      widget.onSelectedServerChanged?.call(selectedServer);
    }
  }


  Future<ServerConnection> doConnectSelectedServer() async {
    
  if (selectedServer == null) return Future.error('No server selected');

  ServerConnection conn = ServerConnection(selectedServer!.ipAddress ?? '', 9922);
  await conn.connect();
  
  // Get device name (will use saved name from database or fallback to system name)
  String phoneName = await DeviceManager.getLocalDeviceName();
  
  await MediaSyncProtocol.sendSyncStart(conn, phoneName);
  return conn;
  }


  final int _chunkSize = 5;  // Process image assets in small batches (videos always process 1 at a time)

  Future<void> _syncAssets(RequestType type, String assetType, {ServerConnection? connection}) async {
    // Don't start a new sync if cancel was requested or user cancelled
    if (_cancelSync || _userCancelled) {
      return;
    }
    
    ServerConnection? conn = connection;
    var createdConn = false;
    try {
      _cancelSync = false;  // Reset cancel flag
      setState(() {
        _isSyncing = true;
        _syncStatus = 'Connecting to server...';
      });

        if (conn == null) {
        conn = await doConnectSelectedServer();
        createdConn = true;
        _activeConn = conn;

        // NOTE: To run reliably in background on Android you should set up
        // a foreground service (notification) in native code or using a
        // plugin. This code currently does not start a service automatically
        // to avoid introducing platform-specific required setup here.
        // You can enable it by adding a foreground-service plugin and native
        // manifest changes, or I can implement that for you if you want.
      }
      final assets = await PhotoManager.getAssetListPaged(
        type: type,
        page: 0,
        pageCount: 1000000,
      );

      final int totalCount = assets.length;
      
      setState(() {
        _syncStatus = 'Checking sync status for $totalCount ${assetType}s...';
      });
      
      final List<AssetEntity> unsyncedAssets = [];
      int skippedFromCache = 0;
      
      // Check all files sequentially (getAssetFilename is now very fast)
      for (var i = 0; i < totalCount; i++) {
        if (_cancelSync) break;
        
        final asset = assets[i];
        
        try {
          final fileId = await MediaSyncProtocol.getAssetFilename(asset);
          final isSynced = history.isFileSyncedCached(fileId);
          
          if (isSynced) {
            skippedFromCache++;
          } else {
            unsyncedAssets.add(asset);
          }
        } catch (e) {
          print('Error checking asset ${asset.id}: $e');
          unsyncedAssets.add(asset);
        }
        
        // Update progress every 100 items
        if ((i + 1) % 100 == 0) {
          setState(() {
            _syncStatus = 'Checking ${assetType}s: ${i + 1}/$totalCount...';
          });
        }
      }
      
      if (_cancelSync) {
        _showErrorToast(context, 'Sync cancelled');
        return;
      }
      
      setState(() {
        _syncStatus = 'Found ${unsyncedAssets.length} new ${assetType}s to sync (already synced: $skippedFromCache)';
      });
      
      print('Checked $totalCount files, found ${unsyncedAssets.length} unsynced, skipped $skippedFromCache already synced');
      
      if (unsyncedAssets.isEmpty) {
        if (mounted) {
          setState(() {
            _syncStatus = 'All ${assetType}s already synced!';
          });
          await Future.delayed(const Duration(seconds: 2));
        }
        return;
      }

      // For videos, process one at a time to avoid memory issues
      // For images, process in chunks for better performance
      final effectiveChunkSize = type == RequestType.video ? 1 : _chunkSize;

      // Process assets in chunks (1 for videos, _chunkSize for images)
      for (var i = 0; i < unsyncedAssets.length; i += effectiveChunkSize) {
        if (_cancelSync) {
          _showErrorToast(context, 'Sync cancelled');
          break;
        }

        setState(() {
          if (type == RequestType.video) {
            _syncStatus = 'Processing video ${i + 1} of ${unsyncedAssets.length}... (skipped: $skippedFromCache)';
          } else {
            _syncStatus = 'Processing ${i + 1} to ${(i + effectiveChunkSize).clamp(0, unsyncedAssets.length)} of ${unsyncedAssets.length} ${assetType}s... (skipped: $skippedFromCache)';
          }
        });

        final chunk = unsyncedAssets.skip(i).take(effectiveChunkSize);
        for (var asset in chunk) {
          if (_cancelSync) break;

          // Re-check cancel before heavy work
          if (_cancelSync) break;

          try {
            // Step 1: Get filename WITHOUT loading full file data
            if (_cancelSync) break;
            final fileId = await MediaSyncProtocol.getAssetFilename(asset);
            print('Filename determined: id: ${asset.id} -> name: $fileId');
            
            // Step 2: Double-check if synced (in case it was synced during this run)
            if (history.isFileSyncedCached(fileId)) {
              print('Asset $fileId already synced, skipping (file not loaded)');
              // Reload count from database to ensure accuracy
              await _loadSyncedCounts();
              continue;  // Skip already synced assets - saves memory!
            }

            bool success = false;
            
            // Step 3: For videos, use chunked upload; for images, use regular packet
            if (type == RequestType.video) {
              // Videos: Use chunked upload to avoid loading entire file into memory
              if (_cancelSync) break;
              print('Starting chunked upload for video: $fileId');
              
              // Extract media type from filename
              String mediaType = 'mp4';
              final dotIndex = fileId.lastIndexOf('.');
              if (dotIndex != -1 && dotIndex < fileId.length - 1) {
                mediaType = fileId.substring(dotIndex + 1).toLowerCase();
              }
              
              success = await MediaSyncProtocol.sendVideoWithChunks(
                conn,
                asset,
                fileId,
                mediaType,
                shouldCancel: () => _cancelSync,
                onProgress: (current, total) {
                  // Update status with chunk progress
                  final progress = (current / total * 100).toStringAsFixed(1);
                  setState(() {
                    _syncStatus = 'Uploading video ${i + 1}/${unsyncedAssets.length}: chunk $current/$total ($progress%) (checked: $totalCount)';
                  });
                },
              );
              if (_cancelSync) break;
              print('Chunked upload result for $fileId: $success');
            } else {
              // Images: Use regular packet method (they're typically small)
              if (_cancelSync) break;
              print('Converting image to packet: ${asset.id}');
              final packet = await MediaSyncProtocol.assetToPacket(asset);
              if (_cancelSync) break;
              print('Packet created for: $fileId');

              print('Sending $assetType $fileId to server...');
              success = await MediaSyncProtocol.sendPacketWithAck(
                conn, 
                packet, 
                null, // fileId will be extracted from packet
                () => _cancelSync, // Pass cancel check function
              );
              if (_cancelSync) break;
              print('Server ACK received for $fileId: $success');
            }
            
            // Step 4: Record sync if successful
            if (success) {
              await history.recordSync(fileId, assetType);
              // Reload count from database to ensure accuracy
              await _loadSyncedCounts();
              print('Successfully synced $assetType $fileId');
            } else {
              print('Server failed to acknowledge $assetType $fileId');
            }
          } catch (e) {
            print('Error syncing $assetType: $e');
            // Continue with next asset even if one fails
          }
          
          // For videos, add extra delay after each video to ensure memory is freed
          if (type == RequestType.video && !_cancelSync) {
            print('Waiting 200ms before next video to free memory...');
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }

        // Small delay between chunks for images only (videos already have per-item delay)
        if (type == RequestType.image && !_cancelSync) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
    } catch (e) {
      if (!_cancelSync) {  // Don't show error toast if cancelled
        print('Error in $assetType sync process: $e');
        _showErrorToast(context, 'Error syncing $assetType: ${e.toString()}');
      }
    } finally {
      // Send sync complete signal to server if we have a connection and created it
      // Skip if user cancelled to avoid waiting for timeout
      if (conn != null && createdConn && !_cancelSync) {
        try {
          print('Sending sync complete signal to server ($assetType, createdConn=$createdConn)...');
          await MediaSyncProtocol.sendSyncComplete(conn);
          print('Sync complete signal sent successfully for $assetType');
        } catch (e) {
          print('Error sending sync complete for $assetType: $e');
        }
      } else if (_cancelSync) {
        print('Skipping sync complete signal (cancelled)');
      }
      
      // Close the connection we created
      if (conn != null && createdConn) {
        try {
          conn.disconnect();
          print('Connection closed for $assetType');
        } catch (e) {
          print('Error closing connection for $assetType: $e');
        }
      } else {
        print('Skipping connection close for $assetType (conn=$conn, createdConn=$createdConn)');
      }
      // Clear active connection reference
      _activeConn = null;

      // If you implemented a foreground service, stop it here.
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncStatus = null;
          if (!_userCancelled) {
            _cancelSync = false;  // Only reset cancel flag if not user-cancelled
          }
        });
        // Check and update device name lock after sync completes
        await _checkDeviceNameLock();
      }
    }
  }

  Future<void> doSyncPhotos() async {
    _userCancelled = false;  // Reset user cancel flag when starting new sync
    _cancelSync = false;  // Reset cancel flag when starting new sync
    _activeSyncMode = SyncMode.photos;
    await _syncAssets(RequestType.image, 'photo');
  }  
  
  Future<void> doSyncVideos() async {
    _userCancelled = false;  // Reset user cancel flag when starting new sync
    _cancelSync = false;  // Reset cancel flag when starting new sync
    _activeSyncMode = SyncMode.videos;
    await _syncAssets(RequestType.video, 'video');
  }

  // -----------------------------
  // Sync Functions
  // -----------------------------
    void _showErrorToast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  void _showInfoToast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.white),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Future<void> _clearSyncHistory() async {
    // Ask for confirmation
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear sync history'),
        content: const Text('This will delete all sync history and allow re-syncing. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await history.clearHistory();
      await _loadSyncedCounts();  // This will load from database (should be 0 after clear)
      await _checkDeviceNameLock();  // Unlock device name after clearing history
      _showInfoToast(context, 'Sync history cleared — you can re-sync now.');
    } catch (e) {
      _showErrorToast(context, 'Failed to clear history: ${e.toString()}');
    }
  }

  Future<bool> _checkServerSelected() async {
    if (selectedServer == null) {
      _showErrorToast(context, "Please select a server before syncing");
      return false;
    }
    return true;
  }

  Future<void> syncPhotos() async {
    if (!await _checkServerSelected()) return;

    // Check if there are any photos to sync (allow sync even if syncedPhotos > totalPhotos due to deletions)
    if (totalPhotos == 0) {
      _showInfoToast(context, 'No photos found on device.');
      return;
    }

    // Load current count from database before starting
    await _loadSyncedCounts();
    await doSyncPhotos();
  }

  Future<void> syncVideos() async {
    if (!await _checkServerSelected()) return;

    // Check if there are any videos to sync (allow sync even if syncedVideos > totalVideos due to deletions)
    if (totalVideos == 0) {
      _showInfoToast(context, 'No videos found on device.');
      return;
    }

    // Load current count from database before starting
    await _loadSyncedCounts();
    await doSyncVideos();
  }

  Future<void> syncAll() async {
    _userCancelled = false;  // Reset user cancel flag when starting new sync
    _cancelSync = false;  // Reset cancel flag when starting new sync
    _activeSyncMode = SyncMode.all;
    if (!await _checkServerSelected()) return;

    // Check if there's any media to sync (allow even if synced counts are higher due to deletions)
    if (totalPhotos == 0 && totalVideos == 0) {
      _showInfoToast(context, 'No media found on device.');
      return;
    }

    // Load current count from database before starting
    await _loadSyncedCounts();

    try {
      var conn = await doConnectSelectedServer();
      // Reuse the same connection for both photo and video sync to avoid multiple TCP connections
      await _syncAssets(RequestType.image, 'photo', connection: conn);
      if (!_cancelSync) {
        await _syncAssets(RequestType.video, 'video', connection: conn);
      }

      // Send sync complete if not cancelled
      if (!_cancelSync) {
        try {
          print('Sending sync complete signal to server (syncAll)...');
          await MediaSyncProtocol.sendSyncComplete(conn);
        } catch (e) {
          print('Error sending sync complete: $e');
        }
      } else {
        print('Skipping sync complete signal (cancelled)');
      }

      // Close connection after done
      try {
        conn.disconnect();
      } catch (_) {}
    } catch (e) {
      _showErrorToast(context, 'Error during sync: ${e.toString()}');
      print('Error in sync all: $e');
    }
  }

  // Resume logic for syncAll without resetting counters
  Future<void> _resumeSyncAll() async {
    if (!await _checkServerSelected()) return;
    // Load current counts from database before resuming
    await _loadSyncedCounts();
    try {
      var conn = await doConnectSelectedServer();
      if (syncedPhotos < totalPhotos) {
        await _syncAssets(RequestType.image, 'photo', connection: conn);
      }
      if (!_cancelSync && syncedVideos < totalVideos) {
        await _syncAssets(RequestType.video, 'video', connection: conn);
      }
      
      // Send sync complete if not cancelled
      if (!_cancelSync) {
        try {
          print('Sending sync complete signal to server (resumeSyncAll)...');
          await MediaSyncProtocol.sendSyncComplete(conn);
        } catch (e) {
          print('Error sending sync complete: $e');
        }
      } else {
        print('Skipping sync complete signal (cancelled)');
      }
      
      try {
        conn.disconnect();
      } catch (_) {}
    } catch (e) {
      _showErrorToast(context, 'Error resuming sync: ${e.toString()}');
      print('Error in _resumeSyncAll: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Must call super when using AutomaticKeepAliveClientMixin
    int totalAll = totalPhotos + totalVideos;
    int syncedAll = syncedPhotos + syncedVideos;

    return SingleChildScrollView(
      child: Center(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Card(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        _deviceNameLocked ? Icons.lock : Icons.phone_android,
                        size: 20,
                        color: Theme.of(context).primaryColor,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "My Phone Name:",
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).primaryColor,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _deviceNameController,
                          enabled: !_deviceNameLocked,
                          readOnly: _deviceNameLocked,
                          decoration: InputDecoration(
                            hintText: _deviceNameLocked ? 'Locked after first sync' : 'Enter device name',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            isDense: true,
                            filled: _deviceNameLocked,
                            fillColor: _deviceNameLocked ? Colors.grey.shade200 : null,
                          ),
                          style: const TextStyle(fontSize: 14),
                          onSubmitted: _deviceNameLocked ? null : _saveDeviceName,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!_deviceNameLocked)
                        ElevatedButton.icon(
                          onPressed: () => _saveDeviceName(_deviceNameController.text),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: const Icon(Icons.save, size: 16),
                          label: const Text("Save", style: TextStyle(fontSize: 14)),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Card(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.wifi_find,
                        size: 18,
                        color: Theme.of(context).primaryColor,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "Server Discovery",
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).primaryColor,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: discoverServers,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(100, 28),
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text("Discover Servers", style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (discoveredServers.isNotEmpty) ...[
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: Colors.green.shade400,
                      width: 2,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: discoveredServers.map((server) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Checkbox(
                              value: selectedServer?.deviceName == server.deviceName,
                              onChanged: (_) => selectServer(server),
                              visualDensity: VisualDensity.compact,
                            ),
                            Text(server.deviceName, style: const TextStyle(fontSize: 13)),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.perm_media, 
                                size: 18,
                                color: Theme.of(context).primaryColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                "Media on Device",
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).primaryColor,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            onPressed: _loadingMediaCounts ? null : _loadMediaCounts,
                            icon: Icon(
                              Icons.refresh_rounded,
                              size: 18,
                              color: Theme.of(context).primaryColor,
                            ),
                            tooltip: "Refresh Media Count",
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                              padding: const EdgeInsets.all(4),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Theme.of(context).primaryColor.withOpacity(0.04),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Column(
                              children: [
                                Icon(Icons.photo_library, 
                                  size: 22,
                                  color: Theme.of(context).primaryColor,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  totalPhotos.toString(),
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).primaryColor,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Photos",
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              height: 40,
                              width: 1,
                              color: Colors.black12,
                            ),
                            Column(
                              children: [
                                Icon(Icons.videocam, 
                                  size: 22,
                                  color: Theme.of(context).primaryColor,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  totalVideos.toString(),
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).primaryColor,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Videos",
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Text(
                              "$syncedAll / $totalAll synced",
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (_syncStatus != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: null, // Indeterminate progress
                                      backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Theme.of(context).primaryColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _cancelSync = true;
                                        _userCancelled = true;  // Mark as user-initiated cancel
                                        _syncStatus = 'Cancelling sync...';
                                      });
                                      // Force-close any active connection to immediately unblock pending I/O
                                      try {
                                        _activeConn?.disconnect();
                                      } catch (_) {}
                                    },
                                    icon: const Icon(Icons.stop_circle_outlined),
                                    color: Colors.red,
                                    tooltip: 'Stop sync',
                                    iconSize: 20,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _syncStatus!,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).primaryColor,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                            ],
                            ElevatedButton(
                              onPressed: (_isSyncing || _deviceNameController.text.trim().isEmpty) ? null : syncAll,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(120, 32),
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text(_isSyncing ? "Syncing..." : "Sync All", style: const TextStyle(fontSize: 14)),
                            ),
                            const SizedBox(height: 4),
                            OutlinedButton(
                              onPressed: _isSyncing ? null : _clearSyncHistory,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(120, 28),
                                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                side: BorderSide(color: Theme.of(context).primaryColor.withOpacity(0.4)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text(
                                'Clear Sync History',
                                style: TextStyle(color: Theme.of(context).primaryColor, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  "$syncedPhotos / $totalPhotos",
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const Text("photos", style: TextStyle(fontSize: 12)),
                                const SizedBox(height: 4),
                                ElevatedButton(
                                  onPressed: _isSyncing ? null : syncPhotos,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                    foregroundColor: Theme.of(context).primaryColor,
                                    elevation: 0,
                                    minimumSize: const Size(80, 28),
                                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: Text(
                                    _isSyncing ? "Syncing..." : "Sync Photos",
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            height: 30,
                            width: 1,
                            color: Colors.black12,
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  "$syncedVideos / $totalVideos",
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const Text("videos", style: TextStyle(fontSize: 12)),
                                const SizedBox(height: 4),
                                ElevatedButton(
                                  onPressed: _isSyncing ? null : syncVideos,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                    foregroundColor: Theme.of(context).primaryColor,
                                    elevation: 0,
                                    minimumSize: const Size(80, 28),
                                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: Text(
                                    _isSyncing ? "Syncing..." : "Sync Videos",
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
    );
  }

}
