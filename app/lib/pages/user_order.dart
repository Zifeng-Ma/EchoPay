// Dual-purpose screen: shows live progress of the current order
// (e.g., "Kitchen is preparing") and a historical list of past receipts.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/order.dart';
import '../services/payment.dart';
import '../services/provider.dart';
import '../services/supabase.dart';
import 'user_home.dart';

class UserOrderPage extends ConsumerStatefulWidget {
  const UserOrderPage({super.key});

  @override
  ConsumerState<UserOrderPage> createState() => _UserOrderPageState();
}

class _UserOrderPageState extends ConsumerState<UserOrderPage> {
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  String? _payingOrderId;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _subscribeToActiveOrder();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final data = await SupabaseService.getCustomerOrders(user.id);
      if (mounted) setState(() { _history = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handlePayNow(String orderId) async {
    setState(() => _payingOrderId = orderId);
    try {
      await PaymentService.payNow(orderId: orderId);
      await _loadHistory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _payingOrderId = null);
    }
  }

  void _subscribeToActiveOrder() {
    final orderId = ref.read(activeOrderIdProvider);
    if (orderId == null) return;
    _channel = SupabaseService.subscribeToOrder(orderId, (record) {
      final status = record['order_status'] as String?;
      if (status != null && mounted) {
        ref.read(orderStatusProvider.notifier).state = status;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeOrderId = ref.watch(activeOrderIdProvider);
    final orderStatus = ref.watch(orderStatusProvider);
    final teal = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const UserHomePage()),
            );
          },
        ),
        title: const Text(
          'Orders',
          style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1A1A2E)),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Active order tracker
          if (activeOrderId != null && orderStatus != 'idle' && orderStatus != 'completed')
            _OrderTracker(
              status: orderStatus,
              teal: teal,
              onPayNow: orderStatus == 'pending_payment' && _payingOrderId == null
                  ? () => _handlePayNow(activeOrderId!)
                  : null,
              paying: _payingOrderId == activeOrderId,
            ),

          // History
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              'Order History',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1A1A2E),
                  ),
            ),
          ),

          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _history.isEmpty
                    ? Center(
                        child: Text(
                          'No past orders yet.',
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _history.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _OrderHistoryCard(
                          order: _history[i],
                          onPayNow: _history[i]['order_status'] == 'pending_payment' &&
                                  _payingOrderId == null
                              ? () => _handlePayNow(_history[i]['id'] as String)
                              : null,
                          paying: _payingOrderId == _history[i]['id'],
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live order status tracker
// ---------------------------------------------------------------------------

class _OrderTracker extends StatelessWidget {
  final String status;
  final Color teal;
  final VoidCallback? onPayNow;
  final bool paying;

  const _OrderTracker({
    required this.status,
    required this.teal,
    this.onPayNow,
    this.paying = false,
  });

  static const _labels = {
    'draft': 'Order placed',
    'pending_payment': 'Waiting for payment…',
    'confirmed': 'Payment confirmed!',
    'in_progress': 'Kitchen is preparing your order',
    'ready_for_delivery': 'Your order is ready!',
    'completed': 'Order complete',
    'cancelled': 'Order cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final label = _labels[status] ?? status;
    final isCancelled = status == 'cancelled';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isCancelled
            ? Colors.red.withAlpha(15)
            : teal.withAlpha(20),
        border: Border.all(
          color: isCancelled ? Colors.red.withAlpha(60) : teal.withAlpha(60),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isCancelled && !paying)
                const Icon(Icons.cancel_outlined, size: 20, color: Colors.red)
              else
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(teal),
                  ),
                ),
              const SizedBox(width: 12),
              Text(
                paying ? 'Processing payment…' : label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isCancelled ? Colors.red : const Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
          if (status == 'pending_payment' && onPayNow != null && !paying)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onPayNow,
                  style: FilledButton.styleFrom(backgroundColor: teal),
                  child: const Text('Pay Now'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Order history card
// ---------------------------------------------------------------------------

class _OrderHistoryCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback? onPayNow;
  final bool paying;

  const _OrderHistoryCard({
    required this.order,
    this.onPayNow,
    this.paying = false,
  });

  @override
  Widget build(BuildContext context) {
    final restaurantName =
        (order['restaurants'] as Map<String, dynamic>?)?['name'] as String? ??
            'Restaurant';
    final status = order['order_status'] as String? ?? '';
    final totalCents = (order['total_amount'] as int?) ?? 0;
    final createdAt = DateTime.tryParse(order['created_at'] as String? ?? '');
    final items = (order['order_items'] as List<dynamic>?) ?? [];
    final itemNames = items
        .map((i) =>
            (i['menu_items'] as Map<String, dynamic>?)?['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .take(3)
        .join(', ');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  restaurantName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                if (itemNames.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      itemNames,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (createdAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _formatDate(createdAt),
                      style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                    ),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                OrderService.formatPrice(totalCents),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              const SizedBox(height: 4),
              _StatusChip(status: status),
              if (status == 'pending_payment') ...[
                const SizedBox(height: 8),
                paying
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: onPayNow,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Pay Now',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

class _StatusChip extends StatelessWidget {
  final String status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'completed' => ('Completed', Colors.green),
      'cancelled' => ('Cancelled', Colors.red),
      'confirmed' => ('Confirmed', Colors.blue),
      'in_progress' => ('In Progress', Colors.orange),
      'ready_for_delivery' => ('Ready', Colors.green),
      _ => (status, Colors.grey),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
