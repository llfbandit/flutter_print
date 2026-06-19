import 'dart:io';
import 'dart:typed_data';

const _prefix = 'flutter_print_';
const _ext = '.pdf';

Future<String> bytesToPath(Uint8List bytes) async {
  final dir = Directory.systemTemp;
  try {
    dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains(_prefix) && f.path.endsWith(_ext))
        .forEach((f) => f.deleteSync());
  } catch (_) {}
  final file = File(
    '${dir.path}${Platform.pathSeparator}$_prefix${DateTime.now().millisecondsSinceEpoch}$_ext',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
