import 'package:flutter/material.dart';
import 'package:photo_sync/device_finder.dart';
import 'package:photo_sync/server_conn.dart';
import 'package:photo_sync/sync_history.dart';
import 'package:photo_sync/media_eumerator.dart';
import 'package:photo_sync/media_sync_protocol.dart';
import 'package:photo_sync/server_tab.dart';
import 'package:photo_sync/phone_tab.dart';
import 'package:photo_manager/photo_manager.dart';
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

class _MainTabPageState extends State<MainTabPage> {
  String? _selectedServerName;
  DeviceInfo? _selectedServer;

  void _updateServerName(String? serverName) {
    print('DEBUG: _updateServerName called with: $serverName');
    if (mounted) {
      setState(() {
        _selectedServerName = serverName;
      });
      print('DEBUG: _selectedServerName is now: $_selectedServerName');
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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
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
                      child: Text(
                        _selectedServerName!,
                        style: const TextStyle(
                          color: Colors.lightGreenAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
          centerTitle: false,
          toolbarHeight: 70, // Increased height for better visibility
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(36), // Reduce tab bar height
            child: TabBar(
              tabs: [
                Tab(text: 'Sync', icon: Icon(Icons.sync)),
                Tab(text: 'Server', icon: Icon(Icons.dns)),
                Tab(text: 'Phone', icon: Icon(Icons.phone_android)),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            SyncPage(
              onServerSelected: _updateServerName,
              onSelectedServerChanged: _onSelectedServerChanged,
            ),
            ServerTab(selectedServer: _selectedServer),
            const PhoneTab(),
          ],
        ),
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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMediaCounts();
    _loadSyncedCounts();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause ongoing sync when app is backgrounded; mark to resume on foreground
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (_isSyncing) {
        _resumeOnForeground = true;
        _cancelSync = true;
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_resumeOnForeground && !_isSyncing) {
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
        widget.onServerSelected?.call(null);
        widget.onSelectedServerChanged?.call(null);
      } else {
        selectedServer = server;
        print('DEBUG: Selected server: ${server.deviceName}, calling callbacks');
        widget.onServerSelected?.call(server.deviceName);
        widget.onSelectedServerChanged?.call(server);
      }
    });
  }


  Future<ServerConnection> doConnectSelectedServer() async {
    
  if (selectedServer == null) return Future.error('No server selected');

  ServerConnection conn = ServerConnection(selectedServer!.ipAddress ?? '', 9922);
  await conn.connect();
  // Await the async device name getter
  String phoneName = await DeviceManager.getLocalDeviceName();
  await MediaSyncProtocol.sendSyncStart(conn, phoneName);
  return conn;
  }


  final int _chunkSize = 5;  // Process assets in small batches

  Future<void> _syncAssets(RequestType type, String assetType, {ServerConnection? connection}) async {
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

  // Process assets in chunks to keep UI responsive
      for (var i = 0; i < assets.length; i += _chunkSize) {
        if (_cancelSync) {
          _showErrorToast(context, 'Sync cancelled');
          break;
        }

        setState(() {
          _syncStatus = 'Processing ${i + 1} to ${(i + _chunkSize).clamp(0, assets.length)} of ${assets.length} ${assetType}s...';
        });

        final chunk = assets.skip(i).take(_chunkSize);
        for (var asset in chunk) {
          if (_cancelSync) break;

          // Check if already synced
          if (await history.isFileSynced(asset.id)) {
            setState(() {
              if (type == RequestType.image) {
                syncedPhotos++;
              } else {
                syncedVideos++;
              }
            });
            continue;  // Skip already synced assets
          }

            try {
            // Convert to packet and send - do heavy work in isolate
            final packet = await MediaSyncProtocol.assetToPacket(asset);
            if (_cancelSync) break;

            final success = await MediaSyncProtocol.sendPacketWithAck(conn, packet, asset.id);
            
            // Only record if server acknowledged
            if (success) {
              await history.recordSync(asset.id, assetType);
              setState(() {
                if (type == RequestType.image) {
                  syncedPhotos++;
                } else {
                  syncedVideos++;
                }
              });
            } else {
              print('Server failed to acknowledge $assetType ${asset.id}');
            }
          } catch (e) {
            print('Error syncing $assetType ${asset.id}: $e');
            // Continue with next asset even if one fails
          }
        }

        if (!_cancelSync) {
          // Small delay between chunks to keep UI responsive
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
    } catch (e) {
      if (!_cancelSync) {  // Don't show error toast if cancelled
        print('Error in $assetType sync process: $e');
        _showErrorToast(context, 'Error syncing $assetType: ${e.toString()}');
      }
    } finally {
      // Clean up: only close connection if we created it here
      if (createdConn && conn != null) {
        try {
          conn.disconnect();
        } catch (e) {
          print('Error closing connection: $e');
        }
      }

      // If you implemented a foreground service, stop it here.
      setState(() {
        _isSyncing = false;
        _syncStatus = null;
        _cancelSync = false;  // Reset cancel flag
      });
    }
  }

  Future<void> doSyncPhotos() async {
    _activeSyncMode = SyncMode.photos;
    await _syncAssets(RequestType.image, 'photo');
  }  
  
  Future<void> doSyncVideos() async {
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
      await _loadSyncedCounts();
      setState(() {
        syncedPhotos = 0;
        syncedVideos = 0;
      });
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

    if (syncedPhotos >= totalPhotos) {
      _showInfoToast(context, 'All photos are already synced — no action needed.');
      return;
    }

    setState(() {
      syncedPhotos = 0;  // Reset counter before starting
    });
    await doSyncPhotos();
  }

  Future<void> syncVideos() async {
    if (!await _checkServerSelected()) return;

    if (syncedVideos >= totalVideos) {
      _showInfoToast(context, 'All videos are already synced — no action needed.');
      return;
    }

    setState(() {
      syncedVideos = 0;  // Reset counter before starting
    });
    await doSyncVideos();
  }

  Future<void> syncAll() async {
    _activeSyncMode = SyncMode.all;
    if (!await _checkServerSelected()) return;

    // If everything already synced, notify user and skip
    if (syncedPhotos >= totalPhotos && syncedVideos >= totalVideos) {
      _showInfoToast(context, 'All media already synced — no action needed.');
      return;
    }

    setState(() {
      syncedPhotos = 0;
      syncedVideos = 0;
    });

    try {
      var conn = await doConnectSelectedServer();
      // Reuse the same connection for both photo and video sync to avoid multiple TCP connections
      await _syncAssets(RequestType.image, 'photo', connection: conn);
      if (!_cancelSync) {
        await _syncAssets(RequestType.video, 'video', connection: conn);
      }

      if (!_cancelSync) {
        await MediaSyncProtocol.sendSyncComplete(conn);
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
    try {
      var conn = await doConnectSelectedServer();
      if (syncedPhotos < totalPhotos) {
        await _syncAssets(RequestType.image, 'photo', connection: conn);
      }
      if (!_cancelSync && syncedVideos < totalVideos) {
        await _syncAssets(RequestType.video, 'video', connection: conn);
      }
      if (!_cancelSync) {
        await MediaSyncProtocol.sendSyncComplete(conn);
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
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.wifi_find,
                            size: 18,
                            color: Theme.of(context).primaryColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "Server Discovery",
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).primaryColor,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: discoverServers,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(120, 32),
                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text("Discover Servers", style: TextStyle(fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (discoveredServers.isNotEmpty) ...[
                const SizedBox(height: 6),
                Column(
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
                const SizedBox(height: 10),
              ] else
                const SizedBox(height: 4),
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
                                        _syncStatus = 'Cancelling sync...';
                                      });
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
                              onPressed: _isSyncing ? null : syncAll,
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
