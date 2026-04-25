class VoiceOrderItem {
  const VoiceOrderItem({
    required this.name,
    required this.quantity,
    required this.notes,
  });

  final String name;
  final int quantity;
  final String notes;

  factory VoiceOrderItem.fromJson(Map<String, dynamic> json) {
    return VoiceOrderItem(
      name: _asString(json['name']),
      quantity: _asInt(json['quantity'], fallback: 1),
      notes: _asString(json['notes']),
    );
  }

  String get displayName => quantity > 1 ? '$quantity x $name' : name;

  Map<String, dynamic> toJson() {
    return {'name': name, 'quantity': quantity, 'notes': notes};
  }
}

class SpeakerTurn {
  const SpeakerTurn({
    required this.speakerLabel,
    required this.text,
    required this.startSeconds,
    required this.endSeconds,
  });

  final String speakerLabel;
  final String text;
  final double? startSeconds;
  final double? endSeconds;

  factory SpeakerTurn.fromJson(Map<String, dynamic> json) {
    return SpeakerTurn(
      speakerLabel: _asString(json['speaker_label'], fallback: 'Speaker 1'),
      text: _asString(json['text']),
      startSeconds: (json['start_seconds'] as num?)?.toDouble(),
      endSeconds: (json['end_seconds'] as num?)?.toDouble(),
    );
  }

  String get timeLabel {
    if (startSeconds == null && endSeconds == null) {
      return '';
    }

    final start = startSeconds?.toStringAsFixed(1);
    final end = endSeconds?.toStringAsFixed(1);
    if (start != null && end != null) {
      return '$start-$end s';
    }
    return '${start ?? end} s';
  }

  Map<String, dynamic> toJson() {
    return {
      'speaker_label': speakerLabel,
      'text': text,
      'start_seconds': startSeconds,
      'end_seconds': endSeconds,
    };
  }
}

class SpeakerInsight {
  const SpeakerInsight({
    required this.speakerLabel,
    required this.role,
    required this.displayName,
    required this.needsHelp,
    required this.helpReason,
  });

  final String speakerLabel;
  final String role;
  final String displayName;
  final bool needsHelp;
  final String helpReason;

  factory SpeakerInsight.fromJson(Map<String, dynamic> json) {
    return SpeakerInsight(
      speakerLabel: _asString(json['speaker_label'], fallback: 'Speaker 1'),
      role: _asString(json['role'], fallback: 'unknown'),
      displayName: _asString(json['display_name']),
      needsHelp: _asBool(json['needs_help']),
      helpReason: _asString(json['help_reason']),
    );
  }

  String get label => displayName.isEmpty ? speakerLabel : displayName;

  Map<String, dynamic> toJson() {
    return {
      'speaker_label': speakerLabel,
      'role': role,
      'display_name': displayName,
      'needs_help': needsHelp,
      'help_reason': helpReason,
    };
  }
}

class SplitPaymentRequest {
  const SplitPaymentRequest({
    required this.speakerLabel,
    required this.customerName,
    required this.amount,
    required this.currency,
    required this.paymentReason,
    required this.orderItems,
  });

  final String speakerLabel;
  final String customerName;
  final String amount;
  final String currency;
  final String paymentReason;
  final List<VoiceOrderItem> orderItems;

  factory SplitPaymentRequest.fromJson(Map<String, dynamic> json) {
    final rawItems = _asMapList(json['order_items']);
    return SplitPaymentRequest(
      speakerLabel: _asString(json['speaker_label'], fallback: 'Speaker 1'),
      customerName: _asString(json['customer_name']),
      amount: _asString(json['amount']),
      currency: _asString(json['currency'], fallback: 'EUR'),
      paymentReason: _asString(json['payment_reason']),
      orderItems: rawItems.map(VoiceOrderItem.fromJson).toList(),
    );
  }

  String get displayName => customerName.isEmpty ? speakerLabel : customerName;
  double? get amountValue => double.tryParse(amount);
  bool get hasAmount => amountValue != null;

  Map<String, dynamic> toJson() {
    return {
      'speaker_label': speakerLabel,
      'customer_name': customerName,
      'amount': amount,
      'currency': currency,
      'payment_reason': paymentReason,
      'order_items': orderItems.map((item) => item.toJson()).toList(),
    };
  }
}

class VoiceOrderResult {
  const VoiceOrderResult({
    required this.transcript,
    required this.shortSummary,
    required this.finalConfirmation,
    required this.needsConfirmation,
    required this.paymentReady,
    required this.contradictions,
    required this.merchantName,
    required this.customerName,
    required this.paymentAmount,
    required this.currency,
    required this.paymentReason,
    required this.orderItems,
    required this.speakerTurns,
    required this.speakerInsights,
    required this.splitRequested,
    required this.splitSummary,
    required this.splitPaymentRequests,
    required this.agentResponse,
    required this.sessionStatus,
    required this.shouldCallHumanServer,
    required this.handoffReason,
    required this.userType,
    required this.hesitationDetected,
    required this.turnCount,
    required this.turnLimitReached,
    required this.agentAudioBase64,
    required this.agentAudioContentType,
  });

