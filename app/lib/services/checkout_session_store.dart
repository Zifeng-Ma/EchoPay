import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/voice_order_result.dart';

class CheckoutSessionSnapshot {
  const CheckoutSessionSnapshot({
    required this.agentText,
    required this.userTranscript,
    required this.history,
  });

  final String agentText;
  final String userTranscript;
  final List<VoiceOrderResult> history;

  VoiceOrderResult? get latestResult => history.isEmpty ? null : history.last;

  Map<String, dynamic> toJson() {
    return {
      'agent_text': agentText,
      'user_transcript': userTranscript,
      'history': history.map((item) => item.toJson()).toList(),
    };
  }

  factory CheckoutSessionSnapshot.fromJson(Map<String, dynamic> json) {
    final history = (json['history'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(VoiceOrderResult.fromJson)
        .toList();

    return CheckoutSessionSnapshot(
      agentText: json['agent_text'] as String? ?? '',
      userTranscript: json['user_transcript'] as String? ?? '',
      history: history,
    );
  }
}

class CheckoutSessionStore {
  static const String _storageKey = 'echopay_checkout_session_v1';

  Future<void> save(CheckoutSessionSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(snapshot.toJson()));
  }

  Future<CheckoutSessionSnapshot?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    return CheckoutSessionSnapshot.fromJson(decoded);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
