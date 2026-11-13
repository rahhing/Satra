import Flutter
import QuartzCore
import UIKit

private struct IOSGlassCornerRadii: Equatable {
  let tl: CGFloat
  let tr: CGFloat
  let bl: CGFloat
  let br: CGFloat

  var isUniform: Bool {
    abs(tl - tr) < 0.5 && abs(tl - bl) < 0.5 && abs(tl - br) < 0.5
  }

  var maxRadius: CGFloat {
    max(max(tl, tr), max(bl, br))
  }

  func isCapsule(for size: CGSize) -> Bool {
    guard size.width > 0, size.height > 0, isUniform else { return false }
    let halfShortSide = min(size.width, size.height) * 0.5
    return tl >= halfShortSide - 1.0
  }

  var maskedCorners: CACornerMask {
    var mask: CACornerMask = []
    if tl > 0.5 { mask.insert(.layerMinXMinYCorner) }
    if tr > 0.5 { mask.insert(.layerMaxXMinYCorner) }
    if bl > 0.5 { mask.insert(.layerMinXMaxYCorner) }
    if br > 0.5 { mask.insert(.layerMaxXMaxYCorner) }
    return mask
  }
}

/// Hosts native iOS 26+ Liquid Glass (`UIGlassEffect` over a tuned within-window
/// frosted `UIBlurEffect` backdrop) so pills, bars, sheets, menus, and video
/// overlays combine Desktop-grade creamy interior blur with authentic iOS 26
/// optical edge refraction and specular highlights.
///
/// Clears backdrop-isolating `masksToBounds` / `mask` state on Flutter's
/// `UiKitView` wrapper views (`FlutterTouchInterceptingView`, `ChildClippingView`)
/// right before Core Animation commits so `CABackdropLayer` samples Flutter's
/// Metal surface and mpv's native video layer directly underneath.
private final class IOSGlassSurfaceView: UIView {
  private static let setAllowsGroupBlendingSelector = NSSelectorFromString("setAllowsGroupBlending:")

  private let viewId: Int64
  private let blurEffectView = UIVisualEffectView(effect: nil)
  private let glassEffectView = UIVisualEffectView(effect: nil)
  private var currentRadii = IOSGlassCornerRadii(tl: 24, tr: 24, bl: 24, br: 24)
  private var currentLiquidGlass = true
  private var currentInteractive = false
  private var currentBlurRadius: Double = 28.0

  init(viewId: Int64, arguments: Any?) {
    self.viewId = viewId
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    autoresizesSubviews = true

    for subview in [blurEffectView, glassEffectView] {
      subview.frame = bounds
      subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      subview.backgroundColor = .clear
      subview.isUserInteractionEnabled = false
      addSubview(subview)
    }

    apply(arguments: arguments)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    IOSGlassSurfaceRegistry.shared.unregister(viewId: viewId, view: self)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    unblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    applyBackdropBlurTuning()
    unblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if blurEffectView.frame != bounds {
      blurEffectView.frame = bounds
    }
    if glassEffectView.frame != bounds {
      glassEffectView.frame = bounds
    }
    applyCornerGeometry()
    applyBackdropBlurTuning()
    unblockAncestorBackdropSampling()
  }

