import Cocoa
import FlutterMacOS

/// Flutter plugin that bridges MPV player to Dart via method and event channels
class MpvPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, MpvPluginShared {

  // MARK: - Properties

  private var playerCore: MpvPlayerCore?
  var eventSink: FlutterEventSink?
  private weak var registrar: FlutterPluginRegistrar?
  var nameToId: [String: Int] = [:]

  var coreBase: MpvPlayerCoreBase? { playerCore }
  func setPlayerVisible(_ visible: Bool, restoreOnWindowVisible: Bool) {
    playerCore?.setVisible(visible, restoreOnWindowVisible: restoreOnWindowVisible)
  }
  func updatePlayerFrame() { playerCore?.updateFrame() }
  func setPlayerVideoZoom(_ scale: Double) { playerCore?.setVideoZoom(scale) }

  private var pipController: MpvPipController?
  private var pipChannel: FlutterMethodChannel?
  private var autoPipEnabled = false
  private var enteredPipViaAuto = false
  private var observedDisplayWidth: Double?
  private var observedDisplayHeight: Double?
  private let displayModes = DisplayModeManager()

  // MARK: - FlutterPlugin Registration

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "com.satra/mpv_player",
      binaryMessenger: registrar.messenger
    )

    let eventChannel = FlutterEventChannel(
      name: "com.satra/mpv_player/events",
      binaryMessenger: registrar.messenger
    )

    let pipChannel = FlutterMethodChannel(
      name: "com.satra/pip",
      binaryMessenger: registrar.messenger
    )

    let instance = MpvPlayerPlugin()
    instance.registrar = registrar
    instance.pipChannel = pipChannel

    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    pipChannel.setMethodCallHandler(instance.handlePipCall)

    MpvLog.debug("[MpvPlayerPlugin] Registered with Flutter")
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.eventSink = events
    MpvLog.debug("[MpvPlayerPlugin] Event stream connected")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    MpvLog.debug("[MpvPlayerPlugin] Event stream disconnected")
    return nil
  }

  // MARK: - FlutterPlugin Method Handler

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      handleInitialize(result: result)

    case "dispose":
      handleDispose(result: result)

    case "setProperty":
      handleSetProperty(call: call, result: result)

    case "getProperty":
      handleGetProperty(call: call, result: result)

    case "observeProperty":
      handleObserveProperty(call: call, result: result)

    case "command":
      handleCommand(call: call, result: result)

    case "setVisible":
      handleSetVisible(call: call, result: result)

    case "isInitialized":
      result(playerCore?.isInitialized ?? false)

    case "updateFrame":
      handleUpdateFrame(result: result)

    case "setVideoZoom":
      handleSetVideoZoom(call: call, result: result)

    case "setLogLevel":
      handleSetLogLevel(call: call, result: result)

    // Display mode matching (DisplayModeService): refresh rate only, Match
    // Dynamic Range is Windows-only.
    case "isModeChanged":
      result(displayModes.isModeChanged)

    case "getCurrentDisplayMode":
      withFlutterWindow(result) { result(self.displayModes.currentMode(on: $0)) }

    case "getDisplayModes":
      withFlutterWindow(result) { result(self.displayModes.modes(on: $0)) }

    case "setDisplayMode":
      handleSetDisplayMode(call: call, result: result)

    case "restoreDisplayMode":
      result(displayModes.restore())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensurePipController() -> MpvPipController {
    if let existing = pipController { return existing }
    let controller = MpvPipController()
    controller.delegate = self
    pipController = controller
    return controller
  }

  private static func validAspectSize(width: Double?, height: Double?) -> NSSize? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return NSSize(width: width, height: height)
  }

  private func handlePipCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(MpvPipController.isSupported)
    case "enter":
      let args = call.arguments as? [String: Any]
      let width = (args?["width"] as? NSNumber)?.doubleValue
      let height = (args?["height"] as? NSNumber)?.doubleValue
      if let size = Self.validAspectSize(width: width, height: height) {
        observedDisplayWidth = size.width
        observedDisplayHeight = size.height
      }
      enterPip(manual: true, preferredSize: Self.validAspectSize(width: width, height: height), result: result)
    case "exit":
      pipController?.stopPip()
      result(nil)
    case "setAutoPipReady":
      if let args = call.arguments as? [String: Any], let ready = args["ready"] as? Bool {
        autoPipEnabled = ready
        if let width = (args["width"] as? NSNumber)?.doubleValue,
          let height = (args["height"] as? NSNumber)?.doubleValue,
          width > 0, height > 0
        {
          observedDisplayWidth = width
          observedDisplayHeight = height
        }
        let pip = ensurePipController()
        pip.setAutoStart(ready)
        if ready {
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil)
          NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
          NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        } else {
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil)
          NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Enter PiP by lending the player's video layers to a PiP window.
  /// No VO switching — mpv keeps rendering into the same layers.
  private func enterPip(manual: Bool, preferredSize: NSSize? = nil, result: FlutterResult? = nil) {
    guard let playerCore = playerCore else {
      result?([
        "success": false, "errorCode": "failed", "errorMessage": "Player not initialized",
      ])
      return
    }
    guard let window = findFlutterWindow()?.0 else {
      result?(["success": false, "errorCode": "failed", "errorMessage": "No window"])
      return
    }

    let pip = ensurePipController()
    guard !pip.isActive else {
      result?(["success": false, "errorCode": "failed", "errorMessage": "PiP already active"])
      return
    }

    let aspectRatio: NSSize
    if let preferredSize {
      aspectRatio = preferredSize
    } else if let observed = Self.validAspectSize(width: observedDisplayWidth, height: observedDisplayHeight) {
      aspectRatio = observed
    } else if let videoSize = playerCore.videoSize, videoSize.width > 0, videoSize.height > 0 {
      aspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
    } else {
      aspectRatio = NSSize(width: 16, height: 9)
    }

    guard let layers = playerCore.lendVideoLayersForPip() else {
      result?(["success": false, "errorCode": "failed", "errorMessage": "No video layer"])
      return
    }

    enteredPipViaAuto = !manual
    playerCore.isPipActive = true

    pip.startPip(layers: layers, window: window, aspectRatio: aspectRatio)
    pipChannel?.invokeMethod("onPipChanged", arguments: true)
    result?(["success": true])
  }

  /// App resigned active — auto-enter PiP if enabled and playing
  @objc private func appDidResignActive() {
    guard autoPipEnabled,
      let pc = playerCore,
      !pc.isPipActive,
      !pc.isPaused,
      pipController?.autoPipEnabled == true
    else { return }
    MpvLog.debug("[MpvPlayerPlugin] Auto-PiP: app resigned active, entering PiP")
    enterPip(manual: false)
  }

  /// App became active — auto-exit PiP if it was entered automatically
  @objc private func appDidBecomeActive() {
    guard enteredPipViaAuto, let pip = pipController, pip.isActive else { return }
    MpvLog.debug("[MpvPlayerPlugin] Auto-PiP: app became active, exiting PiP")
    pip.stopPip()
  }

  // MARK: - Platform-Specific Method Handlers

  private func handleInitialize(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(FlutterError(code: "ERROR", message: "Plugin deallocated", details: nil))
        return
      }

      if self.playerCore?.isInitialized == true {
        MpvLog.debug("[MpvPlayerPlugin] Already initialized")
        result(true)
        return
      }

      guard let (window, _, _) = self.findFlutterWindow() else {
        MpvLog.debug("[MpvPlayerPlugin] Failed to find Flutter window")
        result(
          FlutterError(
            code: "NO_WINDOW", message: "Could not find Flutter window", details: nil))
        return
      }

      let core = MpvPlayerCore()
      core.delegate = self

      guard core.initialize(in: window) else {
        MpvLog.debug("[MpvPlayerPlugin] Failed to initialize MPV")
        result(
          FlutterError(
            code: "MPV_INIT_FAILED", message: "Failed to initialize MPV", details: nil))
        return
      }

      self.playerCore = core

      core.setVisible(false)

      MpvLog.debug("[MpvPlayerPlugin] Initialized successfully")
      result(true)
    }
  }

  private func handleDispose(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { result(nil); return }
      if let pip = self.pipController, pip.isActive {
        pip.stopPip()
        pip.detachLayers()
        // The controller is released below, before PiP's close callback
        // (pipDidStop) can arrive, so tell Dart PiP ended here; otherwise
        // later players stay covered by the PiP placeholder.
        self.playerCore?.isPipActive = false
        self.enteredPipViaAuto = false
        self.pipChannel?.invokeMethod("onPipChanged", arguments: false)
      }
      self.pipController = nil
      self.autoPipEnabled = false
      self.observedDisplayWidth = nil
      self.observedDisplayHeight = nil
      NotificationCenter.default.removeObserver(
        self, name: NSApplication.didResignActiveNotification, object: nil)
      NotificationCenter.default.removeObserver(
        self, name: NSApplication.didBecomeActiveNotification, object: nil)
      self.playerCore?.dispose()
      self.playerCore = nil
      MpvLog.debug("[MpvPlayerPlugin] Disposed")
      result(nil)
    }
  }

  func didSetPauseProperty(value: String) {
    let isPlaying = value == "no"
    pipController?.setPlaying(isPlaying)
    playerCore?.setPaused(!isPlaying)
  }

  func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
    switch name {
    case "pause":
      let isPaused: Bool?
      if let flag = value as? Bool {
        isPaused = flag
      } else if let str = value as? String {
        isPaused = (str == "yes" || str == "true")
      } else {
        isPaused = nil
      }
      if let isPaused {
        pipController?.setPlaying(!isPaused)
        playerCore?.setPaused(isPaused)
      }
    case "dwidth":
      if let width = (value as? NSNumber)?.doubleValue, width > 0 {
        observedDisplayWidth = width
        if let size = Self.validAspectSize(width: observedDisplayWidth, height: observedDisplayHeight),
          pipController?.isActive == true
        {
          pipController?.setAspectRatio(size)
        }
      }
    case "dheight":
      if let height = (value as? NSNumber)?.doubleValue, height > 0 {
        observedDisplayHeight = height
        if let size = Self.validAspectSize(width: observedDisplayWidth, height: observedDisplayHeight),
          pipController?.isActive == true
        {
          pipController?.setAspectRatio(size)
        }
      }
    case "width", "height":
      if pipController?.isActive == true,
        Self.validAspectSize(width: observedDisplayWidth, height: observedDisplayHeight) == nil,
        let videoSize = playerCore?.videoSize,
        videoSize.width > 0, videoSize.height > 0
      {
        pipController?.setAspectRatio(NSSize(width: videoSize.width, height: videoSize.height))
      }
    default:
      break
    }

    guard let eventSink = eventSink, let propId = nameToId[name] else { return }
    let message: [Any?] = [propId, value, sourceId]
    eventSink(message)
  }

  private func handleSetDisplayMode(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let width = args["width"] as? Int,
      let height = args["height"] as? Int,
      let refreshRate = (args["refreshRate"] as? NSNumber)?.doubleValue
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "Expected width, height and refreshRate", details: nil))
      return
    }
    withFlutterWindow(result) { window in
      self.displayModes.setMode(on: window, width: width, height: height, refreshRate: refreshRate) {
        result($0)
      }
    }
  }

  // MARK: - Helpers

  private func withFlutterWindow(_ result: @escaping FlutterResult, _ body: (NSWindow) -> Void) {
    guard let (window, _, _) = findFlutterWindow() else {
      result(FlutterError(code: "NO_WINDOW", message: "Could not find Flutter window", details: nil))
      return
    }
    body(window)
  }

  private func findFlutterWindow() -> (NSWindow, NSView, NSView)? {
    for window in NSApplication.shared.windows {
      if window is MainFlutterWindow,
        let contentView = window.contentView,
        let contentVC = window.contentViewController
      {
        let flutterView = contentVC.view
        return (window, contentView, flutterView)
      }
    }

    for window in NSApplication.shared.windows {
      if let contentView = window.contentView,
        let contentVC = window.contentViewController
      {
        let flutterView = contentVC.view
        return (window, contentView, flutterView)
      }
    }

    return nil
  }
}

// MARK: - MpvPipDelegate

extension MpvPlayerPlugin: MpvPipDelegate {

  func pipWillStart() {
    MpvLog.debug("[MpvPlayerPlugin] PiP will start")
  }

  func pipDidStart() {
    MpvLog.debug("[MpvPlayerPlugin] PiP did start")
  }

  func pipDidStop(restored: Bool) {
    MpvLog.debug("[MpvPlayerPlugin] PiP did stop (restored: \(restored))")
    playerCore?.isPipActive = false
    enteredPipViaAuto = false

    let layers = pipController?.detachLayers() ?? []
    playerCore?.takeBackVideoLayers(layers)

    pipChannel?.invokeMethod("onPipChanged", arguments: false)
  }

  func pipSetPlaying(_ playing: Bool) {
    guard let playerCore else { return }
    playerCore.setPropertyAsync("pause", value: playing ? "no" : "yes") { [weak self] propertyResult in
      guard case .success = propertyResult else { return }
      self?.pipController?.setPlaying(playing)
      playerCore.setPaused(!playing)
    }
  }

  var isPipPlaying: Bool { !(playerCore?.isPaused ?? true) }
}
