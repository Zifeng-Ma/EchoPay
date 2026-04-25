import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models/voice_order_result.dart';
import 'services/voice_agent_tts_service.dart';
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

final tableOrdersProvider =
    StateNotifierProvider<TableOrdersNotifier, List<TableOrder>>(
      (ref) => TableOrdersNotifier(),
    );

class TableOrder {
  const TableOrder({
    required this.tableNumber,
    required this.status,
    required this.turnCount,
    required this.items,
    required this.summary,
    required this.userType,
    required this.requiresHuman,
    required this.handoffReason,
  });

  final int tableNumber;
  final String status;
  final int turnCount;
  final List<String> items;
  final String summary;
  final String userType;
  final bool requiresHuman;
  final String handoffReason;

  String get label => 'Table $tableNumber';

  TableOrder copyWith({
    String? status,
    int? turnCount,
    List<String>? items,
    String? summary,
    String? userType,
    bool? requiresHuman,
    String? handoffReason,
  }) {
    return TableOrder(
      tableNumber: tableNumber,
      status: status ?? this.status,
      turnCount: turnCount ?? this.turnCount,
      items: items ?? this.items,
      summary: summary ?? this.summary,
      userType: userType ?? this.userType,
      requiresHuman: requiresHuman ?? this.requiresHuman,
      handoffReason: handoffReason ?? this.handoffReason,
    );
  }
}

class TableOrdersNotifier extends StateNotifier<List<TableOrder>> {
  TableOrdersNotifier() : super(const []);

  int _nextTableNumber = 1;

  int startTable() {
    final tableNumber = _nextTableNumber++;
    state = [
      TableOrder(
        tableNumber: tableNumber,
        status: 'ordering',
        turnCount: 0,
        items: const [],
        summary: 'AI waiter is ready to take the order.',
        userType: 'unknown',
        requiresHuman: false,
        handoffReason: '',
      ),
      ...state,
    ];
    return tableNumber;
  }

  void updateFromResult(int tableNumber, VoiceOrderResult result) {
    final items = result.orderItems
        .map(
          (item) => item.notes.isEmpty
              ? item.displayName
              : '${item.displayName} (${item.notes})',
        )
        .toList();

    state = [
      for (final order in state)
        if (order.tableNumber == tableNumber)
          order.copyWith(
            status: result.needsHuman
                ? 'needs_human'
                : (result.isCompleted ? 'completed' : 'ordering'),
            turnCount: result.turnCount,
            items: items,
            summary: result.shortSummary.isEmpty
                ? result.agentResponse
                : result.shortSummary,
            userType: result.userType,
            requiresHuman: result.needsHuman,
            handoffReason: result.handoffReason,
          )
        else
          order,
    ];
  }
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
      'Hi, I would like one cappuccino and one croissant. Actually make it two cappuccinos. That is all.';

  final VoiceOrderService _voiceOrderService = VoiceOrderService();
  final VoiceAgentTtsService _ttsService = VoiceAgentTtsService();
  final List<VoiceOrderResult> _history = [];

