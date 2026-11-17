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


/// Group avatars share the avatar editor's authorized presentation. Only the
/// decoded bytes and deadline cross into this bounded display cache.
class _SdkGroupAvatarCache {
  static const _maximumBytes = 16 * 1024 * 1024;
  static final _cache = <String, _CachedAvatar>{};
  static final _pending = <String, Future<_LoadedAvatar?>>{};
  static var _bytes = 0;

  static Future<_LoadedAvatar?> load(ImClient client, String roomId) {
    final now = DateTime.now();
    final hit = _cache[roomId];
    if (hit != null) {
      if (hit.expires.isAfter(now)) {
        return Future.value((
          bytes: hit.bytes,
          remaining: hit.expires.difference(now),
        ));
      }
      _cache.remove(roomId);
      _bytes -= hit.bytes.length;
    }
    final pending = _pending[roomId];
    if (pending != null) return pending;
    final completer = Completer<_LoadedAvatar?>();
    _pending[roomId] = completer.future;
    client.openAvatarEditor(roomId: roomId).then((editor) {
      final bytes = editor?.image;
      if (editor == null ||
          bytes == null ||
          editor.remainingMilliseconds <= 0) {
        completer.complete(null);
        return;
      }
      final remaining = Duration(milliseconds: editor.remainingMilliseconds);
      final entry = (bytes: bytes, expires: DateTime.now().add(remaining));
      _cache[roomId] = entry;
      _bytes += bytes.length;
      _trim();
      completer.complete((bytes: bytes, remaining: remaining));
    }, onError: completer.completeError).whenComplete(() {
      _pending.remove(roomId);
    });
    return completer.future;
  }

  static void _trim() {
    while (_bytes > _maximumBytes && _cache.isNotEmpty) {
      final room = _cache.keys.first;
      _bytes -= _cache.remove(room)!.bytes.length;
    }
  }

  static void invalidate(String roomId) {
    final old = _cache.remove(roomId);
    if (old != null) _bytes -= old.bytes.length;
  }

  static void clear() {
    _cache.clear();
    _pending.clear();
    _bytes = 0;
  }
}

class SdkGroupAvatar extends StatefulWidget {
  const SdkGroupAvatar({
    super.key,
    required this.roomId,
    required this.name,
    this.size = 43,
  });
  final String roomId, name;
  final double size;

  @override
  State<SdkGroupAvatar> createState() => _SdkGroupAvatarState();
}

class _SdkGroupAvatarState extends State<SdkGroupAvatar> {
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
      final value = await _SdkGroupAvatarCache.load(client, widget.roomId);
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
    } catch (_) {
      // Keep the group placeholder on authorization or network failures.
    }
  }

  @override
  void dispose() {
    expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatAvatar(
    id: _avatarId(widget.roomId),
    name: widget.name,
    group: true,
    size: widget.size,
    avatar: bytes,
  );
}

Future<Uint8List?> pickSquareAvatar(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选择'),
            onTap: () => Navigator.pop(sheet, ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍照'),
            onTap: () => Navigator.pop(sheet, ImageSource.camera),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  final picked = await ImagePicker().pickImage(
    source: source,
    maxWidth: 2048,
    maxHeight: 2048,
  );
  if (picked == null || !context.mounted) return null;
  final bytes = await picked.readAsBytes();
  return compute(_squareAvatarJpeg, bytes);
}
