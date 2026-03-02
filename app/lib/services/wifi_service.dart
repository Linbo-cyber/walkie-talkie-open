import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wifi_iot/wifi_iot.dart';

class WifiService {
  static const String espSsid = 'WalkieTalkie';
  static const String espPassword = 'walkie1234';
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

  /// 自动连接到 ESP32 WiFi，返回是否成功
  Future<bool> autoConnect() async {
    if (await isConnectedToEsp()) return true;

    try {
      final result = await WiFiForIoTPlugin.connect(
        espSsid,
        password: espPassword,
        security: NetworkSecurity.WPA,
        joinOnce: false,
        withInternet: false,
      );
      return result;
    } catch (e) {
      debugPrint('WiFi auto-connect error: $e');
      return false;
    }
  }
}
