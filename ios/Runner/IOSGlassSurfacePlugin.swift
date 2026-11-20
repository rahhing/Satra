import Flutter
import QuartzCore
import SwiftUI
import UIKit

private let satraSetAllowsGroupBlendingSelector = NSSelectorFromString("setAllowsGroupBlending:")

private extension UIView {
  /// Flutter's iOS platform-view wrappers (`ChildClippingView`,
  /// `FlutterTouchInterceptingView`) apply `clipsToBounds = true` or a
  /// `CAShapeLayer` mask on their backing `CALayer`, creating an offscreen
  /// backdrop group that prevents `CABackdropLayer` inside `UIVisualEffectView`
  /// and SwiftUI materials from sampling `FlutterView` and mpv video underneath.
  func satraUnblockAncestorBackdropSampling() {
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
      if layer.responds(to: satraSetAllowsGroupBlendingSelector) {
        layer.setValue(true, forKey: "allowsGroupBlending")
      }
      if isFlutterRoot {
        break
      }
      cursor = view.superview
    }
  }
}

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
  private let viewId: Int64
  private let blurEffectView = UIVisualEffectView(effect: nil)
  private let glassEffectView = UIVisualEffectView(effect: nil)
  private var currentRadii = IOSGlassCornerRadii(tl: 24, tr: 24, bl: 24, br: 24)
  private var currentBlurRadius: Double = 28.0
  private var glassTint: UIColor?
  private var glassInteractive = false

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
    satraUnblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    applyBackdropBlurTuning()
    satraUnblockAncestorBackdropSampling()
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
    satraUnblockAncestorBackdropSampling()
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

    let radii = IOSGlassCornerRadii(tl: tl, tr: tr, bl: bl, br: br)
    currentRadii = radii
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
    if liquidGlass, visibility > 0, #available(iOS 26.0, *) {
      let nextTint = tintArgb.map { UIColor(satraARGB: $0).withAlphaComponent(tintStrength) }
      if glassEffectView.effect == nil || glassTint != nextTint || glassInteractive != interactive {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = interactive
        glassEffect.tintColor = nextTint
        glassEffectView.effect = glassEffect
        glassTint = nextTint
        glassInteractive = interactive
      }
      glassEffectView.isHidden = false
      appliedNativeLiquidGlass = true
    }
    #endif

    if !appliedNativeLiquidGlass {
      glassEffectView.effect = nil
      glassEffectView.isHidden = true
    }

    blurEffectView.alpha = appliedNativeLiquidGlass ? 0 : visibility

    applyCornerGeometry()
    applyBackdropBlurTuning()
    satraUnblockAncestorBackdropSampling()
    CATransaction.commit()
  }

  private func applyCornerGeometry() {
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
    guard blurEffectView.alpha > 0, let root = blurEffectView.layer as CALayer?,
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
}

private final class IOSGlassSurfaceRegistry {
  static let shared = IOSGlassSurfaceRegistry()

  private let viewsById = NSMapTable<NSNumber, IOSGlassSurfaceView>.strongToWeakObjects()
  private let spotlightBackdropsById = NSMapTable<NSNumber, IOSSpotlightBackdropView>.strongToWeakObjects()
  private let allBackdropViews = NSHashTable<UIView>.weakObjects()
  private var runLoopObserver: CFRunLoopObserver?

  func register(viewId: Int64, view: IOSGlassSurfaceView) {
    viewsById.setObject(view, forKey: NSNumber(value: viewId))
    allBackdropViews.add(view)
    syncObserverState()
  }

  func unregister(viewId: Int64, view: IOSGlassSurfaceView) {
    if viewsById.object(forKey: NSNumber(value: viewId)) === view {
      viewsById.removeObject(forKey: NSNumber(value: viewId))
    }
    allBackdropViews.remove(view)
    syncObserverState()
  }

  func registerSpotlightBackdrop(viewId: Int64, view: IOSSpotlightBackdropView) {
    spotlightBackdropsById.setObject(view, forKey: NSNumber(value: viewId))
    allBackdropViews.add(view)
    syncObserverState()
  }

  func unregisterSpotlightBackdrop(viewId: Int64, view: IOSSpotlightBackdropView) {
    if spotlightBackdropsById.object(forKey: NSNumber(value: viewId)) === view {
      spotlightBackdropsById.removeObject(forKey: NSNumber(value: viewId))
    }
    allBackdropViews.remove(view)
    syncObserverState()
  }

  func registerBackdropView(_ view: UIView) {
    allBackdropViews.add(view)
    syncObserverState()
  }

  func unregisterBackdropView(_ view: UIView) {
    allBackdropViews.remove(view)
    syncObserverState()
  }

  func update(viewId: Int64, arguments: Any?) {
    guard let view = viewsById.object(forKey: NSNumber(value: viewId)) else { return }
    view.apply(arguments: arguments)
  }

  func updateSpotlightBackdrop(viewId: Int64, arguments: Any?) {
    guard let view = spotlightBackdropsById.object(forKey: NSNumber(value: viewId)) else { return }
    view.apply(arguments: arguments)
  }

