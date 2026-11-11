import Cocoa
import FlutterMacOS

private struct GlassCornerRadii: Equatable, Hashable {
  let tl: CGFloat
  let tr: CGFloat
  let bl: CGFloat
  let br: CGFloat

  var maxRadius: CGFloat {
    max(max(tl, tr), max(bl, br))
  }

  var isBottomDocked: Bool {
    bl <= 0.5 && br <= 0.5 && (tl > 0.5 || tr > 0.5)
  }

  var isTopDocked: Bool {
    tl <= 0.5 && tr <= 0.5 && (bl > 0.5 || br > 0.5)
  }
}

private enum GlassCornerMaskCache {
  private struct Key: Hashable {
    let tlHalfPts: Int
    let trHalfPts: Int
    let blHalfPts: Int
    let brHalfPts: Int
  }

  private static var cache: [Key: NSImage] = [:]

  static func maskImage(for radii: GlassCornerRadii) -> NSImage? {
    let cap = ceil(radii.maxRadius)
    guard cap > 0.5 else { return nil }

    let key = Key(
      tlHalfPts: Int((radii.tl * 2).rounded()),
      trHalfPts: Int((radii.tr * 2).rounded()),
      blHalfPts: Int((radii.bl * 2).rounded()),
      brHalfPts: Int((radii.br * 2).rounded())
    )
    if let cached = cache[key] {
      return cached
    }

    let side = cap * 2 + 2
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      let w = rect.width
      let h = rect.height
      let tl = min(max(0, radii.tl), cap)
      let tr = min(max(0, radii.tr), cap)
      let bl = min(max(0, radii.bl), cap)
      let br = min(max(0, radii.br), cap)

      // Non-flipped AppKit coordinates: y = 0 is bottom, y = h is top.
      let path = CGMutablePath()
      path.move(to: CGPoint(x: bl, y: 0))
      path.addLine(to: CGPoint(x: w - br, y: 0))
      if br > 0 {
        path.addArc(
          tangent1End: CGPoint(x: w, y: 0),
          tangent2End: CGPoint(x: w, y: br),
          radius: br
        )
      }
      path.addLine(to: CGPoint(x: w, y: h - tr))
      if tr > 0 {
        path.addArc(
          tangent1End: CGPoint(x: w, y: h),
          tangent2End: CGPoint(x: w - tr, y: h),
          radius: tr
        )
      }
      path.addLine(to: CGPoint(x: tl, y: h))
      if tl > 0 {
        path.addArc(
          tangent1End: CGPoint(x: 0, y: h),
          tangent2End: CGPoint(x: 0, y: h - tl),
          radius: tl
        )
      }
      path.addLine(to: CGPoint(x: 0, y: bl))
      if bl > 0 {
        path.addArc(
          tangent1End: CGPoint(x: 0, y: 0),
          tangent2End: CGPoint(x: bl, y: 0),
          radius: bl
        )
      }
      path.closeSubpath()

      if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
      }
      return true
    }
    image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    image.resizingMode = .stretch

    if cache.count >= 64 {
      cache.removeAll(keepingCapacity: true)
    }
    cache[key] = image
    return image
  }
}

@available(macOS 26.0, *)
private final class SatraGlassEffectView: NSGlassEffectView {
  var radii = GlassCornerRadii(tl: 24, tr: 24, bl: 24, br: 24) {
    didSet {
      guard oldValue != radii else { return }
      self.cornerRadius = radii.maxRadius
      if #available(macOS 27.0, *) {
        self.invalidateCornerConfiguration()
      }
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var acceptsFirstResponder: Bool { false }

  @available(macOS 27.0, *)
  override var cornerConfiguration: NSViewCornerConfiguration? {
    .corners(
      topLeftRadius: .fixed(max(0, radii.tl)),
      topRightRadius: .fixed(max(0, radii.tr)),
      bottomLeftRadius: .fixed(max(0, radii.bl)),
      bottomRightRadius: .fixed(max(0, radii.br))
    )
  }
}

private final class SatraVisualEffectView: NSVisualEffectView {
  private static let filterWithTypeSelector = NSSelectorFromString("filterWithType:")
  private var hasCustomBackdropTuning = false

