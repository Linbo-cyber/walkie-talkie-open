import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/udp_service.dart';
import '../services/audio_service.dart';
import '../services/wifi_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final UdpService _udp = UdpService();
  final AudioService _audio = AudioService();
  final WifiService _wifi = WifiService();

  bool _connected = false;
  bool _muted = false;
  bool _recording = false;
  bool _sendingFile = false;
  String _status = '未连接';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupUdp();
    _connectToEsp();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.nearbyWifiDevices,
      Permission.location,
    ].request();
  }

  void _setupUdp() {
    _udp.onConnected = () {
      setState(() {
        _connected = true;
        _status = '已连接';
      });
    };

    _udp.onDisconnected = () {
      setState(() {
        _connected = false;
        _status = '连接断开';
      });
    };

    _udp.onAudioReceived = (Uint8List data) {
      // TODO: phone playback if needed
    };

    _udp.onStatusReceived = (int code) {};
  }

  Future<void> _connectToEsp() async {
    setState(() => _status = '正在连接WiFi...');
    final wifiOk = await _wifi.autoConnect();
    if (!wifiOk) {
      setState(() => _status = 'WiFi连接失败，请手动连接WalkieTalkie');
      return;
    }
    setState(() => _status = '连接设备中...');
    await _udp.connect();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _udp.sendCommand(_muted ? Cmd.mute : Cmd.unmute);
    _audio.setMute(_muted);
  }

  Future<void> _startTalk() async {
    if (!_connected) return;
    _udp.sendCommand(Cmd.startStream);
    _audio.onAudioCaptured = (Uint8List pcmData) {
      _udp.sendAudioStream(pcmData);
    };
    await _audio.startRecording();
    setState(() => _recording = true);
  }

  Future<void> _stopTalk() async {
    await _audio.stopRecording();
    _udp.sendCommand(Cmd.stopStream);
    setState(() => _recording = false);
  }

  Future<void> _pickAndSendFile() async {
    if (!_connected) {
      _showSnack('请先连接设备');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放音频'),
        content: const Text('选择一个音频文件发送到设备播放？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );

    if (confirmed != true) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    setState(() {
      _sendingFile = true;
      _status = '发送音频中...';
    });

    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      await _udp.sendAudioFile(bytes);
      _showSnack('音频已发送');
    } catch (e) {
      _showSnack('发送失败: $e');
    } finally {
      setState(() {
        _sendingFile = false;
        _status = '已连接';
      });
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _audio.dispose();
    _udp.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _connected;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('WalkieTalkie'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              connected ? Icons.wifi : Icons.wifi_off,
              color: connected ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: connected
                ? Colors.green.withValues(alpha: 0.1)
                : Colors.red.withValues(alpha: 0.1),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: connected ? Colors.green : Colors.red,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          const Spacer(),

          if (_recording)
            Column(
              children: [
                Icon(Icons.mic, size: 64, color: Colors.red.shade400),
                const SizedBox(height: 8),
                Text(
                  '正在对讲...',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.red.shade400,
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),

          if (_sendingFile)
            Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 8),
                Text('发送音频中...', style: theme.textTheme.titleMedium),
                const SizedBox(height: 32),
              ],
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ActionButton(
                  icon: _muted ? Icons.volume_off : Icons.volume_up,
                  label: _muted ? '已静音' : '声音',
                  color: _muted ? Colors.red : theme.colorScheme.primary,
                  onTap: _toggleMute,
                ),

                GestureDetector(
                  onLongPressStart: (_) => _startTalk(),
                  onLongPressEnd: (_) => _stopTalk(),
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording
                          ? Colors.red
                          : (connected
                              ? theme.colorScheme.primary
                              : Colors.grey),
                      boxShadow: [
                        if (_recording)
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.4),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                      ],
                    ),
                    child: const Icon(
                      Icons.mic,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),

                _ActionButton(
                  icon: Icons.music_note,
                  label: '音频',
                  color: theme.colorScheme.primary,
                  onTap: _pickAndSendFile,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          Text(
            '长按麦克风按钮对讲',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),

          const Spacer(),

          if (!connected)
            Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: ElevatedButton.icon(
                onPressed: _connectToEsp,
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
            ),

          if (connected) const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.1),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
