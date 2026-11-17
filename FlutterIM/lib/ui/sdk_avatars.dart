part of 'workspace.dart';

typedef _CachedAvatar = ({Uint8List bytes, DateTime expires});
typedef _LoadedAvatar = ({Uint8List bytes, Duration remaining});

/// Bounded in-memory cache for authorized avatar renditions. The runtime keeps
/// its own page-scoped grant; this cache only shortens a render's lifetime to
/// the remaining deadline returned with the bytes.
class _SdkAvatarCache {
  static const _maximumBytes = 24 * 1024 * 1024;
  static final _cache = <String, _CachedAvatar>{};
  static final _pending = <String, Future<_LoadedAvatar?>>{};
  static var _bytes = 0;

  static Future<_LoadedAvatar?> load(
    ImClient client, {
    required String userId,
    required String context,
    String? roomId,
  }) {
    final key = '$context|${roomId ?? ''}|$userId';
    final now = DateTime.now();
    final hit = _cache[key];
    if (hit != null) {
      if (hit.expires.isAfter(now)) {
        return Future.value((
          bytes: hit.bytes,
          remaining: hit.expires.difference(now),
        ));
      }
      _cache.remove(key);
      _bytes -= hit.bytes.length;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final completer = Completer<_LoadedAvatar?>();
    _pending[key] = completer.future;
    client
        .avatar(userId, context: context, roomId: roomId)
        .then((value) {
          if (value == null) {
            completer.complete(null);
            return;
          }
          final entry = (
            bytes: value.bytes,
            expires: DateTime.now().add(value.remaining),
          );
          _cache[key] = entry;
          _bytes += value.bytes.length;
          _trim();
          completer.complete((bytes: value.bytes, remaining: value.remaining));
        }, onError: completer.completeError)
        .whenComplete(() {
          _pending.remove(key);
        });
    return completer.future;
  }

  static void _trim() {
    while (_bytes > _maximumBytes && _cache.isNotEmpty) {
      final key = _cache.keys.first;
      _bytes -= _cache.remove(key)!.bytes.length;
    }
  }

  static void clear() {
    _cache.clear();
    _pending.clear();
    _bytes = 0;
  }
}

int _avatarId(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash;
}

/// Renders an initials placeholder until the shared runtime returns an
/// authorized avatar bytes payload, then falls back again when it expires.
class SdkAvatar extends StatefulWidget {
  const SdkAvatar({
    super.key,
    required this.userId,
    required this.name,
    this.context = 'relationship',
    this.roomId,
    this.size = 43,
    this.group = false,
  });
  final String userId, name, context;
  final String? roomId;
  final double size;
  final bool group;

  @override
  State<SdkAvatar> createState() => _SdkAvatarState();
}

class _SdkAvatarState extends State<SdkAvatar> {
  Uint8List? bytes;
  Timer? expiry;
  bool initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(load());
      });
    }
  }

  Future<void> load() async {
    final client = _SdkScope.of(context)?.client;
    if (client == null) return;
    try {
      final value = await _SdkAvatarCache.load(
        client,
        userId: widget.userId,
        context: widget.context,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      expiry?.cancel();
      setState(() => bytes = value?.bytes);
      if (value != null && value.remaining > Duration.zero) {
        expiry = Timer(value.remaining, () {
          if (!mounted) return;
          setState(() => bytes = null);
          unawaited(load());
        });
      }
    } catch (error) {
      // Authorization and network failures keep the initials placeholder.
    }
  }

  @override
  void dispose() {
    expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatAvatar(
    id: _avatarId(widget.userId),
    name: widget.name,
    group: widget.group,
    size: widget.size,
    avatar: bytes,
  );
}
