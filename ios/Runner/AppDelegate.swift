import Flutter
import UIKit
import MediaPlayer
import AVFoundation
import CryptoKit

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
  private static var requestedArtworkID: String?
  private static var generatedStaticArtwork: MPMediaItemArtwork?

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
    if let generated = Self.generatedStaticArtwork,
       let current = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
       current === generated {
      info.removeValue(forKey: MPMediaItemPropertyArtwork)
    }
    Self.generatedStaticArtwork = nil
    center.nowPlayingInfo = info

    guard call.method == "setAnimatedArtwork" else {
      Self.requestedArtworkID = nil
      result(true)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let artworkID = args["artworkId"] as? String,
      let ratio = args["aspectRatio"] as? Double
    else {
      Self.requestedArtworkID = nil
      result(false)
      return
    }
    Self.requestedArtworkID = artworkID

    let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
    let isTall = ratio < 0.9
    let key = isTall ? tallKey : squareKey
    guard supported.contains(key) else {
      result(false)
      return
    }

    Self.prepareVideo(args: args, artworkID: artworkID, targetAspect: isTall ? 0.75 : 1.0) { videoURL in
      DispatchQueue.main.async {
        guard Self.requestedArtworkID == artworkID, let videoURL else {
          result(false)
          return
        }
        Self.loadPreview(
          args: args,
          fallbackVideoURL: videoURL,
          targetAspect: isTall ? 0.75 : 1.0
        ) { preview in
          DispatchQueue.main.async {
            guard Self.requestedArtworkID == artworkID, let preview else {
              result(false)
              return
            }
            var updatedInfo = center.nowPlayingInfo ?? [:]
            updatedInfo[key] = MPMediaItemAnimatedArtwork(
              artworkID: artworkID,
              previewImageRequestHandler: { _ in preview },
              videoAssetFileURLRequestHandler: { _ in videoURL }
            )
            if updatedInfo[MPMediaItemPropertyArtwork] == nil {
              let staticArtwork = MPMediaItemArtwork(boundsSize: preview.size) { _ in preview }
              updatedInfo[MPMediaItemPropertyArtwork] = staticArtwork
              Self.generatedStaticArtwork = staticArtwork
            }
            center.nowPlayingInfo = updatedInfo
            result(true)
          }
        }
      }
    }
  }

  private static func loadPreview(
    args: [String: Any],
    fallbackVideoURL: URL,
    targetAspect: CGFloat,
    completion: @escaping (UIImage?) -> Void
  ) {
    if let path = args["posterPath"] as? String,
       let image = UIImage(contentsOfFile: path),
       let cropped = cropPreview(image, to: targetAspect) {
      completion(cropped)
      return
    }
    guard let value = args["posterUrl"] as? String,
          let url = URL(string: value), url.scheme == "https" else {
      previewFromVideo(fallbackVideoURL, targetAspect: targetAspect, completion: completion)
      return
    }
    URLSession.shared.dataTask(with: url) { data, response, _ in
      if let response = response as? HTTPURLResponse,
         (200..<300).contains(response.statusCode),
         let data,
         let image = UIImage(data: data),
         let cropped = cropPreview(image, to: targetAspect) {
        completion(cropped)
        return
      }
      previewFromVideo(fallbackVideoURL, targetAspect: targetAspect, completion: completion)
    }.resume()
  }

  private static func previewFromVideo(
    _ url: URL,
    targetAspect: CGFloat,
    completion: @escaping (UIImage?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      let frame = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 10), actualTime: nil)
      let preview = frame.flatMap { cropPreview(UIImage(cgImage: $0), to: targetAspect) }
      DispatchQueue.main.async { completion(preview) }
    }
  }

  private static func cropPreview(_ image: UIImage, to targetAspect: CGFloat) -> UIImage? {
    guard let source = image.cgImage else { return nil }
    let sourceWidth = CGFloat(source.width)
    let sourceHeight = CGFloat(source.height)
    let sourceAspect = sourceWidth / sourceHeight
    let crop: CGRect
    if sourceAspect > targetAspect {
      let width = sourceHeight * targetAspect
      crop = CGRect(x: (sourceWidth - width) / 2, y: 0, width: width, height: sourceHeight)
    } else {
      let height = sourceWidth / targetAspect
      crop = CGRect(x: 0, y: (sourceHeight - height) / 2, width: sourceWidth, height: height)
    }
    guard let cropped = source.cropping(to: crop.integral) else { return nil }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
  }

  private static func prepareVideo(
    args: [String: Any],
    artworkID: String,
    targetAspect: CGFloat,
    completion: @escaping (URL?) -> Void
  ) {
    if let path = args["videoPath"] as? String,
       FileManager.default.fileExists(atPath: path) {
      completion(URL(fileURLWithPath: path))
      return
    }
    guard let value = args["videoUrl"] as? String,
          let remoteURL = URL(string: value), remoteURL.scheme == "https" else {
      completion(nil)
      return
    }

    let digest = SHA256.hash(data: Data(artworkID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BitwaveMotionArtwork", isDirectory: true)
    let outputURL = directory.appendingPathComponent("\(digest).mp4")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      completion(outputURL)
      return
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      completion(nil)
      return
    }

    let asset = AVURLAsset(url: remoteURL)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
      var loadError: NSError?
      guard asset.statusOfValue(forKey: "tracks", error: &loadError) == .loaded,
            asset.statusOfValue(forKey: "duration", error: &loadError) == .loaded,
            let sourceTrack = asset.tracks(withMediaType: .video).first,
            asset.duration.isNumeric,
            asset.duration.seconds > 0 else {
        completion(nil)
        return
      }

      let composition = AVMutableComposition()
      guard let videoTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ) else {
        completion(nil)
        return
      }
      do {
        try videoTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: asset.duration),
          of: sourceTrack,
          at: .zero
        )
      } catch {
        completion(nil)
        return
      }

      let outputHeight: CGFloat = 1200
      let outputSize = CGSize(width: outputHeight * targetAspect, height: outputHeight)
      let transformedBounds = CGRect(origin: .zero, size: sourceTrack.naturalSize)
        .applying(sourceTrack.preferredTransform).standardized
      guard transformedBounds.width > 0, transformedBounds.height > 0 else {
        completion(nil)
        return
      }
      let scale = max(outputSize.width / transformedBounds.width, outputSize.height / transformedBounds.height)
      let xOffset = (outputSize.width - transformedBounds.width * scale) / 2
      let yOffset = (outputSize.height - transformedBounds.height * scale) / 2
      var transform = sourceTrack.preferredTransform
      transform.a *= scale
      transform.b *= scale
      transform.c *= scale
      transform.d *= scale
      transform.tx = (transform.tx - transformedBounds.minX) * scale + xOffset
      transform.ty = (transform.ty - transformedBounds.minY) * scale + yOffset

      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
      layer.setTransform(transform, at: .zero)
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      instruction.layerInstructions = [layer]
      let videoComposition = AVMutableVideoComposition()
      videoComposition.renderSize = outputSize
      videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
      videoComposition.instructions = [instruction]

      guard let exporter = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetHighestQuality
      ), exporter.supportedFileTypes.contains(.mp4) else {
        completion(nil)
        return
      }
      exporter.outputURL = outputURL
      exporter.outputFileType = .mp4
      exporter.videoComposition = videoComposition
      exporter.shouldOptimizeForNetworkUse = true
      exporter.exportAsynchronously {
        DispatchQueue.main.async {
          if exporter.status == .completed {
            completion(outputURL)
          } else {
            try? FileManager.default.removeItem(at: outputURL)
            completion(nil)
          }
        }
      }
    }
  }
}
