import 'dart:math';

// Additional contacts start without any chat or history.
int firstContactPoolSize(int initialChats) => max(1, initialChats ~/ 10);

/// Changes only the recipient of each individual mock message.
enum TrafficPattern {
  hotspot,
  uniform;

  int nextConversation(Random random, int count, int? focus) {
    if (count < 1) throw ArgumentError.value(count, 'count');
    if (this == uniform) return random.nextInt(count);
    final chance = random.nextDouble();
    return chance < .10 && focus != null
        ? focus
        : chance < .30
        ? random.nextInt(min(100, count))
        : random.nextInt(count);
  }
}
