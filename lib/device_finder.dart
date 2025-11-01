import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';

//server suppose to listen on TCP Port 9922 for incoming connections
//server also need to listen on udp port 7799 for discovery requests

class DeviceInfo {
  final String deviceName;
  final String? ipAddress;
  DeviceInfo({required this.deviceName,  this.ipAddress});
}



class DeviceManager {
  // Simulated device discovery
  static Future<List<DeviceInfo>> discoverDevices() async {
    var responses = await sendUdpBroadcast('who is photo server?', 7799);
    //server should response with the following msg:
    //"photo_server:$name,IP:$ip"
    var devices = <DeviceInfo>[];
    for (var response in responses) {
      print('Discovered device response: $response');
      var deviceName = 'Unknown';
      var ipAddress = 'Unknown';
      var parts = response.split(',');
      for (var part in parts) {
        if (part.startsWith('photo_server:')) {
          deviceName = part.substring('photo_server:'.length);
        } else if (part.startsWith('IP:')) {
          ipAddress = part.substring('IP:'.length);
        }
      }

      devices.add(DeviceInfo(deviceName: deviceName, ipAddress: ipAddress));
    }

    return devices;
  }


  static Future<Map<String, String?>> getIpAndMask() async {
  final info = NetworkInfo();

  String? ip = await info.getWifiIP();
  String? mask = await info.getWifiSubmask();

  return {
    "ip": ip,
    "mask": mask,
  };
}


static String calculateBroadcastAddress(String ip, String mask) {
  final ipParts = ip.split('.').map(int.parse).toList();
  final maskParts = mask.split('.').map(int.parse).toList();

  final broadcast = List<int>.filled(4, 0);

  for (int i = 0; i < 4; i++) {
    broadcast[i] = (ipParts[i] & maskParts[i]) | (~maskParts[i] & 0xFF);
  }

  return broadcast.join('.');
}



 static Future<List<String>> sendUdpBroadcast(String message, int port) async {
  final responses = <String>[];

  // 1. Create UDP socket
  RawDatagramSocket socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4, // bind to any local IP
    0, // system-assigned port
  );

  print('UDP socket bound to ${socket.address.address}:${socket.port}');

  // 2. Enable broadcast
  socket.broadcastEnabled = true;

  // 3. Convert string message to bytes
  final data = Uint8List.fromList(message.codeUnits);

  // 4. Get broadcast address
  var ipAndMask = await getIpAndMask();
  print('Local IP: ${ipAndMask["ip"]}, Mask: ${ipAndMask["mask"]}');
  String localIp = ipAndMask["ip"] ?? '255.255.255.255';
  String mask = ipAndMask["mask"] ?? '255.255.255.0';
  String broadcastAddress = calculateBroadcastAddress(localIp, mask);

  // 5. Send broadcast
  socket.send(data, InternetAddress(broadcastAddress), port);
  print('UDP broadcast sent to $broadcastAddress:$port');

  // // 6. Prepare a completer to collect responses
  // final completer = Completer<List<String>>();

  // 7. Listen for incoming responses
  // server should respond with the string "photo_server:$name,IP:$ip"
  socket.listen((RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final dg = socket.receive();
      if (dg != null) {
        final msg = String.fromCharCodes(dg.data);
        final from = dg.address.address;
        print('Received: $msg from $from:${dg.port}');
        responses.add(msg);
      }
    }
  });

  // 8. Wait for responses for 5 seconds
  await Future.delayed(const Duration(seconds: 5));

  // 9. Close socket and return responses
  socket.close();
  return responses;
}


  /// Stream-based discovery: emits each discovered DeviceInfo as responses arrive.
  /// This allows callers (UI) to update incrementally instead of waiting
  /// for a fixed timeout to collect all responses.
  static Stream<DeviceInfo> discoverDevicesStream({int timeoutSeconds = 5}) {
    StreamController<DeviceInfo>? controller;
    RawDatagramSocket? socket;

    controller = StreamController<DeviceInfo>(
      onListen: () async {
        try {
          socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            0,
          );

          socket!.broadcastEnabled = true;

          final data = Uint8List.fromList('who is photo server?'.codeUnits);

          var ipAndMask = await getIpAndMask();
          String localIp = ipAndMask["ip"] ?? '255.255.255.255';
          String mask = ipAndMask["mask"] ?? '255.255.255.0';
          String broadcastAddress = calculateBroadcastAddress(localIp, mask);

          socket!.send(data, InternetAddress(broadcastAddress), 7799);

          socket!.listen((RawSocketEvent event) {
            if (event == RawSocketEvent.read) {
              final dg = socket!.receive();
              if (dg != null) {
                final msg = String.fromCharCodes(dg.data);
                // parse device response
                var deviceName = 'Unknown';
                String? ipAddress;
                var parts = msg.split(',');
                for (var part in parts) {
                  if (part.startsWith('photo_server:')) {
                    deviceName = part.substring('photo_server:'.length);
                  } else if (part.startsWith('IP:')) {
                    ipAddress = part.substring('IP:'.length);
                  }
                }
                controller!.add(DeviceInfo(deviceName: deviceName, ipAddress: ipAddress));
              }
            }
          });

          // Close socket and controller after timeoutSeconds
          Future.delayed(Duration(seconds: timeoutSeconds), () {
            try {
              socket?.close();
            } catch (_) {}
            try {
              controller?.close();
            } catch (_) {}
          });
        } catch (e) {
          controller?.addError(e);
          try {
            controller?.close();
          } catch (_) {}
        }
      },
      onCancel: () {
        try {
          socket?.close();
        } catch (_) {}
        try {
          controller?.close();
        } catch (_) {}
      },
    );

    return controller.stream;
  }

  static Future<String> getLocalDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.model ?? 'Android';
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.name ?? 'iPhone';
    } else {
      return Platform.operatingSystem;
    }
  }

}