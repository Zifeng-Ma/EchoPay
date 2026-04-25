import 'package:flutter_tts/flutter_tts.dart';

class VoiceAgentTtsService {
  VoiceAgentTtsService() : _tts = FlutterTts();

  final FlutterTts _tts;
  bool _configured = false;

  Future<void> speak(String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }

    await _configureIfNeeded();
    await _tts.stop();
    await _tts.speak(trimmed);
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<void> dispose() async {
    await _tts.stop();
  }

  Future<void> _configureIfNeeded() async {
    if (_configured) {
      return;
    }

    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.56);
    await _tts.setPitch(1.02);
    await _tts.setVolume(1.0);
    await _selectPreferredVoice();

    try {
      await _tts.setSharedInstance(true);
    } catch (_) {
      // Not supported on every platform.
    }

    _configured = true;
  }

  Future<void> _selectPreferredVoice() async {
    try {
      final voices = await _tts.getVoices;
      if (voices is! List) {
        return;
      }

      Map<String, dynamic>? selected;
      final preferredNames = <String>[
        'samantha',
        'ava',
        'allison',
        'karen',
        'serena',
        'google us english',
        'en-us-language',
      ];

      for (final voice in voices) {
        if (voice is! Map) {
          continue;
        }
        final locale = (voice['locale'] ?? voice['language'] ?? '')
            .toString()
            .toLowerCase();
        final name = (voice['name'] ?? '').toString().toLowerCase();
        if (!locale.contains('en-us') && !locale.contains('en_us')) {
          continue;
        }

        if (preferredNames.any(name.contains)) {
          selected = Map<String, dynamic>.from(voice);
          break;
        }

        selected ??= Map<String, dynamic>.from(voice);
      }

      if (selected == null) {
        return;
      }

      final chosen = <String, String>{};
      final name = selected['name']?.toString();
      final locale = (selected['locale'] ?? selected['language'])?.toString();
      final identifier = selected['identifier']?.toString();

      if (name != null && name.isNotEmpty) {
        chosen['name'] = name;
      }
      if (locale != null && locale.isNotEmpty) {
        chosen['locale'] = locale;
      }
      if (identifier != null && identifier.isNotEmpty) {
        chosen['identifier'] = identifier;
      }

      if (chosen.isNotEmpty) {
        await _tts.setVoice(chosen);
      }
    } catch (_) {
      // Voice availability differs across browsers and devices.
    }
  }
}
