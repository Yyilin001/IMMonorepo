part of 'workspace.dart';

// Reverse scrolling normally keeps the bottom edge stationary. In history,
// keep the message at the top stationary when the keyboard or window resizes.
class _ReadingScrollView extends CustomScrollView {
  const _ReadingScrollView({
    super.key,
    required this.preserveReadingPosition,
    super.controller,
    super.reverse,
    super.center,
    super.keyboardDismissBehavior,
    super.slivers,
  });

  final bool preserveReadingPosition;

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) {
    return _ReadingViewport(
      offset: offset,
      axisDirection: axisDirection,
      center: center,
      preserveReadingPosition: preserveReadingPosition,
      slivers: slivers,
    );
  }
}

class _ReadingViewport extends Viewport {
  _ReadingViewport({
    required super.offset,
    required super.axisDirection,
    required super.center,
    required super.slivers,
    required this.preserveReadingPosition,
  });
  final bool preserveReadingPosition;

  @override
  _ReadingRenderViewport createRenderObject(BuildContext context) =>
      _ReadingRenderViewport(
        offset: offset,
        axisDirection: axisDirection,
        crossAxisDirection: Viewport.getDefaultCrossAxisDirection(
          context,
          axisDirection,
        ),
        preserveReadingPosition: preserveReadingPosition,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _ReadingRenderViewport renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    renderObject.preserveReadingPosition = preserveReadingPosition;
  }
}

// The lazy sliver estimates its total extent. Record the actual end of the
// last laid-out child so it can also serve as a reading anchor after reflow.
class _ReadingSliver extends SliverList {
  _ReadingSliver.builder({
    required super.itemBuilder,
    required super.itemCount,
    required super.findChildIndexCallback,
  }) : super.builder();

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _ReadingRenderSliver(
        childManager: context as SliverMultiBoxAdaptorElement,
      );
}

class _ReadingRenderSliver extends RenderSliverList {
  _ReadingRenderSliver({required super.childManager});
  double lastChildEnd = 0;

  @override
  void performLayout() {
    super.performLayout();
    final last = lastChild;
    if (last != null && last.hasSize && childScrollOffset(last) != null) {
      lastChildEnd = childScrollOffset(last)! + paintExtentOf(last);
    }
  }
}

class _ReadingRenderViewport extends RenderViewport {
  _ReadingRenderViewport({
    required super.offset,
    required super.axisDirection,
    required super.crossAxisDirection,
    required this.preserveReadingPosition,
  });
  bool preserveReadingPosition;
  Size? _previousSize;

  // The center sliver grows upwards. Messages newer than the reading
  // origin occupy the preceding sliver, which grows downwards on screen.
  // Use sliver layout offsets: they are valid even for cached, unpainted rows.
  (double, double) _rowEdges(
    RenderSliverPadding padding,
    _ReadingRenderSliver list,
    RenderBox row,
    double height,
  ) {
    final origin = height + offset.pixels;
    final start = list.childScrollOffset(row)!;
    final next = list.childAfter(row);
    final end = next == null
        ? list.lastChildEnd
        : list.childScrollOffset(next)!;
    final insets = padding.padding.resolve(padding.textDirection);
    if (identical(padding, center)) {
      return (origin - insets.bottom - end, origin - insets.bottom - start);
    }
    return (origin + insets.top + start, origin + insets.top + end);
  }

  (RenderBox, double)? _topRow(double height) {
    for (var sliver = firstChild; sliver != null; sliver = childAfter(sliver)) {
      if (sliver is! RenderSliverPadding || sliver.geometry?.visible != true) {
        continue;
      }
      final list = sliver.child;
      if (list is! _ReadingRenderSliver) continue;
      for (var row = list.firstChild; row != null; row = list.childAfter(row)) {
        final (top, bottom) = _rowEdges(sliver, list, row, height);
        if (top <= .01 && bottom > 0) return (row, top);
      }
    }
    return null;
  }

  @override
  void performLayout() {
    final previous = _previousSize;
    _previousSize = size;
    if (!preserveReadingPosition ||
        previous == null ||
        previous == size ||
        previous.isEmpty ||
        size.isEmpty) {
      super.performLayout();
      return;
    }
    final anchor = _topRow(previous.height);
    // Account for height first so the same lazy child remains in the cache.
    offset.correctBy(previous.height - size.height);
    super.performLayout();
    if (anchor == null || !anchor.$1.attached) return;
    final row = anchor.$1;
    final list = row.parent;
    if (list is! _ReadingRenderSliver || list.parent is! RenderSliverPadding) {
      return;
    }
    final (top, _) = _rowEdges(
      list.parent! as RenderSliverPadding,
      list,
      row,
      size.height,
    );
    final correction = anchor.$2 - top;
    if (correction.abs() > .1) {
      offset.correctBy(correction);
      super.performLayout();
    }
  }
}
