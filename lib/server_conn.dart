import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class ServerConnection {
  final String address;
  final int port;
  bool isClosed = false; // reflects terminal closed/error state

  // Helper for timestamp prefix
  String _timestamp() {
    final now = DateTime.now();
    return '[${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${(now.millisecond ~/ 10).toString().padLeft(2, '0')}]';
  }

  Socket? _socket;
  StreamSubscription?
  _socketSubscription; // Track subscription for proper cleanup

  Socket get socket {
    if (_socket == null) {
      throw StateError('Not connected');
    }
    return _socket!;
  }

  // --------------- SEND QUEUE ---------------
  final List<Uint8List> _sendQueue = [];
  bool _isSending = false;
  static const int _maxQueueSize =
      10; // Very small queue - only 10 packets max to prevent OS buffer overflow
  DateTime _lastActivityTime = DateTime.now();
  Timer? _watchdogTimer;

  // --------------- RECEIVE STREAM ----------
  final StreamController<Uint8List> _receiveController =
      StreamController.broadcast();

  Stream<Uint8List> get onData => _receiveController.stream;

  // --------------- CONNECTION ---------------
  ServerConnection(this.address, this.port);

  Future<void> connect() async {
    _socket = await Socket.connect(address, port);
    

    
    // Prefer disabling Nagle for lower latency small acks; adjust if batching proves better.
    try {
      _socket!.setOption(SocketOption.tcpNoDelay, true);
      print('${_timestamp()} [socket] tcpNoDelay enabled');
    } catch (e) {
      print('${_timestamp()} [socket] Failed to set tcpNoDelay: $e');
    }
    
    print('${_timestamp()} [socket] Connected to $address:$port with SO_LINGER=0');
    isClosed = false;
    _lastActivityTime = DateTime.now();

    // Start watchdog to detect stuck Send-Q
    _startWatchdog();

    // Start listening for incoming data
    _socketSubscription?.cancel(); // Cancel any previous subscription
    _socketSubscription = _socket!.listen(
      _handleIncomingData,
      onDone: () {
        print('${_timestamp()} Connection closed by server');
        disconnect();
      },
      onError: (err) {
        print('${_timestamp()} Socket error: $err');
        disconnect();
      },
      cancelOnError: true,
    );
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (isClosed) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final timeSinceActivity = now.difference(_lastActivityTime);

      // If no activity for 30 seconds, connection is likely stuck
      if (timeSinceActivity.inSeconds > 30) {
        print(
          '${_timestamp()} WARNING: No socket activity for ${timeSinceActivity.inSeconds}s - connection appears stuck',
        );
        print('${_timestamp()} Force closing stuck connection...');
        disconnect();
        timer.cancel();
      }
    });
  }

  void disconnect() {
    print('${_timestamp()} Disconnecting: cleaning up all resources...');

    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    // Cancel socket subscription first to stop receiving data
    if (_socketSubscription != null) {
      try {
        _socketSubscription!.cancel();
        _socketSubscription = null;
        print('${_timestamp()} Socket subscription cancelled');
      } catch (e) {
        print('${_timestamp()} Error cancelling subscription: $e');
      }
    }

    // Destroy socket; rely on OS defaults (no manual SO_LINGER hacking)
    if (_socket != null) {
      try {
        _socket!.destroy();
        print('${_timestamp()} Socket destroyed');
      } catch (e) {
        print('${_timestamp()} Error destroying socket: $e');
      }
      _socket = null;
    }

    // Clear send queue to prevent stale data on reconnect
    _sendQueue.clear();
    _isSending = false;

    // Force garbage collection hint by nulling everything
    print('${_timestamp()} Disconnected: all resources released');
    isClosed = true;
    _stopHeartbeat();
  }

  Future<void> reconnect() async {
    disconnect();

    // CRITICAL: Wait longer for OS to fully clear TCP state
    // With stuck Send-Q, kernel needs time to abort retransmissions
    print('${_timestamp()} Waiting 2 seconds for OS to clear TCP stack and Send-Q...');
    await Future.delayed(const Duration(seconds: 2));

    // Additional hint to OS: give scheduler time to process RST
    await Future.delayed(const Duration(milliseconds: 100));

    await connect();
  }

  // --------------- QUEUED SENDING ----------
  Future<void> sendData(Uint8List data) async {
    if (isClosed) {
      print('${_timestamp()} sendData skipped: connection closed');
      return;
    }

    // Apply backpressure if queue is too large
    while (_sendQueue.length >= _maxQueueSize && !isClosed) {
      print('${_timestamp()} Send queue full (${_sendQueue.length}), applying backpressure...');
      await Future.delayed(
        const Duration(milliseconds: 100),
      ); // Longer wait for ACKs
    }

    if (isClosed) return;

    _sendQueue.add(data);
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isSending) return;
    _isSending = true;

    try {
      int packetsSinceFlush = 0;
      while (_sendQueue.isNotEmpty && _socket != null && !isClosed) {
        final data = _sendQueue.removeAt(0);

        try {
          _socket!.add(data);
        } catch (e) {
          print('${_timestamp()} Socket write failed: $e - marking connection as dead');
          isClosed = true;
          _sendQueue.clear();
          break;
        }

        packetsSinceFlush++;

        // Flush every 3 packets (very small batches to allow ACKs to arrive)
        // or when queue is empty
        if (_sendQueue.isEmpty || packetsSinceFlush >= 3) {
          try {
            await _socket!.flush();
            _lastActivityTime =
                DateTime.now(); // Mark activity on successful flush
          } catch (e) {
            print('${_timestamp()} Socket flush failed: $e - marking connection as dead');
            isClosed = true;
            _sendQueue.clear();
            break;
          }
          packetsSinceFlush = 0;

          // CRITICAL: Wait for OS send buffer to drain before continuing
          // This prevents netstat Send-Q from filling up
          // The OS buffer filling means network can't keep up with our send rate
          await Future.delayed(const Duration(milliseconds: 100));

          // Extra delay if application queue is still large
          if (_sendQueue.length > 10) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      }

      // Final flush to ensure all data is sent
      if (_socket != null && !isClosed) {
        await _socket!.flush();
        // Give final data time to leave OS buffer
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _isSending = false;
    }
  }

  // --------------- INCOMING DATA -----------
  void _handleIncomingData(Uint8List data) {
    _lastActivityTime = DateTime.now();
    // Send to stream
    _receiveController.add(data);
  }

  // --------------- OPTIONAL REQUEST/RESPONSE ---------------
  /// Sends data and waits for next response packet
  Future<Uint8List> sendAndWait(Uint8List data) async {
    final completer = Completer<Uint8List>();

    late StreamSubscription sub;
    sub = onData.listen((packet) {
      completer.complete(packet);
      sub.cancel();
    });

    sendData(data);
    return completer.future.timeout(const Duration(seconds: 5));
  }

  /// Returns true if a socket instance currently exists.
  /// Further health is monitored via listen callbacks (onError/onDone).
  bool get isConnected => _socket != null;

  /// Ensure a connection is available; reconnect if missing.
  Future<void> ensureConnected() async {
    if (!isConnected) {
      print('${_timestamp()} ensureConnected: no active socket, reconnecting...');
      await reconnect();
    }
  }

  /// Force a hard reset of the connection to clear any stuck TCP state.
  /// Use this when detecting stuck retransmissions or timeout issues.
  Future<void> forceReconnect() async {
    print('${_timestamp()} Force reconnecting to clear TCP stack state...');
    disconnect();

    // Even longer delay for force reconnect - ensure complete cleanup
    print('${_timestamp()} Waiting 3 seconds for complete TCP stack cleanup...');
    await Future.delayed(const Duration(seconds: 3));

    await connect();
    print('${_timestamp()} Force reconnect complete - Send-Q should be clear');
  }

  // ---------------- HEARTBEAT ----------------
  void enableHeartbeat({Duration interval = const Duration(seconds: 45)}) {
    heartbeatInterval = interval;
    _startHeartbeat();
  }

  void disableHeartbeat() => _stopHeartbeat();

  Duration heartbeatInterval = const Duration(seconds: 45);
  Timer? _heartbeatTimer;
  int _missedHeartbeats = 0;
  final int _maxMisses = 2;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _missedHeartbeats = 0;
    if (isClosed || !isConnected) return;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) async {
      if (isClosed || !isConnected) {
        _stopHeartbeat();
        return;
      }
      try {
        // send 1-byte ping; server may ignore but activity keeps TCP fresh
        _socket!.add(const [0]);
        await _socket!.flush();
        _missedHeartbeats = 0;
      } catch (e) {
        _missedHeartbeats++;
        print('${_timestamp()} [hb] heartbeat send failed miss=$_missedHeartbeats: $e');
        if (_missedHeartbeats >= _maxMisses) {
          print('${_timestamp()} [hb] heartbeat exceeded misses, disconnecting');
          disconnect();
        }
      }
    });
    print('${_timestamp()} [hb] heartbeat started interval=${heartbeatInterval.inSeconds}s');
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _missedHeartbeats = 0;
    print('${_timestamp()} [hb] heartbeat stopped');
  }

  /// Dispose of all resources including the stream controller.
  /// Call this when permanently done with the connection.
  void dispose() {
    print('${_timestamp()} Disposing ServerConnection...');
    disconnect();

    // Close the broadcast stream controller to release all listeners
    if (!_receiveController.isClosed) {
      _receiveController.close();
      print('${_timestamp()} Receive controller closed');
    }
  }
}
