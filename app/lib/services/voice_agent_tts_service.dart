import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';

class VoiceAgentTtsService {
  VoiceAgentTtsService() : _player = AudioPlayer();

  final AudioPlayer _player;

  Future<void> playBase64({
    required String audioBase64,
    String contentType = 'audio/wav',
  }) async {
    final trimmed = audioBase64.trim();
    if (trimmed.isEmpty) {
      return;
    }

    await _player.stop();
    await _player.play(
      BytesSource(base64Decode(trimmed), mimeType: contentType),
    );
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
