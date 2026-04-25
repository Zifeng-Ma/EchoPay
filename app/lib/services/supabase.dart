// Initializes the Supabase client and provides standardized CRUD methods for database interaction.
//
// Usage: call SupabaseService.initialize() from main() before runApp().

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:logger/logger.dart';

final _logger = Logger();

class SupabaseService {
  static SupabaseClient get _db => Supabase.instance.client;

  // -------------------------------------------------------------------------
  // Initialization
  // -------------------------------------------------------------------------

  /// Call once from main() before runApp().
  /// Reads credentials from the app/.env asset file.
  static Future<void> initialize() async {
    await dotenv.load(fileName: '.env');
    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );
  }

  // -------------------------------------------------------------------------
  // CUSTOMERS
  // -------------------------------------------------------------------------

  /// Returns the customer profile row, or null if it doesn't exist yet.
  static Future<Map<String, dynamic>?> getCustomerProfile(String userId) async {
    try {
      return await _db
          .from('customers')
          .select()
          .eq('id', userId)
          .maybeSingle();
    } catch (e) {
      _logger.e('getCustomerProfile: $e');
      rethrow;
    }
  }

  /// Creates or updates the customer row (safe to call on every sign-in).
  static Future<void> upsertCustomerProfile(Map<String, dynamic> data) async {
    try {
      await _db.from('customers').upsert({
        ...data,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      _logger.e('upsertCustomerProfile: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // RESTAURANTS
  // -------------------------------------------------------------------------

  /// Fetch a restaurant by its primary key.
  static Future<Map<String, dynamic>?> getRestaurant(
    String restaurantId,
  ) async {
    try {
      return await _db
          .from('restaurants')
          .select()
          .eq('id', restaurantId)
          .maybeSingle();
    } catch (e) {
      _logger.e('getRestaurant: $e');
      rethrow;
    }
  }

  /// Fetch the restaurant owned by the given auth user (for the admin flow).
  static Future<Map<String, dynamic>?> getRestaurantByOwner(
    String ownerId,
  ) async {
    try {
      return await _db
          .from('restaurants')
          .select()
          .eq('owner_id', ownerId)
          .maybeSingle();
    } catch (e) {
      _logger.e('getRestaurantByOwner: $e');
      rethrow;
    }
  }

  /// Update restaurant settings (agent_name, opening_hours, currency, etc.).
  static Future<void> updateRestaurant(
    String restaurantId,
    Map<String, dynamic> updates,
  ) async {
    try {
      await _db
          .from('restaurants')
          .update({...updates, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', restaurantId);
    } catch (e) {
      _logger.e('updateRestaurant: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // QR LOCATIONS
  // -------------------------------------------------------------------------

  /// Resolves a scanned QR hash to its table + restaurant context.
  /// Returns null when the hash is unknown or the location is inactive.
  static Future<Map<String, dynamic>?> resolveQrCode(String qrHash) async {
    try {
      return await _db
          .from('qr_locations')
          .select(
            'id, location_name, restaurant_id, '
            'restaurants(id, name, agent_name, opening_hours, default_language, currency)',
          )
          .eq('qr_code_hash', qrHash)
          .eq('is_active', true)
          .maybeSingle();
    } catch (e) {
      _logger.e('resolveQrCode: $e');
      rethrow;
    }
  }

  /// Returns all QR locations for [restaurantId], ordered by location_name.
  static Future<List<Map<String, dynamic>>> getQrLocations(
    String restaurantId,
  ) async {
    try {
      final data = await _db
          .from('qr_locations')
          .select('id, location_name, qr_code_hash, is_active')
          .eq('restaurant_id', restaurantId)
          .order('location_name');
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      _logger.e('getQrLocations: $e');
      rethrow;
    }
  }

  /// Inserts a new QR location. Returns the created row.
  static Future<Map<String, dynamic>> createQrLocation({
    required String restaurantId,
    required String locationName,
    required String qrCodeHash,
  }) async {
    try {
      return await _db
          .from('qr_locations')
          .insert({
            'restaurant_id': restaurantId,
            'location_name': locationName,
            'qr_code_hash': qrCodeHash,
            'is_active': true,
          })
          .select()
          .single();
    } catch (e) {
      _logger.e('createQrLocation: $e');
      rethrow;
    }
  }

  /// Toggles or sets any column on a QR location (is_active, location_name, etc.).
  static Future<void> updateQrLocation(
    String locationId,
    Map<String, dynamic> updates,
  ) async {
    try {
      await _db.from('qr_locations').update(updates).eq('id', locationId);
    } catch (e) {
      _logger.e('updateQrLocation: $e');
      rethrow;
    }
  }

  /// Permanently removes a QR location.
  static Future<void> deleteQrLocation(String locationId) async {
    try {
      await _db.from('qr_locations').delete().eq('id', locationId);
    } catch (e) {
      _logger.e('deleteQrLocation: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // MENU ITEMS
  // -------------------------------------------------------------------------

  /// Returns all menu items for a restaurant, including nested modifier groups
  /// and their individual modifiers. Ordered by category then name.
  static Future<List<Map<String, dynamic>>> getMenuItems(
    String restaurantId,
  ) async {
    try {
      final data = await _db
          .from('menu_items')
          .select('''
            id, name, description, name_translations, description_translations,
            category, price, inventory_count, dietary_tags, is_available,
            menu_item_modifiers(
              modifier_groups(id, name, modifiers(id, name, price_change))
            )
          ''')
          .eq('restaurant_id', restaurantId)
          .order('category')
          .order('name');
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      _logger.e('getMenuItems: $e');
      rethrow;
    }
  }

  /// Insert a new menu item. Returns the created row.
  static Future<Map<String, dynamic>> createMenuItem(
    Map<String, dynamic> item,
  ) async {
    try {
      return await _db.from('menu_items').insert(item).select().single();
    } catch (e) {
      _logger.e('createMenuItem: $e');
      rethrow;
    }
  }

  /// Patch an existing menu item (price, is_available, description, etc.).
  static Future<void> updateMenuItem(
    String itemId,
    Map<String, dynamic> updates,
  ) async {
    try {
      await _db
          .from('menu_items')
          .update({...updates, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', itemId);
    } catch (e) {
      _logger.e('updateMenuItem: $e');
      rethrow;
    }
  }

  /// Permanently remove a menu item.
  static Future<void> deleteMenuItem(String itemId) async {
    try {
      await _db.from('menu_items').delete().eq('id', itemId);
    } catch (e) {
      _logger.e('deleteMenuItem: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // ORDERS
  // -------------------------------------------------------------------------

  /// Create a new draft order (shopping-cart stage).
  static Future<Map<String, dynamic>> createOrder({
    required String restaurantId,
    String? customerId,
    String? qrLocationId,
    required int totalAmount,
  }) async {
    try {
      final orderData = <String, dynamic>{
        'restaurant_id': restaurantId,
        'order_status': 'draft',
        'total_amount': totalAmount,
      };
      if (customerId != null) {
        orderData['customer_id'] = customerId;
      }
      if (qrLocationId != null) {
        orderData['qr_location_id'] = qrLocationId;
      }

      return await _db.from('orders').insert(orderData).select().single();
    } catch (e) {
      _logger.e('createOrder: $e');
      rethrow;
    }
  }

  /// Patch order fields (status, total_amount, bunq_transaction_id, etc.).
  static Future<void> updateOrder(
    String orderId,
    Map<String, dynamic> updates,
  ) async {
    try {
      await _db
          .from('orders')
          .update({...updates, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', orderId);
    } catch (e) {
      _logger.e('updateOrder: $e');
      rethrow;
    }
  }

  /// Fetch a single order with full item and modifier detail.
  static Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      return await _db
          .from('orders')
          .select('''
            *,
            qr_locations(location_name),
            order_items(
              id, quantity, special_instructions, price_at_purchase,
              menu_items(id, name, price),
              order_item_modifiers(modifier_id, modifiers(id, name, price_change))
            )
          ''')
          .eq('id', orderId)
          .maybeSingle();
    } catch (e) {
      _logger.e('getOrder: $e');
      rethrow;
    }
  }

  /// Order history for the current customer (excludes drafts).
  static Future<List<Map<String, dynamic>>> getCustomerOrders(
    String customerId,
  ) async {
    try {
      final data = await _db
          .from('orders')
          .select('''
            id, order_status, total_amount, created_at,
            restaurants(name),
            order_items(
              id, quantity, price_at_purchase,
              menu_items(name)
            )
          ''')
          .eq('customer_id', customerId)
          .neq('order_status', 'draft')
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      _logger.e('getCustomerOrders: $e');
      rethrow;
    }
  }

  /// All active orders for a restaurant — used by the KDS dashboard.
  static Future<List<Map<String, dynamic>>> getRestaurantOrders(
    String restaurantId,
  ) async {
    try {
      final data = await _db
          .from('orders')
          .select('''
            id, order_status, total_amount, created_at,
            qr_locations(location_name),
            order_items(
              id, quantity, special_instructions,
              menu_items(name),
              order_item_modifiers(modifiers(name))
            )
          ''')
          .eq('restaurant_id', restaurantId)
          .inFilter('order_status', [
            'confirmed',
            'in_progress',
            'ready_for_delivery',
          ])
          .order('created_at');
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      _logger.e('getRestaurantOrders: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // ORDER ITEMS
  // -------------------------------------------------------------------------

  /// Add one line item to a draft order. Returns the created row.
  static Future<Map<String, dynamic>> addOrderItem({
    required String orderId,
    required String menuItemId,
    required int quantity,
    required int priceAtPurchase,
    String? specialInstructions,
  }) async {
    try {
      final itemData = <String, dynamic>{
        'order_id': orderId,
        'menu_item_id': menuItemId,
        'quantity': quantity,
        'price_at_purchase': priceAtPurchase,
      };
      if (specialInstructions != null) {
        itemData['special_instructions'] = specialInstructions;
      }

      return await _db.from('order_items').insert(itemData).select().single();
    } catch (e) {
      _logger.e('addOrderItem: $e');
      rethrow;
    }
  }

  /// Patch an order item (quantity, special_instructions).
  static Future<void> updateOrderItem(
    String orderItemId,
    Map<String, dynamic> updates,
  ) async {
    try {
      await _db.from('order_items').update(updates).eq('id', orderItemId);
    } catch (e) {
      _logger.e('updateOrderItem: $e');
      rethrow;
    }
  }

  /// Remove a line item from the order.
  static Future<void> removeOrderItem(String orderItemId) async {
    try {
      await _db.from('order_items').delete().eq('id', orderItemId);
    } catch (e) {
      _logger.e('removeOrderItem: $e');
      rethrow;
    }
  }

  /// Record which modifiers were selected for a given order item.
  static Future<void> addOrderItemModifiers(
    String orderItemId,
    List<String> modifierIds,
  ) async {
    try {
      await _db
          .from('order_item_modifiers')
          .insert(
            modifierIds
                .map((id) => {'order_item_id': orderItemId, 'modifier_id': id})
                .toList(),
          );
    } catch (e) {
      _logger.e('addOrderItemModifiers: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // ANALYTICS
  // -------------------------------------------------------------------------

  /// Completed orders within an optional date range, with item breakdown.
  /// Used by admin_analytics.dart to compute revenue, popular items, etc.
  static Future<List<Map<String, dynamic>>> getCompletedOrders(
    String restaurantId, {
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      var query = _db
          .from('orders')
          .select('''
            id, total_amount, created_at,
            order_items(
              quantity, price_at_purchase,
              menu_items(name, category)
            )
          ''')
          .eq('restaurant_id', restaurantId)
          .eq('order_status', 'completed');

      if (from != null) query = query.gte('created_at', from.toIso8601String());
      if (to != null) query = query.lte('created_at', to.toIso8601String());

      final data = await query.order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      _logger.e('getCompletedOrders: $e');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // REAL-TIME
  // -------------------------------------------------------------------------

  /// Subscribe to status changes on a single order (customer-facing progress).
  /// Caller must call `.unsubscribe()` on the returned channel when done.
  static RealtimeChannel subscribeToOrder(
    String orderId,
    void Function(Map<String, dynamic> record) onUpdate,
  ) {
    return _db
        .channel('order:$orderId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: orderId,
          ),
          callback: (payload) => onUpdate(payload.newRecord),
        )
        .subscribe();
  }

  /// Subscribe to all order mutations for a restaurant (KDS live feed).
  /// Caller must call `.unsubscribe()` on the returned channel when done.
  static RealtimeChannel subscribeToRestaurantOrders(
    String restaurantId,
    void Function(Map<String, dynamic> record) onUpdate,
  ) {
    return _db
        .channel('restaurant_orders:$restaurantId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'restaurant_id',
            value: restaurantId,
          ),
          callback: (payload) => onUpdate(payload.newRecord),
        )
        .subscribe();
  }
}