  func syncObserverState() {
    let hasMountedViews = allBackdropViews.allObjects.contains { $0.window != nil }
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
      for view in self.allBackdropViews.allObjects where view.window != nil {
        anyMounted = true
        view.satraUnblockAncestorBackdropSampling()
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
  private var spotlightBackdropChannel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(
      IOSGlassControlFactory(messenger: registrar.messenger()),
      withId: "com.satra/ios_glass_control"
    )
    let factory = IOSGlassSurfaceFactory()
    registrar.register(
      factory,
      withId: "com.satra/ios_glass_surface",
      gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicyWaitUntilTouchesEnded
    )
    registrar.register(
      IOSSpotlightBackdropFactory(),
      withId: "com.satra/ios_spotlight_backdrop",
      gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicyWaitUntilTouchesEnded
    )
    registrar.register(
      IOSPinKeypadFactory(messenger: registrar.messenger()),
      withId: "com.satra/ios_pin_keypad"
    )

    let channel = FlutterMethodChannel(
      name: "com.satra/ios_glass_surface",
      binaryMessenger: registrar.messenger()
    )
    let spotlightChannel = FlutterMethodChannel(
      name: "com.satra/ios_spotlight_backdrop",
      binaryMessenger: registrar.messenger()
    )
    let instance = IOSGlassSurfacePlugin()
    instance.channel = channel
    instance.spotlightBackdropChannel = spotlightChannel
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
    spotlightChannel.setMethodCallHandler { call, result in
      if call.method == "update",
        let dict = call.arguments as? [String: Any],
        let viewId = (dict["viewId"] as? NSNumber)?.int64Value
      {
        IOSGlassSurfaceRegistry.shared.updateSpotlightBackdrop(viewId: viewId, arguments: dict)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

private extension UIColor {
  convenience init(satraARGB argb: UInt32) {
    self.init(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }
}

private final class IOSGlassControlFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    IOSGlassControlPlatformView(frame: frame, id: viewId, arguments: args, messenger: messenger)
  }
}

private final class IOSGlassControlContainerView: UIView {
  weak var passthroughTabBar: UITabBar?
  weak var hostedController: UIViewController?
  var registersBackdropSampling = false

  deinit {
    if registersBackdropSampling {
      IOSGlassSurfaceRegistry.shared.unregisterBackdropView(self)
    }
    detachHostedController()
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    if let tabBar = passthroughTabBar {
      let local = convert(point, to: tabBar)
      guard let hit = tabBar.hitTest(local, with: event) else { return false }
      return hit !== tabBar
    }
    return super.point(inside: point, with: event)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let tabBar = passthroughTabBar {
      let local = convert(point, to: tabBar)
      guard let hit = tabBar.hitTest(local, with: event), hit !== tabBar else { return nil }
      return hit
    }
    return super.hitTest(point, with: event)
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
      detachHostedController()
    }
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    if registersBackdropSampling {
      satraUnblockAncestorBackdropSampling()
      IOSGlassSurfaceRegistry.shared.syncObserverState()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      attachHostedControllerIfNeeded()
      if registersBackdropSampling {
        satraUnblockAncestorBackdropSampling()
        IOSGlassSurfaceRegistry.shared.syncObserverState()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if registersBackdropSampling {
      satraUnblockAncestorBackdropSampling()
    }
  }

  private func attachHostedControllerIfNeeded() {
    guard let child = hostedController, child.parent == nil,
      let parent = nearestViewController()
    else { return }
    parent.addChild(child)
    child.didMove(toParent: parent)
  }

  private func detachHostedController() {
    guard let child = hostedController, child.parent != nil else { return }
    child.willMove(toParent: nil)
    child.removeFromParent()
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = next
    while let current = responder {
      if let vc = current as? UIViewController {
        return vc
      }
      responder = current.next
    }
    return window?.rootViewController
  }
}

private final class IOSGlassTabBarController: UITabBarController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.clipsToBounds = false
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    view.backgroundColor = .clear
    view.isOpaque = false
    for subview in view.subviews where subview !== tabBar {
      subview.backgroundColor = .clear
      subview.isOpaque = false
      subview.isUserInteractionEnabled = false
    }
  }
}

private final class IOSGlassControlPlatformView: NSObject, FlutterPlatformView, UITabBarControllerDelegate {
  private struct Tab: Equatable {
    let id: String
    let label: String
  }

  private let container: IOSGlassControlContainerView
  private let channel: FlutterMethodChannel
  private let button = UIButton(type: .system)
  private let progress = UIProgressView(progressViewStyle: .bar)
  private var tabBarController: IOSGlassTabBarController?
  private var refreshView: IOSGlassRefreshView?
  private var tabs: [Tab] = []
  private var selectedTabID: String?
  private var hidesLabels = false
  private var separateSearch = false
  private var didDispatchSearchInShouldSelect = false
  private var quickPickerLabel: String?
  private var displaysTabs = false
  private lazy var libraryHold = UILongPressGestureRecognizer(
    target: self, action: #selector(didHoldLibrary(_:))
  )

  private var activeTabBar: UITabBar? { tabBarController?.tabBar }

  init(frame: CGRect, id: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
    container = IOSGlassControlContainerView(frame: frame)
    container.backgroundColor = .clear
    container.isOpaque = false
    container.clipsToBounds = false
    channel = FlutterMethodChannel(name: "com.satra/ios_glass_control/\(id)", binaryMessenger: messenger)
    super.init()

    let args = arguments as? [String: Any] ?? [:]
    displaysTabs = args["kind"] as? String == "tabBar"
    if args["kind"] as? String == "refresh" {
      let refresh = IOSGlassRefreshView()
      refreshView = refresh
      container.isUserInteractionEnabled = false
      mount(refresh)
    } else if displaysTabs {
      // Host a genuine UITabBarController (the exact controller backing SwiftUI
      // TabView on iOS 26/27) so the floating Liquid Glass dock gets Apple's
      // native vertical placement, platter height, per-tab width, and system
      // blue active highlight automatically in portrait and landscape.
      let controller = IOSGlassTabBarController()
      if #available(iOS 18.0, *) {
        controller.mode = .tabBar
      }
      controller.delegate = self
      controller.tabBar.itemPositioning = .automatic
      controller.tabBar.tintColor = .systemBlue
      libraryHold.delegate = self
      controller.tabBar.addGestureRecognizer(libraryHold)
      tabBarController = controller
      container.hostedController = controller
      container.passthroughTabBar = controller.tabBar
      container.registersBackdropSampling = true
      IOSGlassSurfaceRegistry.shared.registerBackdropView(container)
      mount(controller.view)
    } else {
      button.backgroundColor = .clear
      button.isOpaque = false
      button.addTarget(self, action: #selector(didPressButton), for: .primaryActionTriggered)
      mount(button)
      progress.translatesAutoresizingMaskIntoConstraints = false
      progress.isUserInteractionEnabled = false
      progress.isAccessibilityElement = false
      button.addSubview(progress)
      NSLayoutConstraint.activate([
        progress.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 18),
        progress.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -18),
        progress.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -5),
      ])
    }

    update(args)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update", let args = call.arguments as? [String: Any] {
        self?.update(args)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView { container }

  private func mount(_ control: UIView, horizontalExtension: CGFloat = 0, verticalOffset: CGFloat = 0) {
    control.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -horizontalExtension),
      control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: horizontalExtension),
      control.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalOffset),
      control.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: verticalOffset),
    ])
  }

  private func update(_ args: [String: Any]) {
    let style: UIUserInterfaceStyle = (args["dark"] as? Bool ?? false) ? .dark : .light
    container.overrideUserInterfaceStyle = style
    tabBarController?.overrideUserInterfaceStyle = style
    container.semanticContentAttribute = (args["rtl"] as? Bool ?? false) ? .forceRightToLeft : .forceLeftToRight
    if let refreshView {
      refreshView.update(args)
    } else if displaysTabs {
      updateTabs(args)
    } else {
      updateButton(args)
    }
  }

  private func updateButton(_ args: [String: Any]) {
    let chromeless = args["chromeless"] as? Bool ?? false
    var configuration: UIButton.Configuration
    if chromeless {
      configuration = .plain()
      configuration.background.backgroundColor = .clear
      configuration.baseBackgroundColor = .clear
    } else {
      configuration = .gray()
      #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
          configuration = .glass()
        }
      #endif
      configuration.cornerStyle = .capsule
    }
    configuration.contentInsets = .zero
    configuration.imagePadding = 7
    configuration.imagePlacement = .trailing
    if let symbol = args["symbol"] as? String {
      let size = (args["symbolSize"] as? NSNumber)?.doubleValue ?? 21
      let weight: UIImage.SymbolWeight = (args["regularSymbolWeight"] as? Bool ?? false) ? .regular : .semibold
      configuration.image = UIImage(
        systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight)
      )
    }
    configuration.title = args["title"] as? String
    configuration.showsActivityIndicator = args["activity"] as? Bool ?? false
    if let size = (args["titleSize"] as? NSNumber)?.doubleValue {
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
        var updated = attributes
        updated.font = .systemFont(ofSize: size, weight: .semibold)
        return updated
      }
    }
    if let color = (args["foreground"] as? NSNumber)?.uint32Value {
      configuration.baseForegroundColor = UIColor(satraARGB: color)
    }
    button.configuration = configuration
    button.accessibilityLabel = args["label"] as? String
    button.isEnabled = args["enabled"] as? Bool ?? false
    progress.isHidden = args["progress"] == nil
    progress.progress = (args["progress"] as? NSNumber)?.floatValue ?? 0
    progress.progressTintColor = configuration.baseForegroundColor ?? .label

    let actions = (args["menu"] as? [[String: Any]] ?? []).compactMap { entry -> UIAction? in
      guard let id = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
      let image = (entry["symbol"] as? String).flatMap { UIImage(systemName: $0) }
      return UIAction(title: label, image: image) { [weak self] _ in
        self?.channel.invokeMethod("menuSelected", arguments: id)
      }
    }
    button.menu = actions.isEmpty ? nil : UIMenu(children: actions)
    button.showsMenuAsPrimaryAction = !actions.isEmpty
  }

  private func updateTabs(_ args: [String: Any]) {
    guard let tabBarController else { return }
    let nextTabs = (args["tabs"] as? [[String: String]] ?? []).compactMap { entry -> Tab? in
      guard let id = entry["id"], let label = entry["label"] else { return nil }
      return Tab(id: id, label: label)
    }
    let nextHidesLabels = args["hideLabels"] as? Bool ?? false
    let nextSeparateSearch = args["separateSearch"] as? Bool ?? false
    let nextQuickPickerLabel = args["quickPicker"] as? String
    if tabs != nextTabs || hidesLabels != nextHidesLabels || separateSearch != nextSeparateSearch
      || quickPickerLabel != nextQuickPickerLabel
    {
      tabs = nextTabs
      hidesLabels = nextHidesLabels
      separateSearch = nextSeparateSearch
      quickPickerLabel = nextQuickPickerLabel
      libraryHold.isEnabled = quickPickerLabel != nil

      let symbols: [String: (String, String)] = [
        "discover": ("house", "house.fill"),
        "libraries": ("play.rectangle.on.rectangle", "play.rectangle.on.rectangle.fill"),
        "liveTv": ("tv", "tv.fill"),
        "explore": ("safari", "safari.fill"),
        "downloads": ("arrow.down", "arrow.down"),
        "settings": ("gearshape", "gearshape.fill"),
        "search": ("magnifyingglass", "magnifyingglass"),
      ]

      func makePlaceholderVC() -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isOpaque = false
        vc.view.isUserInteractionEnabled = false
        return vc
      }

      if #available(iOS 18.0, *) {
        let uiTabs: [UITab] = tabs.map { tab in
          if tab.id == "search" && separateSearch {
            let searchTab = UISearchTab { _ in makePlaceholderVC() }
            #if compiler(>=6.2)
              if #available(iOS 26.0, *) {
                // On iOS 26/27, UISearchTab receives the separated circular Liquid Glass
                // Search orb treatment when automaticallyActivatesSearch is enabled (and
                // via prominentTabIdentifier on iOS 27+). Because its placeholder VC has no
                // UISearchController, selecting it highlights the orb without spawning a
                // native UIKit search bar.
                searchTab.automaticallyActivatesSearch = true
              }
            #endif
            searchTab.accessibilityLabel = tab.label
            return searchTab
          }
          let (normalSymbol, selectedSymbol) = symbols[tab.id] ?? ("circle", "circle.fill")
          let uiTab = UITab(
            title: hidesLabels ? "" : tab.label,
            image: UIImage(systemName: normalSymbol),
            identifier: tab.id
          ) { _ in makePlaceholderVC() }
          #if compiler(>=6.2)
            if #available(iOS 26.1, *) {
              uiTab.selectedImage = UIImage(systemName: selectedSymbol)
            }
          #endif
          uiTab.accessibilityLabel = tab.label
          if tab.id == "libraries", let quickPickerLabel {
            uiTab.accessibilityCustomActions = [
              UIAccessibilityCustomAction(name: quickPickerLabel) { [weak self] _ in
                self?.channel.invokeMethod("librariesHeld", arguments: nil)
                return self != nil
              }
            ]
          }
          return uiTab
        }
        tabBarController.setTabs(uiTabs, animated: false)
        #if compiler(>=6.2)
          if #available(iOS 27.0, *) {
            let prominentID = separateSearch
              ? uiTabs.first(where: { $0 is UISearchTab })?.identifier
              : nil
            tabBarController.setProminentTabIdentifier(prominentID, animated: false)
          }
        #endif
        tabBarController.tabBar.setNeedsLayout()
      } else {
        let controllers: [UIViewController] = tabs.enumerated().map { index, tab in
          let vc = makePlaceholderVC()
          let (normalSymbol, selectedSymbol) = symbols[tab.id] ?? ("circle", "circle.fill")
          let item = UITabBarItem(
            title: hidesLabels ? nil : tab.label,
            image: UIImage(systemName: normalSymbol),
            selectedImage: UIImage(systemName: selectedSymbol)
          )
          item.tag = index
          item.accessibilityLabel = tab.label
          if tab.id == "libraries", let quickPickerLabel {
            item.accessibilityCustomActions = [
              UIAccessibilityCustomAction(name: quickPickerLabel) { [weak self] _ in
                self?.channel.invokeMethod("librariesHeld", arguments: nil)
                return self != nil
              }
            ]
          }
          vc.tabBarItem = item
          return vc
        }
        tabBarController.setViewControllers(controllers, animated: false)
      }
    }

    let selectedID = args["selected"] as? String
    selectedTabID = selectedID
    if #available(iOS 18.0, *) {
      let target: UITab?
      if selectedID == "search" {
        target = tabBarController.tabs.first(where: { $0 is UISearchTab || $0.identifier == "search" })
      } else {
        target =
          selectedID.flatMap { tabBarController.tab(forIdentifier: $0) }
          ?? tabBarController.tabs.first(where: { !($0 is UISearchTab) && $0.identifier != "search" })
      }
      if let target, tabBarController.selectedTab !== target {
        tabBarController.selectedTab = target
      }
    } else if let controllers = tabBarController.viewControllers, !controllers.isEmpty {
      let index = tabs.firstIndex(where: { $0.id == selectedID }) ?? 0
      if tabBarController.selectedIndex != index {
        tabBarController.selectedIndex = index
      }
    }
  }

  @objc private func didPressButton() {
    guard button.menu == nil else { return }
    channel.invokeMethod("pressed", arguments: nil)
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    if tab is UISearchTab || tab.identifier == "search" {
      didDispatchSearchInShouldSelect = true
      selectedTabID = "search"
      channel.invokeMethod("searchPressed", arguments: nil)
      return true
    }
    if tab === tabBarController.selectedTab {
      channel.invokeMethod("selected", arguments: tab.identifier)
      return false
    }
    return true
  }

  @available(iOS 18.0, *)
  func tabBarController(
    _ tabBarController: UITabBarController,
    didSelectTab selectedTab: UITab,
    previousTab: UITab?
  ) {
    if selectedTab is UISearchTab || selectedTab.identifier == "search" {
      let alreadyDispatched = didDispatchSearchInShouldSelect
      didDispatchSearchInShouldSelect = false
      selectedTabID = "search"
      if !alreadyDispatched {
        channel.invokeMethod("searchPressed", arguments: nil)
      }
      return
    }
    didDispatchSearchInShouldSelect = false
    selectedTabID = selectedTab.identifier
    channel.invokeMethod("selected", arguments: selectedTab.identifier)
  }

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
    guard let index = tabBarController.viewControllers?.firstIndex(of: viewController),
      tabs.indices.contains(index)
    else { return true }
    let tab = tabs[index]
    if tab.id == "search" {
      didDispatchSearchInShouldSelect = true
      selectedTabID = "search"
      channel.invokeMethod("searchPressed", arguments: nil)
      return true
    }
    if viewController === tabBarController.selectedViewController {
      channel.invokeMethod("selected", arguments: tab.id)
      return false
    }
    return true
  }

  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    guard let index = tabBarController.viewControllers?.firstIndex(of: viewController),
      tabs.indices.contains(index)
    else { return }
    let tab = tabs[index]
    if tab.id == "search" {
      let alreadyDispatched = didDispatchSearchInShouldSelect
      didDispatchSearchInShouldSelect = false
      selectedTabID = "search"
      if !alreadyDispatched {
        channel.invokeMethod("searchPressed", arguments: nil)
      }
      return
    }
    didDispatchSearchInShouldSelect = false
    selectedTabID = tab.id
    channel.invokeMethod("selected", arguments: tab.id)
  }

  @objc private func didHoldLibrary(_ recognizer: UILongPressGestureRecognizer) {
    if recognizer.state == .began {
      channel.invokeMethod("librariesHeld", arguments: nil)
    }
  }
}

