// List view of the menu where managers edit prices and use a toggle to instantly update is_available status.

import 'package:flutter/material.dart';
import '../services/supabase.dart';

class MenuManagementTab extends StatefulWidget {
  final Map<String, dynamic> restaurant;

  const MenuManagementTab({super.key, required this.restaurant});

  @override
  State<MenuManagementTab> createState() => _MenuManagementTabState();
}

class _MenuManagementTabState extends State<MenuManagementTab> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;

  String get _restaurantId => widget.restaurant['id'] as String;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final items = await SupabaseService.getMenuItems(_restaurantId);
      setState(() => _items = items);
    } catch (e) {
      _showSnack('Failed to load menu: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // Groups items by category, preserving server order within each group.
  Map<String, List<Map<String, dynamic>>> get _grouped {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in _items) {
      final cat = (item['category'] as String?) ?? 'Uncategorized';
      map.putIfAbsent(cat, () => []).add(item);
    }
    return map;
  }

  Future<void> _toggleAvailable(Map<String, dynamic> item) async {
    final newValue = !(item['is_available'] as bool);
    try {
      await SupabaseService.updateMenuItem(
          item['id'] as String, {'is_available': newValue});
      await _load();
    } catch (e) {
      _showSnack('Failed to update availability: $e');
    }
  }

  Future<void> _editPrice(Map<String, dynamic> item) async {
    final controller = TextEditingController(
      text: ((item['price'] as int) / 100).toStringAsFixed(2),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Edit price — ${item['name']}'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Price',
            prefixText:
                '${(widget.restaurant['currency'] as String?) ?? 'EUR'} ',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final parsed = double.tryParse(controller.text.trim());
    if (parsed == null || parsed < 0) {
      _showSnack('Invalid price');
      return;
    }
    try {
      await SupabaseService.updateMenuItem(
          item['id'] as String, {'price': (parsed * 100).round()});
      await _load();
    } catch (e) {
      _showSnack('Failed to update price: $e');
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete item'),
        content: Text('Remove "${item['name']}" from the menu? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SupabaseService.deleteMenuItem(item['id'] as String);
      await _load();
    } catch (e) {
      _showSnack('Failed to delete item: $e');
    }
  }

  Future<void> _addItem() async {
    final nameCtrl = TextEditingController();
    final categoryCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add menu item'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name *'),
                textCapitalization: TextCapitalization.words,
                autofocus: true,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: categoryCtrl,
                decoration: const InputDecoration(labelText: 'Category *'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: priceCtrl,
                decoration: InputDecoration(
                  labelText: 'Price *',
                  prefixText:
                      '${(widget.restaurant['currency'] as String?) ?? 'EUR'} ',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                decoration:
                    const InputDecoration(labelText: 'Description (optional)'),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final name = nameCtrl.text.trim();
    final category = categoryCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim());

    if (name.isEmpty || category.isEmpty || price == null || price < 0) {
      _showSnack('Please fill in name, category, and a valid price.');
      return;
    }

    try {
      await SupabaseService.createMenuItem({
        'restaurant_id': _restaurantId,
        'name': name,
        'category': category,
        'price': (price * 100).round(),
        if (descCtrl.text.trim().isNotEmpty)
          'description': descCtrl.text.trim(),
        'is_available': true,
      });
      await _load();
    } catch (e) {
      _showSnack('Failed to add item: $e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatPrice(int cents) {
    final currency = (widget.restaurant['currency'] as String?) ?? 'EUR';
    return '$currency ${(cents / 100).toStringAsFixed(2)}';
  }

  Widget _buildItem(Map<String, dynamic> item) {
    final isAvailable = item['is_available'] as bool;
    final teal = Theme.of(context).colorScheme.primary;

    return ListTile(
      title: Text(
        item['name'] as String,
        style: TextStyle(
          color: isAvailable ? null : Colors.grey,
          decoration: isAvailable ? null : TextDecoration.lineThrough,
        ),
      ),
      subtitle: (item['description'] as String?)?.isNotEmpty == true
          ? Text(
              item['description'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Price chip — tap to edit
          GestureDetector(
            onTap: () => _editPrice(item),
            child: Chip(
              label: Text(
                _formatPrice(item['price'] as int),
                style: const TextStyle(fontSize: 13),
              ),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          Switch(
            value: isAvailable,
            onChanged: (_) => _toggleAvailable(item),
            activeThumbColor: teal,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: Colors.red,
            tooltip: 'Delete',
            onPressed: () => _deleteItem(item),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final grouped = _grouped;

    return Scaffold(
      body: _items.isEmpty
          ? const Center(
              child: Text(
                'No menu items yet.\nTap + to add one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            )
          : ListView(
              children: [
                for (final entry in grouped.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      entry.key.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  for (final item in entry.value) _buildItem(item),
                ],
                const SizedBox(height: 80), // space for FAB
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addItem,
        icon: const Icon(Icons.add),
        label: const Text('Add Item'),
      ),
    );
  }
}
