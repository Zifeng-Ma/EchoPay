import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  runApp(
    const ProviderScope(
      child: EchoPayApp(),
    ),
  );
}

class EchoPayApp extends StatelessWidget {
  const EchoPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoPay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C4B4), // bunq-ish teal
          primary: const Color(0xFF00C4B4),
          secondary: const Color(0xFFFF5C5C), // bunq-ish red
          surface: Colors.white,
        ),
        textTheme: GoogleFonts.interTextTheme(),
      ),
      home: const MainEntryScreen(),
    );
  }
}

// --- Providers ---

final orderStatusProvider = StateProvider<String>((ref) => 'idle');
final cartProvider = StateProvider<List<MenuItem>>((ref) => []);

class MenuItem {
  final String id;
  final String name;
  final double price;
  final String image;

  MenuItem(this.id, this.name, this.price, this.image);
}

// --- Screens ---

class MainEntryScreen extends StatelessWidget {
  const MainEntryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.primary.withOpacity(0.8),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.record_voice_over, size: 80, color: Colors.white),
              const SizedBox(height: 24),
              Text(
                'EchoPay',
                style: GoogleFonts.lexend(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Voice-First Restaurant Agent',
                style: GoogleFonts.lexend(
                  fontSize: 18,
                  color: Colors.white.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 64),
              _EntryButton(
                label: 'Customer App',
                icon: Icons.restaurant,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CustomerAgentScreen()),
                ),
              ),
              const SizedBox(height: 16),
              _EntryButton(
                label: 'Restaurant Admin',
                icon: Icons.dashboard,
                isSecondary: true,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RestaurantAdminScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isSecondary;

  const _EntryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isSecondary = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 60,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: isSecondary ? Colors.black87 : Colors.white),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: isSecondary ? Colors.black87 : Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isSecondary ? Colors.white : Colors.black87,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
      ),
    );
  }
}

class CustomerAgentScreen extends ConsumerStatefulWidget {
  const CustomerAgentScreen({super.key});

  @override
  ConsumerState<CustomerAgentScreen> createState() => _CustomerAgentScreenState();
}

