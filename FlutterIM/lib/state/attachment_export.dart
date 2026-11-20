import 'dart:io';

/// The picker must retain access to the copy until it finishes or is cancelled.
Future<String?> saveAttachmentCopy({
  required String name,
  required Future<void> Function(String) write,
  required Future<String?> Function(String) chooseDestination,
}) async {
  final dir = await Directory.systemTemp.createTemp('im-export-');
  try {
    final cleaned = name.replaceAll(RegExp(r'[\/\\:\x00-\x1f]'), '_').trim();
    final leaf = cleaned.isEmpty || cleaned == '.' || cleaned == '..'
        ? '附件'
        : cleaned;
    final path = File.fromUri(dir.uri.resolveUri(Uri(pathSegments: [leaf])))
        .path;
    await write(path);
    return await chooseDestination(path);
  } finally {
    await dir.delete(recursive: true);
  }
}
