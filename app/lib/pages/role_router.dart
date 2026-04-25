import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase.dart';
import 'admin_dashboard.dart';
import 'user_home.dart';

/// Shown immediately after login. Checks whether the signed-in user is a
/// restaurant owner and routes accordingly. Replaces itself in the nav stack.
class RoleRouterPage extends StatefulWidget {
  const RoleRouterPage({super.key});

  @override
  State<RoleRouterPage> createState() => _RoleRouterPageState();
}

class _RoleRouterPageState extends State<RoleRouterPage> {
  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    Widget destination = const UserHomePage();

    if (userId != null) {
      try {
        final restaurant = await SupabaseService.getRestaurantByOwner(userId);
        if (restaurant != null) {
          destination = AdminDashboardPage(restaurant: restaurant);
        }
      } catch (e) {
        debugPrint('RoleRouter: getRestaurantByOwner failed: $e');
        // Fall back to customer view
      }
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => destination),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