private final class IOSGlassRefreshView: UIVisualEffectView {
  private let arrow = UIImageView(image: UIImage(systemName: "arrow.clockwise"))
  private let spinner = UIActivityIndicatorView(style: .medium)

  init() {
    var material: UIVisualEffect = UIBlurEffect(style: .systemMaterial)
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        material = UIGlassEffect(style: .regular)
      }
    #endif
    super.init(effect: material)
    if #available(iOS 26.0, *) {
      cornerConfiguration = .capsule()
    } else {
      layer.cornerRadius = 22
      clipsToBounds = true
    }
    arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    arrow.tintColor = .label
    spinner.color = .label
    for view in [arrow, spinner] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
      NSLayoutConstraint.activate([
        view.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        view.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      ])
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(_ args: [String: Any]) {
    let refreshing = args["refreshing"] as? Bool ?? false
    let progress = (args["progress"] as? NSNumber)?.doubleValue ?? 0
    arrow.isHidden = refreshing
    arrow.transform = CGAffineTransform(rotationAngle: .pi * (progress - 1))
    if refreshing { spinner.startAnimating() } else { spinner.stopAnimating() }
    isAccessibilityElement = refreshing
    accessibilityLabel = args["label"] as? String
  }
}

extension IOSGlassControlPlatformView: UIGestureRecognizerDelegate {
  private static func collectTabControlFrames(in root: UIView, coordinateSpace: UIView) -> [CGRect] {
    var result: [CGRect] = []
    for subview in root.subviews where !subview.isHidden && subview.alpha > 0.01 && !subview.bounds.isEmpty {
      if subview is UIControl {
        result.append(subview.convert(subview.bounds, to: coordinateSpace))
      } else {
        result.append(contentsOf: collectTabControlFrames(in: subview, coordinateSpace: coordinateSpace))
      }
    }
    return result
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let tabBar = activeTabBar,
      let index = tabs.firstIndex(where: { $0.id == "libraries" }),
      tabBar.bounds.width > 0
    else {
      return false
    }
    let location = gestureRecognizer.location(in: tabBar)
    let controlFrames = Self.collectTabControlFrames(in: tabBar, coordinateSpace: tabBar)
      .sorted { $0.midX < $1.midX }
    let visualIndex =
      tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft
      ? tabs.count - 1 - index : index
    if controlFrames.count == tabs.count {
      return controlFrames[visualIndex].contains(location)
    }
    let locationInContainer = gestureRecognizer.location(in: container)
    let itemWidth = container.bounds.width / CGFloat(tabs.count)
    return itemWidth > 0 && container.bounds.contains(locationInContainer)
      && Int(locationInContainer.x / itemWidth) == visualIndex
  }
}

