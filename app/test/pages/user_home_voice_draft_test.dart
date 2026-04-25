import 'package:flutter_test/flutter_test.dart';

import 'package:app/model/voice_order_result.dart';
import 'package:app/pages/user_home.dart';

void main() {
  test('needs_human voice draft blocks checkout with handoff reason', () {
    final draft = VoiceOrderResult.fromJson({
      'session_status': 'needs_human',
      'handoff_reason': 'Please wait for a team member.',
      'agent_response': 'I will call someone over.',
    });

    expect(voiceDraftBlocksCheckout(draft), isTrue);
    expect(
      voiceDraftCheckoutBlockMessage(draft),
      'Please wait for a team member.',
    );
    expect(voiceDraftDisplayMessage(draft), 'Please wait for a team member.');
  });

  test('non-handoff draft displays agent response and allows checkout', () {
    final draft = VoiceOrderResult.fromJson({
      'agent_response': 'Your order is ready to review.',
      'final_confirmation': 'Confirm this order?',
      'session_status': 'payment_ready',
    });

    expect(voiceDraftBlocksCheckout(draft), isFalse);
    expect(voiceDraftDisplayMessage(draft), 'Your order is ready to review.');
  });
}
