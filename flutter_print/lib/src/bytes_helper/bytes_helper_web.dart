import 'dart:js_interop';
import 'dart:typed_data';

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny?> parts, [_BlobOptions options]);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectURL(JSObject blob);

Future<String> bytesToPath(Uint8List bytes) async {
  final blob = _Blob(
    [bytes.buffer.toJS as JSAny].toJS,
    _BlobOptions(type: 'application/pdf'),
  );
  return _createObjectURL(blob);
}
