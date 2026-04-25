import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:app/services/voice_order_service.dart';

void main() {
  test(
    'analyzeTranscript posts transcript context and parses response',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/payment-draft');
        expect(request.headers['Content-Type'], 'application/json');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['transcript'], 'I want a latte and I am ready to pay.');
        expect(body['conversation_context'], 'Earlier context');
        expect(body['turn_count'], 3);

        return http.Response(
          jsonEncode({
            'transcript': body['transcript'],
            'final_confirmation': 'Ready to charge the latte.',
            'payment_ready': true,
            'currency': 'EUR',
            'order_items': [
              {'name': 'Latte', 'quantity': 1, 'notes': ''},
            ],
            'agent_response': 'Ready to charge the latte.',
            'session_status': 'payment_ready',
            'turn_count': 3,
          }),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final service = VoiceOrderService(client: client);
      final result = await service.analyzeTranscript(
        transcript: 'I want a latte and I am ready to pay.',
        conversationContext: 'Earlier context',
        turnCount: 3,
      );

      expect(result.paymentReady, isTrue);
      expect(result.orderItems.single.name, 'Latte');
      expect(result.agentResponse, 'Ready to charge the latte.');
      expect(result.turnCount, 3);
    },
  );

  test('analyzeTranscript surfaces backend detail on errors', () async {
    final service = VoiceOrderService(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'detail': 'bad transcript'}), 400),
      ),
    );

    expect(
      service.analyzeTranscript(transcript: 'hello'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'bad transcript',
        ),
      ),
    );
  });
}
