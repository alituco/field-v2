import Flutter
import UIKit

/// Supplies the system material only. Flutter owns navigation, gestures, and semantics.
final class FieldrushLiquidGlassPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "fieldrush/liquid_glass_support",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(FieldrushLiquidGlassPlugin(), channel: channel)
    registrar.register(
      FieldrushLiquidGlassFactory(),
      withId: "fieldrush/liquid_glass"
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "isAvailable" {
      result(true)
      return
    }
    guard call.method == "isSupported" else {
      result(FlutterMethodNotImplemented)
      return
    }
    if #available(iOS 26.0, *) {
      result(true)
    } else {
      result(false)
    }
  }
}

private final class FieldrushLiquidGlassFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    FieldrushLiquidGlassPlatformView(frame: frame)
  }
}

private final class FieldrushLiquidGlassPlatformView: NSObject, FlutterPlatformView {
  private let surface: FieldrushLiquidGlassSurface

  init(frame: CGRect) {
    surface = FieldrushLiquidGlassSurface(frame: frame)
    super.init()
  }

  func view() -> UIView {
    surface
  }
}

private final class FieldrushLiquidGlassSurface: UIView {
  private let effectView = UIVisualEffectView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    // Fieldrush currently uses a light palette even when iOS is in Dark Mode.
    // Match its dark foreground icons, including with Reduce Transparency on.
    overrideUserInterfaceStyle = .light
    isOpaque = false
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    effectView.isUserInteractionEnabled = false
    effectView.isOpaque = false
    effectView.clipsToBounds = true
    effectView.layer.cornerCurve = .continuous
    addSubview(effectView)
    updateMaterial()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateMaterial),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    effectView.frame = bounds
    effectView.layer.cornerRadius = min(bounds.height / 2, 28)
  }

  @objc private func updateMaterial() {
    if UIAccessibility.isReduceTransparencyEnabled {
      effectView.effect = nil
      effectView.backgroundColor = .secondarySystemBackground
    } else {
      effectView.backgroundColor = .clear
      if #available(iOS 26.0, *) {
        let glass = UIGlassEffect(style: .clear)
        glass.isInteractive = false
        effectView.effect = glass
      } else {
        effectView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
      }
    }
  }
}
