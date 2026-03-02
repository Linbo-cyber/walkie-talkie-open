import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';

class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _recorderSub;
  bool _isRecording = false;
  bool _isMuted = false;
  bool _disposed = false;

  bool get isRecording => _isRecording;
  bool get isMuted => _isMuted;

  void Function(Uint8List pcmData)? onAudioCaptured;

  Future<bool> checkPermission() async {
    if (_disposed) return false;
    return await _recorder.hasPermission();
  }

  Future<void> startRecording() async {
    if (_disposed || _isRecording) return;
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission || _disposed) return;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
    );

    _recorderSub = stream.listen((data) {
      if (!_isMuted && !_disposed) {
        onAudioCaptured?.call(data);
      }
    });

    _isRecording = true;
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    await _recorderSub?.cancel();
    _recorderSub = null;
    await _recorder.stop();
    _isRecording = false;
  }

  void setMute(bool mute) {
    _isMuted = mute;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopRecording();
    _recorder.dispose();
  }
}
