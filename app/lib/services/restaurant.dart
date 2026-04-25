// Logic to resolve QR codes into a RestaurantContext and fetch the associated
// menu/inventory from Supabase.

import 'package:logger/logger.dart';
import 'supabase.dart';
import 'provider.dart';

final _logger = Logger();

class RestaurantService {
  // ---------------------------------------------------------------------------
  // QR Resolution
  // ---------------------------------------------------------------------------

  /// Resolves a scanned QR hash into a [RestaurantContext].
  /// Returns null when the code is unknown or the location is inactive.
  static Future<RestaurantContext?> resolveQrCode(String qrHash) async {
    try {
      final data = await SupabaseService.resolveQrCode(qrHash);
      if (data == null) return null;
      return RestaurantContext.fromQrData(data);
    } catch (e) {
      _logger.e('RestaurantService.resolveQrCode: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Menu
  // ---------------------------------------------------------------------------

  /// Fetches all menu items for [restaurantId], each including nested modifier
  /// groups and their individual modifiers.
  static Future<List<Map<String, dynamic>>> fetchMenu(
      String restaurantId) async {
    try {
      return await SupabaseService.getMenuItems(restaurantId);
    } catch (e) {
      _logger.e('RestaurantService.fetchMenu: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Opening Hours
  // ---------------------------------------------------------------------------

  /// Returns true when the restaurant is currently open.
  ///
  /// [openingHours] format: `{"monday": "09:00-22:00", "tuesday": "09:00-22:00", ...}`
  /// Pass null to treat the restaurant as always open.
  static bool isOpen(Map<String, dynamic>? openingHours) {
    if (openingHours == null) return true;

    final now = DateTime.now();
    final dayKey = _weekdayKey(now.weekday);
    final hours = openingHours[dayKey] as String?;
    if (hours == null) return false; // closed that day

    final parts = hours.split('-');
    if (parts.length != 2) return false;

    final open = _parseTime(parts[0].trim(), now);
    final close = _parseTime(parts[1].trim(), now);
    return now.isAfter(open) && now.isBefore(close);
  }

  static String _weekdayKey(int weekday) => const {
        1: 'monday',
        2: 'tuesday',
        3: 'wednesday',
        4: 'thursday',
        5: 'friday',
        6: 'saturday',
        7: 'sunday',
      }[weekday]!;

  static DateTime _parseTime(String hhmm, DateTime ref) {
    final parts = hhmm.split(':');
    return DateTime(
        ref.year, ref.month, ref.day, int.parse(parts[0]), int.parse(parts[1]));
  }
}
