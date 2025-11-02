import 'dart:typed_data';
import 'dart:convert';

/// A helper class to encode and decode packets in the format:
/// [type:1 byte][len:4 bytes][data:variable length]
/// 
/// // type 1 is photo packet request will be sent to server. after server recv it , it will respond with complete response  which is packet type 3
/// // type 2 is video packet request will be sent to server. after server recv it , it will respond with complete response  which is packet type 3
/// // type 4 is client sync start request, the data part will be the client phone name in string.
/// 
class PacketEnc {
  /// The type of the packet (1 byte)
  final int type;

  /// The payload data
  final Uint8List data;

  PacketEnc(this.type, this.data);

  /// Encode the packet into a binary format.
  Uint8List encode() {
    final len = data.length;
    final buffer = BytesBuilder();

    // Type (1 byte)
    buffer.addByte(type);

    // Length (4 bytes, big-endian)
    final lenBytes = ByteData(4)..setUint32(0, len, Endian.big);
    buffer.add(lenBytes.buffer.asUint8List());

    // Data (variable)
    buffer.add(data);

    return buffer.toBytes();
  }

  /// Decode a binary packet into a PacketEnc object.
  /// Returns null if data is incomplete or invalid.
  static PacketEnc? decode(Uint8List bytes) {
    if (bytes.length < 5) return null; // must have at least type + length

    final type = bytes[0];

    final len = ByteData.sublistView(bytes, 1, 5).getUint32(0, Endian.big);
    if (bytes.length < 5 + len) return null; // incomplete packet

    final data = bytes.sublist(5, 5 + len);

    return PacketEnc(type, Uint8List.fromList(data));
  }

  /// Convert data to string for debugging (if it's text)
  @override
  String toString() {
    final displayData = utf8.decode(data, allowMalformed: true);
    return 'PacketEnc(type=$type, len=${data.length}, data="$displayData")';
  }
}
