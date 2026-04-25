import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../model/voice_order_result.dart';
import '../services/agent.dart';
import '../services/auth.dart';
import '../services/order.dart';
import '../services/payment.dart';
import '../services/provider.dart';
import '../services/restaurant.dart';
import '../services/voice_agent_tts_service.dart';
import 'landing.dart';
import 'user_order.dart';

// ---------------------------------------------------------------------------
// Page-local providers  (scoped to this screen's lifecycle)
// ---------------------------------------------------------------------------

enum _Phase { idle, loading, active, checkoutConfirm, payment }

/// Voice button state machine:
///   idle → recording → processing → idle
enum _VoiceState { idle, recording, processing }

final _phaseProvider = StateProvider<_Phase>((ref) => _Phase.idle);
final _agentMessageProvider = StateProvider<String?>((ref) => null);
final _agentPendingConfirmationProvider = StateProvider<bool>((ref) => false);
final _voiceStateProvider = StateProvider<_VoiceState>(
  (ref) => _VoiceState.idle,
);
final _paymentStatusProvider = StateProvider<String>((ref) => '');
final _latestVoiceDraftProvider = StateProvider<VoiceOrderResult?>(
  (ref) => null,
);
final _conversationContextProvider = StateProvider<String>((ref) => '');
final _voiceTurnCountProvider = StateProvider<int>((ref) => 0);
final _voiceAgentTtsServiceProvider = Provider<VoiceAgentTtsService>((ref) {
  final service = VoiceAgentTtsService();
  ref.onDispose(service.dispose);
  return service;
});

String _newSessionId() => 'session_${DateTime.now().millisecondsSinceEpoch}';
final _sessionIdProvider = StateProvider<String>((ref) => _newSessionId());

bool voiceDraftBlocksCheckout(VoiceOrderResult? draft) {
  return draft?.needsHuman ?? false;
}

String voiceDraftCheckoutBlockMessage(VoiceOrderResult draft) {
  final reason = draft.handoffReason.trim();
  if (reason.isNotEmpty) {
    return reason;
  }

  final response = draft.agentResponse.trim();
  if (response.isNotEmpty) {
    return response;
  }

  return 'A team member needs to help with this order before checkout.';
}

String? voiceDraftDisplayMessage(VoiceOrderResult draft) {
  if (draft.needsHuman) {
    return voiceDraftCheckoutBlockMessage(draft);
  }

  final agentResponse = draft.agentResponse.trim();
  if (agentResponse.isNotEmpty) {
    return agentResponse;
  }

  final confirmation = draft.finalConfirmation.trim();
  if (confirmation.isNotEmpty) {
    return confirmation;
  }

  final summary = draft.shortSummary.trim();
  if (summary.isNotEmpty) {
    return summary;
  }

  return null;
}

// ---------------------------------------------------------------------------
// Root page
// ---------------------------------------------------------------------------

class UserHomePage extends ConsumerStatefulWidget {
  const UserHomePage({super.key});

  @override
  ConsumerState<UserHomePage> createState() => _UserHomePageState();
}

class _UserHomePageState extends ConsumerState<UserHomePage> {
  static const _silenceAutoStopDelay = Duration(seconds: 4);
  static const _amplitudeSampleInterval = Duration(milliseconds: 250);
  static const _speechAmplitudeThresholdDb = -45.0;