  func apply(arguments: Any?) {
    let dict = arguments as? [String: Any]
    let liquidGlass = dict?["liquidGlass"] as? Bool ?? true
    let interactive = dict?["interactive"] as? Bool ?? false
    let dark = dict?["dark"] as? Bool ?? true
    let tl = CGFloat((dict?["tl"] as? NSNumber)?.doubleValue ?? 24.0)
    let tr = CGFloat((dict?["tr"] as? NSNumber)?.doubleValue ?? 24.0)
    let bl = CGFloat((dict?["bl"] as? NSNumber)?.doubleValue ?? 24.0)
    let br = CGFloat((dict?["br"] as? NSNumber)?.doubleValue ?? 24.0)
    let visibility = CGFloat(min(max((dict?["visibility"] as? NSNumber)?.doubleValue ?? 1.0, 0.0), 1.0))
    let tintStrength = CGFloat(min(max((dict?["tintStrength"] as? NSNumber)?.doubleValue ?? 0.32, 0.0), 1.0))
    let tintArgb = (dict?["tintArgb"] as? NSNumber)?.uint32Value
    let sigma = (dict?["sigma"] as? NSNumber)?.doubleValue ?? (interactive ? 26.0 : 32.0)
    let pressProgress = CGFloat(min(max((dict?["pressProgress"] as? NSNumber)?.doubleValue ?? 0.0, 0.0), 1.0))

    let radii = IOSGlassCornerRadii(tl: tl, tr: tr, bl: bl, br: br)
    currentRadii = radii
    currentLiquidGlass = liquidGlass
    currentInteractive = interactive
    currentBlurRadius = min(max(sigma, 10.0), 48.0)

    let interfaceStyle: UIUserInterfaceStyle = dark ? .dark : .light
    if overrideUserInterfaceStyle != interfaceStyle {
      overrideUserInterfaceStyle = interfaceStyle
    }
    if blurEffectView.overrideUserInterfaceStyle != interfaceStyle {
      blurEffectView.overrideUserInterfaceStyle = interfaceStyle
    }
    if glassEffectView.overrideUserInterfaceStyle != interfaceStyle {
      glassEffectView.overrideUserInterfaceStyle = interfaceStyle
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Base frosted blur layer matches Desktop's `SatraVisualEffectView` blur so
    // sharp text/posters behind pills, menus, sheets, and Spotlight diffuse into
    // a smooth, creamy backdrop instead of bleeding through unblurred.
    let blurStyle: UIBlurEffect.Style = interactive
      ? (dark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
      : (dark ? .systemThickMaterialDark : .systemThickMaterialLight)
    blurEffectView.effect = UIBlurEffect(style: blurStyle)

    var appliedNativeLiquidGlass = false
    #if compiler(>=6.2)
    if liquidGlass, #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.isInteractive = interactive
      if let argb = tintArgb, tintStrength > 0.001 || pressProgress > 0.001 {
        let baseR = CGFloat((argb >> 16) & 0xFF) / 255.0
        let baseG = CGFloat((argb >> 8) & 0xFF) / 255.0
        let baseB = CGFloat(argb & 0xFF) / 255.0
        // Brighten the glass tint slightly while held so native UIGlassEffect
        // blooms with pressurized luminosity during touch-hold interactions.
        let r = baseR + (1.0 - baseR) * pressProgress * (dark ? 0.22 : 0.30)
        let g = baseG + (1.0 - baseG) * pressProgress * (dark ? 0.22 : 0.30)
        let b = baseB + (1.0 - baseB) * pressProgress * (dark ? 0.24 : 0.32)
        let boostedAlpha = min(max(tintStrength + pressProgress * 0.12, 0.0), 0.92)
        glassEffect.tintColor = UIColor(red: r, green: g, blue: b, alpha: boostedAlpha)
      } else {
        glassEffect.tintColor = nil
      }
      glassEffectView.effect = glassEffect
      glassEffectView.isHidden = false
      appliedNativeLiquidGlass = true
    }
    #endif

    if !appliedNativeLiquidGlass {
      glassEffectView.effect = nil
      glassEffectView.isHidden = true
    }

    // Keep full frosted blur behind sheets/menus/Spotlight and rich Desktop-matching
    // frosted blur behind interactive pills while letting UIGlassEffect's rim shine.
    blurEffectView.alpha = appliedNativeLiquidGlass ? 0 : visibility
    glassEffectView.alpha = visibility

    applyCornerGeometry(nativeLiquidGlass: appliedNativeLiquidGlass)
    applyBackdropBlurTuning()
    unblockAncestorBackdropSampling()
    CATransaction.commit()
  }

  private func applyCornerGeometry(nativeLiquidGlass: Bool? = nil) {
    let halfShortSide = bounds.width > 0 && bounds.height > 0
      ? min(bounds.width, bounds.height) * 0.5
      : currentRadii.maxRadius
    let clampRadius: (CGFloat) -> CGFloat = { raw in
      guard halfShortSide > 0 else { return max(0, raw) }
      return min(max(0, raw), halfShortSide)
    }

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let config: UICornerConfiguration
      if currentRadii.isCapsule(for: bounds.size) {
        config = .capsule()
      } else {
        config = .corners(
          topLeftRadius: .fixed(clampRadius(currentRadii.tl)),
          topRightRadius: .fixed(clampRadius(currentRadii.tr)),
          bottomLeftRadius: .fixed(clampRadius(currentRadii.bl)),
          bottomRightRadius: .fixed(clampRadius(currentRadii.br))
        )
      }
      for subview in [blurEffectView, glassEffectView] {
        subview.clipsToBounds = false
        subview.layer.cornerRadius = 0
        subview.cornerConfiguration = config
      }
      return
    }
    #endif

    for subview in [blurEffectView, glassEffectView] {
      subview.clipsToBounds = true
      subview.layer.cornerCurve = .continuous
      subview.layer.cornerRadius = clampRadius(currentRadii.maxRadius)
      subview.layer.maskedCorners = currentRadii.maskedCorners
    }
  }

