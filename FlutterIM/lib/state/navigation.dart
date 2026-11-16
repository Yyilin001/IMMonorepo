import 'package:flutter_riverpod/flutter_riverpod.dart';

enum WorkspaceSection { messages, contacts, me }

final workspaceSectionProvider =
    NotifierProvider<WorkspaceSectionNotifier, WorkspaceSection>(
      WorkspaceSectionNotifier.new,
    );

class WorkspaceSectionNotifier extends Notifier<WorkspaceSection> {
  @override
  WorkspaceSection build() => WorkspaceSection.messages;
  void select(WorkspaceSection section) => state = section;
}