class _CustomerAgentScreenState extends ConsumerState<CustomerAgentScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  bool _isListening = false;
  String _agentText = "Welcome to Bella Napoli! 🍕\nHow can I help you today?";
  String _userTranscript = "";

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _simulateInteraction() async {
    setState(() {
      _isListening = true;
      _userTranscript = "I'd like a Margherita pizza and a Coke, please.";
    });

    await Future.delayed(const Duration(seconds: 3));

    setState(() {
      _isListening = false;
      _agentText = "Excellent choice! A Margherita pizza, a Coke, and I've added our famous Tiramisu as a recommendation. Anything else, or shall I place the order?";
      ref.read(cartProvider.notifier).state = [
        MenuItem('1', 'Margherita Pizza', 12.50, ''),
        MenuItem('2', 'Coca Cola', 3.50, ''),
        MenuItem('3', 'Tiramisu (Upsell)', 6.50, ''),
      ];
    });
  }

  void _showPaymentSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const BunqPaymentSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text('Bella Napoli Agent', style: GoogleFonts.lexend()),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: 150 + (20 * _pulseController.value),
                            height: 150 + (20 * _pulseController.value),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                            ),
                          );
                        },
                      ),
                      GestureDetector(
                        onLongPress: _simulateInteraction,
                        onLongPressUp: () {},
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isListening 
                              ? Theme.of(context).colorScheme.secondary 
                              : Theme.of(context).colorScheme.primary,
                            boxShadow: [
                              BoxShadow(
                                color: (_isListening ? Colors.red : Colors.teal).withOpacity(0.3),
                                blurRadius: 20,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                          child: Icon(
                            _isListening ? Icons.mic : Icons.record_voice_over,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 48),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          _agentText,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.lexend(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: Colors.black87,
                          ),
                        ),
                        if (_userTranscript.isNotEmpty) ...[
                          const Divider(height: 32),
                          Text(
                            "“$_userTranscript”",
                            style: GoogleFonts.lexend(
                              fontSize: 16,
                              fontStyle: FontStyle.italic,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (cart.isNotEmpty)
            _CartSummary(
              items: cart,
              onCheckout: _showPaymentSheet,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _agentText = "Welcome to Bella Napoli! 🍕\nHow can I help you today?";
            _userTranscript = "";
            ref.read(cartProvider.notifier).state = [];
          });
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

class _CartSummary extends StatelessWidget {
  final List<MenuItem> items;
  final VoidCallback onCheckout;

  const _CartSummary({required this.items, required this.onCheckout});

  @override
  Widget build(BuildContext context) {
    double total = items.fold(0, (sum, item) => sum + item.price);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 20,
            offset: Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Your Cart',
                  style: GoogleFonts.lexend(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${items.length} items',
                  style: GoogleFonts.lexend(color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(item.name, style: GoogleFonts.lexend(fontSize: 16)),
                      Text('€${item.price.toStringAsFixed(2)}',
                          style: GoogleFonts.lexend(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                )),
            const Divider(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total', style: GoogleFonts.lexend(fontSize: 24, fontWeight: FontWeight.bold)),
                Text(
                  '€${total.toStringAsFixed(2)}',
                  style: GoogleFonts.lexend(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton(
                onPressed: onCheckout,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('Confirm & Pay with bunq',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BunqPaymentSheet extends ConsumerStatefulWidget {
  const BunqPaymentSheet({super.key});

  @override
  ConsumerState<BunqPaymentSheet> createState() => _BunqPaymentSheetState();
}

class _BunqPaymentSheetState extends ConsumerState<BunqPaymentSheet> {
  bool _isProcessing = false;
  bool _isSuccess = false;

  void _pay() async {
    setState(() => _isProcessing = true);
    await Future.delayed(const Duration(seconds: 2));
    setState(() {
      _isProcessing = false;
      _isSuccess = true;
    });
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      Navigator.pop(context);
      ref.read(orderStatusProvider.notifier).state = 'paid';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    double total = cart.fold(0, (sum, item) => sum + item.price);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_isSuccess) ...[
            Image.network(
              'https://raw.githubusercontent.com/bunq/hackathon_toolkit/main/docs/bunq_logo.png',
              height: 40,
              errorBuilder: (_, __, ___) => const Text('bunq',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.blue)),
            ),
            const SizedBox(height: 24),
            Text(
              'Payment Request',
              style: GoogleFonts.lexend(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Bella Napoli is requesting €${total.toStringAsFixed(2)}',
              style: GoogleFonts.lexend(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            if (_isProcessing)
              const CircularProgressIndicator()
            else
              SizedBox(
                width: double.infinity,
                height: 64,
                child: ElevatedButton(
                  onPressed: _pay,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C4B4),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('Approve Payment',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
              ),
          ] else ...[
            const Icon(Icons.check_circle, size: 80, color: Color(0xFF00C4B4)),
            const SizedBox(height: 24),
            Text(
              'Payment Successful!',
              style: GoogleFonts.lexend(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Your order has been sent to the kitchen.',
              style: GoogleFonts.lexend(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class RestaurantAdminScreen extends ConsumerWidget {
  const RestaurantAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderStatus = ref.watch(orderStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Bella Napoli Admin', style: GoogleFonts.lexend()),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatCard(label: 'Total Orders', value: orderStatus == 'paid' ? '12' : '11'),
                const SizedBox(width: 16),
                _StatCard(label: 'Revenue', value: orderStatus == 'paid' ? '€284.50' : '€268.50'),
              ],
            ),
            const SizedBox(height: 32),
            Text('Live Orders', style: GoogleFonts.lexend(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  if (orderStatus == 'paid')
                    _OrderTile(
                      table: 'Table 4',
                      items: '1x Margherita Pizza, 1x Coke, 1x Tiramisu',
                      status: 'Paid',
                      time: 'Just now',
                      isNew: true,
                    ),
                  const _OrderTile(
                    table: 'Table 1',
                    items: '2x Lasagna, 1x Red Wine',
                    status: 'Preparing',
                    time: '5 mins ago',
                  ),
                  const _OrderTile(
                    table: 'Table 7',
                    items: '1x Tiramisu, 2x Espresso',
                    status: 'Ready',
                    time: '12 mins ago',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: GoogleFonts.lexend(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 8),
            Text(value, style: GoogleFonts.lexend(fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final String table;
  final String items;
  final String status;
  final String time;
  final bool isNew;

  const _OrderTile({
    required this.table,
    required this.items,
    required this.status,
    required this.time,
    this.isNew = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isNew ? Colors.teal.withOpacity(0.05) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: isNew ? Border.all(color: Colors.teal.withOpacity(0.3)) : null,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                table.split(' ')[1],
                style: GoogleFonts.lexend(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(table, style: GoogleFonts.lexend(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(time, style: GoogleFonts.lexend(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(items, style: GoogleFonts.lexend(fontSize: 14, color: Colors.black87)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getStatusColor(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: GoogleFonts.lexend(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _getStatusColor(status),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Paid': return Colors.teal;
      case 'Preparing': return Colors.orange;
      case 'Ready': return Colors.blue;
      default: return Colors.grey;
    }
  }
}