  private func applyBackdropBlurTuning() {
    guard let root = blurEffectView.layer as CALayer?,
      let backdrop = Self.findBackdropLayer(in: root)
    else { return }

    var updated: [Any] = []
    var modified = false
    for raw in (backdrop.filters ?? []) {
      guard let obj = raw as? NSObject else {
        updated.append(raw)
        continue
      }
      let fname = obj.value(forKey: "name") as? String
      if fname == "gaussianBlur" || String(describing: obj).contains("gaussianBlur") {
        if let copy = obj.mutableCopy() as? NSObject {
          copy.setValue(currentBlurRadius, forKey: "inputRadius")
          copy.setValue(true, forKey: "inputNormalizeEdges")
          updated.append(copy)
          modified = true
          continue
        }
      }
      updated.append(obj)
    }
    if modified {
      backdrop.filters = updated
    }
  }

  private static func findBackdropLayer(in layer: CALayer) -> CALayer? {
    let clsName = NSStringFromClass(type(of: layer))
    if layer.name == "backdrop" || clsName.contains("BackdropLayer") {
      return layer
    }
    for sub in layer.sublayers ?? [] {
      if let found = findBackdropLayer(in: sub) {
        return found
      }
    }
    return nil
  }

  /// Flutter's iOS platform-view wrappers (`ChildClippingView`,
  /// `FlutterTouchInterceptingView`) apply `clipsToBounds = true` or a
  /// `CAShapeLayer` mask on their backing `CALayer`, creating an offscreen
  /// backdrop group that prevents `CABackdropLayer` inside `UIVisualEffectView`
  /// from sampling `FlutterView` and mpv video underneath.
  func unblockAncestorBackdropSampling() {
    let rootView = window?.rootViewController?.view
    var cursor: UIView? = self
    while let view = cursor {
      let className = NSStringFromClass(type(of: view))
      let isFlutterRoot = view === rootView || className == "FlutterView"
      let layer = view.layer
      if !isFlutterRoot {
        if layer.masksToBounds {
          layer.masksToBounds = false
        }
        if layer.mask != nil {
          layer.mask = nil
        }
      }
      if layer.responds(to: Self.setAllowsGroupBlendingSelector) {
        layer.setValue(true, forKey: "allowsGroupBlending")
      }
      if isFlutterRoot {
        break
      }
      cursor = view.superview
    }
  }
}

private final class IOSGlassSurfaceRegistry {
  static let shared = IOSGlassSurfaceRegistry()

  private let viewsById = NSMapTable<NSNumber, IOSGlassSurfaceView>.strongToWeakObjects()
  private let allViews = NSHashTable<IOSGlassSurfaceView>.weakObjects()
  private var runLoopObserver: CFRunLoopObserver?

  func register(viewId: Int64, view: IOSGlassSurfaceView) {
    viewsById.setObject(view, forKey: NSNumber(value: viewId))
    allViews.add(view)
    syncObserverState()
  }

  func unregister(viewId: Int64, view: IOSGlassSurfaceView) {
    if viewsById.object(forKey: NSNumber(value: viewId)) === view {
      viewsById.removeObject(forKey: NSNumber(value: viewId))
    }
    allViews.remove(view)
    syncObserverState()
  }

  func update(viewId: Int64, arguments: Any?) {
    guard let view = viewsById.object(forKey: NSNumber(value: viewId)) else { return }
    view.apply(arguments: arguments)
  }

