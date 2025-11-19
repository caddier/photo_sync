import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class ServerConnection {
  final String address;
  final int port;
  bool isClosed = false; // reflects terminal closed/error state

  Socket? _socket;
  Socket get socket {
    if (_socket == null) {
      throw StateError('Not connected');
    }
    return _socket!;
  }

  // --------------- SEND QUEUE ---------------
  final List<Uint8List> _sendQueue = [];
  bool _isSending = false;
  static const int _maxQueueSize = 10; // Very small queue - only 10 packets max to prevent OS buffer overflow

  // --------------- RECEIVE STREAM ----------
  final StreamController<Uint8List> _receiveController =
      StreamController.broadcast();

  Stream<Uint8List> get onData => _receiveController.stream;

  // --------------- CONNECTION ---------------
  ServerConnection(this.address, this.port);

  Future<void> connect() async {
    _socket = await Socket.connect(address, port);
    
    // Configure TCP socket for reliable large transfers with slow/variable networks
    // Disable TCP_NODELAY to enable Nagle's algorithm (reduce small packets)
    // This reduces retransmissions by allowing better packet coalescing
    _socket!.setOption(SocketOption.tcpNoDelay, false);
    
    // Enable TCP keepalive to maintain connection and help OS track RTT
    try {
      // Enable keepalive
      RawSocketOption keepalive = RawSocketOption.fromBool(
        6,  // IPPROTO_TCP
        9,  // TCP_KEEPALIVE / SO_KEEPALIVE
        true
      );
      _socket!.setRawOption(keepalive);
      
      // Set keepalive interval to 10 seconds
      RawSocketOption keepaliveInterval = RawSocketOption.fromInt(
        6,  // IPPROTO_TCP  
        17, // TCP_KEEPINTVL
        10
      );
      _socket!.setRawOption(keepaliveInterval);
    } catch (e) {
      print('Warning: Could not set TCP keepalive: $e');
    }
    
    print("Connected to $address:$port with Nagle + keepalive enabled");
    isClosed = false;

    // Start listening for incoming data
    _socket!.listen(
      _handleIncomingData,
      onDone: () {
        print("Connection closed by server");
        disconnect();
      },
      onError: (err) {
        print("Socket error: $err");
        disconnect();
      },
      cancelOnError: true,
    );
  }

  void disconnect() {
    if (_socket != null) {
      try {
        // Force immediate close without lingering
        _socket!.destroy();
      } catch (e) {
        print('Error destroying socket: $e');
      }
      _socket = null;
    }
    
    // Clear send queue to prevent stale data on reconnect
    _sendQueue.clear();
    _isSending = false;
    
    print("Disconnected and cleared buffers");
    isClosed = true;
  }

  Future<void> reconnect() async {
    disconnect();
    
    // Wait for OS to clear TCP retransmission timers and TIME_WAIT state
    // This prevents inheriting bad TCP state from previous connection
    print('Waiting for TCP stack to clear...');
    await Future.delayed(const Duration(milliseconds: 500));
    
    await connect();
  }

  // --------------- QUEUED SENDING ----------
  Future<void> sendData(Uint8List data) async {
    if (isClosed) {
      print('sendData skipped: connection closed');
      return;
    }
    
    // Apply backpressure if queue is too large
    while (_sendQueue.length >= _maxQueueSize && !isClosed) {
      print('Send queue full (${_sendQueue.length}), applying backpressure...');
      await Future.delayed(const Duration(milliseconds: 100)); // Longer wait for ACKs
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
        _socket!.add(data);
        packetsSinceFlush++;
        
        // Flush every 3 packets (very small batches to allow ACKs to arrive)
        // or when queue is empty
        if (_sendQueue.isEmpty || packetsSinceFlush >= 3) {
          await _socket!.flush();
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
      print('ensureConnected: no active socket, reconnecting...');
      await reconnect();
    }
  }
  
  /// Force a hard reset of the connection to clear any stuck TCP state.
  /// Use this when detecting stuck retransmissions or timeout issues.
  Future<void> forceReconnect() async {
    print('Force reconnecting to clear TCP stack state...');
    disconnect();
    
    // Longer delay to ensure OS fully clears retransmission timers
    await Future.delayed(const Duration(seconds: 1));
    
    await connect();
    print('Force reconnect complete');
  }
}
