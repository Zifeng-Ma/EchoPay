import 'package:flutter_test/flutter_test.dart';

import 'package:app/model/voice_order_result.dart';

void main() {
  group('VoiceOrderResult.fromJson', () {
    test('parses new voice order fields and split requests', () {
      final result = VoiceOrderResult.fromJson({
        'transcript': 'Two coffees split between Sam and Alex.',
        'short_summary': 'Two coffees with separate payment requests.',
        'final_confirmation': 'I can split this between Sam and Alex.',
        'needs_confirmation': true,
        'payment_ready': true,
        'contradictions': ['Alex changed tea to coffee'],
        'merchant_name': 'Echo Cafe',
        'customer_name': 'Sam',
        'payment_amount': '8.50',
        'currency': 'EUR',
        'payment_reason': 'Coffee order',
        'order_items': [
          {'name': 'Coffee', 'quantity': 2, 'notes': 'oat milk'},
        ],
        'speaker_turns': [
          {
            'speaker_label': 'Speaker 1',
            'text': 'Two coffees please',
            'start_seconds': 0,
            'end_seconds': 1.5,
          },
        ],
        'speaker_insights': [
          {
            'speaker_label': 'Speaker 1',
            'role': 'customer',
            'display_name': 'Sam',
            'needs_help': false,
            'help_reason': '',
          },
        ],
        'split_requested': true,
        'split_summary': 'Sam and Alex each pay for one coffee.',
        'split_payment_requests': [
          {
            'speaker_label': 'Speaker 1',
            'customer_name': 'Sam',
            'amount': '4.25',
            'currency': 'EUR',
            'payment_reason': 'Coffee',
            'order_items': [
              {'name': 'Coffee', 'quantity': 1, 'notes': ''},
            ],
          },
        ],
        'agent_response': 'I have the split ready.',
        'session_status': 'payment_ready',
        'should_call_human_server': false,
        'handoff_reason': '',
        'user_type': 'customer',
        'hesitation_detected': false,
        'turn_count': 2,
        'turn_limit_reached': false,
      });

      expect(result.transcript, contains('Two coffees'));
      expect(result.paymentReady, isTrue);
      expect(result.paymentAmountValue, 8.5);
      expect(result.orderItems.single.displayName, '2 x Coffee');
      expect(result.speakerTurns.single.endSeconds, 1.5);
      expect(result.speakerInsights.single.label, 'Sam');
      expect(result.splitRequested, isTrue);
      expect(result.splitPaymentRequests.single.amountValue, 4.25);
      expect(result.agentResponse, 'I have the split ready.');
      expect(result.needsHuman, isFalse);
      expect(result.turnCount, 2);
    });

    test('uses defaults and marks needsHuman from session status', () {
      final result = VoiceOrderResult.fromJson({
        'session_status': 'needs_human',
        'handoff_reason': 'A team member should help confirm this order.',
      });

      expect(result.currency, 'EUR');
      expect(result.needsConfirmation, isFalse);
      expect(result.paymentReady, isFalse);
      expect(result.orderItems, isEmpty);
      expect(result.splitPaymentRequests, isEmpty);
      expect(result.needsHuman, isTrue);
      expect(result.handoffReason, contains('team member'));
      expect(result.turnCount, 1);
    });
  });
}
