// Handles the voice interface: sends audio to the Python backend, parses the
// AI response, and applies cart-update intents returned by the agent.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  final bool requiresConfirmation;
  final String agentAudioBase64;
  final String agentAudioContentType;
  final Map<String, dynamic>? pendingAction;
  final Map<String, dynamic>? actionResult;
  final String? orderId;
  final String? paymentStatus;

  const AgentResponse({
    required this.message,
    required this.intents,
    this.triggerCheckout = false,
    this.requiresConfirmation = false,
    this.agentAudioBase64 = '',
    this.agentAudioContentType = 'audio/wav',
    this.pendingAction,
    this.actionResult,
    this.orderId,
    this.paymentStatus,
  });

  factory AgentResponse.fromJson(Map<String, dynamic> json) {
    final rawIntents =
        (json['cart_intents'] as List<dynamic>?) ??
        (json['intents'] as List<dynamic>?) ??
        [];
    return AgentResponse(
      message:
          (json['message'] as String?) ??
          (json['agent_response'] as String?) ??
          '',
      intents: rawIntents
          .cast<Map<String, dynamic>>()
          .map(AgentItemIntent.fromJson)
          .toList(),
      triggerCheckout: (json['trigger_checkout'] as bool?) ?? false,
      requiresConfirmation: (json['requires_confirmation'] as bool?) ?? false,
      agentAudioBase64: (json['agent_audio_base64'] as String?) ?? '',
      agentAudioContentType:
          (json['agent_audio_content_type'] as String?) ?? 'audio/wav',
      pendingAction: json['pending_action'] is Map<String, dynamic>
          ? json['pending_action'] as Map<String, dynamic>
          : null,
      actionResult: json['action_result'] is Map<String, dynamic>
          ? json['action_result'] as Map<String, dynamic>
          : null,
      orderId: json['order_id'] as String?,
      paymentStatus: json['payment_status'] as String?,
    );
  }
}

// =============================================================================
// AGENT SERVICE
// =============================================================================

class AgentService {
  static String get _backendUrl => BackendConfig.baseUrl;

  static Map<String, String> _jsonHeaders() {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static List<Map<String, dynamic>> cartContext(List<CartItem> cartItems) {
    return cartItems
        .map(
          (item) => {
            'menu_item_id': item.menuItemId,
            'name': item.name,
            'base_price': item.basePrice,
            'quantity': item.quantity,
            'line_total': item.lineTotal,
            'special_instructions': item.specialInstructions,
            'modifiers': item.modifiers
                .map(
                  (modifier) => {
                    'id': modifier.id,
                    'name': modifier.name,
                    'price_change': modifier.priceChange,
                  },
                )
                .toList(),
          },
        )
        .toList();
  }

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
    List<CartItem> cartItems = const [],
    String? qrLocationId,
    bool confirmAction = false,
    String language = 'en',
  }) async {
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      final request =
          http.MultipartRequest('POST', Uri.parse('$_backendUrl/agent/voice'))
            ..fields['restaurant_id'] = restaurantId
            ..fields['qr_location_id'] = qrLocationId ?? ''
            ..fields['session_id'] = sessionId
            ..fields['language'] = language
            ..fields['menu_context'] = jsonEncode(menuItems)
            ..fields['cart_context'] = jsonEncode(cartContext(cartItems))
            ..fields['confirm_action'] = '$confirmAction'
            ..files.add(
              http.MultipartFile.fromBytes(
                'audio',
                audioBytes,
                filename: 'audio.wav',
              ),
            );
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      final streamed = await request.send().timeout(
        const Duration(seconds: 50),
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

  static Future<AgentResponse> sendRecordingFile({
    required String recordingPath,
    required String restaurantId,
    required String sessionId,
    required List<Map<String, dynamic>> menuItems,
    List<CartItem> cartItems = const [],
    String? qrLocationId,
    bool confirmAction = false,
    String language = 'en',
  }) async {
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      final request =
          http.MultipartRequest('POST', Uri.parse('$_backendUrl/agent/voice'))
            ..fields['restaurant_id'] = restaurantId
            ..fields['qr_location_id'] = qrLocationId ?? ''
            ..fields['session_id'] = sessionId
            ..fields['language'] = language
            ..fields['menu_context'] = jsonEncode(menuItems)
            ..fields['cart_context'] = jsonEncode(cartContext(cartItems))
            ..fields['confirm_action'] = '$confirmAction'
            ..files.add(
              await http.MultipartFile.fromPath('audio', recordingPath),
            );
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      final streamed = await request.send().timeout(
        const Duration(seconds: 45),
        onTimeout: () =>
            throw TimeoutException('Agent voice request timed out'),
      );
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        throw Exception('Agent voice error ${streamed.statusCode}: $body');
      }
      return AgentResponse.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } on TimeoutException catch (e) {
      throw BackendConfig.connectionException(e);
    } on http.ClientException catch (e) {
      throw BackendConfig.connectionException(e);
    } catch (e) {
      _logger.e('AgentService.sendRecordingFile: $e');
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
    List<CartItem> cartItems = const [],
    String? qrLocationId,
    bool confirmAction = false,
    String language = 'en',
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_backendUrl/agent/turn'),
            headers: _jsonHeaders(),
            body: jsonEncode({
              'text': text,
              'restaurant_id': restaurantId,
              'qr_location_id': qrLocationId,
              'session_id': sessionId,
              'language': language,
              'menu_context': menuItems,
              'cart_context': cartContext(cartItems),
              'confirm_action': confirmAction,
            }),
          )
          .timeout(const Duration(seconds: 50));

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