// MARK: - SwiftUI Mobile Spotlight Backdrop (`com.satra/ios_spotlight_backdrop`)

private final class IOSSpotlightBackdropModel: ObservableObject {
  @Published var isDark: Bool = true
  @Published var progress: Double = 1.0
  @Published var accentColor: Color = Color(red: 0.45, green: 0.65, blue: 1.0)
}

private struct IOSSpotlightBackdropSwiftUIView: View {
  @ObservedObject var model: IOSSpotlightBackdropModel

  var body: some View {
    let p = min(max(model.progress, 0.0), 1.0)
    ZStack {
      Rectangle()
        .fill(model.isDark ? Material.thinMaterial : Material.regularMaterial)
        .opacity(p)

      RadialGradient(
        colors: [
          model.accentColor.opacity((model.isDark ? 0.16 : 0.11) * p),
          .clear,
        ],
        center: UnitPoint(x: 0.5, y: 0.06),
        startRadius: 8,
        endRadius: 420
      )

      LinearGradient(
        colors: model.isDark
          ? [
            Color.black.opacity(0.46 * p),
            Color.black.opacity(0.34 * p),
            Color.black.opacity(0.56 * p),
          ]
          : [
            Color.white.opacity(0.46 * p),
            Color.white.opacity(0.32 * p),
            Color.white.opacity(0.50 * p),
          ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .ignoresSafeArea()
    .preferredColorScheme(model.isDark ? .dark : .light)
    .allowsHitTesting(false)
  }
}

private final class IOSSpotlightBackdropView: UIView {
  private let viewId: Int64
  private let model = IOSSpotlightBackdropModel()
  private let hostingController: UIHostingController<IOSSpotlightBackdropSwiftUIView>

  init(viewId: Int64, arguments: Any?) {
    self.viewId = viewId
    self.hostingController = UIHostingController(rootView: IOSSpotlightBackdropSwiftUIView(model: model))
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    autoresizesSubviews = true

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }
    let hostedView = hostingController.view!
    hostedView.frame = bounds
    hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostedView.backgroundColor = .clear
    hostedView.isOpaque = false
    hostedView.isUserInteractionEnabled = false
    addSubview(hostedView)

    apply(arguments: arguments)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    IOSGlassSurfaceRegistry.shared.unregisterSpotlightBackdrop(viewId: viewId, view: self)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    satraUnblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    satraUnblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if hostingController.view.frame != bounds {
      hostingController.view.frame = bounds
    }
    satraUnblockAncestorBackdropSampling()
  }

  func apply(arguments: Any?) {
    let dict = arguments as? [String: Any]
    let dark = dict?["dark"] as? Bool ?? true
    let progress = min(max((dict?["progress"] as? NSNumber)?.doubleValue ?? 1.0, 0.0), 1.0)
    let accentArgb = (dict?["accentArgb"] as? NSNumber)?.uint32Value

    let style: UIUserInterfaceStyle = dark ? .dark : .light
    if overrideUserInterfaceStyle != style {
      overrideUserInterfaceStyle = style
    }
    if hostingController.overrideUserInterfaceStyle != style {
      hostingController.overrideUserInterfaceStyle = style
    }

    model.isDark = dark
    model.progress = progress
    if let accentArgb {
      model.accentColor = Color(uiColor: UIColor(satraARGB: accentArgb))
    }
    satraUnblockAncestorBackdropSampling()
  }
}

private final class IOSSpotlightBackdropPlatformView: NSObject, FlutterPlatformView {
  private let containerView: IOSSpotlightBackdropView

  init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) {
    containerView = IOSSpotlightBackdropView(viewId: viewId, arguments: args)
    containerView.frame = frame
    super.init()
    IOSGlassSurfaceRegistry.shared.registerSpotlightBackdrop(viewId: viewId, view: containerView)
  }

  func view() -> UIView {
    containerView
  }
}

private final class IOSSpotlightBackdropFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    IOSSpotlightBackdropPlatformView(frame: frame, viewIdentifier: viewId, arguments: args)
  }
}