  var blurScale: CGFloat = 1.0 {
    didSet {
      guard abs(oldValue - blurScale) > 0.0005 else { return }
      applyBackdropTuning()
    }
  }

  var backgroundBrightness: CGFloat = 1.0 {
    didSet {
      guard abs(oldValue - backgroundBrightness) > 0.0005 else { return }
      applyBackdropTuning()
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var acceptsFirstResponder: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyBackdropTuning()
  }

  override func updateLayer() {
    super.updateLayer()
    applyBackdropTuning()
  }

  override func layout() {
    super.layout()
    applyBackdropTuning()
  }

  func applyBackdropTuning() {
    let isDefaultBlur = abs(blurScale - 1.0) <= 0.001
    let isDefaultBrightness = abs(backgroundBrightness - 1.0) <= 0.001
    if isDefaultBlur && isDefaultBrightness && !hasCustomBackdropTuning {
      return
    }
    guard let root = self.layer else { return }

    if let bd = Self.findSublayer(named: "backdrop", in: root),
      let filterCls = NSClassFromString("CAFilter") as? NSObject.Type
    {
      let radius = Double(max(0.0, 30.0 * blurScale))
      var updated: [Any] = []
      for raw in (bd.filters ?? []) {
        guard let obj = raw as? NSObject else {
          updated.append(raw)
          continue
        }
        let fname = obj.value(forKey: "name") as? String
        if fname == "satraBrightness" {
          continue
        }
        if fname == "gaussianBlur" || String(describing: obj).contains("gaussianBlur") {
          if let copy = obj.mutableCopy() as? NSObject {
            copy.setValue(radius, forKey: "inputRadius")
            updated.append(copy)
            continue
          }
        }
        updated.append(obj)
      }
      if !isDefaultBrightness,
        filterCls.responds(to: Self.filterWithTypeSelector),
        let bf = filterCls.perform(Self.filterWithTypeSelector, with: "colorBrightness")?
          .takeUnretainedValue() as? NSObject
      {
        bf.setValue("satraBrightness", forKey: "name")
        let delta =
          backgroundBrightness < 1.0
          ? Double(backgroundBrightness - 1.0) * 0.55
          : Double(backgroundBrightness - 1.0) * 0.24
        bf.setValue(delta, forKey: "inputAmount")
        updated.append(bf)
      }
      bd.filters = updated
    }

    if let fill = Self.findSublayer(named: "fill", in: root) {
      if backgroundBrightness > 1.001 {
        fill.opacity = Float(max(0.0, 1.0 - (backgroundBrightness - 1.0)))
      } else {
        fill.opacity = 1.0
      }
    }

    hasCustomBackdropTuning = !(isDefaultBlur && isDefaultBrightness)
  }

  private static func findSublayer(named name: String, in layer: CALayer) -> CALayer? {
    if layer.name == name { return layer }
    for sub in layer.sublayers ?? [] {
      if let found = findSublayer(named: name, in: sub) {
        return found
      }
    }
    return nil
  }
}

/// Hosts native macOS Liquid Glass (`NSGlassEffectView` on macOS 26+) or
/// vibrant within-window AppKit blur (`NSVisualEffectView`), and clears
/// backdrop-isolating `masksToBounds` / `CAShapeLayer` masks on Flutter's
/// platform-view wrapper views so `CABackdropLayer` samples both Flutter's
/// background Metal surface and mpv's native video layer directly underneath.
private final class MacOSGlassSurfaceView: NSView {
  private static let setAllowsGroupBlendingSelector = NSSelectorFromString("setAllowsGroupBlending:")

  private let viewId: Int64
  private var glassEffectView: NSView?
  private var visualEffectView: SatraVisualEffectView?
  private var currentRadii = GlassCornerRadii(tl: 24, tr: 24, bl: 24, br: 24)
  private var currentLiquidGlass = false

