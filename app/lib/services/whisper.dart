// Sends recorded audio to the OpenAI Whisper API for speech-to-text.
// Returns the transcribed text string.

import 'dart:io';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

final _logger = Logger();

class WhisperService {
  static const _url = 'https://api.openai.com/v1/audio/transcriptions';
  static const _model = 'whisper-1';

  static String get _apiKey => dotenv.env['OPENAI_API_KEY'] ?? '';

  /// Transcribes the audio file at [audioPath] using OpenAI Whisper.
  ///
  /// [language] is a BCP-47 language hint (e.g. 'en', 'nl') — improves
  /// accuracy and latency. Omit to let Whisper auto-detect.
  static Future<String> transcribe({
    required String audioPath,
    String? language,
  }) async {
    if (_apiKey.isEmpty) throw Exception('OPENAI_API_KEY not set in .env');

    final file = File(audioPath);
    if (!file.existsSync()) {
      throw Exception('Audio file not found: $audioPath');
    }
    final fileSize = await file.length();
    if (fileSize < 512) {
      throw Exception('Audio recording is empty or incomplete: $audioPath');
    }

    final request = http.MultipartRequest('POST', Uri.parse(_url))
      ..headers['Authorization'] = 'Bearer $_apiKey'
      ..fields['model'] = _model
      ..files.add(await http.MultipartFile.fromPath('file', audioPath));

    if (language != null && language.isNotEmpty) {
      request.fields['language'] = language;
    }

    try {
      final streamed = await request.send().timeout(
        const Duration(seconds: 30),
      );
      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        throw Exception('Whisper error ${streamed.statusCode}: $body');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final text = (json['text'] as String? ?? '').trim();
      _logger.d('Whisper: "$text"');
      return text;
    } catch (e) {
      _logger.e('WhisperService.transcribe: $e');
      rethrow;
    } finally {
      // Clean up temp file
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }
}
