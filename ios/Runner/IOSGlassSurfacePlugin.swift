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
    unblockAncestorBackdropSampling()
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

private final class IOSGlassControlPlatformView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private struct Tab: Equatable {
    let id: String
    let label: String
  }

  private let container: UIView
  private let channel: FlutterMethodChannel
  private let button = UIButton(type: .system)
  private let progress = UIProgressView(progressViewStyle: .bar)
  private let tabBar = UITabBar()
  private var refreshView: IOSGlassRefreshView?
  private var tabs: [Tab] = []
  private var hidesLabels = false
  private var quickPickerLabel: String?
  private var displaysTabs = false
  private lazy var libraryHold = UILongPressGestureRecognizer(
    target: self, action: #selector(didHoldLibrary(_:))
  )

  init(frame: CGRect, id: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    container.isOpaque = false
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
      tabBar.delegate = self
      tabBar.itemPositioning = .fill
      tabBar.tintColor = .label
      libraryHold.delegate = self
      tabBar.addGestureRecognizer(libraryHold)
      // UITabBar reserves its own horizontal margins on iOS 26. Flutter
      // already keeps the row clear of the safe area and detached Search.
      mount(tabBar, horizontalExtension: 19, verticalOffset: 8)
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
    container.overrideUserInterfaceStyle = (args["dark"] as? Bool ?? false) ? .dark : .light
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
    let nextTabs = (args["tabs"] as? [[String: String]] ?? []).compactMap { entry -> Tab? in
      guard let id = entry["id"], let label = entry["label"] else { return nil }
      return Tab(id: id, label: label)
    }
    let nextHidesLabels = args["hideLabels"] as? Bool ?? false
    let nextQuickPickerLabel = args["quickPicker"] as? String
    if tabs != nextTabs || hidesLabels != nextHidesLabels || quickPickerLabel != nextQuickPickerLabel {
      tabs = nextTabs
      hidesLabels = nextHidesLabels
      quickPickerLabel = nextQuickPickerLabel
      libraryHold.isEnabled = quickPickerLabel != nil

      let symbols = [
        "discover": "house", "libraries": "play.rectangle.on.rectangle", "liveTv": "tv",
        "explore": "safari", "downloads": "arrow.down", "settings": "gearshape",
      ]
      tabBar.items = tabs.enumerated().map { index, tab in
        let symbol = symbols[tab.id] ?? "circle"
        let item = UITabBarItem(
          title: hidesLabels ? nil : tab.label,
          image: UIImage(systemName: symbol),
          tag: index
        )
        item.accessibilityLabel = tab.label
        if tab.id == "libraries", let quickPickerLabel {
          item.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: quickPickerLabel) { [weak self] _ in
              self?.channel.invokeMethod("librariesHeld", arguments: nil)
              return self != nil
            }
          ]
        }
        return item
      }
    }

    let selectedID = args["selected"] as? String
    if let items = tabBar.items, !items.isEmpty {
      let index = tabs.firstIndex(where: { $0.id == selectedID }) ?? 0
      tabBar.selectedItem = items[index]
    }
  }

  @objc private func didPressButton() {
    guard button.menu == nil else { return }
    channel.invokeMethod("pressed", arguments: nil)
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard tabs.indices.contains(item.tag) else { return }
    channel.invokeMethod("selected", arguments: tabs[item.tag].id)
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
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == "libraries" }), tabBar.bounds.width > 0 else {
      return false
    }
    let location = gestureRecognizer.location(in: tabBar)
    let controls = tabBar.subviews.compactMap { $0 as? UIControl }
      .filter { !$0.isHidden && !$0.bounds.isEmpty }
      .sorted { $0.frame.midX < $1.frame.midX }
    let visualIndex =
      tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft
      ? tabs.count - 1 - index : index
    if controls.count == tabs.count {
      return controls[visualIndex].frame.contains(location)
    }
    let locationInContainer = gestureRecognizer.location(in: container)
    let itemWidth = container.bounds.width / CGFloat(tabs.count)
    return itemWidth > 0 && container.bounds.contains(locationInContainer)
      && Int(locationInContainer.x / itemWidth) == visualIndex
  }
}