  init(viewId: Int64, arguments: Any?) {
    self.viewId = viewId
    super.init(frame: .zero)
    self.wantsLayer = true
    self.autoresizesSubviews = true
    apply(arguments: arguments)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    MacOSGlassSurfaceRegistry.shared.unregister(viewId: viewId, view: self)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var acceptsFirstResponder: Bool { false }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    unblockAncestorBackdropSampling()
    MacOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    unblockAncestorBackdropSampling()
    MacOSGlassSurfaceRegistry.shared.syncObserverState()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutEffectSubviews()
    unblockAncestorBackdropSampling()
  }

  override func layout() {
    super.layout()
    layoutEffectSubviews()
    unblockAncestorBackdropSampling()
  }

  func apply(arguments: Any?) {
    let dict = arguments as? [String: Any]
    let liquidGlass = dict?["liquidGlass"] as? Bool ?? false
    let dark = dict?["dark"] as? Bool ?? true
    let tl = CGFloat((dict?["tl"] as? NSNumber)?.doubleValue ?? 24.0)
    let tr = CGFloat((dict?["tr"] as? NSNumber)?.doubleValue ?? 24.0)
    let bl = CGFloat((dict?["bl"] as? NSNumber)?.doubleValue ?? 24.0)
    let br = CGFloat((dict?["br"] as? NSNumber)?.doubleValue ?? 24.0)
    let visibility = CGFloat(min(max((dict?["visibility"] as? NSNumber)?.doubleValue ?? 1.0, 0.0), 1.0))
    let tintStrength = CGFloat(min(max((dict?["tintStrength"] as? NSNumber)?.doubleValue ?? 0.16, 0.0), 1.0))
    let tintArgb = (dict?["tintArgb"] as? NSNumber)?.uint32Value
    let blurScale = CGFloat(min(max((dict?["blurScale"] as? NSNumber)?.doubleValue ?? 1.0, 0.0), 3.0))
    let backgroundBrightness = CGFloat(
      min(max((dict?["backgroundBrightness"] as? NSNumber)?.doubleValue ?? 1.0, 0.0), 2.5)
    )

    let radii = GlassCornerRadii(tl: tl, tr: tr, bl: bl, br: br)
    self.currentRadii = radii
    self.currentLiquidGlass = liquidGlass
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    if liquidGlass, #available(macOS 26.0, *) {
      if let vev = visualEffectView {
        vev.removeFromSuperview()
        visualEffectView = nil
      }
      let glass: SatraGlassEffectView
      if let existing = glassEffectView as? SatraGlassEffectView {
        glass = existing
      } else {
        let created = SatraGlassEffectView(frame: bounds)
        created.cornerRadius = radii.maxRadius
        addSubview(created)
        glassEffectView = created
        glass = created
      }
      // `.clear` avoids `.regular`'s heavy built-in grey smoke so low opacity
      // settings stay genuinely crystal-clear while `tintColor` scales density.
      glass.style = .clear
      glass.appearance = appearance
      glass.radii = radii
      if let argb = tintArgb, tintStrength > 0.001 {
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        glass.tintColor = NSColor(srgbRed: r, green: g, blue: b, alpha: tintStrength)
      } else {
        glass.tintColor = nil
      }
      glass.alphaValue = visibility
    } else {
      if let gv = glassEffectView {
        gv.removeFromSuperview()
        glassEffectView = nil
      }
      let vev: SatraVisualEffectView
      if let existing = visualEffectView {
        vev = existing
      } else {
        let created = SatraVisualEffectView(frame: bounds)
        created.wantsLayer = true
        created.blendingMode = .withinWindow
        created.state = .active
        addSubview(created)
        visualEffectView = created
        vev = created
      }
      vev.blendingMode = .withinWindow
      vev.state = .active
      vev.material = dark ? .hudWindow : .popover
      vev.appearance = appearance
      vev.maskImage = GlassCornerMaskCache.maskImage(for: radii)
      vev.blurScale = blurScale
      vev.backgroundBrightness = backgroundBrightness
      vev.applyBackdropTuning()
      vev.alphaValue = visibility
    }

