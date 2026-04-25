import 'package:flutter/material.dart';
import '../services/auth.dart';
import 'admin_analytics.dart';
import 'admin_menu_management.dart';
import 'admin_qr_tab.dart';
import 'admin_kds_tab.dart';
import 'landing.dart';

class AdminDashboardPage extends StatelessWidget {
  final Map<String, dynamic> restaurant;

  const AdminDashboardPage({super.key, required this.restaurant});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(restaurant['name'] as String),
          actions: [_SignOutButton()],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.qr_code), text: 'QR Codes'),
              Tab(icon: Icon(Icons.view_kanban), text: 'KDS'),
              Tab(icon: Icon(Icons.restaurant_menu), text: 'Menu'),
              Tab(icon: Icon(Icons.bar_chart), text: 'Analytics'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            QrLocationsTab(restaurant: restaurant),
            KdsTab(restaurant: restaurant),
            MenuManagementTab(restaurant: restaurant),
            AnalyticsTab(restaurant: restaurant),
          ],
        ),
      ),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.logout),
      tooltip: 'Sign Out',
      onPressed: () async {
        await AuthService().signOut();
        if (!context.mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LandingPage()),
          (_) => false,
        );
      },
    );
  }
}
