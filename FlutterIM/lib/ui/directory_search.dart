part of 'workspace.dart';

Future<void> _openDirectorySearch(
  BuildContext context,
  Widget page,
  String name,
) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  late final PageRoute<void> route;
  route = PageRouteBuilder<void>(
    settings: RouteSettings(name: name),
    transitionDuration: Duration(milliseconds: reduceMotion ? 0 : 280),
    reverseTransitionDuration: Duration(milliseconds: reduceMotion ? 0 : 230),
    pageBuilder: (_, _, _) => Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(child: page),
    ),
    transitionsBuilder: (context, animation, _, child) {
      final fade = FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
        child: child,
      );
      final theme = Theme.of(context);
      if (theme.platform != TargetPlatform.iOS) return fade;
      // Keep the native edge-back recognizer with a stationary page.
      return theme.pageTransitionsTheme.builders[TargetPlatform.iOS]
              ?.buildTransitions<void>(
                route,
                context,
                kAlwaysCompleteAnimation,
                kAlwaysDismissedAnimation,
                fade,
              ) ??
          fade;
    },
  );
  return Navigator.of(context).push<void>(route);
}

const _searchHintStyle = TextStyle(color: muted, fontSize: 16);

enum _SearchBarTag { conversations, contacts }

class _MovingSearchBar extends StatefulWidget {
  const _MovingSearchBar({
    required this.tag,
    required this.label,
    required this.child,
  });
  final _SearchBarTag tag;
  final String label;
  final Widget child;

  @override
  State<_MovingSearchBar> createState() => _MovingSearchBarState();
}

class _MovingSearchBarState extends State<_MovingSearchBar> {
  // The flight placeholder reparents this subtree. Preserve the live editor
  // and its native keyboard connection throughout both transitions.
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _contentKey, child: widget.child);
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return Hero(
      tag: widget.tag,
      transitionOnUserGestures: true,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      placeholderBuilder: (_, size, child) => SizedBox.fromSize(
        size: size,
        child: Opacity(opacity: 0, child: child),
      ),
      flightShuttleBuilder: (_, _, _, _, _) => _SearchBarFace(
        key: const Key('search-bar-flight'),
        label: widget.label,
      ),
      child: child,
    );
  }
}

InputDecoration _searchDecoration(String label, {Widget? trailing}) =>
    InputDecoration(
      hintText: label,
      hintStyle: _searchHintStyle,
      hintMaxLines: 1,
      filled: true,
      fillColor: const Color(0xFFF2F5F3),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      prefixIcon: const Icon(Icons.search_rounded, size: 20, color: muted),
      suffixIcon: trailing,
      suffixIconConstraints: const BoxConstraints(),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
    );

class _SearchBarFace extends StatelessWidget {
  const _SearchBarFace({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: InputDecorator(decoration: _searchDecoration(label), isEmpty: true),
  );
}

void _restoreDirectoryOffset(ScrollController scroll, double offset) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!scroll.hasClients) return;
    final target = offset.clamp(0.0, scroll.position.maxScrollExtent);
    if (scroll.offset != target) scroll.jumpTo(target);
  });
}

class _SearchEntry extends StatelessWidget {
  const _SearchEntry({
    required this.entryKey,
    required this.tag,
    required this.hint,
    required this.onTap,
  });
  final Key entryKey;
  final _SearchBarTag tag;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: InkWell(
      key: entryKey,
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: _MovingSearchBar(
        tag: tag,
        label: hint,
        child: _SearchBarFace(label: hint),
      ),
    ),
  );
}

class _SearchScope extends StatelessWidget {
  const _SearchScope({
    this.onPageExit,
    required this.active,
    required this.onCancel,
    required this.child,
  });
  final VoidCallback? onPageExit;
  final bool active;
  final VoidCallback onCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final enabled = active && TickerMode.valuesOf(context).enabled;
    return PopScope(
      canPop: !enabled,
      onPopInvokedWithResult: (popped, _) {
        if (popped) onPageExit?.call();
        if (!popped && enabled) onCancel();
      },
      child: CallbackShortcuts(
        bindings: {
          if (enabled)
            const SingleActivator(LogicalKeyboardKey.escape): onCancel,
        },
        child: child,
      ),
    );
  }
}

class _DirectorySearchField extends StatelessWidget {
  const _DirectorySearchField({
    this.autofocus = false,
    required this.fieldKey,
    required this.tag,
    required this.controller,
    required this.focus,
    required this.active,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    required this.onCancel,
  });
  final bool autofocus;
  final Key fieldKey;
  final _SearchBarTag tag;
  final TextEditingController controller;
  final FocusNode focus;
  final bool active;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      key: fieldKey,
      controller: controller,
      focusNode: focus,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      onSubmitted: (_) => onSubmitted(),
      decoration: _searchDecoration(
        hint,
        trailing: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: '清除搜索',
                  icon: const Icon(
                    Icons.cancel_rounded,
                    size: 18,
                    color: muted,
                  ),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                    focus.requestFocus();
                  },
                ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(18, active ? 12 : 0, active ? 8 : 18, 0),
      child: Row(
        children: [
          Expanded(
            child: autofocus
                ? _MovingSearchBar(
                    tag: tag,
                    label: controller.text.isEmpty ? hint : controller.text,
                    child: field,
                  )
                : field,
          ),
          if (active)
            TextFieldTapRegion(
              child: TextButton(onPressed: onCancel, child: const Text('取消')),
            ),
        ],
      ),
    );
  }
}

void _rememberDirectoryQuery(
  BuildContext context,
  WidgetRef ref,
  SearchDirectory directory,
  String text,
) {
  if (text.trim().isEmpty) return;
  _saveSearchHistory(
    context,
    ref.read(recentSearchesProvider(directory).notifier).remember(text),
  );
}

Future<void> _saveSearchHistory(
  BuildContext context,
  Future<void> write,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await write;
  } catch (_) {
    if (messenger.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('未能保存搜索记录，请重试。')));
    }
  }
}

class _RecentSearchPanel extends ConsumerWidget {
  const _RecentSearchPanel({
    required this.directory,
    required this.hint,
    required this.controller,
    required this.focus,
    required this.onChanged,
  });
  final SearchDirectory directory;
  final String hint;
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queries = ref.watch(recentSearchesProvider(directory));
    if (queries.isEmpty) {
      return Center(
        child: Text(hint, style: const TextStyle(color: muted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '最近搜索',
                style: TextStyle(
                  color: ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _saveSearchHistory(
                context,
                ref.read(recentSearchesProvider(directory).notifier).clear(),
              ),
              child: const Text('清空'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final query in queries)
              ActionChip(
                label: Text(
                  query,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () {
                  controller.value = TextEditingValue(
                    text: query,
                    selection: TextSelection.collapsed(offset: query.length),
                  );
                  onChanged(query);
                  _rememberDirectoryQuery(context, ref, directory, query);
                  focus.unfocus();
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _SearchResultsLabel extends StatelessWidget {
  const _SearchResultsLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(text, style: const TextStyle(color: muted, fontSize: 12)),
    ),
  );
}
