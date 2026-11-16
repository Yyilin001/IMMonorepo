import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

final photoLibraryProvider = Provider<PhotoLibrary>((ref) => PhotoLibrary());

class PhotoDraft {
  const PhotoDraft(this.conversationId, this.file, this.width, this.height);
  final int conversationId;
  final File file;
  final int width, height;
}

class PhotoLibrary {
  PhotoLibrary({this.supportDirectory = getApplicationSupportDirectory});
  final Future<Directory> Function() supportDirectory;
  final _picker = ImagePicker();
  static const _pendingKey = 'ripple.pending-photo-conversation';
  Directory? _directory;
  int _sequence = 0;
  bool busy = false;

  bool get supportsCamera => Platform.isIOS || Platform.isAndroid;

  Future<PhotoDraft?> pick(
    int conversationId, {
    required ImageSource source,
  }) async {
    final prefs = Platform.isAndroid ? SharedPreferencesAsync() : null;
    await prefs?.setInt(_pendingKey, conversationId);
    try {
      final file = await _picker.pickImage(
        source: source,
        requestFullMetadata: false,
      );
      return file == null ? null : await _read(conversationId, file.path);
    } finally {
      await prefs?.remove(_pendingKey);
    }
  }

  Future<PhotoDraft?> recover() async {
    if (!Platform.isAndroid) return null;
    final prefs = SharedPreferencesAsync();
    final id = await prefs.getInt(_pendingKey);
    try {
      final result = await _picker.retrieveLostData();
      if (id == null || result.isEmpty) return null;
      if (result.exception case final error?) throw error;
      final file = result.files?.firstOrNull;
      return file == null ? null : await _read(id, file.path);
    } finally {
      await prefs.remove(_pendingKey);
    }
  }

  Future<PhotoDraft> _read(int id, String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return PhotoDraft(id, File(path), descriptor.width, descriptor.height);
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  // Chat history is scoped to this run. Retire the previous run's copies when
  // the first photo is saved; never modify the photo returned by the picker.
  Future<Directory> _openDirectory() async {
    final root = Directory('${(await supportDirectory()).path}/chat-photos');
    if (await root.exists()) await root.delete(recursive: true);
    return root.create(recursive: true);
  }

  Future<ImageMessageData> save(PhotoDraft draft) async {
    final directory = _directory ??= await _openDirectory();
    final name = 'photo-${_sequence++}';
    final target = File('${directory.path}/$name');
    try {
      await draft.file.copy(target.path);
      return ImageMessageData(
        width: draft.width,
        height: draft.height,
        localFileName: name,
      );
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    }
  }

  File fileFor(String name) => File('${_directory!.path}/$name');
}
