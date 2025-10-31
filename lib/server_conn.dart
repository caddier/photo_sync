import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class ServerConnection {
  final String address;
  final int port;

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

  // --------------- RECEIVE STREAM ----------
  final StreamController<Uint8List> _receiveController =
      StreamController.broadcast();

  Stream<Uint8List> get onData => _receiveController.stream;

  // --------------- CONNECTION ---------------
  ServerConnection(this.address, this.port);

  Future<void> connect() async {
    _socket = await Socket.connect(address, port);
    print("Connected to $address:$port");

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
    _socket?.destroy();
    _socket = null;
    print("Disconnected");
  }

  Future<void> reconnect() async {
  disconnect();
  await connect();
}

  // --------------- QUEUED SENDING ----------
  Future<void> sendData(Uint8List data) async {
    _sendQueue.add(data);
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isSending) return;
    _isSending = true;

    try {
      while (_sendQueue.isNotEmpty && _socket != null) {
        final data = _sendQueue.removeAt(0);

        _socket!.add(data);
        await _socket!.flush();

        // Prevent flooding (tune as needed)
        await Future.delayed(const Duration(milliseconds: 3));
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
}