  func syncObserverState() {
    let hasMountedViews = allViews.allObjects.contains { $0.window != nil }
    if hasMountedViews {
      installObserverIfNeeded()
    } else {
      removeObserverIfNeeded()
    }
  }

  private func installObserverIfNeeded() {
    guard runLoopObserver == nil else { return }
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault,
      CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
      true,
      2_100_000
    ) { [weak self] _, _ in
      guard let self = self else { return }
      var anyMounted = false
      for view in self.allViews.allObjects where view.window != nil {
        anyMounted = true
        view.unblockAncestorBackdropSampling()
      }
      if !anyMounted {
        self.removeObserverIfNeeded()
      }
    }
    if let observer = observer {
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      runLoopObserver = observer
    }
  }

  private func removeObserverIfNeeded() {
    guard let observer = runLoopObserver else { return }
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    runLoopObserver = nil
  }
}

private final class IOSGlassSurfacePlatformView: NSObject, FlutterPlatformView {
  private let containerView: IOSGlassSurfaceView

  init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) {
    containerView = IOSGlassSurfaceView(viewId: viewId, arguments: args)
    containerView.frame = frame
    super.init()
    IOSGlassSurfaceRegistry.shared.register(viewId: viewId, view: containerView)
  }

  func view() -> UIView {
    containerView
  }
}

final class IOSGlassSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    IOSGlassSurfacePlatformView(frame: frame, viewIdentifier: viewId, arguments: args)
  }
}

final class IOSGlassSurfacePlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(IOSNativeTabBarFactory(messenger: registrar.messenger()), withId: "com.satra/ios_tab_bar")
    let factory = IOSGlassSurfaceFactory()
    registrar.register(
      factory,
      withId: "com.satra/ios_glass_surface",
      gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicyWaitUntilTouchesEnded
    )
    let channel = FlutterMethodChannel(
      name: "com.satra/ios_glass_surface",
      binaryMessenger: registrar.messenger()
    )
    let instance = IOSGlassSurfacePlugin()
    instance.channel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "update",
        let dict = call.arguments as? [String: Any],
        let viewId = (dict["viewId"] as? NSNumber)?.int64Value
      {
        IOSGlassSurfaceRegistry.shared.update(viewId: viewId, arguments: dict)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}


private final class IOSNativeTabBarFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    IOSNativeTabBar(frame: frame, id: viewId, arguments: args, messenger: messenger)
  }
}

private final class IOSNativeTabBar: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let bar: UITabBar
  private let channel: FlutterMethodChannel
  init(frame: CGRect, id: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
    bar = UITabBar(frame: frame)
    channel = FlutterMethodChannel(name: "com.satra/ios_tab_bar/\(id)", binaryMessenger: messenger)
    super.init()
    bar.delegate = self
    bar.backgroundColor = .clear
    update(arguments)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update" { self?.update(call.arguments); result(nil) }
      else { result(FlutterMethodNotImplemented) }
    }
  }
  func view() -> UIView { bar }
  private func update(_ arguments: Any?) {
    guard let args = arguments as? [String: Any], let tabs = args["tabs"] as? [[String: String]] else { return }
    let symbols = ["discover": "house", "libraries": "play.rectangle.on.rectangle", "liveTv": "tv", "explore": "safari", "downloads": "arrow.down", "settings": "gearshape", "search": "magnifyingglass"]
    bar.overrideUserInterfaceStyle = (args["dark"] as? Bool ?? true) ? .dark : .light
    bar.tintColor = .label
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .medium)]
    appearance.stackedLayoutAppearance.normal.titleTextAttributes = attributes
    appearance.stackedLayoutAppearance.selected.titleTextAttributes = attributes
    bar.standardAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    let hideLabels = args["hideLabels"] as? Bool ?? false
    bar.items = tabs.enumerated().map { index, tab in
      let item = UITabBarItem(title: hideLabels ? nil : tab["label"], image: UIImage(systemName: symbols[tab["id"] ?? ""] ?? "circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), tag: index)
      item.accessibilityLabel = tab["label"]
      return item
    }
    let selected = args["selected"] as? Int ?? 0
    if let items = bar.items, items.indices.contains(selected) { bar.selectedItem = items[selected] }
  }
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("selected", arguments: item.tag)
  }
}
