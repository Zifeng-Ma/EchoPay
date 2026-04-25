// Visualizes sales data, peak ordering hours, and popular menu items for the restaurant owner.

import 'package:flutter/material.dart';
import '../services/supabase.dart';
import '../services/order.dart';

enum _DateRange { week, month, all }

class AnalyticsTab extends StatefulWidget {
  final Map<String, dynamic> restaurant;

  const AnalyticsTab({super.key, required this.restaurant});

  @override
  State<AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<AnalyticsTab> {
  List<Map<String, dynamic>> _orders = [];
  bool _isLoading = true;
  _DateRange _range = _DateRange.week;

  String get _restaurantId => widget.restaurant['id'] as String;
  String get _currency =>
      (widget.restaurant['currency'] as String?) ?? 'EUR';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final from = switch (_range) {
        _DateRange.week => now.subtract(const Duration(days: 7)),
        _DateRange.month => now.subtract(const Duration(days: 30)),
        _DateRange.all => null,
      };
      final orders = await SupabaseService.getCompletedOrders(
        _restaurantId,
        from: from,
      );
      setState(() => _orders = orders);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to load analytics: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Derived statistics
  // ---------------------------------------------------------------------------

  int get _totalRevenue =>
      _orders.fold(0, (sum, o) => sum + (o['total_amount'] as int));

  int get _orderCount => _orders.length;

  int get _avgOrderValue =>
      _orderCount == 0 ? 0 : (_totalRevenue / _orderCount).round();

  /// Number of completed orders that were confirmed via bunq.
  int get _bunqPaymentCount => _orders
      .where((o) =>
          (o['bunq_transaction_id'] as String?) != null &&
          (o['bunq_transaction_id'] as String).isNotEmpty)
      .length;

  /// Orders per hour-of-day (0–23).
  List<int> get _hourlyVolume {
    final counts = List<int>.filled(24, 0);
    for (final o in _orders) {
      final ts = DateTime.parse(o['created_at'] as String).toLocal();
      counts[ts.hour]++;
    }
    return counts;
  }

  /// Top menu items by total quantity sold, sorted descending.
  List<MapEntry<String, int>> get _topItems {
    final totals = <String, int>{};
    for (final o in _orders) {
      final items = o['order_items'] as List<dynamic>? ?? [];
      for (final item in items) {
        final name =
            (item['menu_items'] as Map<String, dynamic>?)?['name'] as String? ??
                'Unknown';
        final qty = (item['quantity'] as int?) ?? 1;
        totals[name] = (totals[name] ?? 0) + qty;
      }
    }
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(8).toList();
  }

  /// Revenue by category, sorted descending.
  List<MapEntry<String, int>> get _revenueByCategory {
    final totals = <String, int>{};
    for (final o in _orders) {
      final items = o['order_items'] as List<dynamic>? ?? [];
      for (final item in items) {
        final cat =
            (item['menu_items'] as Map<String, dynamic>?)?['category']
                as String? ??
                'Uncategorized';
        final revenue =
            ((item['price_at_purchase'] as int?) ?? 0) *
            ((item['quantity'] as int?) ?? 1);
        totals[cat] = (totals[cat] ?? 0) + revenue;
      }
    }
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          _RangeSelector(
            selected: _range,
            onChanged: (r) {
              setState(() => _range = r);
              _load();
            },
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _orders.isEmpty
                    ? Center(
                        child: Text(
                          'No completed orders in this period.',
                          style: TextStyle(
                              color: colorScheme.onSurfaceVariant, fontSize: 16),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        children: [
                          _SummaryRow(
                            totalRevenue: _totalRevenue,
                            orderCount: _orderCount,
                            avgOrderValue: _avgOrderValue,
                            currency: _currency,
                            bunqPaymentCount: _bunqPaymentCount,
                          ),
                          const SizedBox(height: 20),
                          _SectionHeader('Peak Ordering Hours'),
                          const SizedBox(height: 8),
                          _HourlyChart(hourly: _hourlyVolume),
                          const SizedBox(height: 20),
                          _SectionHeader('Top Items by Quantity'),
                          const SizedBox(height: 8),
                          _BarList(
                            entries: _topItems,
                            formatLabel: (v) => '$v sold',
                          ),
                          const SizedBox(height: 20),
                          _SectionHeader('Revenue by Category'),
                          const SizedBox(height: 8),
                          _BarList(
                            entries: _revenueByCategory,
                            formatLabel: (v) =>
                                OrderService.formatPrice(v, currency: _currency),
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _RangeSelector extends StatelessWidget {
  final _DateRange selected;
  final ValueChanged<_DateRange> onChanged;

  const _RangeSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SegmentedButton<_DateRange>(
        segments: const [
          ButtonSegment(value: _DateRange.week, label: Text('7 Days')),
          ButtonSegment(value: _DateRange.month, label: Text('30 Days')),
          ButtonSegment(value: _DateRange.all, label: Text('All Time')),
        ],
        selected: {selected},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final int totalRevenue;
  final int orderCount;
  final int avgOrderValue;
  final String currency;
  final int bunqPaymentCount;

  const _SummaryRow({
    required this.totalRevenue,
    required this.orderCount,
    required this.avgOrderValue,
    required this.currency,
    required this.bunqPaymentCount,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Revenue',
                value: OrderService.formatPrice(totalRevenue, currency: currency),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(label: 'Orders', value: '$orderCount'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Avg Order',
                value: OrderService.formatPrice(avgOrderValue, currency: currency),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: 'Paid via bunq',
                value: '$bunqPaymentCount',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: cs.onPrimaryContainer)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: cs.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// Compact 24-bar chart showing order volume by hour.
class _HourlyChart extends StatelessWidget {
  final List<int> hourly;

  const _HourlyChart({required this.hourly});

  @override
  Widget build(BuildContext context) {
    final maxVal = hourly.reduce((a, b) => a > b ? a : b);
    final color = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: 80,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(24, (h) {
          final frac = maxVal == 0 ? 0.0 : hourly[h] / maxVal;
          final isLabelHour = h % 6 == 0;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: frac == 0 ? 0.02 : frac,
                        child: Container(
                          decoration: BoxDecoration(
                            color: frac > 0.6
                                ? color
                                : color.withAlpha((frac * 255 * 1.5).clamp(60, 255).toInt()),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(2)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isLabelHour ? '$h' : '',
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Horizontal bar list for top items or categories.
class _BarList extends StatelessWidget {
  final List<MapEntry<String, int>> entries;
  final String Function(int) formatLabel;

  const _BarList({required this.entries, required this.formatLabel});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Text('No data.',
          style: TextStyle(color: Colors.grey, fontSize: 14));
    }
    final maxVal = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final color = Theme.of(context).colorScheme.primary;

    return Column(
      children: entries.map((entry) {
        final frac = maxVal == 0 ? 0.0 : entry.value / maxVal;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      entry.key,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    formatLabel(entry.value),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 8,
                  backgroundColor: color.withAlpha(40),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
