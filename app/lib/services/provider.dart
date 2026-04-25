// The central hub for Riverpod providers, exposing the state of the current
// user, restaurant context, cart, and active order globally.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _logger = Logger();

// =============================================================================
// MODELS
// =============================================================================

class RestaurantContext {
  final String restaurantId;
  final String name;
  final String agentName;
  final String qrLocationId;
  final String locationName;
  final Map<String, dynamic>? openingHours;
  final String currency;
  final String defaultLanguage;

  const RestaurantContext({
    required this.restaurantId,
    required this.name,
    required this.agentName,
    required this.qrLocationId,
    required this.locationName,
    this.openingHours,
    this.currency = 'EUR',
    this.defaultLanguage = 'en',
  });

  /// Builds from the joined row returned by [SupabaseService.resolveQrCode].
  factory RestaurantContext.fromQrData(Map<String, dynamic> data) {
    final r = data['restaurants'] as Map<String, dynamic>;
    return RestaurantContext(
      restaurantId: r['id'] as String,
      name: r['name'] as String,
      agentName: (r['agent_name'] as String?) ?? 'Echo',
      qrLocationId: data['id'] as String,
      locationName: data['location_name'] as String,
      openingHours: r['opening_hours'] as Map<String, dynamic>?,
      currency: (r['currency'] as String?) ?? 'EUR',
      defaultLanguage: (r['default_language'] as String?) ?? 'en',
    );
  }
}

class SelectedModifier {
  final String id;
  final String name;
  final int priceChange; // in cents

  const SelectedModifier({
    required this.id,
    required this.name,
    required this.priceChange,
  });
}

class CartItem {
  final String menuItemId;
  final String name;
  final int basePrice; // in cents
  final int quantity;
  final List<SelectedModifier> modifiers;
  final String? specialInstructions;

  const CartItem({
    required this.menuItemId,
    required this.name,
    required this.basePrice,
    required this.quantity,
    this.modifiers = const [],
    this.specialInstructions,
  });

  int get modifierTotal =>
      modifiers.fold(0, (sum, m) => sum + m.priceChange);

  int get unitPrice => basePrice + modifierTotal;

  int get lineTotal => unitPrice * quantity;

  CartItem copyWith({
    int? quantity,
    String? specialInstructions,
    List<SelectedModifier>? modifiers,
  }) =>
      CartItem(
        menuItemId: menuItemId,
        name: name,
        basePrice: basePrice,
        quantity: quantity ?? this.quantity,
        modifiers: modifiers ?? this.modifiers,
        specialInstructions: specialInstructions ?? this.specialInstructions,
      );
}

// =============================================================================
// AUTH PROVIDERS
// =============================================================================

/// Streams every auth state change (sign-in / sign-out / token refresh).
final authStateProvider = StreamProvider<AuthState>((ref) {
  return Supabase.instance.client.auth.onAuthStateChange;
});

/// The currently authenticated [User], or null when signed out.
final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider); // re-evaluate on every auth event
  return Supabase.instance.client.auth.currentUser;
});

// =============================================================================
// RESTAURANT PROVIDERS
// =============================================================================

/// Holds the restaurant + table context resolved from a QR scan.
/// Null until the user scans a valid QR code.
final restaurantContextProvider = StateProvider<RestaurantContext?>((ref) => null);

/// Flat list of raw menu-item rows (including nested modifier groups) for the
/// current restaurant. Populated by RestaurantService.fetchMenu().
final menuItemsProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

// =============================================================================
// CART PROVIDER
// =============================================================================

class CartNotifier extends StateNotifier<List<CartItem>> {
  CartNotifier() : super([]);

  /// Add an item. Merges with an existing entry when item id and modifiers match.
  void addItem(CartItem newItem) {
    final idx = state.indexWhere(
      (c) =>
          c.menuItemId == newItem.menuItemId &&
          _modifiersMatch(c.modifiers, newItem.modifiers),
    );
    if (idx >= 0) {
      final updated = List<CartItem>.from(state);
      updated[idx] =
          updated[idx].copyWith(quantity: updated[idx].quantity + newItem.quantity);
      state = updated;
    } else {
      state = [...state, newItem];
    }
    _logger.d('Cart: added ${newItem.name} ×${newItem.quantity}');
  }

  /// Decrement quantity by 1; removes the entry when quantity reaches 0.
  void removeOne(String menuItemId) {
    state = state
        .map((c) =>
            c.menuItemId == menuItemId ? c.copyWith(quantity: c.quantity - 1) : c)
        .where((c) => c.quantity > 0)
        .toList();
    _logger.d('Cart: decremented $menuItemId');
  }

  /// Remove every entry for [menuItemId] regardless of modifiers.
  void removeAll(String menuItemId) {
    state = state.where((c) => c.menuItemId != menuItemId).toList();
    _logger.d('Cart: removed all $menuItemId');
  }

  /// Replace the entire cart (used when the agent rewrites the order).
  void replaceCart(List<CartItem> items) {
    state = List<CartItem>.unmodifiable(items);
    _logger.d('Cart: replaced with ${items.length} items');
  }

  void clearCart() {
    state = [];
    _logger.d('Cart: cleared');
  }

  int get totalCents => state.fold(0, (sum, item) => sum + item.lineTotal);

  bool _modifiersMatch(List<SelectedModifier> a, List<SelectedModifier> b) {
    if (a.length != b.length) return false;
    final aIds = a.map((m) => m.id).toSet();
    return b.every((m) => aIds.contains(m.id));
  }
}

final cartProvider =
    StateNotifierProvider<CartNotifier, List<CartItem>>((ref) => CartNotifier());

// =============================================================================
// ORDER PROVIDERS
// =============================================================================

/// The Supabase UUID of the order currently in progress; null when idle.
final activeOrderIdProvider = StateProvider<String?>((ref) => null);

/// High-level order lifecycle state for the UI.
/// Values mirror the DB enum: 'idle' | 'draft' | 'pending_payment' |
/// 'confirmed' | 'in_progress' | 'ready_for_delivery' | 'completed' | 'cancelled'
final orderStatusProvider = StateProvider<String>((ref) => 'idle');

// =============================================================================
// AGENT PROVIDER
// =============================================================================

/// True while the agent is actively listening or processing a voice turn.
final agentListeningProvider = StateProvider<bool>((ref) => false);
