import Flutter
import UIKit
import AVFoundation

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BitwaveFolderImportPlugin") {
      BitwaveFolderImportPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BitwaveEqualizerPlugin") {
      BitwaveEqualizerPlugin.register(with: registrar)
    }
  }
}

private final class BitwaveFolderImportPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let channelName = "org.bitwave.dev/folder_import"
  private var pendingResult: FlutterResult?
  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "ape"
  ]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BitwaveFolderImportPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickAndStageFolder" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pendingResult == nil else {
      result(FlutterError(code: "picker_busy", message: "A folder picker is already open.", details: nil))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "picker_unavailable", message: "The folder picker is unavailable.", details: nil))
      return
    }

    pendingResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(["files": [String]()])
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let folder = urls.first else {
      finish(["files": [String]()])
      return
    }
    let hasScopedAccess = folder.startAccessingSecurityScopedResource()
    let stagingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BitwaveFolderImport-\(UUID().uuidString)", isDirectory: true)
    let completion = pendingResult
    pendingResult = nil

    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
      }
      let fileManager = FileManager.default
      var copiedPaths: [String] = []
      var coordinationError: NSError?
      do {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: folder, options: [], error: &coordinationError) { readableFolder in
          guard let enumerator = fileManager.enumerator(
                  at: readableFolder,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return }

          while let source = enumerator.nextObject() as? URL {
            guard Self.audioExtensions.contains(source.pathExtension.lowercased()),
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }

            let destination = stagingDirectory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
            do {
              try fileManager.copyItem(at: source, to: destination)
              copiedPaths.append(destination.path)
            } catch {
              continue
            }
          }
        }
      } catch {
        coordinationError = error as NSError
      }

      if copiedPaths.isEmpty {
        try? fileManager.removeItem(at: stagingDirectory)
      }
      DispatchQueue.main.async {
        if coordinationError != nil {
          completion?(["files": copiedPaths, "error": "The selected folder could not be read."])
        } else {
          completion?(["files": copiedPaths])
        }
      }
    }
  }

  private func finish(_ value: Any) {
    let completion = pendingResult
    pendingResult = nil
    completion?(value)
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?.rootViewController
    var top = root
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

private final class BitwaveEqualizerPlugin: NSObject, FlutterPlugin {
  private static let channelName = "org.bitwave.dev/equalizer"
  private var audioSession: AVAudioSession?
  private var audioEngine: AVAudioEngine?
  private var equalizer: AVAudioUnitEQ?
  private var bands: [AVAudioUnitEQFilterParameters] = []
  private var requestedEnabled = false
  private var requestedGains = Array(repeating: Float(0), count: 10)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BitwaveEqualizerPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setEnabled":
      setEnabled(call, result)
    case "setBands":
      setBands(call, result)
    case "getBands":
      getBands(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setupEqualizer() throws {
    if audioEngine != nil, equalizer != nil { return }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
    try session.setActive(true)

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    eq.globalGain = 0.0

    let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    bands = eq.bands
    for (index, band) in bands.enumerated() {
      band.filterType = .parametric
      band.frequency = frequencies[index]
      band.bandwidth = 1.0
      band.gain = requestedGains[index]
      band.bypass = false
    }

    engine.attach(player)
    engine.attach(eq)
    engine.connect(player, to: eq, format: nil)
    engine.connect(eq, to: engine.mainMixerNode, format: nil)

    try engine.start()
    audioSession = session
    audioEngine = engine
    equalizer = eq
  }

  private func setEnabled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool else {
      result(FlutterError(code: "invalid_args", message: "Expected an enabled boolean", details: nil))
      return
    }

    requestedEnabled = enabled
    if enabled {
      do {
        try setupEqualizer()
        bands.indices.forEach { bands[$0].gain = requestedGains[$0] }
        result(nil)
      } catch {
        result(FlutterError(code: "equalizer_setup_failed", message: "Could not start the equalizer audio engine: \(error.localizedDescription)", details: nil))
      }
    } else {
      audioEngine?.stop()
      audioEngine = nil
      equalizer = nil
      bands.removeAll()
      audioSession = nil
      result(nil)
    }
  }

  private func setBands(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let bandValues = args["bands"] as? [Double],
          bandValues.count == 10 else {
      result(FlutterError(code: "invalid_bands", message: "Expected 10 band values", details: nil))
      return
    }

    requestedGains = bandValues.map { Float(max(-12, min(12, $0))) }
    if requestedEnabled {
      do {
        try setupEqualizer()
        for index in bands.indices {
          bands[index].gain = requestedGains[index]
        }
      } catch {
        result(FlutterError(code: "equalizer_setup_failed", message: "Could not apply equalizer bands: \(error.localizedDescription)", details: nil))
        return
      }
    }
    result(nil)
  }

  private func getBands(_ result: @escaping FlutterResult) {
    result([
      "enabled": requestedEnabled,
      "bands": requestedGains.map { Double($0) }
    ])
  }
}