    layoutEffectSubviews()
    unblockAncestorBackdropSampling()
    CATransaction.commit()
  }

  private func layoutEffectSubviews() {
    if let vev = visualEffectView {
      if vev.frame != bounds {
        vev.frame = bounds
      }
    }
    if #available(macOS 26.0, *), let glass = glassEffectView as? SatraGlassEffectView {
      var target = bounds
      if #unavailable(macOS 27.0) {
        let ext = currentRadii.maxRadius
        if ext > 0.5 {
          if currentRadii.isBottomDocked {
            target = NSRect(x: 0, y: -ext, width: bounds.width, height: bounds.height + ext)
          } else if currentRadii.isTopDocked {
            target = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + ext)
          }
        }
      }
      if glass.frame != target {
        glass.frame = target
      }
    }
  }

  /// `FlutterMutatorView` defaults `layer.masksToBounds = YES` on an
  /// `NSViewBackingLayer` (`allowsGroupBlending = NO`), which creates an
  /// isolated Core Animation backdrop group that blocks `CABackdropLayer`
  /// from sampling `FlutterSurface` and `MpvVideoContainerLayer` underneath.
  func unblockAncestorBackdropSampling() {
    let contentView = window?.contentView
    var cursor: NSView? = self
    while let view = cursor {
      if let layer = view.layer {
        if view !== contentView && layer.masksToBounds {
          layer.masksToBounds = false
        }
        if view !== contentView && NSStringFromClass(type(of: view)) != "FlutterView" && layer.mask != nil {
          layer.mask = nil
        }
        if layer.responds(to: Self.setAllowsGroupBlendingSelector) {
          layer.setValue(true, forKey: "allowsGroupBlending")
        }
      }
      if view === contentView {
        break
      }
      cursor = view.superview
    }
  }
}

private final class MacOSGlassSurfaceRegistry {
  static let shared = MacOSGlassSurfaceRegistry()

  private let viewsById = NSMapTable<NSNumber, MacOSGlassSurfaceView>.strongToWeakObjects()
  private let allViews = NSHashTable<MacOSGlassSurfaceView>.weakObjects()
  private var runLoopObserver: CFRunLoopObserver?

  func register(viewId: Int64, view: MacOSGlassSurfaceView) {
    viewsById.setObject(view, forKey: NSNumber(value: viewId))
    allViews.add(view)
    syncObserverState()
  }

  func unregister(viewId: Int64, view: MacOSGlassSurfaceView) {
    if viewsById.object(forKey: NSNumber(value: viewId)) === view {
      viewsById.removeObject(forKey: NSNumber(value: viewId))
    }
    allViews.remove(view)
    syncObserverState()
  }

  func update(viewId: Int64, arguments: Any?) {
    viewsById.object(forKey: NSNumber(value: viewId))?.apply(arguments: arguments)
  }

  func syncObserverState() {
    let hasWindowedViews = allViews.allObjects.contains { $0.window != nil }
    if hasWindowedViews && runLoopObserver == nil {
      // Order 1,999,900 runs immediately before Core Animation's implicit
      // CATransaction commit (order 2,000,000), clearing any `masksToBounds`
      // restored by `FlutterMutatorView.applyFlutterLayer:` on the same frame.
      let observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault,
        CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
        true,
        1_999_900
      ) { [weak self] _, _ in
        guard let self else { return }
        for view in self.allViews.allObjects where view.window != nil {
          view.unblockAncestorBackdropSampling()
        }
      }
      if let observer {
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
      }
    } else if !hasWindowedViews, let observer = runLoopObserver {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      runLoopObserver = nil
    }
  }
}

private final class MacOSGlassSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let view = MacOSGlassSurfaceView(viewId: viewId, arguments: args)
    MacOSGlassSurfaceRegistry.shared.register(viewId: viewId, view: view)
    return view
  }
}

class ForwardingView: NSView {
  weak var flutterViewController: NSViewController?

