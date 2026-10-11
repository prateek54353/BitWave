import Flutter
import UIKit
import MediaPlayer

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BitwaveNowPlayingArtworkPlugin") {
      BitwaveNowPlayingArtworkPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BitwaveFolderImportPlugin") {
      BitwaveFolderImportPlugin.register(with: registrar)
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

private final class BitwaveNowPlayingArtworkPlugin: NSObject, FlutterPlugin {
  private static let channelName = "org.bitwave.dev/now_playing_artwork"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(BitwaveNowPlayingArtworkPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setAnimatedArtwork" || call.method == "clearAnimatedArtwork" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard #available(iOS 26.0, *) else {
      result(false)
      return
    }

    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [:]
    let squareKey = MPNowPlayingInfoProperty1x1AnimatedArtwork
    let tallKey = MPNowPlayingInfoProperty3x4AnimatedArtwork
    info.removeValue(forKey: squareKey)
    info.removeValue(forKey: tallKey)

    if call.method == "setAnimatedArtwork" {
      guard
        let args = call.arguments as? [String: Any],
        let artworkID = args["artworkId"] as? String,
        let videoPath = args["videoPath"] as? String,
        let posterPath = args["posterPath"] as? String,
        let ratio = args["aspectRatio"] as? Double,
        FileManager.default.fileExists(atPath: videoPath),
        let preview = UIImage(contentsOfFile: posterPath)
      else {
        result(false)
        return
      }

      let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
      let key: String
      if abs(ratio - 1.0) <= 0.06 && supported.contains(squareKey) {
        key = squareKey
      } else if abs(ratio - 0.75) <= 0.06 && supported.contains(tallKey) {
        key = tallKey
      } else {
        center.nowPlayingInfo = info
        result(false)
        return
      }

      info[key] = MPMediaItemAnimatedArtwork(
        artworkID: artworkID,
        previewImageRequestHandler: { _ in preview },
        videoAssetFileURLRequestHandler: { _ in URL(fileURLWithPath: videoPath) }
      )
    }
    center.nowPlayingInfo = info
    result(true)
  }
}
