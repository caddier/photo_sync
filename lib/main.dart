import 'package:flutter/material.dart';
import 'package:photo_sync/device_finder.dart';
import 'package:photo_sync/server_conn.dart';
import 'package:photo_sync/sync_history.dart';
import 'package:photo_sync/media_eumerator.dart';
import 'package:photo_sync/media_sync_protocol.dart';
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
      home: SyncPage(),
      debugShowCheckedModeBanner: true,
    );
  }
}

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  // Media totals
  int totalPhotos = 0;
  int totalVideos = 0;

  // Synced counts
  int syncedPhotos = 0;
  int syncedVideos = 0;

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

    setState(() {
      syncedPhotos = photos;
      syncedVideos = videos;
    });
  }

  @override
  void initState() {
    super.initState();
    // Load both media counts and sync history
    _loadMediaCounts();
    _loadSyncedCounts();
  }

  Future<void> _loadMediaCounts() async {
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

    setState(() {
      totalPhotos = photos.length;
      totalVideos = videos.length;
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
    setState(() {
      // Toggle selection: if the same server is clicked again, deselect it
      if (selectedServer?.deviceName == server.deviceName) {
        selectedServer = null;
      } else {
        selectedServer = server;
      }
    });
  }


  Future<ServerConnection> doConnectSelectedServer() async {
    
    if (selectedServer == null) return Future.error('No server selected');

    ServerConnection conn = ServerConnection(selectedServer!.ipAddress ?? '', 9922);
    await conn.connect();
    return conn;  
  }


  static const int _chunkSize = 5;  // Process assets in small batches

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
    await _syncAssets(RequestType.image, 'photo');
  }  
  
  Future<void> doSyncVideos() async {
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

  @override
  Widget build(BuildContext context) {
    int totalAll = totalPhotos + totalVideos;
    int syncedAll = syncedPhotos + syncedVideos;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          selectedServer == null
              ? "Photo Sync"
              : "Photo Sync → ${selectedServer?.deviceName}",
        ),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Column(
            children: [
              const SizedBox(height: 30),

              // -----------------------------
              // Discover Servers Card
              // -----------------------------
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.wifi_find,
                            size: 24,
                            color: Theme.of(context).primaryColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Server Discovery",
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: discoverServers,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(200, 45),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text("Discover Servers"),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // -----------------------------
              // Discovered server list
              // -----------------------------
              if (discoveredServers.isNotEmpty) ...[
                const SizedBox(height: 10),
                Column(
                  children: discoveredServers.map((server) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Checkbox(
                          value: selectedServer?.deviceName == server.deviceName,
                          onChanged: (_) => selectServer(server),
                        ),
                        Text(server.deviceName),
                      ],
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
              ] else
                const SizedBox(height: 8),

              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.perm_media, 
                                size: 24,
                                color: Theme.of(context).primaryColor,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "Media on Device",
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            onPressed: _loadMediaCounts,
                            icon: Icon(
                              Icons.refresh_rounded,
                              color: Theme.of(context).primaryColor,
                            ),
                            tooltip: "Refresh Media Count",
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Theme.of(context).primaryColor.withOpacity(0.05),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Column(
                              children: [
                                Icon(Icons.photo_library, 
                                  size: 32,
                                  color: Theme.of(context).primaryColor,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  totalPhotos.toString(),
                                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).primaryColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Photos",
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              height: 80,
                              width: 1,
                              color: Colors.black12,
                            ),
                            Column(
                              children: [
                                Icon(Icons.videocam, 
                                  size: 32,
                                  color: Theme.of(context).primaryColor,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  totalVideos.toString(),
                                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).primaryColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Videos",
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
              
              const SizedBox(height: 16),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Sync All Section
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              "$syncedAll / $totalAll synced",
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (_syncStatus != null) ...[
                              const SizedBox(height: 8),
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
                                  const SizedBox(width: 16),
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
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _syncStatus!,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).primaryColor,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                            ],
                            ElevatedButton(
                              onPressed: _isSyncing ? null : syncAll,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(200, 45),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(_isSyncing ? "Syncing..." : "Sync All"),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _isSyncing ? null : _clearSyncHistory,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(200, 40),
                                side: BorderSide(color: Theme.of(context).primaryColor.withOpacity(0.4)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                'Clear Sync History',
                                style: TextStyle(color: Theme.of(context).primaryColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      
                      // Individual Sync Options
                      Row(
                        children: [
                          // Photos Section
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  "$syncedPhotos / $totalPhotos",
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Text("photos"),
                                const SizedBox(height: 8),
                                ElevatedButton(
                                  onPressed: _isSyncing ? null : syncPhotos,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                    foregroundColor: Theme.of(context).primaryColor,
                                    elevation: 0,
                                  ),
                                  child: Text(
                                    _isSyncing ? "Syncing..." : "Sync Photos",
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            height: 80,
                            width: 1,
                            color: Colors.black12,
                          ),
                          // Videos Section
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  "$syncedVideos / $totalVideos",
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Text("videos"),
                                const SizedBox(height: 8),
                                ElevatedButton(
                                  onPressed: _isSyncing ? null : syncVideos,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
                                    foregroundColor: Theme.of(context).primaryColor,
                                    elevation: 0,
                                  ),
                                  child: Text(
                                    _isSyncing ? "Syncing..." : "Sync Videos",
                                    style: const TextStyle(fontWeight: FontWeight.bold),
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
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

}