// MARK: - SwiftUI Native PIN Unlock Keypad (`com.satra/ios_pin_keypad`)

private struct IOSPinShakeEffect: GeometryEffect {
  var travelDistance: CGFloat = 11
  var shakesPerUnit: CGFloat = 3
  var animatableData: CGFloat

  func effectValue(size: CGSize) -> ProjectionTransform {
    let offset = travelDistance * sin(animatableData * .pi * shakesPerUnit)
    return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
  }
}

private final class IOSPinKeypadModel: ObservableObject {
  @Published var userName: String = ""
  @Published var subtitle: String = ""
  @Published var errorMessage: String?
  @Published var cancelLabel: String = "Cancel"
  @Published var deleteLabel: String = "Delete"
  @Published var isDark: Bool = true
  @Published var accentColor: Color = .accentColor
  @Published var digits: String = ""
  @Published var shakeTrigger: Int = 0
  @Published var appeared: Bool = false
  @Published var isSubmitting: Bool = false

  var onSubmit: ((String) -> Void)?
  var onCancel: (() -> Void)?

  private var lastAppliedError: String?

  func apply(_ args: [String: Any], initial: Bool = false) {
    let nextUser = args["userName"] as? String ?? userName
    let nextSubtitle = args["subtitle"] as? String ?? subtitle
    let nextCancel = args["cancelLabel"] as? String ?? cancelLabel
    let nextDelete = args["deleteLabel"] as? String ?? deleteLabel
    let nextDark = args["dark"] as? Bool ?? isDark
    let nextError = args["errorMessage"] as? String

    userName = nextUser
    subtitle = nextSubtitle
    cancelLabel = nextCancel
    deleteLabel = nextDelete
    isDark = nextDark
    if let accentArgb = (args["accentArgb"] as? NSNumber)?.uint32Value {
      accentColor = Color(uiColor: UIColor(satraARGB: accentArgb))
    }

    let trimmedError = (nextError?.isEmpty == true) ? nil : nextError
    errorMessage = trimmedError
    if let trimmedError, (initial || trimmedError != lastAppliedError) {
      digits = ""
      isSubmitting = false
      DispatchQueue.main.asyncAfter(deadline: .now() + (initial ? 0.14 : 0.02)) { [weak self] in
        guard let self = self else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.44)) {
          self.shakeTrigger += 1
        }
      }
    }
    lastAppliedError = trimmedError
  }

  func appendDigit(_ digit: Int) {
    guard !isSubmitting, digits.count < 4 else { return }
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) {
      digits.append(String(digit))
    }
    if digits.count == 4 {
      isSubmitting = true
      let pin = digits
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
        self?.onSubmit?(pin)
      }
    }
  }

  func deleteLastDigit() {
    guard !isSubmitting, !digits.isEmpty else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
      digits.removeLast()
    }
  }

  func cancel() {
    guard !isSubmitting else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    onCancel?()
  }
}

