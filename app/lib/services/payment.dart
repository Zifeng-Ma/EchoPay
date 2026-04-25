// Interacts with the bunq API (via the Python backend) to initiate payment
// requests and confirms transaction success through Supabase order-status polling.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import 'supabase.dart';

final _logger = Logger();

class PaymentService {
  static String get _backendUrl =>
      dotenv.env['BACKEND_URL'] ?? 'http://localhost:8000';

  // ---------------------------------------------------------------------------
  // Payment Request
  // ---------------------------------------------------------------------------

  /// Asks the backend to create a bunq payment request for [orderId].
  ///
  /// The backend handles the bunq API call and stores the resulting
  /// `bunq_transaction_id` in the `orders` row.
  ///
  /// Returns the bunq transaction reference returned by the backend.
  static Future<String> initiatePayment({
    required String orderId,
    required int amountCents,
    required String currency,
    String description = 'EchoPay Order',
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_backendUrl/payment/initiate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'order_id': orderId,
              'amount_cents': amountCents,
              'currency': currency,
              'description': description,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception(
            'Payment initiation failed (${response.statusCode}): ${response.body}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final transactionRef = data['transaction_ref'] as String;

      // Mark order as waiting for customer approval
      await SupabaseService.updateOrder(orderId, {
        'order_status': 'pending_payment',
        'bunq_transaction_id': transactionRef,
      });

      _logger.i(
          'PaymentService: initiated bunq request $transactionRef for order $orderId');
      return transactionRef;
    } on TimeoutException {
      rethrow;
    } catch (e) {
      _logger.e('PaymentService.initiatePayment: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Payment Confirmation
  // ---------------------------------------------------------------------------

  /// Polls the `orders` table until the status leaves `pending_payment`.
  ///
  /// Returns `true` when the order reaches `confirmed`, `false` when it is
  /// `cancelled`. Throws [TimeoutException] if [timeout] elapses first.
  static Future<bool> waitForConfirmation(
    String orderId, {
    Duration timeout = const Duration(minutes: 5),
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);

      final order = await SupabaseService.getOrder(orderId);
      if (order == null) throw Exception('Order $orderId not found during polling');

      final status = order['order_status'] as String;
      _logger.d('PaymentService: polling $orderId → $status');

      if (status == 'confirmed') return true;
      if (status == 'cancelled') return false;
      // 'pending_payment' → keep polling
    }

    throw TimeoutException(
        'Payment confirmation timed out for order $orderId', timeout);
  }

  // ---------------------------------------------------------------------------
  // Full Flow
  // ---------------------------------------------------------------------------

  /// Runs the complete payment flow:
  /// 1. Initiates the bunq request.
  /// 2. Waits for the customer to approve via the bunq app.
  /// 3. Returns `true` on success, `false` on cancellation.
  ///
  /// [onStatusUpdate] is called with a human-readable status string at each
  /// stage so the UI can display progress.
  static Future<bool> processPayment({
    required String orderId,
    required int amountCents,
    required String currency,
    String description = 'EchoPay Order',
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      onStatusUpdate?.call('initiating');
      await initiatePayment(
        orderId: orderId,
        amountCents: amountCents,
        currency: currency,
        description: description,
      );

      onStatusUpdate?.call('pending');
      final confirmed = await waitForConfirmation(orderId);

      onStatusUpdate?.call(confirmed ? 'confirmed' : 'cancelled');
      return confirmed;
    } on TimeoutException {
      onStatusUpdate?.call('timeout');
      rethrow;
    } catch (e) {
      onStatusUpdate?.call('error');
      _logger.e('PaymentService.processPayment: $e');
      rethrow;
    }
  }
}
