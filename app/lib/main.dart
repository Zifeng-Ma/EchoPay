import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'pages/landing.dart';
import 'services/supabase.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();
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
      home: const LandingPage(),
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
      ),
    );
  }
}
