import 'dart:math';

import 'models.dart';

/// Order-statistic treap. Each message updates only O(log N) nodes; indexed
/// reads also take O(log N), without sorting or copying all conversations.
class ConversationIndex {
  ConversationIndex({int Function(Conversation, Conversation)? compare})
    : _ordering = compare ?? _compare;
  final int Function(Conversation, Conversation) _ordering;
  final Random _random = Random(42);
  _Node? _root;

  int get length => _size(_root);

  void insert(Conversation value) {
    _root = _insert(_root, _Node(value, _random.nextInt(1 << 30)));
  }

  void remove(Conversation value) {
    _root = _remove(_root, value);
  }

  Conversation at(int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    var node = _root!;
    var remaining = index;
    while (true) {
      final leftSize = _size(node.left);
      if (remaining == leftSize) return node.value;
      if (remaining < leftSize) {
        node = node.left!;
      } else {
        remaining -= leftSize + 1;
        node = node.right!;
      }
    }
  }

  Iterable<Conversation> get values sync* {
    final stack = <_Node>[];
    var node = _root;
    while (node != null || stack.isNotEmpty) {
      while (node != null) {
        stack.add(node);
        node = node.left;
      }
      node = stack.removeLast();
      yield node.value;
      node = node.right;
    }
  }

  static int _compare(Conversation a, Conversation b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final recent = b.sequence.compareTo(a.sequence);
    return recent != 0 ? recent : a.id.compareTo(b.id);
  }

  static int _size(_Node? node) => node?.size ?? 0;

  static _Node _refresh(_Node node) {
    node.size = 1 + _size(node.left) + _size(node.right);
    return node;
  }

  static _Node _rotateRight(_Node root) {
    final next = root.left!;
    root.left = next.right;
    next.right = _refresh(root);
    return _refresh(next);
  }

  static _Node _rotateLeft(_Node root) {
    final next = root.right!;
    root.right = next.left;
    next.left = _refresh(root);
    return _refresh(next);
  }

  _Node _insert(_Node? root, _Node entry) {
    if (root == null) return entry;
    final comparison = _ordering(entry.value, root.value);
    if (comparison == 0) {
      root.value = entry.value;
    } else if (comparison < 0) {
      root.left = _insert(root.left, entry);
      if (root.left!.priority < root.priority) return _rotateRight(root);
    } else {
      root.right = _insert(root.right, entry);
      if (root.right!.priority < root.priority) return _rotateLeft(root);
    }
    return _refresh(root);
  }

  static _Node? _merge(_Node? left, _Node? right) {
    if (left == null) return right;
    if (right == null) return left;
    if (left.priority < right.priority) {
      left.right = _merge(left.right, right);
      return _refresh(left);
    }
    right.left = _merge(left, right.left);
    return _refresh(right);
  }

  _Node? _remove(_Node? root, Conversation value) {
    if (root == null) return null;
    final comparison = _ordering(value, root.value);
    if (comparison == 0) return _merge(root.left, root.right);
    if (comparison < 0) {
      root.left = _remove(root.left, value);
    } else {
      root.right = _remove(root.right, value);
    }
    return _refresh(root);
  }
}

class _Node {
  _Node(this.value, this.priority);
  Conversation value;
  final int priority;
  _Node? left, right;
  int size = 1;
}
