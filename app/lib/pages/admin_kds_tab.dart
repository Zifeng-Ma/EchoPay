import 'package:flutter/material.dart';
import '../services/supabase.dart';
import '../services/order.dart';

class KdsTab extends StatefulWidget {
  final Map<String, dynamic> restaurant;

  const KdsTab({super.key, required this.restaurant});

  @override
  State<KdsTab> createState() => _KdsTabState();
}

class _KdsTabState extends State<KdsTab> {
  List<Map<String, dynamic>> _orders = [];
  bool _isLoading = true;
  dynamic _subscription;

  String get _restaurantId => widget.restaurant['id'] as String;
  String get _currency => (widget.restaurant['currency'] as String?) ?? 'EUR';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final orders = await SupabaseService.getRestaurantOrders(_restaurantId);
      setState(() => _orders = orders);
      _subscribeToUpdates();
    } catch (e) {
      _showSnack('Failed to load orders: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _subscribeToUpdates() {
    _subscription?.unsubscribe();
    _subscription = SupabaseService.subscribeToRestaurantOrders(_restaurantId, (
      record,
    ) {
      if (!mounted) return;
      setState(() {
        // Find and update the order, or add if new
        final idx = _orders.indexWhere((o) => o['id'] == record['id']);
        if (idx >= 0) {
          _orders[idx] = record;
        } else {
          // Reload to get full data
          _load();
        }
      });
    });
  }

  Future<void> _updateOrderStatus(String orderId, String newStatus) async {
    try {
      await SupabaseService.updateOrder(orderId, {'order_status': newStatus});
      if (!mounted) return;
      _showSnack('Order status updated to $newStatus');
    } catch (e) {
      _showSnack('Failed to update order: $e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _subscription?.unsubscribe();
    super.dispose();
  }

  List<Map<String, dynamic>> _getOrdersByStatus(String status) {
    return _orders
        .where((o) => (o['order_status'] as String?) == status)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_orders.isEmpty) {
      return const Center(
        child: Text(
          'No active orders.',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _KdsColumn(
              title: 'Confirmed',
              orders: _getOrdersByStatus('confirmed'),
              currency: _currency,
              onStatusChange: _updateOrderStatus,
              nextStatus: 'in_progress',
              nextLabel: 'Start Cooking',
            ),
            _KdsColumn(
              title: 'In Progress',
              orders: _getOrdersByStatus('in_progress'),
              currency: _currency,
              onStatusChange: _updateOrderStatus,
              nextStatus: 'ready_for_delivery',
              nextLabel: 'Ready',
            ),
            _KdsColumn(
              title: 'Ready for Delivery',
              orders: _getOrdersByStatus('ready_for_delivery'),
              currency: _currency,
              onStatusChange: null,
              nextStatus: null,
              nextLabel: null,
            ),
          ],
        ),
      ),
    );
  }
}

class _KdsColumn extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> orders;
  final String currency;
  final Future<void> Function(String, String)? onStatusChange;
  final String? nextStatus;
  final String? nextLabel;

  const _KdsColumn({
    required this.title,
    required this.orders,
    required this.currency,
    required this.onStatusChange,
    required this.nextStatus,
    required this.nextLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 380,
      height: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border(
          right: BorderSide(color: colorScheme.outline.withAlpha(80)),
        ),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              border: Border(
                bottom: BorderSide(color: colorScheme.outline.withAlpha(80)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${orders.length} order${orders.length == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onPrimaryContainer.withAlpha(180),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Orders list
          Expanded(
            child: orders.isEmpty
                ? Center(
                    child: Text(
                      'No orders',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: orders.length,
                    itemBuilder: (_, i) => _OrderCard(
                      order: orders[i],
                      currency: currency,
                      onStatusChange: onStatusChange,
                      nextStatus: nextStatus,
                      nextLabel: nextLabel,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final String currency;
  final Future<void> Function(String, String)? onStatusChange;
  final String? nextStatus;
  final String? nextLabel;

  const _OrderCard({
    required this.order,
    required this.currency,
    required this.onStatusChange,
    required this.nextStatus,
    required this.nextLabel,
  });

  String _formatTime(String createdAt) {
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inMinutes < 1) return 'now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m';
      if (diff.inHours < 24) return '${diff.inHours}h';
      return 'yesterday';
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final orderId = order['id'] as String;
    final locationName =
        (order['qr_locations'] as Map<String, dynamic>?)?['location_name']
            as String? ??
        'Unknown';
    final totalAmount = order['total_amount'] as int? ?? 0;
    final createdAt = order['created_at'] as String? ?? '';
    final items = order['order_items'] as List<dynamic>? ?? [];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _showOrderDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Order header: ID, table, time
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Order #${orderId.substring(0, 8)}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                        Text(
                          locationName,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _formatTime(createdAt),
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Items list
              ...items.map((item) {
                final itemMap = item as Map<String, dynamic>;
                final qty = itemMap['quantity'] as int? ?? 1;
                final name =
                    (itemMap['menu_items'] as Map<String, dynamic>?)?['name']
                        as String? ??
                    'Unknown';
                final modifiers =
                    itemMap['order_item_modifiers'] as List<dynamic>? ?? [];
                final instructions =
                    itemMap['special_instructions'] as String? ?? '';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '✕ $qty',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (modifiers.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 28),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: modifiers.map((mod) {
                              final modMap = mod as Map<String, dynamic>;
                              final modName =
                                  (modMap['modifiers']
                                          as Map<String, dynamic>?)?['name']
                                      as String? ??
                                  'Unknown';
                              return Text(
                                '• $modName',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      if (instructions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 28),
                          child: Text(
                            '📝 $instructions',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                );
              }),

              const SizedBox(height: 12),

              // Total + action button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    OrderService.formatPrice(totalAmount, currency: currency),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.primary,
                    ),
                  ),
                  if (nextStatus != null && onStatusChange != null)
                    FilledButton.tonal(
                      onPressed: () => onStatusChange!(orderId, nextStatus!),
                      child: Text(nextLabel!),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showOrderDetails(BuildContext context) {
    final items = order['order_items'] as List<dynamic>? ?? [];
    final orderId = order['id'] as String;

    showModalBottomSheet(
      context: context,
      builder: (_) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Order #${orderId.substring(0, 8)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              ...items.map((item) {
                final itemMap = item as Map<String, dynamic>;
                final qty = itemMap['quantity'] as int? ?? 1;
                final name =
                    (itemMap['menu_items'] as Map<String, dynamic>?)?['name']
                        as String? ??
                    'Unknown';
                final instructions =
                    itemMap['special_instructions'] as String? ?? '';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$qty × $name',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (instructions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Note: $instructions',
                            style: const TextStyle(
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