  final String transcript;
  final String shortSummary;
  final String finalConfirmation;
  final bool needsConfirmation;
  final bool paymentReady;
  final List<String> contradictions;
  final String merchantName;
  final String customerName;
  final String paymentAmount;
  final String currency;
  final String paymentReason;
  final List<VoiceOrderItem> orderItems;
  final List<SpeakerTurn> speakerTurns;
  final List<SpeakerInsight> speakerInsights;
  final bool splitRequested;
  final String splitSummary;
  final List<SplitPaymentRequest> splitPaymentRequests;
  final String agentResponse;
  final String sessionStatus;
  final bool shouldCallHumanServer;
  final String handoffReason;
  final String userType;
  final bool hesitationDetected;
  final int turnCount;
  final bool turnLimitReached;
  final String agentAudioBase64;
  final String agentAudioContentType;

  double? get paymentAmountValue => double.tryParse(paymentAmount);
  bool get hasPayableAmount => paymentAmountValue != null;
  bool get hasSplitRequests => splitPaymentRequests.isNotEmpty;
  bool get isCompleted => sessionStatus == 'completed';
  bool get needsHuman =>
      sessionStatus == 'needs_human' || shouldCallHumanServer;

  factory VoiceOrderResult.fromJson(Map<String, dynamic> json) {
    final rawItems = _asMapList(json['order_items']);
    final rawSpeakerTurns = _asMapList(json['speaker_turns']);
    final rawSpeakerInsights = _asMapList(json['speaker_insights']);
    final rawSplitRequests = _asMapList(json['split_payment_requests']);

    return VoiceOrderResult(
      transcript: _asString(json['transcript']),
      shortSummary: _asString(json['short_summary']),
      finalConfirmation: _asString(json['final_confirmation']),
      needsConfirmation: _asBool(json['needs_confirmation']),
      paymentReady: _asBool(json['payment_ready']),
      contradictions: _asList(json['contradictions'])
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(),
      merchantName: _asString(json['merchant_name']),
      customerName: _asString(json['customer_name']),
      paymentAmount: _asString(json['payment_amount']),
      currency: _asString(json['currency'], fallback: 'EUR'),
      paymentReason: _asString(json['payment_reason']),
      orderItems: rawItems.map(VoiceOrderItem.fromJson).toList(),
      speakerTurns: rawSpeakerTurns.map(SpeakerTurn.fromJson).toList(),
      speakerInsights: rawSpeakerInsights.map(SpeakerInsight.fromJson).toList(),
      splitRequested: _asBool(json['split_requested']),
      splitSummary: _asString(json['split_summary']),
      splitPaymentRequests: rawSplitRequests
          .map(SplitPaymentRequest.fromJson)
          .toList(),
      agentResponse: _asString(json['agent_response']),
      sessionStatus: _asString(json['session_status'], fallback: 'ordering'),
      shouldCallHumanServer: _asBool(json['should_call_human_server']),
      handoffReason: _asString(json['handoff_reason']),
      userType: _asString(json['user_type'], fallback: 'unknown'),
      hesitationDetected: _asBool(json['hesitation_detected']),
      turnCount: _asInt(json['turn_count'], fallback: 1),
      turnLimitReached: _asBool(json['turn_limit_reached']),
      agentAudioBase64: _asString(json['agent_audio_base64']),
      agentAudioContentType: _asString(
        json['agent_audio_content_type'],
        fallback: 'audio/wav',
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transcript': transcript,
      'short_summary': shortSummary,
      'final_confirmation': finalConfirmation,
      'needs_confirmation': needsConfirmation,
      'payment_ready': paymentReady,
      'contradictions': contradictions,
      'merchant_name': merchantName,
      'customer_name': customerName,
      'payment_amount': paymentAmount,
      'currency': currency,
      'payment_reason': paymentReason,
      'order_items': orderItems.map((item) => item.toJson()).toList(),
      'speaker_turns': speakerTurns.map((turn) => turn.toJson()).toList(),
      'speaker_insights': speakerInsights
          .map((insight) => insight.toJson())
          .toList(),
      'split_requested': splitRequested,
      'split_summary': splitSummary,
      'split_payment_requests': splitPaymentRequests
          .map((request) => request.toJson())
          .toList(),
      'agent_response': agentResponse,
      'session_status': sessionStatus,
      'should_call_human_server': shouldCallHumanServer,
      'handoff_reason': handoffReason,
      'user_type': userType,
      'hesitation_detected': hesitationDetected,
      'turn_count': turnCount,
      'turn_limit_reached': turnLimitReached,
      'agent_audio_base64': agentAudioBase64,
      'agent_audio_content_type': agentAudioContentType,
    };
  }
}

String _asString(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

int _asInt(Object? value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _asBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return value.toLowerCase() == 'true';
  }
  return false;
}

List<dynamic> _asList(Object? value) {
  return value is List ? value : const [];
}

List<Map<String, dynamic>> _asMapList(Object? value) {
  return _asList(
    value,
  ).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
}