  late final AudioRecorder _recorder;
  late final TextEditingController _agentTextController;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _silenceTimer;
  bool _isStoppingRecording = false;

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecorder();
    _agentTextController = TextEditingController();
  }

  @override
  void dispose() {
    _cancelSilenceDetection();
    _recorder.dispose();
    _agentTextController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // QR scan → resolve restaurant + fetch menu
  // -------------------------------------------------------------------------
  Future<void> _onScanQr() async {
    final qrHash = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _QrScannerPage()));
    if (qrHash == null || qrHash.trim().isEmpty) return;

    ref.read(_phaseProvider.notifier).state = _Phase.loading;

    try {
      final ctx = await RestaurantService.resolveQrCode(qrHash.trim());
      if (ctx == null) {
        _showSnack('QR code not recognised.');
        ref.read(_phaseProvider.notifier).state = _Phase.idle;
        return;
      }

      ref.read(restaurantContextProvider.notifier).state = ctx;
      final items = await RestaurantService.fetchMenu(ctx.restaurantId);
      ref.read(menuItemsProvider.notifier).state = items;
      ref.read(_sessionIdProvider.notifier).state = _newSessionId();
      ref.read(_latestVoiceDraftProvider.notifier).state = null;
      ref.read(_conversationContextProvider.notifier).state = '';
      ref.read(_voiceTurnCountProvider.notifier).state = 0;
      ref.read(_agentPendingConfirmationProvider.notifier).state = false;
      ref.read(_phaseProvider.notifier).state = _Phase.active;
    } catch (e) {
      _showSnack('Failed to load menu: $e');
      ref.read(_phaseProvider.notifier).state = _Phase.idle;
    }
  }

  // -------------------------------------------------------------------------
  // Leave store → reset everything
  // -------------------------------------------------------------------------
  void _leaveStore() {
    _cancelSilenceDetection();
    ref.read(restaurantContextProvider.notifier).state = null;
    ref.read(menuItemsProvider.notifier).state = [];
    ref.read(cartProvider.notifier).clearCart();
    ref.read(_phaseProvider.notifier).state = _Phase.idle;
    ref.read(_agentMessageProvider.notifier).state = null;
    ref.read(_latestVoiceDraftProvider.notifier).state = null;
    ref.read(_conversationContextProvider.notifier).state = '';
    ref.read(_voiceTurnCountProvider.notifier).state = 0;
    ref.read(_agentPendingConfirmationProvider.notifier).state = false;
    ref.read(_voiceStateProvider.notifier).state = _VoiceState.idle;
    ref.read(orderStatusProvider.notifier).state = 'idle';
    ref.read(activeOrderIdProvider.notifier).state = null;
  }

  // -------------------------------------------------------------------------
  // Voice recording → Whisper transcription → agent
  // -------------------------------------------------------------------------

  /// Called when user taps the mic button.
  Future<void> _onMicTap() async {
    final vs = ref.read(_voiceStateProvider);
    if (vs == _VoiceState.idle) {
      await _startRecording();
    } else if (vs == _VoiceState.recording) {
      await _stopAndProcess();
    }
    // Ignore taps while processing
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _showSnack('Microphone permission denied.');
      return;
    }

    final supportsWav = await _recorder.isEncoderSupported(AudioEncoder.wav);
    final encoder = supportsWav ? AudioEncoder.wav : AudioEncoder.aacLc;
    final extension = supportsWav ? 'wav' : 'm4a';
    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/echopay_${DateTime.now().millisecondsSinceEpoch}.$extension';

    await _recorder.start(
      RecordConfig(
        encoder: encoder,
        sampleRate: 44100,
        bitRate: 128000,
        numChannels: 1,
      ),
      path: path,
    );

    _startSilenceDetection();
    ref.read(_voiceStateProvider.notifier).state = _VoiceState.recording;
  }

  Future<void> _stopAndProcess() async {
    if (_isStoppingRecording) return;
    _isStoppingRecording = true;
    _cancelSilenceDetection();

    final path = await _recorder.stop();
    if (path == null) {
      ref.read(_voiceStateProvider.notifier).state = _VoiceState.idle;
      _isStoppingRecording = false;
      _showSnack('Recording failed — no audio captured.');
      return;
    }

    ref.read(_voiceStateProvider.notifier).state = _VoiceState.processing;
    ref.read(_agentMessageProvider.notifier).state = null;

    try {
      final ctx = ref.read(restaurantContextProvider);
      if (ctx == null) return;

      final response = await AgentService.sendRecordingFile(
        recordingPath: path,
        restaurantId: ctx.restaurantId,
        qrLocationId: ctx.qrLocationId,
        sessionId: ref.read(_sessionIdProvider),
        menuItems: ref.read(menuItemsProvider),
        cartItems: ref.read(cartProvider),
        language: ctx.defaultLanguage,
        confirmAction: ref.read(_agentPendingConfirmationProvider),
      );
      await _handleAgentResponse(response);
    } catch (e) {
      _showSnack('Voice agent failed: $e');
    } finally {
      ref.read(_voiceStateProvider.notifier).state = _VoiceState.idle;
      _isStoppingRecording = false;
    }
  }

  void _startSilenceDetection() {
    _cancelSilenceDetection();
    _scheduleAutoStopAfterSilence();
    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(_amplitudeSampleInterval)
        .listen((amplitude) {
          if (amplitude.current > _speechAmplitudeThresholdDb) {
            _scheduleAutoStopAfterSilence();
          }
        });
  }

  void _scheduleAutoStopAfterSilence() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceAutoStopDelay, () {
      if (!mounted) return;
      if (ref.read(_voiceStateProvider) != _VoiceState.recording) return;
      unawaited(_stopAndProcess());
    });
  }

  void _cancelSilenceDetection() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
  }

  Future<void> _playAgentResponseAudio(AgentResponse response) async {
    if (response.agentAudioBase64.trim().isEmpty) {
      return;
    }

    try {
      await ref
          .read(_voiceAgentTtsServiceProvider)
          .playBase64(
            audioBase64: response.agentAudioBase64,
            contentType: response.agentAudioContentType,
          );
    } catch (_) {
      // The visible agent response is still shown when audio playback fails.
    }
  }

  Future<void> _onSendText() async {
    if (ref.read(_voiceStateProvider) == _VoiceState.processing) return;

    final text = _agentTextController.text.trim();
    if (text.isEmpty) return;

    _agentTextController.clear();
    ref.read(_voiceStateProvider.notifier).state = _VoiceState.processing;

    try {
      await _dispatchText(
        text,
        confirmAction: ref.read(_agentPendingConfirmationProvider),
      );
    } finally {
      ref.read(_voiceStateProvider.notifier).state = _VoiceState.idle;
    }
  }

  Future<void> _dispatchText(String text, {bool confirmAction = false}) async {
    final ctx = ref.read(restaurantContextProvider);
    if (ctx == null) return;

    try {
      final response = await AgentService.sendText(
        text: text,
        restaurantId: ctx.restaurantId,
        qrLocationId: ctx.qrLocationId,
        sessionId: ref.read(_sessionIdProvider),
        menuItems: ref.read(menuItemsProvider),
        cartItems: ref.read(cartProvider),
        language: ctx.defaultLanguage,
        confirmAction: confirmAction,
      );

      await _handleAgentResponse(response);
    } catch (e) {
      ref.read(_agentMessageProvider.notifier).state =
          'Sorry, I heard you but could not process that: $e';
    }
  }

  Future<void> _handleAgentResponse(AgentResponse response) async {
    if (response.message.trim().isNotEmpty) {
      ref.read(_agentMessageProvider.notifier).state = response.message;
    }
    await _playAgentResponseAudio(response);

    if (response.requiresConfirmation) {
      ref.read(_agentPendingConfirmationProvider.notifier).state = true;
      return;
    }

    ref.read(_agentPendingConfirmationProvider.notifier).state = false;

    if (response.intents.isNotEmpty) {
      AgentService.applyIntents(
        ref.read(cartProvider.notifier),
        response.intents,
        ref.read(menuItemsProvider),
      );
    }

    final actionStatus = response.actionResult?['status'] as String?;
    if (actionStatus == 'needs_bunq_connection') {
      _showSnack('Connect bunq before starting payment.');
      return;
    }
    if (actionStatus == 'needs_payment_destination') {
      _showSnack('This restaurant needs a bunq payment destination first.');
      return;
    }
    if (response.orderId != null && response.orderId!.isNotEmpty) {
      ref.read(activeOrderIdProvider.notifier).state = response.orderId;
    }
    if (response.paymentStatus == 'confirmed') {
      ref.read(cartProvider.notifier).clearCart();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const UserOrderPage()),
      );
      return;
    }
    if (response.paymentStatus == 'pending_payment') {
      ref.read(_phaseProvider.notifier).state = _Phase.payment;
      ref.read(_paymentStatusProvider.notifier).state =
          'Waiting for bunq approval…';
      return;
    }
    if (response.triggerCheckout && ref.read(cartProvider).isNotEmpty) {
      ref.read(_phaseProvider.notifier).state = _Phase.checkoutConfirm;
    }
  }

  // -------------------------------------------------------------------------
  // Checkout → submit order → payment
  // -------------------------------------------------------------------------
  void _enterCheckout() {
    final draft = ref.read(_latestVoiceDraftProvider);
    if (voiceDraftBlocksCheckout(draft)) {
      _showVoiceHandoff(draft!);
      return;
    }

    if (ref.read(cartProvider).isNotEmpty) {
      ref.read(_phaseProvider.notifier).state = _Phase.checkoutConfirm;
    }
  }

  void _showVoiceHandoff(VoiceOrderResult draft) {
    final message = voiceDraftCheckoutBlockMessage(draft);
    ref.read(_agentMessageProvider.notifier).state = message;
    ref.read(_phaseProvider.notifier).state = _Phase.active;
    _showSnack(message);
  }

  Future<void> _confirmAndPay() async {
    final ctx = ref.read(restaurantContextProvider);
    final cart = ref.read(cartProvider);
    if (ctx == null || cart.isEmpty) return;

    final draft = ref.read(_latestVoiceDraftProvider);
    if (voiceDraftBlocksCheckout(draft)) {
      _showVoiceHandoff(draft!);
      return;
    }

    ref.read(_phaseProvider.notifier).state = _Phase.payment;
    ref.read(_paymentStatusProvider.notifier).state = 'Submitting order…';

    try {
      final orderId = await OrderService.submitOrder(
        restaurantId: ctx.restaurantId,
        qrLocationId: ctx.qrLocationId,
        cartItems: cart,
      );
      ref.read(activeOrderIdProvider.notifier).state = orderId;

      final confirmed = await PaymentService.processPayment(
        orderId: orderId,
        amountCents: ref.read(cartProvider.notifier).totalCents,
        currency: ctx.currency,
        description: 'EchoPay – ${ctx.name}',
        onStatusUpdate: (s) =>
            ref.read(_paymentStatusProvider.notifier).state = switch (s) {
              'initiating' => 'Opening payment request…',
              'pending' => 'Waiting for bunq approval…',
              'confirmed' => 'Payment confirmed!',
              'cancelled' => 'Payment cancelled.',
              _ => s,
            },
      );

      if (!mounted) return;

      if (confirmed) {
        ref.read(cartProvider.notifier).clearCart();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const UserOrderPage()),
        );
      } else {
        _showSnack('Payment was cancelled.');
        ref.read(_phaseProvider.notifier).state = _Phase.active;
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack('Payment error: $e');
      ref.read(_phaseProvider.notifier).state = _Phase.active;
    }
  }

  Future<void> _logout() async {
    try {
      await AuthService().signOut();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const LandingPage()));
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(_phaseProvider);
    final ctx = ref.watch(restaurantContextProvider);
    final theme = Theme.of(context);
    final teal = theme.colorScheme.primary;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: phase == _Phase.idle
          ? AppBar(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              elevation: 0,
              actions: [
                IconButton(
                  icon: const Icon(Icons.logout),
                  tooltip: 'Log out',
                  onPressed: _logout,
                ),
              ],
            )
          : _buildAppBar(phase, ctx, theme, teal),
      body: _buildBody(phase, teal, theme),
      bottomNavigationBar: phase == _Phase.active
          ? _AgentComposer(
              controller: _agentTextController,
              onSend: _onSendText,
              onMicTap: _onMicTap,
              voiceState: ref.watch(_voiceStateProvider),
              teal: teal,
            )
          : null,
    );
  }

  AppBar _buildAppBar(
    _Phase phase,
    RestaurantContext? ctx,
    ThemeData theme,
    Color teal,
  ) {
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      elevation: 0,
      automaticallyImplyLeading: false,
      leading: phase == _Phase.active
          ? TextButton(
              onPressed: _leaveStore,
              child: Text(
                'Leave',
                style: TextStyle(
                  color: teal,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            )
          : null,
      title: ctx != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ctx.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  ctx.locationName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
                ),
              ],
            )
          : null,
      centerTitle: true,
      actions: [
        if (phase == _Phase.active || phase == _Phase.checkoutConfirm)
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined),
            tooltip: 'Order History',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const UserOrderPage())),
          ),
      ],
    );
  }

  Widget _buildBody(_Phase phase, Color teal, ThemeData theme) {
    return switch (phase) {
      _Phase.idle => _IdleView(onScan: _onScanQr, teal: teal, theme: theme),
      _Phase.loading => const _LoadingView(),
      _Phase.active => _ActiveView(onCheckoutTap: _enterCheckout),
      _Phase.checkoutConfirm => _CheckoutView(
        onConfirm: _confirmAndPay,
        onBack: () => ref.read(_phaseProvider.notifier).state = _Phase.active,
      ),
      _Phase.payment => _PaymentView(
        statusText: ref.watch(_paymentStatusProvider),
      ),
    };
  }
}

