import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/voice_order_result.dart';
import 'services/checkout_session_store.dart';
import 'services/voice_order_service.dart';

void main() {
  runApp(const ProviderScope(child: EchoPayApp()));
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
              const Icon(
                Icons.record_voice_over,
                size: 80,
                color: Colors.white,
              ),
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
                'Voice-To-Payment Assistant',
                style: GoogleFonts.lexend(
                  fontSize: 18,
                  color: Colors.white.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 64),
              _EntryButton(
                label: 'Merchant Checkout',
                icon: Icons.point_of_sale,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CustomerAgentScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _EntryButton(
                label: 'Ops Dashboard',
                icon: Icons.dashboard,
                isSecondary: true,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RestaurantAdminScreen(),
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
  ConsumerState<CustomerAgentScreen> createState() =>
      _CustomerAgentScreenState();
}

class _CustomerAgentScreenState extends ConsumerState<CustomerAgentScreen> {
  static const String _demoTranscript =
      'Customer says two cappuccinos and one croissant. Merchant confirms total is 11.50 euro. '
      'Customer says actually make that one cappuccino, total 8.50 euro.';

  final CheckoutSessionStore _sessionStore = CheckoutSessionStore();
  final VoiceOrderService _voiceOrderService = VoiceOrderService();
  final List<VoiceOrderResult> _history = [];
  final TextEditingController _transcriptController = TextEditingController();

  StreamSubscription<dynamic>? _amplitudeSubscription;
  bool _isListening = false;
  bool _isProcessing = false;
  bool _isRestoringSession = true;
  DateTime? _recordingStartedAt;
  double _inputLevel = 0;
  String _agentText =
      "Capture a spoken checkout and I will turn it into a bunq payment request draft.";
  String _userTranscript = "";
  VoiceOrderResult? _latestResult;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    _transcriptController.dispose();
    _voiceOrderService.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_isProcessing) {
      return;
    }

    if (_isListening) {
      await _stopListening();
      return;
    }

    try {
      await _voiceOrderService.startListening();
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = _voiceOrderService.amplitudeStream().listen((
        amplitude,
      ) {
        if (!mounted) {
          return;
        }

        final normalized = ((amplitude.current + 60) / 60).clamp(0.0, 1.0);
        setState(() {
          _inputLevel = normalized;
        });
      });
      setState(() {
        _isListening = true;
        _recordingStartedAt = DateTime.now();
        _inputLevel = 0;
        _agentText =
            'I am listening now. Let the merchant and customer speak, then tap again to stop.';
      });
      _persistSession();
    } catch (error) {
      setState(() {
        _agentText = 'I could not start the microphone. ${error.toString()}';
      });
      _persistSession();
    }
  }

  Future<void> _stopListening() async {
    final recordingStartedAt = _recordingStartedAt;
    final recordingDuration = recordingStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(recordingStartedAt);

    if (recordingDuration < const Duration(seconds: 2)) {
      setState(() {
        _isListening = false;
        _recordingStartedAt = null;
        _inputLevel = 0;
        _agentText =
            'Keep recording for at least 2 seconds so I can hear the checkout clearly.';
      });
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      await _voiceOrderService.cancelListening();
      _persistSession();
      return;
    }

    setState(() {
      _isListening = false;
      _isProcessing = true;
      _recordingStartedAt = null;
      _inputLevel = 0;
      _agentText = 'Turning speech into a payment request draft...';
    });
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    try {
      final result = await _voiceOrderService.stopListening(
        conversationContext: _buildConversationContext(),
      );

      setState(() {
        _isProcessing = false;
        _inputLevel = 0;
        _userTranscript = result.transcript;
        _latestResult = result;
        _history.add(result);
        _agentText = result.finalConfirmation;
      });
      _persistSession();
    } catch (error) {
      setState(() {
        _isProcessing = false;
        _inputLevel = 0;
        _agentText = 'I could not process that recording. ${error.toString()}';
      });
      _persistSession();
    }
  }

  Future<void> _analyzeTranscript(String transcript) async {
    final trimmed = transcript.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _agentText = 'Please enter or paste a transcript first.';
      });
      _persistSession();
      return;
    }

    setState(() {
      _isProcessing = true;
      _inputLevel = 0;
      _agentText = 'Analyzing transcript and building a payment draft...';
    });

    try {
      final result = await _voiceOrderService.analyzeTranscript(
        transcript: trimmed,
        conversationContext: _buildConversationContext(),
      );

      setState(() {
        _isProcessing = false;
        _userTranscript = result.transcript;
        _latestResult = result;
        _history.add(result);
        _agentText = result.finalConfirmation;
      });
      _persistSession();
    } catch (error) {
      setState(() {
        _isProcessing = false;
        _agentText = 'I could not analyze that transcript. ${error.toString()}';
      });
      _persistSession();
    }
  }

  Future<void> _restoreSession() async {
    final snapshot = await _sessionStore.load();
    if (!mounted) {
      return;
    }

    setState(() {
      _isRestoringSession = false;
      if (snapshot == null) {
        return;
      }

      _agentText = snapshot.agentText.isEmpty ? _agentText : snapshot.agentText;
      _userTranscript = snapshot.userTranscript;
      _history
        ..clear()
        ..addAll(snapshot.history);
      _latestResult = snapshot.latestResult;
    });
  }

  Future<void> _persistSession() async {
    await _sessionStore.save(
      CheckoutSessionSnapshot(
        agentText: _agentText,
        userTranscript: _userTranscript,
        history: List<VoiceOrderResult>.from(_history),
      ),
    );
  }

  Future<void> _resetSession() async {
    setState(() {
      _agentText =
          "Capture a spoken checkout and I will turn it into a bunq payment request draft.";
      _userTranscript = "";
      _latestResult = null;
      _history.clear();
      _recordingStartedAt = null;
      _isListening = false;
      _isProcessing = false;
      _inputLevel = 0;
    });
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _sessionStore.clear();
  }

  Future<void> _showTranscriptInputSheet() async {
    _transcriptController.text = _userTranscript;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paste Transcript',
                style: GoogleFonts.lexend(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _transcriptController,
                minLines: 4,
                maxLines: 7,
                decoration: const InputDecoration(
                  hintText:
                      'Example: Two cappuccinos and one croissant, total 11.50 euro.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        _transcriptController.text = _demoTranscript;
                      },
                      child: const Text('Use Sample'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _analyzeTranscript(_transcriptController.text);
                      },
                      child: const Text('Analyze'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPaymentSheet(VoiceOrderResult result) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => BunqPaymentSheet(result: result),
    );
  }

  String _buildConversationContext() {
    if (_history.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    final recentTurns = _history.length <= 4
        ? _history
        : _history.sublist(_history.length - 4);

    for (final turn in recentTurns) {
      buffer.writeln('Transcript: ${turn.transcript}');
      buffer.writeln('Summary: ${turn.shortSummary}');
      buffer.writeln('Confirmation: ${turn.finalConfirmation}');
      if (turn.paymentAmount.isNotEmpty) {
        buffer.writeln('Amount: ${turn.paymentAmount} ${turn.currency}');
      }
      if (turn.contradictions.isNotEmpty) {
        buffer.writeln('Contradictions: ${turn.contradictions.join(" | ")}');
      }
      if (turn.splitSummary.isNotEmpty) {
        buffer.writeln('Split: ${turn.splitSummary}');
      }
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text('EchoPay Checkout Agent', style: GoogleFonts.lexend()),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Paste transcript',
            onPressed: _showTranscriptInputSheet,
            icon: const Icon(Icons.keyboard_alt_outlined),
          ),
          IconButton(
            tooltip: 'Run sample',
            onPressed: () => _analyzeTranscript(_demoTranscript),
            icon: const Icon(Icons.bolt_outlined),
          ),
        ],
      ),
      body: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 32),
          if (_isRestoringSession)
            const Padding(
              padding: EdgeInsets.only(bottom: 20),
              child: LinearProgressIndicator(),
            ),
          if (_history.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5FBFA),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFD0ECE7)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.history, color: Color(0xFF00A697)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Session restored: ${_history.length} captured turn${_history.length == 1 ? '' : 's'}.',
                      style: GoogleFonts.lexend(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _resetSession,
                    child: const Text('New session'),
                  ),
                ],
              ),
            ),
          Stack(
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: _isListening ? 176 : 150,
                height: _isListening ? 176 : 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withOpacity(_isListening ? 0.18 : 0.10),
                ),
              ),
              InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggleListening,
                child: Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.primary,
                    boxShadow: [
                      BoxShadow(
                        color: (_isListening ? Colors.red : Colors.teal)
                            .withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: _isProcessing
                      ? const Padding(
                          padding: EdgeInsets.all(30),
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        )
                      : Icon(
                          _isListening ? Icons.stop : Icons.mic,
                          color: Colors.white,
                          size: 42,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _isListening
                ? 'Tap to stop listening'
                : 'Tap to start a payment capture session',
            style: GoogleFonts.lexend(fontSize: 14, color: Colors.grey[700]),
          ),
          if (_isListening) ...[
            const SizedBox(height: 14),
            _AudioMeter(level: _inputLevel),
            const SizedBox(height: 8),
            Text(
              _inputLevel > 0.12
                  ? 'Audio detected'
                  : 'Listening... speak closer to the mic',
              style: GoogleFonts.lexend(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _inputLevel > 0.12
                    ? const Color(0xFF00A697)
                    : Colors.grey[600],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _showTranscriptInputSheet,
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('Paste transcript'),
              ),
              OutlinedButton.icon(
                onPressed: () => _analyzeTranscript(_demoTranscript),
                icon: const Icon(Icons.play_arrow_outlined),
                label: const Text('Use sample flow'),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Container(
            width: double.infinity,
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
                if (_userTranscript.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Transcription',
                      style: GoogleFonts.lexend(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "“$_userTranscript”",
                    style: GoogleFonts.lexend(
                      fontSize: 16,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[700],
                    ),
                  ),
                  const Divider(height: 32),
                ],
                Text(
                  _agentText,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.lexend(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          if (_latestResult != null) ...[
            const SizedBox(height: 24),
            _VoiceOrderReview(result: _latestResult!),
            if ((_latestResult!.paymentReady &&
                    _latestResult!.hasPayableAmount) ||
                _latestResult!.splitPaymentRequests.any(
                  (request) => request.hasAmount,
                )) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: ElevatedButton.icon(
                  onPressed: () => _showPaymentSheet(_latestResult!),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C4B4),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  label: Text(
                    _latestResult!.hasSplitRequests
                        ? 'Create Split bunq Requests'
                        : 'Create bunq Payment Request',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 120),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _resetSession,
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

class _VoiceOrderReview extends StatelessWidget {
  const _VoiceOrderReview({required this.result});

  final VoiceOrderResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAF9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFD6ECE7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Payment Draft',
            style: GoogleFonts.lexend(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          if (result.paymentAmount.isNotEmpty) ...[
            _ReviewSection(
              title: 'Amount to request',
              child: Text(
                '${result.currency} ${result.paymentAmount}',
                style: GoogleFonts.lexend(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF00A697),
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (result.merchantName.isNotEmpty ||
              result.customerName.isNotEmpty) ...[
            _ReviewSection(
              title: 'Participants',
              child: Text(
                '${result.merchantName.isEmpty ? "Merchant" : result.merchantName}'
                ' -> ${result.customerName.isEmpty ? "Customer" : result.customerName}',
                style: GoogleFonts.lexend(fontSize: 15, color: Colors.black87),
              ),
            ),
            const SizedBox(height: 14),
          ],
          _ReviewSection(
            title: 'Short recap',
            child: Text(
              result.shortSummary,
              style: GoogleFonts.lexend(fontSize: 15, color: Colors.black87),
            ),
          ),
          if (result.orderItems.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Line items',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: result.orderItems
                    .map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 5),
                              child: Icon(
                                Icons.circle,
                                size: 8,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.notes.isEmpty
                                    ? item.displayName
                                    : '${item.displayName} (${item.notes})',
                                style: GoogleFonts.lexend(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          if (result.speakerTurns.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Speaker timeline',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: result.speakerTurns
                    .map(
                      (turn) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE1ECE9)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    turn.speakerLabel,
                                    style: GoogleFonts.lexend(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (turn.timeLabel.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      turn.timeLabel,
                                      style: GoogleFonts.lexend(
                                        fontSize: 12,
                                        color: Colors.black45,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                turn.text,
                                style: GoogleFonts.lexend(fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          if (result.speakerInsights.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Speaker roles and help signals',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: result.speakerInsights
                    .map(
                      (insight) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: insight.needsHelp
                                ? const Color(0xFFFFF7ED)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: insight.needsHelp
                                  ? const Color(0xFFF3D8B4)
                                  : const Color(0xFFE1ECE9),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${insight.label} • ${insight.role}',
                                style: GoogleFonts.lexend(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                insight.needsHelp
                                    ? 'Needs help: ${insight.helpReason}'
                                    : 'No help signal detected.',
                                style: GoogleFonts.lexend(
                                  fontSize: 13,
                                  color: insight.needsHelp
                                      ? const Color(0xFFAD6C1A)
                                      : Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          if (result.paymentReason.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Payment reason',
              child: Text(
                result.paymentReason,
                style: GoogleFonts.lexend(fontSize: 15, color: Colors.black87),
              ),
            ),
          ],
          if (result.splitRequested || result.hasSplitRequests) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Split payment draft',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (result.splitSummary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        result.splitSummary,
                        style: GoogleFonts.lexend(
                          fontSize: 15,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  if (result.splitPaymentRequests.isEmpty)
                    Text(
                      'A split was mentioned, but there is not enough detail yet to build per-person payment requests.',
                      style: GoogleFonts.lexend(
                        fontSize: 14,
                        color: Colors.black54,
                      ),
                    )
                  else
                    Column(
                      children: result.splitPaymentRequests
                          .map(
                            (split) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _SplitRequestCard(request: split),
                            ),
                          )
                          .toList(),
                    ),
                ],
              ),
            ),
          ],
          if (result.contradictions.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Contradictions found',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: result.contradictions
                    .map((finding) => _ContradictionChip(label: finding))
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 14),
          _ReviewSection(
            title: result.needsConfirmation
                ? 'Final confirmation needed'
                : 'Suggested confirmation',
            child: Text(
              result.finalConfirmation,
              style: GoogleFonts.lexend(fontSize: 15, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioMeter extends StatelessWidget {
  const _AudioMeter({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final bars = List.generate(9, (index) {
      final phase = (index + 1) / 9;
      final scaledLevel = math.max(0.08, level * (0.65 + (phase * 0.5)));
      final height = 10.0 + (scaledLevel * 44.0);

      return AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 10,
        height: height,
        decoration: BoxDecoration(
          color: level > 0.12
              ? const Color(0xFF00C4B4)
              : const Color(0xFFB9DCD8),
          borderRadius: BorderRadius.circular(999),
        ),
      );
    });

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF6FBFA),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD6ECE7)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final bar in bars) ...[bar, const SizedBox(width: 6)],
        ]..removeLast(),
      ),
    );
  }
}

class _ReviewSection extends StatelessWidget {
  const _ReviewSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.lexend(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _ContradictionChip extends StatelessWidget {
  const _ContradictionChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEFEA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.lexend(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: const Color(0xFFAD4C2D),
        ),
      ),
    );
  }
}

class _SplitRequestCard extends StatelessWidget {
  const _SplitRequestCard({required this.request});

  final SplitPaymentRequest request;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1ECE9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            request.displayName,
            style: GoogleFonts.lexend(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            request.hasAmount
                ? '${request.currency} ${request.amount}'
                : 'Amount still needs confirmation',
            style: GoogleFonts.lexend(
              fontSize: 13,
              color: request.hasAmount
                  ? const Color(0xFF00A697)
                  : const Color(0xFFAD6C1A),
            ),
          ),
          if (request.paymentReason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              request.paymentReason,
              style: GoogleFonts.lexend(fontSize: 13, color: Colors.black54),
            ),
          ],
          if (request.orderItems.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              request.orderItems
                  .map(
                    (item) => item.notes.isEmpty
                        ? item.displayName
                        : '${item.displayName} (${item.notes})',
                  )
                  .join(', '),
              style: GoogleFonts.lexend(fontSize: 13, color: Colors.black87),
            ),
          ],
        ],
      ),
    );
  }
}

class BunqPaymentSheet extends ConsumerStatefulWidget {
  const BunqPaymentSheet({super.key, required this.result});

  final VoiceOrderResult result;

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
    final total = widget.result.paymentAmountValue ?? 0;
    final hasSplitRequests = widget.result.hasSplitRequests;
    final merchantLabel = widget.result.merchantName.isEmpty
        ? 'Merchant'
        : widget.result.merchantName;
    final reasonLabel = widget.result.paymentReason.isEmpty
        ? 'Voice checkout'
        : widget.result.paymentReason;

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
              errorBuilder: (context, error, stackTrace) => const Text(
                'bunq',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              hasSplitRequests ? 'Split Payment Requests' : 'Payment Request',
              style: GoogleFonts.lexend(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasSplitRequests
                  ? '$merchantLabel is preparing ${widget.result.splitPaymentRequests.length} bunq payment requests.'
                  : '$merchantLabel is requesting ${widget.result.currency} ${total.toStringAsFixed(2)}',
              style: GoogleFonts.lexend(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 14),
            if (hasSplitRequests)
              ...widget.result.splitPaymentRequests.map(
                (split) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SplitRequestCard(request: split),
                ),
              )
            else if (widget.result.orderItems.isNotEmpty)
              ...widget.result.orderItems.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          item.displayName,
                          style: GoogleFonts.lexend(fontSize: 15),
                        ),
                      ),
                      if (item.notes.isNotEmpty)
                        Text(
                          item.notes,
                          style: GoogleFonts.lexend(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              hasSplitRequests
                  ? (widget.result.splitSummary.isEmpty
                        ? reasonLabel
                        : widget.result.splitSummary)
                  : reasonLabel,
              style: GoogleFonts.lexend(fontSize: 14, color: Colors.grey[700]),
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: Text(
                    hasSplitRequests
                        ? 'Approve Split Requests'
                        : 'Approve Payment',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ] else ...[
            const Icon(Icons.check_circle, size: 80, color: Color(0xFF00C4B4)),
            const SizedBox(height: 24),
            Text(
              'Payment Successful!',
              style: GoogleFonts.lexend(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The payment request draft has been approved and shared.',
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
        title: Text('EchoPay Ops Dashboard', style: GoogleFonts.lexend()),
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
                _StatCard(
                  label: 'Requests Today',
                  value: orderStatus == 'paid' ? '12' : '11',
                ),
                const SizedBox(width: 16),
                _StatCard(
                  label: 'Volume',
                  value: orderStatus == 'paid' ? 'EUR 284.50' : 'EUR 268.50',
                ),
              ],
            ),
            const SizedBox(height: 32),
            Text(
              'Recent Voice Requests',
              style: GoogleFonts.lexend(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [
                  if (orderStatus == 'paid')
                    _OrderTile(
                      table: 'Request 4',
                      items:
                          'Cafe purchase, EUR 11.50, approved from voice checkout',
                      status: 'Paid',
                      time: 'Just now',
                      isNew: true,
                    ),
                  const _OrderTile(
                    table: 'Request 1',
                    items:
                        'Market stall checkout, EUR 18.00, awaiting confirmation',
                    status: 'Preparing',
                    time: '5 mins ago',
                  ),
                  const _OrderTile(
                    table: 'Request 7',
                    items: 'Lunch tab, EUR 24.00, sent to customer',
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
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.lexend(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: GoogleFonts.lexend(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
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
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10),
        ],
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
                style: GoogleFonts.lexend(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
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
                    Text(
                      table,
                      style: GoogleFonts.lexend(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      time,
                      style: GoogleFonts.lexend(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  items,
                  style: GoogleFonts.lexend(
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
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
      case 'Paid':
        return Colors.teal;
      case 'Preparing':
        return Colors.orange;
      case 'Ready':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }
}
