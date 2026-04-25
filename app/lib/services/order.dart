// Business logic for the shopping cart: calculates totals, handles item
// quantities/modifiers, and persists orders to Supabase.

import 'package:logger/logger.dart';
import 'supabase.dart';
import 'provider.dart';

final _logger = Logger();

class OrderService {
  // ---------------------------------------------------------------------------
  // Order Submission
  // ---------------------------------------------------------------------------

  /// Converts the current cart into a persisted order.
  ///
  /// 1. Creates the parent `orders` row with status `draft`.
  /// 2. Writes each cart item to `order_items`.
  /// 3. Writes selected modifiers to `order_item_modifiers`.
  ///
  /// Returns the new order's UUID.
  static Future<String> submitOrder({
    required String restaurantId,
    required String qrLocationId,
    String? customerId,
    required List<CartItem> cartItems,
  }) async {
    if (cartItems.isEmpty) throw Exception('Cannot submit an empty cart.');

    try {
      final totalCents = cartItems.fold(0, (sum, item) => sum + item.lineTotal);

      final order = await SupabaseService.createOrder(
        restaurantId: restaurantId,
        customerId: customerId,
        qrLocationId: qrLocationId,
        totalAmount: totalCents,
      );
      final orderId = order['id'] as String;

      await _persistCartItems(orderId, cartItems);

      _logger.i(
          'OrderService: created order $orderId (${formatPrice(totalCents)})');
      return orderId;
    } catch (e) {
      _logger.e('OrderService.submitOrder: $e');
      rethrow;
    }
  }

  /// Writes `order_items` and `order_item_modifiers` rows for each cart entry.
  static Future<void> _persistCartItems(
      String orderId, List<CartItem> cartItems) async {
    for (final item in cartItems) {
      final orderItem = await SupabaseService.addOrderItem(
        orderId: orderId,
        menuItemId: item.menuItemId,
        quantity: item.quantity,
        priceAtPurchase: item.basePrice,
        specialInstructions: item.specialInstructions,
      );

      if (item.modifiers.isNotEmpty) {
        await SupabaseService.addOrderItemModifiers(
          orderItem['id'] as String,
          item.modifiers.map((m) => m.id).toList(),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Order Status
  // ---------------------------------------------------------------------------

  /// Advance an order to [status].
  static Future<void> updateStatus(String orderId, String status) async {
    try {
      await SupabaseService.updateOrder(orderId, {'order_status': status});
      _logger.i('OrderService: order $orderId → $status');
    } catch (e) {
      _logger.e('OrderService.updateStatus: $e');
      rethrow;
    }
  }

  /// Records the bunq transaction ID and marks the order as `confirmed`.
  static Future<void> attachPaymentId(
      String orderId, String bunqTransactionId) async {
    try {
      await SupabaseService.updateOrder(orderId, {
        'order_status': 'confirmed',
        'bunq_transaction_id': bunqTransactionId,
      });
      _logger.i('OrderService: attached payment $bunqTransactionId to $orderId');
    } catch (e) {
      _logger.e('OrderService.attachPaymentId: $e');
      rethrow;
    }
  }

  /// Marks an order as `cancelled`.
  static Future<void> cancelOrder(String orderId) =>
      updateStatus(orderId, 'cancelled');

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------

  /// Formats [cents] as a human-readable price string (e.g. €10.50).
  static String formatPrice(int cents, {String currency = 'EUR'}) {
    const symbols = {'EUR': '€', 'USD': '\$', 'GBP': '£'};
    final symbol = symbols[currency] ?? currency;
    return '$symbol${(cents / 100).toStringAsFixed(2)}';
  }
}
