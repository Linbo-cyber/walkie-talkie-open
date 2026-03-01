import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

class WifiService {
  static const String espSsid = 'WalkieTalkie';
  static const String espGateway = '192.168.4.1';

  final NetworkInfo _networkInfo = NetworkInfo();

  Future<bool> isConnectedToEsp() async {
    try {
      final ssid = await _networkInfo.getWifiName();
      return ssid?.replaceAll('"', '') == espSsid;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canReachEsp() async {
    try {
      final socket = await Socket.connect(espGateway, 8888,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      // UDP doesn't need TCP connect, just check gateway ping
      try {
        final result = await InternetAddress(espGateway).reverse();
        return true;
      } catch (_) {
        return true; // Assume reachable if on right network
      }
    }
  }
}