  StreamSubscription<dynamic>? _amplitudeSubscription;
  bool _isListening = false;
  bool _isProcessing = false;
  bool _sessionClosed = false;
  DateTime? _recordingStartedAt;
  double _inputLevel = 0;
  int _turnCount = 0;
  int? _currentTableNumber;
  String _agentText =
      'Hi, welcome to EchoPay. What would you like to order today?';
  VoiceOrderResult? _latestResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startNewSession(announce: true);
    });
  }

  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    unawaited(_ttsService.dispose());
    _voiceOrderService.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_isProcessing || _currentTableNumber == null) {
      return;
    }

    if (_isListening) {
      await _stopListening();
      return;
    }

    if (_sessionClosed) {
      return;
    }

    try {
      await _ttsService.stop();
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
        _agentText = 'I am listening. Tell me your order when you are ready.';
      });
    } catch (error) {
      setState(() {
        _agentText = 'I could not start the microphone. ${error.toString()}';
      });
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
            'Keep speaking for at least 2 seconds so I can hear the order clearly.';
      });
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      await _voiceOrderService.cancelListening();
      return;
    }

    setState(() {
      _isListening = false;
      _isProcessing = true;
      _recordingStartedAt = null;
      _inputLevel = 0;
      _agentText = 'Let me think through that order...';
    });
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    try {
      final result = await _voiceOrderService.stopListening(
        conversationContext: _buildConversationContext(),
        turnCount: _turnCount + 1,
      );

      setState(() {
        _isProcessing = false;
        _inputLevel = 0;
        _latestResult = result;
        _history.add(result);
        _turnCount = result.turnCount;
        _sessionClosed = result.needsHuman || result.isCompleted;
        _agentText = _responseFor(result);
      });
      ref
          .read(tableOrdersProvider.notifier)
          .updateFromResult(_currentTableNumber!, result);
      unawaited(_ttsService.speak(_agentText));
    } catch (error) {
      setState(() {
        _isProcessing = false;
        _inputLevel = 0;
        _agentText = 'I could not process that recording. ${error.toString()}';
      });
    }
  }

  Future<void> _analyzeTranscript(String transcript) async {
    final trimmed = transcript.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _agentText = 'I still need an order before I can continue.';
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _inputLevel = 0;
      _agentText = 'Running a sample ordering turn...';
    });

    try {
      final result = await _voiceOrderService.analyzeTranscript(
        transcript: trimmed,
        conversationContext: _buildConversationContext(),
        turnCount: _turnCount + 1,
      );

      setState(() {
        _isProcessing = false;
        _latestResult = result;
        _history.add(result);
        _turnCount = result.turnCount;
        _sessionClosed = result.needsHuman || result.isCompleted;
        _agentText = _responseFor(result);
      });
      ref
          .read(tableOrdersProvider.notifier)
          .updateFromResult(_currentTableNumber!, result);
      unawaited(_ttsService.speak(_agentText));
    } catch (error) {
      setState(() {
        _isProcessing = false;
        _agentText = 'I could not analyze that transcript. ${error.toString()}';
      });
    }
  }

  Future<void> _startNewSession({bool announce = false}) async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _voiceOrderService.cancelListening();
    await _ttsService.stop();

    final tableNumber = ref.read(tableOrdersProvider.notifier).startTable();
    const greeting =
        'Hi, welcome to EchoPay. What would you like to order today?';

    setState(() {
      _currentTableNumber = tableNumber;
      _agentText = greeting;
      _history.clear();
      _latestResult = null;
      _turnCount = 0;
      _recordingStartedAt = null;
      _isListening = false;
      _isProcessing = false;
      _sessionClosed = false;
      _inputLevel = 0;
    });
    if (announce) {
      unawaited(_ttsService.speak(greeting));
    }
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
    final recentTurns = _history.length <= 6
        ? _history
        : _history.sublist(_history.length - 6);

    for (final turn in recentTurns) {
      buffer.writeln('Turn count: ${turn.turnCount}');
      buffer.writeln('AI reply: ${_responseFor(turn)}');
      buffer.writeln('Summary: ${turn.shortSummary}');
      buffer.writeln('Status: ${turn.sessionStatus}');
      if (turn.paymentAmount.isNotEmpty) {
        buffer.writeln('Amount: ${turn.paymentAmount} ${turn.currency}');
      }
      if (turn.orderItems.isNotEmpty) {
        buffer.writeln(
          'Items: ${turn.orderItems.map((item) => item.displayName).join(", ")}',
        );
      }
      if (turn.contradictions.isNotEmpty) {
        buffer.writeln('Contradictions: ${turn.contradictions.join(" | ")}');
      }
      if (turn.handoffReason.isNotEmpty) {
        buffer.writeln('Handoff reason: ${turn.handoffReason}');
      }
      if (turn.splitSummary.isNotEmpty) {
        buffer.writeln('Split: ${turn.splitSummary}');
      }
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  String _responseFor(VoiceOrderResult result) {
    if (result.agentResponse.trim().isNotEmpty) {
      return result.agentResponse.trim();
    }
    if (result.finalConfirmation.trim().isNotEmpty) {
      return result.finalConfirmation.trim();
    }
    return 'I am ready for the next part of your order.';
  }

  String _statusLabel() {
    if (_latestResult == null) {
      return 'ordering';
    }
    return _latestResult!.sessionStatus.replaceAll('_', ' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text('EchoPay AI Waiter', style: GoogleFonts.lexend()),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Run sample',
            onPressed: _sessionClosed
                ? null
                : () => _analyzeTranscript(_demoTranscript),
            icon: const Icon(Icons.bolt_outlined),
          ),
          IconButton(
            tooltip: 'New table',
            onPressed: _startNewSession,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          if (_currentTableNumber != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFD6ECE7)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9F9F7),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(
                        '$_currentTableNumber',
                        style: GoogleFonts.lexend(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF00A697),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Table $_currentTableNumber',
                          style: GoogleFonts.lexend(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Turns: $_turnCount • ${_latestResult?.userType ?? "unknown"} user • ${_statusLabel()}',
                          style: GoogleFonts.lexend(
                            fontSize: 13,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
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
                onTap: _sessionClosed ? null : _toggleListening,
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
            _sessionClosed
                ? (_latestResult?.needsHuman ?? false)
                      ? 'A real server has been called to the table'
                      : 'Order completed'
                : (_isListening
                      ? 'Tap to stop listening'
                      : 'Tap to speak to the AI waiter'),
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
                onPressed: _sessionClosed
                    ? null
                    : () => _analyzeTranscript(_demoTranscript),
                icon: const Icon(Icons.play_arrow_outlined),
                label: const Text('Demo turn'),
              ),
              OutlinedButton.icon(
                onPressed: _startNewSession,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('New table'),
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'AI waiter',
                    style: GoogleFonts.lexend(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
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
            if (_latestResult!.isCompleted &&
                ((_latestResult!.paymentReady &&
                        _latestResult!.hasPayableAmount) ||
                    _latestResult!.splitPaymentRequests.any(
                      (request) => request.hasAmount,
                    ))) ...[
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
        onPressed: _startNewSession,
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
            'Table Status',
            style: GoogleFonts.lexend(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _ReviewSection(
            title: 'Order state',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(
                  label: result.sessionStatus.replaceAll('_', ' '),
                  color: result.needsHuman
                      ? const Color(0xFFAD4C2D)
                      : (result.isCompleted
                            ? const Color(0xFF00A697)
                            : const Color(0xFF4A6CF7)),
                ),
                _StatusPill(
                  label: '${result.turnCount} turns',
                  color: const Color(0xFF56636A),
                ),
                _StatusPill(
                  label: '${result.userType} user',
                  color: result.userType == 'slow'
                      ? const Color(0xFFAD6C1A)
                      : const Color(0xFF00A697),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _ReviewSection(
            title: 'Current recap',
            child: Text(
              result.shortSummary.isEmpty
                  ? 'The AI waiter is still gathering the order.'
                  : result.shortSummary,
              style: GoogleFonts.lexend(fontSize: 15, color: Colors.black87),
            ),
          ),
          const SizedBox(height: 14),
          _ReviewSection(
            title: 'AI next action',
            child: Text(
              result.agentResponse.isEmpty
                  ? result.finalConfirmation
                  : result.agentResponse,
              style: GoogleFonts.lexend(fontSize: 15, color: Colors.black87),
            ),
          ),
          if (result.orderItems.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Items in progress',
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
          if (result.paymentAmount.isNotEmpty && result.isCompleted) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Request total',
              child: Text(
                '${result.currency} ${result.paymentAmount}',
                style: GoogleFonts.lexend(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF00A697),
                ),
              ),
            ),
          ],
          if (result.needsHuman) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Human handoff',
              child: Text(
                result.handoffReason.isEmpty
                    ? 'A real server is on the way to help complete the order.'
                    : result.handoffReason,
                style: GoogleFonts.lexend(
                  fontSize: 15,
                  color: const Color(0xFFAD4C2D),
                ),
              ),
            ),
          ],
          if (result.hesitationDetected || result.turnLimitReached) ...[
            const SizedBox(height: 14),
            _ReviewSection(
              title: 'Why the flow changed',
              child: Text(
                result.turnLimitReached
                    ? 'The conversation passed the six-turn limit, so a real server is stepping in.'
                    : 'The AI waiter detected uncertainty and switched to a real server for a smoother experience.',
                style: GoogleFonts.lexend(fontSize: 14, color: Colors.black54),
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
          if (result.contradictions.isNotEmpty && !result.needsHuman) ...[
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
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.lexend(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
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
    final orders = ref.watch(tableOrdersProvider);
    final humanOrders = orders.where((order) => order.requiresHuman).length;
    final completedOrders = orders
        .where((order) => order.status == 'completed')
        .length;

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
                _StatCard(label: 'Open Tables', value: '${orders.length}'),
                const SizedBox(width: 16),
                _StatCard(label: 'Need Human', value: '$humanOrders'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _StatCard(label: 'Completed', value: '$completedOrders'),
                const SizedBox(width: 16),
                _StatCard(
                  label: 'Ordering',
                  value:
                      '${orders.where((order) => order.status == 'ordering').length}',
                ),
              ],
            ),
            const SizedBox(height: 32),
            Text(
              'Incoming Tables',
              style: GoogleFonts.lexend(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: orders.isEmpty
                  ? Center(
                      child: Text(
                        'No active tables yet.',
                        style: GoogleFonts.lexend(
                          fontSize: 16,
                          color: Colors.black54,
                        ),
                      ),
                    )
                  : ListView(
                      children: orders
                          .map((order) => _OrderTile(order: order))
                          .toList(),
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
  const _OrderTile({required this.order});

  final TableOrder order;

  @override
  Widget build(BuildContext context) {
    final items = order.items.isEmpty
        ? 'Still taking the order'
        : order.items.join(', ');
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: order.requiresHuman ? const Color(0xFFFFF4EF) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: order.requiresHuman
            ? Border.all(color: const Color(0xFFF0C7B8))
            : null,
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
                '${order.tableNumber}',
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
                      order.label,
                      style: GoogleFonts.lexend(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${order.turnCount} turns',
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
                Text(
                  order.summary,
                  style: GoogleFonts.lexend(
                    fontSize: 13,
                    color: Colors.black54,
                  ),
                ),
                if (order.handoffReason.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    order.handoffReason,
                    style: GoogleFonts.lexend(
                      fontSize: 13,
                      color: const Color(0xFFAD4C2D),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _getStatusColor(order.status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    order.status.replaceAll('_', ' '),
                    style: GoogleFonts.lexend(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _getStatusColor(order.status),
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
      case 'completed':
        return Colors.teal;
      case 'needs_human':
        return const Color(0xFFAD4C2D);
      case 'ordering':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }
}
