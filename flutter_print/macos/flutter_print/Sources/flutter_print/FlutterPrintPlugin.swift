import Cocoa
import FlutterMacOS

public class FlutterPrintPlugin: NSObject, FlutterPlugin, FlutterPrintApi {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPrintPlugin()
    FlutterPrintApiSetup.setUp(binaryMessenger: registrar.messenger, api: instance)
  }
}
