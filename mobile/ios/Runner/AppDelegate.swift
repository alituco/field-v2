import Flutter
import FirebaseCore
import FirebaseMessaging
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FieldrushPushCleanup") {
      let channel = FlutterMethodChannel(
        name: "fieldrush/push_cleanup", binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        guard call.method == "deleteRegistrations" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard FirebaseApp.app() != nil else {
          result(FlutterError(code: "not-initialized", message: "Firebase is not initialized.", details: nil))
          return
        }
        // The single-token API requires existing checkin credentials. This
        // public SDK operation also handles fresh installs with none to revoke.
        let messaging = Messaging.messaging()
        messaging.isAutoInitEnabled = false
        messaging.deleteData { error in
          DispatchQueue.main.async {
            if let error = error as NSError? {
              result(FlutterError(
                code: "provider-cleanup-failed", message: error.localizedDescription,
                details: ["domain": error.domain, "code": error.code]
              ))
            } else {
              result(nil)
            }
          }
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FieldrushLiquidGlassPlugin") {
      FieldrushLiquidGlassPlugin.register(with: registrar)
    }
  }
}