private struct IOSPinCircleKeyStyle: ButtonStyle {
  let diameter: CGFloat
  let isDark: Bool

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    configuration.label
      .frame(width: diameter, height: diameter)
      .background(keySurface(pressed: pressed))
      .scaleEffect(pressed ? 0.92 : 1.0)
      .animation(.easeOut(duration: 0.10), value: pressed)
  }

  @ViewBuilder
  private func keySurface(pressed: Bool) -> some View {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      Circle()
        .fill(
          pressed
            ? (isDark ? Color.white.opacity(0.24) : Color.black.opacity(0.14))
            : (isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.22))
        )
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      legacyCircleSurface(pressed: pressed)
    }
    #else
    legacyCircleSurface(pressed: pressed)
    #endif
  }

  @ViewBuilder
  private func legacyCircleSurface(pressed: Bool) -> some View {
    Circle()
      .fill(isDark ? Material.ultraThinMaterial : Material.regularMaterial)
      .overlay(
        Circle().fill(
          pressed
            ? (isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.14))
            : (isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.32))
        )
      )
      .overlay(
        Circle().strokeBorder(
          isDark ? Color.white.opacity(pressed ? 0.30 : 0.16) : Color.black.opacity(pressed ? 0.16 : 0.08),
          lineWidth: 0.85
        )
      )
  }
}

private struct IOSPinUtilityKeyStyle: ButtonStyle {
  let diameter: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: diameter, height: diameter)
      .opacity(configuration.isPressed ? 0.45 : 1.0)
      .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
      .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
  }
}

private struct IOSPinKeypadSwiftUIView: View {
  @ObservedObject var model: IOSPinKeypadModel

  private static let subletters: [Int: String] = [
    1: "",
    2: "A B C",
    3: "D E F",
    4: "G H I",
    5: "J K L",
    6: "M N O",
    7: "P Q R S",
    8: "T U V",
    9: "W X Y Z",
    0: "",
  ]

