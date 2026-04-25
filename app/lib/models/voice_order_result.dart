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
      name: json['name'] as String? ?? '',
      quantity: json['quantity'] as int? ?? 1,
      notes: json['notes'] as String? ?? '',
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
      speakerLabel: json['speaker_label'] as String? ?? 'Speaker 1',
      text: json['text'] as String? ?? '',
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
      speakerLabel: json['speaker_label'] as String? ?? 'Speaker 1',
      role: json['role'] as String? ?? 'unknown',
      displayName: json['display_name'] as String? ?? '',
      needsHelp: json['needs_help'] as bool? ?? false,
      helpReason: json['help_reason'] as String? ?? '',
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
    final rawItems = json['order_items'] as List<dynamic>? ?? const [];
    return SplitPaymentRequest(
      speakerLabel: json['speaker_label'] as String? ?? 'Speaker 1',
      customerName: json['customer_name'] as String? ?? '',
      amount: json['amount'] as String? ?? '',
      currency: json['currency'] as String? ?? 'EUR',
      paymentReason: json['payment_reason'] as String? ?? '',
      orderItems: rawItems
          .whereType<Map<String, dynamic>>()
          .map(VoiceOrderItem.fromJson)
          .toList(),
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

  double? get paymentAmountValue => double.tryParse(paymentAmount);
  bool get hasPayableAmount => paymentAmountValue != null;
  bool get hasSplitRequests => splitPaymentRequests.isNotEmpty;

  factory VoiceOrderResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['order_items'] as List<dynamic>? ?? const [];
    final rawContradictions =
        json['contradictions'] as List<dynamic>? ?? const [];
    final rawSpeakerTurns = json['speaker_turns'] as List<dynamic>? ?? const [];
    final rawSpeakerInsights =
        json['speaker_insights'] as List<dynamic>? ?? const [];
    final rawSplitRequests =
        json['split_payment_requests'] as List<dynamic>? ?? const [];

    return VoiceOrderResult(
      transcript: json['transcript'] as String? ?? '',
      shortSummary: json['short_summary'] as String? ?? '',
      finalConfirmation: json['final_confirmation'] as String? ?? '',
      needsConfirmation: json['needs_confirmation'] as bool? ?? false,
      paymentReady: json['payment_ready'] as bool? ?? false,
      contradictions: rawContradictions
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(),
      merchantName: json['merchant_name'] as String? ?? '',
      customerName: json['customer_name'] as String? ?? '',
      paymentAmount: json['payment_amount'] as String? ?? '',
      currency: json['currency'] as String? ?? 'EUR',
      paymentReason: json['payment_reason'] as String? ?? '',
      orderItems: rawItems
          .whereType<Map<String, dynamic>>()
          .map(VoiceOrderItem.fromJson)
          .toList(),
      speakerTurns: rawSpeakerTurns
          .whereType<Map<String, dynamic>>()
          .map(SpeakerTurn.fromJson)
          .toList(),
      speakerInsights: rawSpeakerInsights
          .whereType<Map<String, dynamic>>()
          .map(SpeakerInsight.fromJson)
          .toList(),
      splitRequested: json['split_requested'] as bool? ?? false,
      splitSummary: json['split_summary'] as String? ?? '',
      splitPaymentRequests: rawSplitRequests
          .whereType<Map<String, dynamic>>()
          .map(SplitPaymentRequest.fromJson)
          .toList(),
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
    };
  }
}
