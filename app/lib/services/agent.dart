// Handles the voice interface: sends audio to the Python backend, parses the
// AI response, and applies cart-update intents returned by the agent.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import 'backend_config.dart';
import 'provider.dart';

final _logger = Logger();

// =============================================================================
// INTENT MODELS
// =============================================================================

enum AgentIntentAction {
  addItem,
  removeItem,
  updateQuantity,
  clearCart,
  checkout,
  unknown,
}

/// A single cart mutation emitted by the AI agent.
class AgentItemIntent {
  final AgentIntentAction action;
  final String? menuItemId;
  final String? name; // fallback when the backend has no UUID yet
  final int quantity;
  final List<SelectedModifier> modifiers;
  final String? specialInstructions;

  const AgentItemIntent({
    required this.action,
    this.menuItemId,
    this.name,
    this.quantity = 1,
    this.modifiers = const [],
    this.specialInstructions,
  });

  factory AgentItemIntent.fromJson(Map<String, dynamic> json) {
    final rawMods = (json['modifiers'] as List<dynamic>?) ?? [];
    return AgentItemIntent(
      action: _parseAction(json['action'] as String? ?? ''),
      menuItemId: json['menu_item_id'] as String?,
      name: json['name'] as String?,
      quantity: (json['quantity'] as int?) ?? 1,
      modifiers: rawMods
          .cast<Map<String, dynamic>>()
          .map(
            (m) => SelectedModifier(
              id: m['id'] as String,
              name: m['name'] as String,
              priceChange: (m['price_change'] as int?) ?? 0,
            ),
          )
          .toList(),
      specialInstructions: json['special_instructions'] as String?,
    );
  }

  static AgentIntentAction _parseAction(String raw) => switch (raw) {
    'add_item' => AgentIntentAction.addItem,
    'remove_item' => AgentIntentAction.removeItem,
    'update_quantity' => AgentIntentAction.updateQuantity,
    'clear_cart' => AgentIntentAction.clearCart,
    'checkout' => AgentIntentAction.checkout,
    _ => AgentIntentAction.unknown,
  };
}

/// Full response from the agent: a spoken message plus zero or more cart intents.
class AgentResponse {
  /// The text the agent wants to speak / display.
  final String message;

  /// Ordered list of cart mutations to apply.
  final List<AgentItemIntent> intents;

  /// When true, the agent is signalling that the customer is ready to pay.
  final bool triggerCheckout;

  const AgentResponse({
    required this.message,
    required this.intents,
    this.triggerCheckout = false,
  });

  factory AgentResponse.fromJson(Map<String, dynamic> json) {
    final rawIntents = (json['intents'] as List<dynamic>?) ?? [];
    return AgentResponse(
      message: (json['message'] as String?) ?? '',
      intents: rawIntents
          .cast<Map<String, dynamic>>()
          .map(AgentItemIntent.fromJson)
          .toList(),
      triggerCheckout: (json['trigger_checkout'] as bool?) ?? false,
    );
  }
}

// =============================================================================
// AGENT SERVICE
// =============================================================================

class AgentService {
  static String get _backendUrl => BackendConfig.baseUrl;

  // ---------------------------------------------------------------------------
  // Voice turn (primary path)
  // ---------------------------------------------------------------------------

  /// Sends raw WAV/PCM audio bytes to the backend.
  ///
  /// The backend runs speech-to-text, calls the LLM with the restaurant's menu
  /// context, and returns a structured [AgentResponse].
  ///
  /// [sessionId] should be stable across the full session (e.g. the order UUID
  /// or a random ID generated on QR scan) so the backend can maintain context.
  static Future<AgentResponse> sendAudio({
    required Uint8List audioBytes,
    required String restaurantId,
    required String sessionId,
    required List<Map<String, dynamic>> menuItems,
    String language = 'en',
  }) async {
    try {
      final request =
          http.MultipartRequest('POST', Uri.parse('$_backendUrl/agent/voice'))
            ..fields['restaurant_id'] = restaurantId
            ..fields['session_id'] = sessionId
            ..fields['language'] = language
            ..fields['menu_context'] = jsonEncode(menuItems)
            ..files.add(
              http.MultipartFile.fromBytes(
                'audio',
                audioBytes,
                filename: 'audio.wav',
              ),
            );

      final streamed = await request.send().timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw TimeoutException('Agent voice request timed out'),
      );

      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        throw Exception('Agent voice error ${streamed.statusCode}: $body');
      }