  private var primaryText: Color {
    model.isDark ? .white : Color(uiColor: .label)
  }

  private var secondaryText: Color {
    model.isDark ? Color.white.opacity(0.68) : Color(uiColor: .secondaryLabel)
  }

  var body: some View {
    ZStack {
      backgroundLayer

      GeometryReader { geo in
        let isCompactLandscape = geo.size.width > geo.size.height && geo.size.height < 500
        Group {
          if isCompactLandscape {
            landscapeContent(size: geo.size)
          } else {
            portraitContent(size: geo.size)
          }
        }
        .frame(width: geo.size.width, height: geo.size.height)
      }
      .opacity(model.appeared ? 1 : 0)
      .scaleEffect(model.appeared ? 1 : 0.96)
      .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.appeared)
    }
    .preferredColorScheme(model.isDark ? .dark : .light)
    .onAppear {
      model.appeared = true
    }
  }

  private var backgroundLayer: some View {
    ZStack {
      Rectangle()
        .fill(model.isDark ? Material.ultraThinMaterial : Material.regularMaterial)

      RadialGradient(
        colors: [
          model.accentColor.opacity(model.isDark ? 0.15 : 0.09),
          .clear,
        ],
        center: UnitPoint(x: 0.5, y: 0.12),
        startRadius: 12,
        endRadius: 420
      )

      LinearGradient(
        colors: model.isDark
          ? [
            Color.black.opacity(0.46),
            Color.black.opacity(0.36),
            Color.black.opacity(0.60),
          ]
          : [
            Color.white.opacity(0.50),
            Color.white.opacity(0.38),
            Color.white.opacity(0.56),
          ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .ignoresSafeArea()
    .opacity(model.appeared ? 1 : 0)
    .animation(.easeOut(duration: 0.24), value: model.appeared)
  }

  private func portraitContent(size: CGSize) -> some View {
    let maxKeyFromWidth = (size.width - 104) / 3.0
    let maxKeyFromHeight = (size.height - 290) / 4.85
    let keySize = min(78, max(54, min(maxKeyFromWidth, maxKeyFromHeight)))
    let colSpacing = min(24, max(14, keySize * 0.29))
    let rowSpacing = min(18, max(10, keySize * 0.22))
    let showSubletters = keySize >= 60

    return VStack(spacing: 0) {
      Spacer(minLength: 24)
      headerBlock(compact: keySize < 62)
      Spacer().frame(height: keySize < 62 ? 18 : 26)
      passcodeDots
      Spacer().frame(height: keySize < 62 ? 22 : 34)
      keypadGrid(
        keySize: keySize,
        colSpacing: colSpacing,
        rowSpacing: rowSpacing,
        showSubletters: showSubletters,
        showCancelInGrid: true
      )
      Spacer(minLength: 28)
    }
    .padding(.horizontal, 24)
  }

  private func landscapeContent(size: CGSize) -> some View {
    let keySize = min(64, max(46, (size.height - 68) / 4.6))
    let colSpacing = min(18, max(10, keySize * 0.24))
    let rowSpacing = min(12, max(7, keySize * 0.16))

    return HStack(spacing: 32) {
      VStack(spacing: 14) {
        headerBlock(compact: true)
        passcodeDots
        Button(action: { model.cancel() }) {
          Text(model.cancelLabel)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(primaryText.opacity(0.88))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .accessibilityLabel(model.cancelLabel)
      }
      .frame(maxWidth: 230)

      keypadGrid(
        keySize: keySize,
        colSpacing: colSpacing,
        rowSpacing: rowSpacing,
        showSubletters: false,
        showCancelInGrid: false
      )
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }

  private func headerBlock(compact: Bool) -> some View {
    VStack(spacing: compact ? 8 : 11) {
      lockBadge(size: compact ? 40 : 48)
      Text(model.userName)
        .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
        .foregroundColor(primaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.75)

      Group {
        if let error = model.errorMessage {
          Text(error)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundColor(Color(uiColor: .systemRed))
            .multilineTextAlignment(.center)
            .lineLimit(2)
        } else if !model.subtitle.isEmpty {
          Text(model.subtitle)
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(secondaryText)
            .lineLimit(1)
        } else {
          Text(" ")
            .font(.system(size: 14))
            .opacity(0)
        }
      }
      .frame(minHeight: 20)
    }
  }

  @ViewBuilder
  private func lockBadge(size: CGFloat) -> some View {
    let icon = Image(systemName: "lock.fill")
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundColor(primaryText)
      .frame(width: size, height: size)

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      icon
        .background(
          Circle()
            .fill(model.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.28))
            .glassEffect(.regular, in: .circle)
        )
    } else {
      icon
        .background(
          Circle()
            .fill(model.isDark ? Material.ultraThinMaterial : Material.regularMaterial)
            .overlay(
              Circle().strokeBorder(
                model.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.08),
                lineWidth: 0.85
              )
            )
        )
    }
    #else
    icon
      .background(
        Circle()
          .fill(model.isDark ? Material.ultraThinMaterial : Material.regularMaterial)
          .overlay(
            Circle().strokeBorder(
              model.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.08),
              lineWidth: 0.85
            )
          )
      )
    #endif
  }

  private var passcodeDots: some View {
    let filledCount = model.digits.count
    return HStack(spacing: 20) {
      ForEach(0..<4, id: \.self) { index in
        let isFilled = index < filledCount
        let isError = model.errorMessage != nil && filledCount == 0
        Circle()
          .fill(isFilled ? primaryText : Color.clear)
          .overlay(
            Circle().strokeBorder(
              isError
                ? Color(uiColor: .systemRed).opacity(0.85)
                : primaryText.opacity(isFilled ? 1.0 : 0.55),
              lineWidth: isFilled ? 0 : 1.7
            )
          )
          .frame(width: 14, height: 14)
          .scaleEffect(isFilled ? 1.15 : 1.0)
          .shadow(color: isFilled ? primaryText.opacity(model.isDark ? 0.35 : 0.16) : .clear, radius: 6)
          .animation(.spring(response: 0.22, dampingFraction: 0.58), value: isFilled)
      }
    }
    .modifier(IOSPinShakeEffect(animatableData: CGFloat(model.shakeTrigger)))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(filledCount) of 4 digits entered")
  }

  private func keypadGrid(
    keySize: CGFloat,
    colSpacing: CGFloat,
    rowSpacing: CGFloat,
    showSubletters: Bool,
    showCancelInGrid: Bool
  ) -> some View {
    let rows: [[Int]] = [
      [1, 2, 3],
      [4, 5, 6],
      [7, 8, 9],
    ]

    return VStack(spacing: rowSpacing) {
      ForEach(rows, id: \.self) { row in
        HStack(spacing: colSpacing) {
          ForEach(row, id: \.self) { digit in
            digitButton(digit: digit, keySize: keySize, showSubletters: showSubletters)
          }
        }
      }

      HStack(spacing: colSpacing) {
        if showCancelInGrid {
          Button(action: { model.cancel() }) {
            Text(model.cancelLabel)
              .font(.system(size: min(17, max(14, keySize * 0.23)), weight: .medium))
              .foregroundColor(primaryText.opacity(0.90))
              .lineLimit(1)
              .minimumScaleFactor(0.75)
          }
          .buttonStyle(IOSPinUtilityKeyStyle(diameter: keySize))
          .accessibilityLabel(model.cancelLabel)
        } else {
          Color.clear.frame(width: keySize, height: keySize)
        }

        digitButton(digit: 0, keySize: keySize, showSubletters: false)

        Button(action: { model.deleteLastDigit() }) {
          Image(systemName: "delete.left")
            .font(.system(size: min(24, max(19, keySize * 0.32)), weight: .regular))
            .foregroundColor(primaryText.opacity(model.digits.isEmpty ? 0.28 : 0.92))
        }
        .buttonStyle(IOSPinUtilityKeyStyle(diameter: keySize))
        .disabled(model.digits.isEmpty)
        .accessibilityLabel(model.deleteLabel)
      }
    }
  }

  private func digitButton(digit: Int, keySize: CGFloat, showSubletters: Bool) -> some View {
    let letters = Self.subletters[digit] ?? ""
    return Button(action: { model.appendDigit(digit) }) {
      VStack(spacing: 1) {
        Text("\(digit)")
          .font(.system(size: keySize * 0.44, weight: .regular, design: .rounded))
          .foregroundColor(primaryText)
          .monospacedDigit()
        if showSubletters, !letters.isEmpty {
          Text(letters)
            .font(.system(size: max(8.5, keySize * 0.125), weight: .semibold))
            .tracking(1.1)
            .foregroundColor(primaryText.opacity(0.72))
        }
      }
    }
    .buttonStyle(IOSPinCircleKeyStyle(diameter: keySize, isDark: model.isDark))
    .accessibilityLabel("\(digit)")
  }
}

