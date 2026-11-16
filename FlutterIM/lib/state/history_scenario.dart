import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/history.dart';
import '../mock/mock_history_repository.dart';
import 'resources.dart';

class HistoryScenarioState {
  const HistoryScenarioState({
    this.network = HistoryNetwork.normal,
    this.failNext = false,
  });
  final HistoryNetwork network;
  final bool failNext;
}

final historyScenarioProvider =
    NotifierProvider<HistoryScenarioNotifier, HistoryScenarioState>(
      HistoryScenarioNotifier.new,
    );

class HistoryScenarioNotifier extends Notifier<HistoryScenarioState> {
  @override
  HistoryScenarioState build() => const HistoryScenarioState();
  void setNetwork(HistoryNetwork mode) {
    final repository = ref.read(historyRepositoryProvider);
    if (repository is MockHistoryRepository) repository.network = mode;
    state = HistoryScenarioState(network: mode, failNext: state.failNext);
  }

  void failNextRequest() {
    final repository = ref.read(historyRepositoryProvider);
    if (repository is MockHistoryRepository) repository.failNext = true;
    state = HistoryScenarioState(network: state.network, failNext: true);
  }

  void consumeFailure() {
    if (state.failNext) state = HistoryScenarioState(network: state.network);
  }
}
