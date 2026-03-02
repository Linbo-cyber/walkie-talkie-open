import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Packet types matching firmware protocol.h
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
    buf.setUint16(1, seq, Endian.little);
    buf.setUint16(3, len, Endian.little);
    buf.setUint8(5, flags);
    buf.setUint16(6, 0, Endian.little); // reserved
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

typedef AudioCallback = void Function(Uint8List opusData);
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

  bool get isConnected => _connected;

  Future<void> connect() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;

    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _socket!.receive();
        if (dg != null) {
          _handleDatagram(dg.data);
        }
      }
    });

    // Send initial ping to register with ESP
    sendCommand(Cmd.ping);

    // Periodic ping: fast retry until connected, then keepalive
    _pingTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      sendCommand(Cmd.ping);

      // Check timeout only after connected
      if (_connected &&
          _lastPong != null &&
          DateTime.now().difference(_lastPong!).inSeconds > 10) {
        _connected = false;
        onDisconnected?.call();
      }

      // Slow down ping once connected
      if (_connected) {
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          sendCommand(Cmd.ping);
          if (_lastPong != null &&
              DateTime.now().difference(_lastPong!).inSeconds > 10) {
            if (_connected) {
              _connected = false;
              onDisconnected?.call();
              // Start fast retry again
              connect();
            }
          }
        });
      }
    });
  }

  void _handleDatagram(Uint8List data) {
    final hdr = PacketHeader.decode(data);
    if (hdr == null) return;

    final payload = data.sublist(headerSize, headerSize + hdr.len);

    switch (hdr.type) {
      case PktType.audioStream:
        onAudioReceived?.call(payload);
        break;
      case PktType.status:
        if (payload.isNotEmpty) {
          onStatusReceived?.call(payload[0]);
        }
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
    if (_socket == null) return;
    final hdr = PacketHeader(
      type: type,
      seq: _seq++,
      len: payload.length,
      flags: flags,
    );
    final packet = Uint8List(headerSize + payload.length);
    packet.setAll(0, hdr.encode());
    packet.setAll(headerSize, payload);
    _socket!.send(packet, InternetAddress(espIp), udpPort);
  }

  void sendAudioStream(Uint8List opusData) {
    _send(PktType.audioStream, opusData);
  }

  void sendCommand(int cmd) {
    _send(PktType.cmd, Uint8List.fromList([cmd]));
  }

  /// Send audio file in chunks
  Future<void> sendAudioFile(Uint8List fileData) async {
    sendCommand(Cmd.fileStart);
    await Future.delayed(const Duration(milliseconds: 50));

    int offset = 0;
    while (offset < fileData.length) {
      final end = (offset + maxPayloadSize).clamp(0, fileData.length);
      final chunk = fileData.sublist(offset, end);
      _send(PktType.audioFile, chunk);
      offset = end;
      // Throttle to avoid overwhelming ESP buffer
      await Future.delayed(const Duration(milliseconds: 5));
    }

    _send(PktType.audioFileEnd, Uint8List(0));
  }

  void disconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _socket?.close();
    _socket = null;
    _connected = false;
  }
}
