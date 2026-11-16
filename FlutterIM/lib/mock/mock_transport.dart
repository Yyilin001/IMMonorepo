import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import '../core/models.dart';
import 'traffic_pattern.dart';
import 'group_members.dart';

const defaultMessageRate = 1 / 3;

/// Every message has its own port event and acknowledgment. A bounded credit
/// window protects the UI mailbox without collecting messages into batches.
class MockTransport {
  MockTransport({required this.onMessage, this.onError, this.onBurstEnd});
  final void Function(ChatMessage) onMessage;
  final void Function(String)? onError;
  final void Function()? onBurstEnd;
  (int, int, num)? _pendingBurst;
  void startBurst(int firstId, int count, num rate) {
    final command = (firstId, count, rate);
    if (_commands == null) {
      _pendingBurst = command;
    } else {
      _commands!.send(command);
    }
  }

  void stopBurst() {
    if (_pendingBurst != null) {
      _pendingBurst = null;
      onBurstEnd?.call();
    } else {
      _commands?.send('stopBurst');
    }
  }

  final ReceivePort _events = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  Isolate? _isolate;
  SendPort? _commands;
  bool _disposed = false;
  bool _running = false;
  num _rate = defaultMessageRate;
  int? _focus;
  TrafficPattern _pattern = TrafficPattern.hotspot;

  Future<void> initialize(int conversationCount) async {
    if (conversationCount < 1) {
      throw ArgumentError.value(conversationCount, 'conversationCount');
    }
    _events.listen((event) {
      if (_disposed) return;
      if (event is SendPort) {
        _commands = event;
        _configure();
        if (_pendingBurst != null) {
          _commands!.send(_pendingBurst);
          _pendingBurst = null;
        }
      } else if (event == 'burstEnd') {
        onBurstEnd?.call();
      } else if (event is ChatMessage) {
        onMessage(event);
        _commands?.send('ack');
      }
    });
    _errors.listen((error) => onError?.call(error.toString()));
    final worker = await Isolate.spawn(
      _produce,
      (_events.sendPort, conversationCount),
      onError: _errors.sendPort,
      errorsAreFatal: true,
      debugName: 'local-im-mock',
    );
    if (_disposed) {
      worker.kill(priority: Isolate.immediate);
    } else {
      _isolate = worker;
    }
  }

  void configure({
    required bool running,
    required num rate,
    int? focus,
    TrafficPattern pattern = TrafficPattern.hotspot,
  }) {
    if (!rate.isFinite || rate <= 0) throw ArgumentError.value(rate, 'rate');
    _running = running;
    _rate = rate;
    _focus = focus;
    _pattern = pattern;
    _configure();
  }

  void _configure() => _commands?.send((_running, _rate, _focus, _pattern));

  void dispose() {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _events.close();
    _errors.close();
  }
}

void _produce((SendPort, int) args) {
  final (output, count) = args;
  final input = ReceivePort();
  output.send(input.sendPort);
  final random = Random(42);
  final clock = Stopwatch()..start();
  const maxInFlight = 64;
  var running = false;
  var inFlight = 0;
  num rate = defaultMessageRate;
  int? focus;
  var pattern = TrafficPattern.hotspot;
  var sequence = 0;
  var knownCount = count;
  final poolEnd = count + firstContactPoolSize(count);
  // Introduce one sender early, then occasionally spend one normal message
  // on a first contact. Faster rates leave room for established conversations.
  var nextDue = 0.0;
  int nextBurstId = 0, burstEnd = 0;
  num burstRate = 0;
  bool inBurst() => nextBurstId < burstEnd;
  Timer? wakeup;

  void scheduleNext() {
    if ((!running && !inBurst()) || inFlight >= maxInFlight || wakeup != null) {
      return;
    }
    final waitUs = max(0.0, nextDue - clock.elapsedMicroseconds);
    // Native timers have millisecond resolution. This is only the source's
    // per-message production deadline, not a receive/publish merge window.
    wakeup = Timer(Duration(milliseconds: (waitUs / 1000).ceil()), () {
      wakeup = null;
      if ((!running && !inBurst()) || inFlight >= maxInFlight) return;
      final stress = inBurst();
      final emissionRate = stress ? burstRate : rate;
      final int id;
      if (stress) {
        id = nextBurstId++;
      } else if (knownCount < poolEnd &&
          (sequence == 0 || random.nextDouble() < min(.25, 1 / (8 * rate)))) {
        id = knownCount++;
      } else {
        id = pattern.nextConversation(random, knownCount, focus);
      }
      final number = sequence++;
      final sender = mockSenderId(id, number, count);
      inFlight++;
      output.send(
        number % 7 == 0
            ? ChatMessage.image(
                id: 'mock-$number',
                conversationId: id,
                senderId: sender,
                isMine: sender == null,
                timestamp: DateTime.now(),
                image: mockImages[(number ~/ 7) % mockImages.length],
              )
            : ChatMessage(
                id: 'mock-$number',
                conversationId: id,
                senderId: sender,
                isMine: sender == null,
                text: mockTexts[random.nextInt(mockTexts.length)],
                timestamp: DateTime.now(),
              ),
      );
      if (stress && !inBurst()) {
        output.send('burstEnd');
        nextDue = clock.elapsedMicroseconds + 1000000 / rate;
        scheduleNext();
        return;
      }
      final intervalUs = 1000000 / emissionRate;
      // Bound catch-up credit after slow consumption; do not accumulate an
      // unbounded amount of future work during a stall.
      nextDue = emissionRate < 1
          ? clock.elapsedMicroseconds + intervalUs
          : max(
              nextDue + intervalUs,
              clock.elapsedMicroseconds - maxInFlight * intervalUs,
            );
      scheduleNext();
    });
  }

  input.listen((command) {
    if (command == 'ack') {
      inFlight--;
    } else if (command is (int, int, num)) {
      nextBurstId = command.$1;
      burstEnd = nextBurstId + command.$2;
      burstRate = command.$3;
      nextDue = clock.elapsedMicroseconds.toDouble();
      wakeup?.cancel();
      wakeup = null;
    } else if (command == 'stopBurst' && inBurst()) {
      nextBurstId = burstEnd;
      output.send('burstEnd');
      wakeup?.cancel();
      wakeup = null;
      nextDue = clock.elapsedMicroseconds + 1000000 / rate;
    } else if (command is (bool, num, int?, TrafficPattern)) {
      final wasRunning = running;
      final previousRate = rate;
      (running, rate, focus, pattern) = command;
      if (inBurst()) return;
      wakeup?.cancel();
      wakeup = null;
      // Focus/mode changes preserve an existing deadline. A slow-rate start or
      // resume waits for a full interval and never catches up in a burst.
      if (!running || !wasRunning || previousRate != rate) {
        nextDue =
            clock.elapsedMicroseconds +
            (running && rate < 1 ? 1000000 / rate : 0.0);
      }
    }
    scheduleNext();
  });
}
