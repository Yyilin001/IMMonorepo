part of 'workspace.dart';

/// A one-shot, view-local ticket, never a queue of messages or delayed writes.
class _MessageEntranceTicket {
  _MessageEntranceTicket(this.onFinished);
  final VoidCallback onFinished;
  VoidCallback? completeAnimation;
  bool _claimed = false;
  bool _finished = false;
  bool get claimed => _claimed;

  bool claim() {
    if (_claimed || _finished) return false;
    _claimed = true;
    return true;
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    final complete = completeAnimation;
    completeAnimation = null;
    complete?.call();
    onFinished();
  }
}

class _MessageEntrance extends StatefulWidget {
  const _MessageEntrance({
    super.key,
    required this.ticket,
    required this.child,
  });
  final _MessageEntranceTicket ticket;
  final Widget child;
  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _progress;
  Animation<double>? _opacity;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_initialized) {
      if (!enabled) widget.ticket.finish();
      return;
    }
    _initialized = true;
    if (!enabled || !widget.ticket.claim()) {
      widget.ticket.finish();
      return;
    }
    final controller = _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final progress = _progress = controller.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );
    _opacity = progress.drive(Tween(begin: .3, end: 1.0));
    widget.ticket.completeAnimation = () {
      controller.stop();
      controller.value = 1;
    };
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.ticket.finish();
    });
    controller.forward();
  }

  @override
  void dispose() {
    widget.ticket.completeAnimation = null;
    widget.ticket.finish();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    if (progress == null) return widget.child;
    // Full layout height is reserved immediately. Only paint changes, so older
    // bubbles retain their layout and image placeholders never grow during entry.
    return FadeTransition(
      opacity: _opacity!,
      child: AnimatedBuilder(
        animation: progress,
        child: widget.child,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 10 * (1 - progress.value)),
          child: child,
        ),
      ),
    );
  }
}