      final response = AgentResponse.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
      _logger.d(
        'AgentService: "${response.message}" '
        '(${response.intents.length} intents)',
      );
      return response;
    } on TimeoutException catch (e) {
      throw BackendConfig.connectionException(e);
    } on http.ClientException catch (e) {
      throw BackendConfig.connectionException(e);
    } catch (e) {
      _logger.e('AgentService.sendAudio: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Text turn (fallback / testing)
  // ---------------------------------------------------------------------------

  /// Sends a typed message to the agent — useful as a fallback when mic
  /// permissions are denied or for integration tests.
  static Future<AgentResponse> sendText({
    required String text,
    required String restaurantId,
    required String sessionId,
    required List<Map<String, dynamic>> menuItems,
    String language = 'en',
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_backendUrl/agent/text'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'text': text,
              'restaurant_id': restaurantId,
              'session_id': sessionId,
              'language': language,
              'menu_context': menuItems,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception(
          'Agent text error ${response.statusCode}: ${response.body}',
        );
      }

      return AgentResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } on TimeoutException catch (e) {
      throw BackendConfig.connectionException(e);
    } on http.ClientException catch (e) {
      throw BackendConfig.connectionException(e);
    } catch (e) {
      _logger.e('AgentService.sendText: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Intent Application
  // ---------------------------------------------------------------------------

  /// Applies [intents] to [cart], looking up item metadata from [menuItems].
  ///
  /// Call this immediately after receiving an [AgentResponse].
  /// The caller is responsible for handling [AgentIntentAction.checkout]
  /// (i.e. [AgentResponse.triggerCheckout]).
  static void applyIntents(
    CartNotifier cart,
    List<AgentItemIntent> intents,
    List<Map<String, dynamic>> menuItems,
  ) {
    for (final intent in intents) {
      switch (intent.action) {
        case AgentIntentAction.addItem:
          final item = _findMenuItem(menuItems, intent.menuItemId, intent.name);
          if (item == null) {
            _logger.w('AgentService: no menu item found for "${intent.name}"');
            continue;
          }
          cart.addItem(
            CartItem(
              menuItemId: item['id'] as String,
              name: item['name'] as String,
              basePrice: item['price'] as int,
              quantity: intent.quantity,
              modifiers: intent.modifiers,
              specialInstructions: intent.specialInstructions,
            ),
          );

        case AgentIntentAction.removeItem:
          if (intent.menuItemId != null) cart.removeAll(intent.menuItemId!);

        case AgentIntentAction.updateQuantity:
          if (intent.menuItemId == null) break;
          cart.removeAll(intent.menuItemId!);
          if (intent.quantity <= 0) break;
          final item = _findMenuItem(menuItems, intent.menuItemId, intent.name);
          if (item != null) {
            cart.addItem(
              CartItem(
                menuItemId: item['id'] as String,
                name: item['name'] as String,
                basePrice: item['price'] as int,
                quantity: intent.quantity,
                modifiers: intent.modifiers,
              ),
            );
          }

        case AgentIntentAction.clearCart:
          cart.clearCart();

        case AgentIntentAction.checkout:
        case AgentIntentAction.unknown:
          break; // handled via AgentResponse.triggerCheckout
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Map<String, dynamic>? _findMenuItem(
    List<Map<String, dynamic>> items,
    String? id,
    String? name,
  ) {
    if (id != null) {
      for (final item in items) {
        if (item['id'] == id) return item;
      }
    }
    if (name != null) {
      final lower = name.toLowerCase();
      for (final item in items) {
        if ((item['name'] as String).toLowerCase().contains(lower)) return item;
      }
    }
    return null;
  }
}