private final class IOSPinKeypadContainerView: UIView {
  private let hostingController: UIHostingController<IOSPinKeypadSwiftUIView>

  init(model: IOSPinKeypadModel) {
    self.hostingController = UIHostingController(rootView: IOSPinKeypadSwiftUIView(model: model))
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    autoresizesSubviews = true

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }
    let hostedView = hostingController.view!
    hostedView.frame = bounds
    hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostedView.backgroundColor = .clear
    hostedView.isOpaque = false
    addSubview(hostedView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    IOSGlassSurfaceRegistry.shared.unregisterBackdropView(self)
  }

  func updateInterfaceStyle(dark: Bool) {
    let style: UIUserInterfaceStyle = dark ? .dark : .light
    if overrideUserInterfaceStyle != style {
      overrideUserInterfaceStyle = style
    }
    if hostingController.overrideUserInterfaceStyle != style {
      hostingController.overrideUserInterfaceStyle = style
    }
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    satraUnblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    satraUnblockAncestorBackdropSampling()
    IOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if hostingController.view.frame != bounds {
      hostingController.view.frame = bounds
    }
    satraUnblockAncestorBackdropSampling()
  }
}

private final class IOSPinKeypadPlatformView: NSObject, FlutterPlatformView {
  private let model = IOSPinKeypadModel()
  private let containerView: IOSPinKeypadContainerView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, id: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
    containerView = IOSPinKeypadContainerView(model: model)
    containerView.frame = frame
    channel = FlutterMethodChannel(name: "com.satra/ios_pin_keypad/\(id)", binaryMessenger: messenger)
    super.init()

    let args = arguments as? [String: Any] ?? [:]
    model.apply(args, initial: true)
    containerView.updateInterfaceStyle(dark: model.isDark)
    IOSGlassSurfaceRegistry.shared.registerBackdropView(containerView)

    model.onSubmit = { [weak self] pin in
      self?.channel.invokeMethod("submit", arguments: pin)
    }
    model.onCancel = { [weak self] in
      self?.channel.invokeMethod("cancel", arguments: nil)
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "update":
        if let dict = call.arguments as? [String: Any] {
          self.model.apply(dict)
          self.containerView.updateInterfaceStyle(dark: self.model.isDark)
        }
        result(nil)
      case "hardwareDigit":
        if let digit = (call.arguments as? NSNumber)?.intValue {
          self.model.appendDigit(digit)
        }
        result(nil)
      case "hardwareBackspace":
        self.model.deleteLastDigit()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    containerView
  }
}

private final class IOSPinKeypadFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    IOSPinKeypadPlatformView(frame: frame, id: viewId, arguments: args, messenger: messenger)
  }
}
