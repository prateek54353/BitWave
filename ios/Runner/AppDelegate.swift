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
  private var equalizer: AVAudioUnitEQ?
  private var bands: [AVAudioUnitEQFilterParameters] = []

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

  private func setupEqualizer() {
    guard equalizer == nil else { return }

    audioSession = AVAudioSession.sharedInstance()
    equalizer = AVAudioUnitEQ()
    equalizer?.globalGain = 0.0

    let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    bands = frequencies.map { freq in
      let band = AVAudioUnitEQFilterParameters()
      band.filterType = .parametric
      band.frequency = freq
      band.bandwidth = 1.0
      band.gain = 0.0
      band.bypass = false
      return band
    }

    for band in bands {
      equalizer?.bandParameters = bands
    }
  }

  private func setEnabled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool else {
      result(FlutterError(code: "invalid_args", message: "Invalid arguments", details: nil))
      return
    }

    if enabled {
      setupEqualizer()
    } else {
      equalizer = nil
      bands.removeAll()
    }

    result(nil)
  }

  private func setBands(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let bandValues = args["bands"] as? [Double] else {
      result(FlutterError(code: "invalid_args", message: "Invalid arguments", details: nil))
      return
    }

    guard bandValues.count == bands.count else {
      result(FlutterError(code: "invalid_bands", message: "Expected 10 band values", details: nil))
      return
    }

    for (index, value) in bandValues.enumerated() {
      bands[index].gain = Float(value)
    }

    result(nil)
  }

  private func getBands(_ result: @escaping FlutterResult) {
    let enabled = equalizer != nil
    let bandValues = bands.map { Double($0.gain) }
    result(["enabled": enabled, "bands": bandValues])
  }
}
