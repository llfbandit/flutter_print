import 'dart:typed_data';

Future<String> createBlobUrl(Uint8List bytes, String mimeType) async {
  throw UnsupportedError('Blob URLs are only available on the web');
}