  override func mouseDown(with event: NSEvent) {
    flutterViewController?.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    flutterViewController?.mouseUp(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    flutterViewController?.scrollWheel(with: event)
  }
}

class ForwardingToolbar: NSToolbar, NSToolbarDelegate {
  let flutterViewController: NSViewController

  init(flutterViewController: NSViewController) {
    self.flutterViewController = flutterViewController
    super.init(identifier: "ForwardingToolbar")
    self.delegate = self
    self.showsBaselineSeparator = false

    self.allowsUserCustomization = false
    self.allowsExtensionItems = false
    if #available(macOS 15.0, *) {
      self.allowsDisplayModeCustomization = false
    }
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, NSToolbarItem.Identifier("ForwardingItem")]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if itemIdentifier == NSToolbarItem.Identifier("ForwardingItem") {
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      let view = ForwardingView()
      view.flutterViewController = flutterViewController
      view.widthAnchor.constraint(lessThanOrEqualToConstant: 100000).isActive = true
      view.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
      item.isBordered = false
      item.view = view
      return item
    }
    return nil
  }
}

// MARK: - WindowUtilsPlugin
class WindowUtilsPlugin: NSObject, FlutterPlugin {
  private static var instance: WindowUtilsPlugin?
  private var channel: FlutterMethodChannel?
  private var glassChannel: FlutterMethodChannel?
  private weak var window: NSWindow?
  private var windowDelegate: WindowDelegate?
  private var originalButtonConstraints: [NSWindow.ButtonType: [NSLayoutConstraint]] = [:]

  private static let customButtonPositions: [(NSWindow.ButtonType, CGPoint)] = [
    (.closeButton, CGPoint(x: 20, y: 21)),
    (.miniaturizeButton, CGPoint(x: 40, y: 21)),
    (.zoomButton, CGPoint(x: 60, y: 21)),
  ]

