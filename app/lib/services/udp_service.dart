import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

class PktType {
  static const int audioStream = 0x01;
  static const int audioFile = 0x02;
  static const int audioFileEnd = 0x03;
  static const int cmd = 0x04;
  static const int status = 0x05;
}

class Cmd {
  static const int stopPlayback = 0x01;
  static const int startStream = 0x02;
  static const int stopStream = 0x03;
  static const int mute = 0x04;
  static const int unmute = 0x05;
  static const int fileStart = 0x06;
  static const int ping = 0x07;
  static const int pong = 0x08;
}

class StatusCode {
  static const int ok = 0x00;
  static const int playing = 0x01;
  static const int streaming = 0x02;
  static const int idle = 0x03;
  static const int error = 0xFF;
}

const int headerSize = 8;
const int maxPayloadSize = 1392;
const int udpPort = 8888;
const String espIp = '192.168.4.1';

class PacketHeader {
  final int type;
  final int seq;
  final int len;
  final int flags;

  PacketHeader({
    required this.type,
    required this.seq,
    required this.len,
    this.flags = 0,
  });

  Uint8List encode() {
    final buf = ByteData(headerSize);
    buf.setUint8(0, type);
    buf.setUint16(1, seq & 0xFFFF, Endian.little);
    buf.setUint16(3, len, Endian.little);
    buf.setUint8(5, flags);
    buf.setUint16(6, 0, Endian.little);
    return buf.buffer.asUint8List();
  }

  static PacketHeader? decode(Uint8List data) {
    if (data.length < headerSize) return null;
    final buf = ByteData.sublistView(data);
    final type = buf.getUint8(0);
    final seq = buf.getUint16(1, Endian.little);
    final len = buf.getUint16(3, Endian.little);
    final flags = buf.getUint8(5);
    if (data.length < headerSize + len) return null;
    return PacketHeader(type: type, seq: seq, len: len, flags: flags);
  }
}

typedef AudioCallback = void Function(Uint8List data);
typedef StatusCallback = void Function(int statusCode);

class UdpService {
  RawDatagramSocket? _socket;
  int _seq = 0;
  AudioCallback? onAudioReceived;
  StatusCallback? onStatusReceived;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;
  Timer? _pingTimer;
  DateTime? _lastPong;
  bool _connected = false;
  bool _disposed = false;
  final NetworkInfo _networkInfo = NetworkInfo();

  bool get isConnected => _connected;

  Future<void> connect() async {
    if (_disposed) return;
    _cleanup();

    // 绑定到 WiFi 网关对应的本机地址，强制走 WiFi 网卡
    // 避免华为等设备自动切回移动数据
    String? bindIp;
    try {
      final ip = await _networkInfo.getWifiIP();
      if (ip != null && ip.isNotEmpty) bindIp = ip;
    } catch (_) {}

    final bindAddr = bindIp != null
        ? InternetAddress(bindIp)
        : InternetAddress.anyIPv4;

    try {
      _socket = await RawDatagramSocket.bind(bindAddr, 0);
    } catch (_) {
      // 绑定指定 IP 失败就退回 anyIPv4
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }

    _socket!.broadcastEnabled = true;
    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _socket?.receive();
        if (dg != null) _handleDatagram(dg.data);
      }
    }, onError: (_) {
      if (_connected && !_disposed) {
        _connected = false;
        onDisconnected?.call();
      }
    });

    sendCommand(Cmd.ping);

    // 未连接时 800ms 快速 ping，连上后换 3s keepalive
    _pingTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (_disposed) return;
      sendCommand(Cmd.ping);

      if (_connected && _lastPong != null &&
          DateTime.now().difference(_lastPong!).inSeconds > 10) {
        _connected = false;
        onDisconnected?.call();
        return;
      }

      if (_connected) {
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          if (_disposed) return;
          sendCommand(Cmd.ping);
          if (_connected && _lastPong != null &&
              DateTime.now().difference(_lastPong!).inSeconds > 10) {
            _connected = false;
            onDisconnected?.call();
          }
        });
      }
    });
  }

  void _handleDatagram(Uint8List data) {
    if (_disposed) return;
    final hdr = PacketHeader.decode(data);
    if (hdr == null) return;

    final payload = data.sublist(headerSize, headerSize + hdr.len);

    switch (hdr.type) {
      case PktType.audioStream:
        onAudioReceived?.call(payload);
        break;
      case PktType.status:
        if (payload.isNotEmpty) onStatusReceived?.call(payload[0]);
        break;
      case PktType.cmd:
        if (payload.isNotEmpty && payload[0] == Cmd.pong) {
          _lastPong = DateTime.now();
          if (!_connected) {
            _connected = true;
            onConnected?.call();
          }
        }
        break;
    }
  }

  void _send(int type, Uint8List payload, {int flags = 0}) {
    if (_socket == null || _disposed) return;
    final hdr = PacketHeader(
      type: type,
      seq: _seq++,
      len: payload.length,
      flags: flags,
    );
    final packet = Uint8List(headerSize + payload.length);
    packet.setAll(0, hdr.encode());
    packet.setAll(headerSize, payload);
    try {
      _socket!.send(packet, InternetAddress(espIp), udpPort);
    } catch (e) {
      debugPrint('UDP send error: $e');
    }
  }

  void sendAudioStream(Uint8List data) => _send(PktType.audioStream, data);
  void sendCommand(int cmd) => _send(PktType.cmd, Uint8List.fromList([cmd]));

  Future<void> sendAudioFile(Uint8List fileData) async {
    if (!_connected || _disposed) return;
    sendCommand(Cmd.fileStart);
    await Future.delayed(const Duration(milliseconds: 50));
    int offset = 0;
    while (offset < fileData.length) {
      if (!_connected || _disposed) break;
      final end = (offset + maxPayloadSize).clamp(0, fileData.length);
      _send(PktType.audioFile, fileData.sublist(offset, end));
      offset = end;
      await Future.delayed(const Duration(milliseconds: 5));
    }
    if (_connected && !_disposed) {
      _send(PktType.audioFileEnd, Uint8List(0));
    }
  }

  void _cleanup() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _socket?.close();
    _socket = null;
    _connected = false;
    _lastPong = null;
  }

  void disconnect() {
    _disposed = true;
    _cleanup();
  }
}