// ===========================================================================
// Idle view — centred QR scan button
// ===========================================================================

class _IdleView extends StatelessWidget {
  final VoidCallback onScan;
  final Color teal;
  final ThemeData theme;

  const _IdleView({
    required this.onScan,
    required this.teal,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: teal,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.mic_rounded, color: Colors.white, size: 40),
          ),
          const SizedBox(height: 20),
          Text(
            'EchoPay',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan the table QR code to start ordering',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey[500],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR Code'),
            style: FilledButton.styleFrom(
              backgroundColor: teal,
              minimumSize: const Size(200, 52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Loading view
// ===========================================================================

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading menu…'),
        ],
      ),
    );
  }
}

// ===========================================================================
// Active view — menu list + agent bubble + cart strip
// ===========================================================================

class _ActiveView extends ConsumerWidget {
  final VoidCallback onCheckoutTap;

  const _ActiveView({required this.onCheckoutTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menuItems = ref.watch(menuItemsProvider);
    final cart = ref.watch(cartProvider);
    final agentMsg = ref.watch(_agentMessageProvider);
    final teal = Theme.of(context).colorScheme.primary;

    // Group items by category
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final item in menuItems) {
      if (item['is_available'] == false) continue;
      final cat = (item['category'] as String?) ?? 'Other';
      grouped.putIfAbsent(cat, () => []).add(item);
    }

    final totalCents = ref.read(cartProvider.notifier).totalCents;
    final itemCount = cart.fold(0, (s, i) => s + i.quantity);

    final agentBubble = agentMsg == null
        ? null
        : _AgentBubble(
            message: agentMsg,
            onDismiss: () =>
                ref.read(_agentMessageProvider.notifier).state = null,
          );

    return Column(
      children: [
        Expanded(
          child: menuItems.isEmpty
              ? ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    ?agentBubble,
                    const SizedBox(height: 160),
                    const Center(child: Text('No menu items available.')),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: grouped.length + (agentBubble == null ? 0 : 1),
                  itemBuilder: (_, i) {
                    if (agentBubble != null && i == 0) return agentBubble;

                    final categoryIndex = agentBubble == null ? i : i - 1;
                    final category = grouped.keys.elementAt(categoryIndex);
                    final items = grouped[category]!;
                    return _CategorySection(category: category, items: items);
                  },
                ),
        ),

        if (itemCount > 0)
          _CartStrip(
            itemCount: itemCount,
            totalCents: totalCents,
            currency: ref.read(restaurantContextProvider)?.currency ?? 'EUR',
            teal: teal,
            onTap: onCheckoutTap,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Agent speech bubble
// ---------------------------------------------------------------------------

class _AgentBubble extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _AgentBubble({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final teal = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: teal.withAlpha(20),
        border: Border.all(color: teal.withAlpha(60)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.mic_rounded, size: 18, color: teal),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: const Color(0xFF1A1A2E),
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            child: Icon(Icons.close, size: 18, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Category section
// ---------------------------------------------------------------------------

class _CategorySection extends ConsumerWidget {
  final String category;
  final List<Map<String, dynamic>> items;

  const _CategorySection({required this.category, required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            category,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.grey[500],
              letterSpacing: 0.5,
            ),
          ),
        ),
        ...items.map((item) => _MenuItem(item: item)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Single menu item row with +/- controls
// ---------------------------------------------------------------------------

class _MenuItem extends ConsumerWidget {
  final Map<String, dynamic> item;

  const _MenuItem({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final itemId = item['id'] as String;
    final name = item['name'] as String;
    final price = item['price'] as int; // cents
    final desc = item['description'] as String?;
    final currency = ref.read(restaurantContextProvider)?.currency ?? 'EUR';

    final inCart = cart
        .where((c) => c.menuItemId == itemId)
        .fold(0, (s, c) => s + c.quantity);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                if (desc != null && desc.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      desc,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  OrderService.formatPrice(price, currency: currency),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          _QuantityControl(
            quantity: inCart,
            onAdd: () => ref
                .read(cartProvider.notifier)
                .addItem(
                  CartItem(
                    menuItemId: itemId,
                    name: name,
                    basePrice: price,
                    quantity: 1,
                  ),
                ),
            onRemove: () => ref.read(cartProvider.notifier).removeOne(itemId),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// +/- quantity control
// ---------------------------------------------------------------------------

class _QuantityControl extends StatelessWidget {
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _QuantityControl({
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final teal = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (quantity > 0) ...[
          _CircleBtn(
            icon: Icons.remove,
            onTap: onRemove,
            color: Colors.grey[300]!,
            iconColor: const Color(0xFF1A1A2E),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '$quantity',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ],
        _CircleBtn(
          icon: Icons.add,
          onTap: onAdd,
          color: teal,
          iconColor: Colors.white,
        ),
      ],
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final Color iconColor;

  const _CircleBtn({
    required this.icon,
    required this.onTap,
    required this.color,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: iconColor),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cart summary strip
// ---------------------------------------------------------------------------

class _CartStrip extends StatelessWidget {
  final int itemCount;
  final int totalCents;
  final String currency;
  final Color teal;
  final VoidCallback onTap;

  const _CartStrip({
    required this.itemCount,
    required this.totalCents,
    required this.currency,
    required this.teal,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: teal,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Text(
              '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            const Spacer(),
            Text(
              OrderService.formatPrice(totalCents, currency: currency),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Agent composer — bottom text input + mic button
// ===========================================================================

class _AgentComposer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onMicTap;
  final _VoiceState voiceState;
  final Color teal;

  const _AgentComposer({
    required this.controller,
    required this.onSend,
    required this.onMicTap,
    required this.voiceState,
    required this.teal,
  });

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final (color, icon) = switch (voiceState) {
      _VoiceState.idle => (teal, Icons.mic_rounded),
      _VoiceState.recording => (Colors.red, Icons.stop_circle_outlined),
      _VoiceState.processing => (Colors.grey, Icons.hourglass_top_rounded),
    };

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.only(left: 16, right: 6),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          onSubmitted: voiceState == _VoiceState.processing
                              ? null
                              : (_) => onSend(),
                          decoration: const InputDecoration(
                            hintText: 'Ask or order…',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send',
                        onPressed: voiceState == _VoiceState.processing
                            ? null
                            : onSend,
                        icon: Icon(
                          Icons.send_rounded,
                          color: voiceState == _VoiceState.processing
                              ? Colors.grey
                              : teal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Semantics(
                button: true,
                label: voiceState == _VoiceState.recording
                    ? 'Stop recording'
                    : voiceState == _VoiceState.processing
                    ? 'Processing'
                    : 'Start recording',
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: color.withAlpha(80),
                        blurRadius: 16,
                        spreadRadius: voiceState == _VoiceState.recording
                            ? 5
                            : 2,
                      ),
                    ],
                  ),
                  child: IconButton(
                    tooltip: voiceState == _VoiceState.recording
                        ? 'Stop and send'
                        : 'Speak',
                    onPressed: voiceState == _VoiceState.processing
                        ? null
                        : onMicTap,
                    icon: Icon(icon, color: Colors.white, size: 28),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Checkout confirm view — order receipt
// ===========================================================================

class _CheckoutView extends ConsumerWidget {
  final VoidCallback onConfirm;
  final VoidCallback onBack;

  const _CheckoutView({required this.onConfirm, required this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final ctx = ref.read(restaurantContextProvider);
    final currency = ctx?.currency ?? 'EUR';
    final teal = Theme.of(context).colorScheme.primary;
    final totalCents = cart.fold(0, (s, item) => s + item.lineTotal);

    return Column(
      children: [
        // Back header
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
                onPressed: onBack,
              ),
              const Text(
                'Your Order',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ),

        // Item list
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            itemCount: cart.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final item = cart[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          if (item.modifiers.isNotEmpty)
                            Text(
                              item.modifiers.map((m) => m.name).join(', '),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[500],
                              ),
                            ),
                          if (item.specialInstructions != null)
                            Text(
                              item.specialInstructions!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[500],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      '×${item.quantity}',
                      style: TextStyle(color: Colors.grey[500], fontSize: 14),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      OrderService.formatPrice(
                        item.lineTotal,
                        currency: currency,
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),

        // Total + confirm button
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey[200]!)),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    Text(
                      OrderService.formatPrice(totalCents, currency: currency),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: teal,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: cart.isEmpty ? null : onConfirm,
                  icon: const Icon(Icons.payment_rounded),
                  label: const Text(
                    'Confirm & Pay',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: teal,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Payment in-progress view
// ===========================================================================

class _PaymentView extends StatelessWidget {
  final String statusText;

  const _PaymentView({required this.statusText});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(
            statusText.isEmpty ? 'Processing payment…' : statusText,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Please approve in your bunq app.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// QR Scanner page
// ===========================================================================

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  late final MobileScannerController _controller;
  bool _detected = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_detected) return;
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || value.isEmpty) return;
    _detected = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(controller: _controller, onDetect: _onDetect),

          // Dimmed overlay with scan-frame cutout
          const _ScanOverlay(),

          // Top bar: close + torch
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  IconButton(
                    icon: Icon(
                      _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () {
                      _controller.toggleTorch();
                      setState(() => _torchOn = !_torchOn);
                    },
                  ),
                ],
              ),
            ),
          ),

          // Label
          const Align(
            alignment: Alignment(0, 0.55),
            child: Text(
              'Point at the table QR code',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a transparent cut-out square in the centre, dimming the rest.
class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OverlayPainter(
        frameSize: MediaQuery.sizeOf(context).width * 0.65,
        borderColor: Theme.of(context).colorScheme.primary,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final double frameSize;
  final Color borderColor;

  const _OverlayPainter({required this.frameSize, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final dimPaint = Paint()..color = Colors.black.withAlpha(140);
    final cx = size.width / 2;
    final cy = size.height / 2;
    final half = frameSize / 2;
    final frame = Rect.fromLTRB(cx - half, cy - half, cx + half, cy + half);

    // Dim everything outside the frame
    final full = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(full),
        Path()
          ..addRRect(RRect.fromRectAndRadius(frame, const Radius.circular(16))),
      ),
      dimPaint,
    );

    // Frame border
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(16)),
      borderPaint,
    );

    // Corner accents
    _drawCorners(canvas, frame, borderColor);
  }

  void _drawCorners(Canvas canvas, Rect r, Color color) {
    const len = 24.0;
    const rad = 16.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    // Top-left
    canvas.drawLine(
      Offset(r.left + rad, r.top),
      Offset(r.left + rad + len, r.top),
      p,
    );
    canvas.drawLine(
      Offset(r.left, r.top + rad),
      Offset(r.left, r.top + rad + len),
      p,
    );
    // Top-right
    canvas.drawLine(
      Offset(r.right - rad - len, r.top),
      Offset(r.right - rad, r.top),
      p,
    );
    canvas.drawLine(
      Offset(r.right, r.top + rad),
      Offset(r.right, r.top + rad + len),
      p,
    );
    // Bottom-left
    canvas.drawLine(
      Offset(r.left + rad, r.bottom),
      Offset(r.left + rad + len, r.bottom),
      p,
    );
    canvas.drawLine(
      Offset(r.left, r.bottom - rad - len),
      Offset(r.left, r.bottom - rad),
      p,
    );
    // Bottom-right
    canvas.drawLine(
      Offset(r.right - rad - len, r.bottom),
      Offset(r.right - rad, r.bottom),
      p,
    );
    canvas.drawLine(
      Offset(r.right, r.bottom - rad - len),
      Offset(r.right, r.bottom - rad),
      p,
    );
  }

  @override
  bool shouldRepaint(_OverlayPainter old) =>
      old.frameSize != frameSize || old.borderColor != borderColor;
}
