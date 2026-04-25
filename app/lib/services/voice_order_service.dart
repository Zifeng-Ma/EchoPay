import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../models/voice_order_result.dart';

class VoiceOrderService {
  VoiceOrderService({http.Client? client}) : _client = client ?? http.Client();

  static const String _baseUrl = String.fromEnvironment(
    'ECHOPAY_AGENT_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  final http.Client _client;
  final AudioRecorder _recorder = AudioRecorder();
  String? _activeRecordingPath;

  Stream<Amplitude> amplitudeStream({
    Duration interval = const Duration(milliseconds: 120),
  }) {
    return _recorder.onAmplitudeChanged(interval);
  }

  Future<void> startListening() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw StateError('Microphone permission was denied.');
    }

    final recordingPath = await _createRecordingTarget();

    await _recorder.start(
      RecordConfig(
        encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: recordingPath,
    );

    _activeRecordingPath = recordingPath;
  }

  Future<VoiceOrderResult> stopListening({
    String conversationContext = '',
    String language = 'en',
    int turnCount = 1,
  }) async {
    final recordingPath = await _recorder.stop() ?? _activeRecordingPath;
    _activeRecordingPath = null;

    if (recordingPath == null || recordingPath.isEmpty) {
      throw StateError('No recording was captured.');
    }

    final request =
        http.MultipartRequest('POST', Uri.parse('$_baseUrl/voice-order'))
          ..fields['conversation_context'] = conversationContext
          ..fields['language'] = language
          ..fields['turn_count'] = '$turnCount';

    if (kIsWeb) {
      final audioBytes = await _readWebRecordingBytes(recordingPath);
      request.files.add(
        http.MultipartFile.fromBytes(
          'audio',
          audioBytes,
          filename: 'voice-order.webm',
        ),
      );
    } else {
      request.files.add(
        await http.MultipartFile.fromPath('audio', recordingPath),
      );
    }

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    final payload = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{};

    if (response.statusCode >= 400) {
      final detail = payload['detail']?.toString() ?? 'Unknown voice error.';
      throw StateError(detail);
    }

    return VoiceOrderResult.fromJson(payload);
  }

  Future<void> cancelListening() async {
    await _recorder.cancel();
    _activeRecordingPath = null;
  }

  Future<VoiceOrderResult> analyzeTranscript({
    required String transcript,
    String conversationContext = '',
    int turnCount = 1,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/payment-draft'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'transcript': transcript,
        'conversation_context': conversationContext,
        'turn_count': turnCount,
      }),
    );

    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    final payload = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{};

    if (response.statusCode >= 400) {
      final detail =
          payload['detail']?.toString() ?? 'Unknown transcript error.';
      throw StateError(detail);
    }

    return VoiceOrderResult.fromJson(payload);
  }

  Future<void> dispose() async {
    await _recorder.dispose();
    _client.close();
  }

  Future<String> _createRecordingTarget() async {
    if (kIsWeb) {
      return '';
    }

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${tempDir.path}/voice-order-$timestamp.m4a';
  }

  Future<Uint8List> _readWebRecordingBytes(String blobUrl) async {
    final response = await http.get(Uri.parse(blobUrl));
    if (response.statusCode >= 400) {
      throw StateError('Could not read the recorded browser audio blob.');
    }
    return response.bodyBytes;
  }
}
