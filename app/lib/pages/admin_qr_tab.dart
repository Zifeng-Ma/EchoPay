import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';
import '../services/supabase.dart';

class QrLocationsTab extends StatefulWidget {
  final Map<String, dynamic> restaurant;

  const QrLocationsTab({super.key, required this.restaurant});

  @override
  State<QrLocationsTab> createState() => _QrLocationsTabState();
}

class _QrLocationsTabState extends State<QrLocationsTab> {
  List<Map<String, dynamic>> _locations = [];
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
      final list = await SupabaseService.getQrLocations(_restaurantId);
      setState(() => _locations = list);
    } catch (e) {
      _showSnack('Failed to load locations: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addLocation() async {
    final nameController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Location'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Location name (e.g. Table 1)',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
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
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final hash = const Uuid().v4();
    try {
      await SupabaseService.createQrLocation(
        restaurantId: _restaurantId,
        locationName: name,
        qrCodeHash: hash,
      );
      await _load();
    } catch (e) {
      _showSnack('Failed to create location: $e');
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> loc) async {
    final newValue = !(loc['is_active'] as bool);
    try {
      await SupabaseService.updateQrLocation(loc['id'] as String, {
        'is_active': newValue,
      });
      await _load();
    } catch (e) {
      _showSnack('Failed to update: $e');
    }
  }

  Future<void> _deleteLocation(Map<String, dynamic> loc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Location'),
        content: Text(
          'Delete "${loc['location_name']}"? This cannot be undone.',
        ),
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
      await SupabaseService.deleteQrLocation(loc['id'] as String);
      await _load();
    } catch (e) {
      _showSnack('Failed to delete: $e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildCard(Map<String, dynamic> loc) {
    final hash = loc['qr_code_hash'] as String;
    final name = loc['location_name'] as String;
    final isActive = loc['is_active'] as bool;
    final teal = Theme.of(context).colorScheme.primary;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  color: Colors.red,
                  onPressed: () => _deleteLocation(loc),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: QrImageView(
                data: hash,
                version: QrVersions.auto,
                size: 200,
                eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: teal),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isActive ? 'Active' : 'Inactive',
                  style: TextStyle(
                    color: isActive ? teal : Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Switch(
                  value: isActive,
                  onChanged: (_) => _toggleActive(loc),
                  activeThumbColor: teal,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      body: _locations.isEmpty
          ? const Center(
              child: Text(
                'No QR locations yet.\nTap + to add one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _locations.length,
              itemBuilder: (_, i) => _buildCard(_locations[i]),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addLocation,
        icon: const Icon(Icons.add),
        label: const Text('Add Location'),
      ),
    );
  }
}