  static func register(with registrar: FlutterPluginRegistrar) {
    let glassFactory = MacOSGlassSurfaceFactory()
    registrar.register(glassFactory, withId: "com.satra/macos_glass_surface")
    registrar.register(glassFactory, withId: "com.satra/video_sheet_blur")
    let glassChannel = FlutterMethodChannel(
      name: "com.satra/macos_glass_surface",
      binaryMessenger: registrar.messenger
    )
    glassChannel.setMethodCallHandler { call, result in
      if call.method == "update",
        let dict = call.arguments as? [String: Any],
        let viewId = (dict["viewId"] as? NSNumber)?.int64Value
      {
        MacOSGlassSurfaceRegistry.shared.update(viewId: viewId, arguments: dict)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    let channel = FlutterMethodChannel(
      name: "com.satra/window_utils",
      binaryMessenger: registrar.messenger
    )
    let instance = WindowUtilsPlugin()
    instance.channel = channel
    instance.glassChannel = glassChannel
    registrar.addMethodCallDelegate(instance, channel: channel)
    self.instance = instance
  }

  static func setWindow(_ window: NSWindow) {
    instance?.window = window
    instance?.windowDelegate?.window = window
  }

  static func installWindowDelegate() {
    guard let instance = instance, let window = instance.window else { return }
    instance.installWindowDelegate(window: window)
  }

  static func syncWindowChrome() {
    guard let instance = instance else { return }
    instance.syncWindowChrome()
  }

  /// Apply traffic light positions. Called by WindowDelegate during fullscreen transitions.
  static func setTrafficLightPositions(custom: Bool, window: NSWindow) {
    guard let instance = instance else { return }
    instance.applyTrafficLightPositions(custom: custom, window: window)
  }

  static func setTrafficLightsVisible(_ visible: Bool, window: NSWindow) {
    for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(buttonType)?.isHidden = !visible
    }
  }

  private func applyTrafficLightPositions(custom: Bool, window: NSWindow) {
    if custom {
      for (buttonType, offset) in WindowUtilsPlugin.customButtonPositions {
        overrideButtonPosition(window: window, buttonType: buttonType, offset: offset)
      }
    } else {
      for (buttonType, _) in WindowUtilsPlugin.customButtonPositions {
        resetButtonPosition(window: window, buttonType: buttonType)
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window = window else {
      result(FlutterError(code: "NO_WINDOW", message: "Window not available", details: nil))
      return
    }

    switch call.method {
    case "initialize":
      let args = call.arguments as? [String: Any]
      let enableWindowDelegate = args?["enableWindowDelegate"] as? Bool ?? false
      initialize(window: window, enableWindowDelegate: enableWindowDelegate)
      result(nil)

    case "setTrafficLightsVisible":
      let args = call.arguments as? [String: Any]
      let visible = args?["visible"] as? Bool ?? true
      WindowUtilsPlugin.setTrafficLightsVisible(visible, window: window)
      result(nil)

    case "syncWindowChrome":
      syncWindowChrome()
      result(nil)

    case "enterFullscreen":
      if !window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
      }
      result(nil)

    case "exitFullscreen":
      if window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
      }
      result(nil)

    case "isFullscreen":
      result(window.styleMask.contains(.fullScreen))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initialize(window: NSWindow, enableWindowDelegate: Bool) {
    self.window = window

    if enableWindowDelegate {
      installWindowDelegate(window: window)
    }

    windowDelegate?.syncWindowChrome()
  }

  private func installWindowDelegate(window: NSWindow) {
    let delegate = windowDelegate ?? WindowDelegate()
    delegate.channel = channel
    delegate.window = window
    windowDelegate = delegate
    window.delegate = delegate
  }

  private func syncWindowChrome() {
    guard let window = window else { return }
    if windowDelegate == nil {
      installWindowDelegate(window: window)
    } else {
      windowDelegate?.channel = channel
      windowDelegate?.window = window
      window.delegate = windowDelegate
    }
    windowDelegate?.syncWindowChrome()
  }

  private func withButton(
    _ buttonType: NSWindow.ButtonType,
    in window: NSWindow,
    action: (NSButton, NSView) -> Void
  ) {
    guard let button = window.standardWindowButton(buttonType),
      let superview = button.superview
    else { return }
    action(button, superview)
  }

  private func positionConstraints(for button: NSButton, in superview: NSView)
    -> [NSLayoutConstraint]
  {
    superview.constraints.filter { constraint in
      ((constraint.firstItem as? NSButton) == button
        || (constraint.secondItem as? NSButton) == button)
        && (constraint.firstAttribute == .left || constraint.firstAttribute == .leading
          || constraint.firstAttribute == .top || constraint.firstAttribute == .centerY)
    }
  }

  private func overrideButtonPosition(
    window: NSWindow, buttonType: NSWindow.ButtonType, offset: CGPoint
  ) {
    withButton(buttonType, in: window) { button, superview in
      if originalButtonConstraints[buttonType] == nil {
        let constraints = superview.constraints.filter { constraint in
          (constraint.firstItem as? NSButton) == button
            || (constraint.secondItem as? NSButton) == button
        }
        originalButtonConstraints[buttonType] = constraints
      }

      superview.removeConstraints(positionConstraints(for: button, in: superview))
      superview.removeConstraints(originalButtonConstraints[buttonType] ?? [])

      button.translatesAutoresizingMaskIntoConstraints = false

      superview.addConstraints([
        button.leftAnchor.constraint(equalTo: superview.leftAnchor, constant: offset.x),
        button.topAnchor.constraint(equalTo: superview.topAnchor, constant: offset.y),
      ])
      superview.layoutSubtreeIfNeeded()
    }
  }

  private func resetButtonPosition(window: NSWindow, buttonType: NSWindow.ButtonType) {
    withButton(buttonType, in: window) { button, superview in
      superview.removeConstraints(positionConstraints(for: button, in: superview))

      if let originalConstraints = originalButtonConstraints[buttonType] {
        superview.addConstraints(originalConstraints)
        originalButtonConstraints.removeValue(forKey: buttonType)
      }

      button.translatesAutoresizingMaskIntoConstraints = true
      superview.layoutSubtreeIfNeeded()
    }
  }
}
