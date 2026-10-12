import Foundation
import AVFoundation
import CoreGraphics
import AppKit

func createVideo() {
    let workDir = URL(fileURLWithPath: "/Users/arunthomas/.gemini/antigravity-ide/scratch/Rec/brag-output/work")
    let outputVideoURL = URL(fileURLWithPath: "/Users/arunthomas/.gemini/antigravity-ide/scratch/Rec/brag-output/work/temp_video.mp4")
    let finalVideoURL = URL(fileURLWithPath: "/Users/arunthomas/.gemini/antigravity-ide/scratch/Rec/brag-output/brag.mp4")
    let audioURL = URL(fileURLWithPath: "/Users/arunthomas/.gemini/antigravity-ide/scratch/Rec/brag-output/composition/assets/music/happy-beats-business-moves-vol-10-by-ende-dot-app.mp3")

    if FileManager.default.fileExists(atPath: outputVideoURL.path) {
        try? FileManager.default.removeItem(at: outputVideoURL)
    }
    if FileManager.default.fileExists(atPath: finalVideoURL.path) {
        try? FileManager.default.removeItem(at: finalVideoURL)
    }

    let scenes: [(filename: String, durationSecs: Double)] = [
        ("scene_01_problem.jpg", 3.5),
        ("scene_02_reveal.jpg", 4.0),
        ("scene_03_features.jpg", 5.0),
        ("scene_04_flow.jpg", 4.5),
        ("scene_05_install.jpg", 3.0)
    ]

    var images: [CGImage] = []
    for s in scenes {
        let imgURL = workDir.appendingPathComponent(s.filename)
        guard let nsImg = NSImage(contentsOf: imgURL),
              let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to load \(s.filename)")
            return
        }
        images.append(cgImg)
    }

    let width = images[0].width
    let height = images[0].height
    let fps: Int32 = 30
    let totalFrames = Int(20.0 * Double(fps))

    guard let writer = try? AVAssetWriter(outputURL: outputVideoURL, fileType: .mp4) else {
        print("Cannot create AVAssetWriter")
        return
    }

    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 6_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ]

    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: attributes)
    writer.add(writerInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    func newPixelBuffer(from image1: CGImage, image2: CGImage?, blend: Double) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let data = CVPixelBufferGetBaseAddress(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image1, in: rect)

        if let img2 = image2, blend > 0.0 {
            context.saveGState()
            context.setAlpha(CGFloat(blend))
            context.draw(img2, in: rect)
            context.restoreGState()
        }

        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    var frameCount = 0
    let crossfadeFrames = 12 // 0.4s crossfade

    // Build timeline of frame to scene mapping
    for sceneIdx in 0..<scenes.count {
        let sceneDuration = scenes[sceneIdx].durationSecs
        let sceneFrames = Int(sceneDuration * Double(fps))
        let img1 = images[sceneIdx]
        let img2 = (sceneIdx + 1 < images.count) ? images[sceneIdx + 1] : nil

        for f in 0..<sceneFrames {
            while !writerInput.isReadyForMoreMediaData {
                usleep(1000)
            }

            let presentationTime = CMTime(value: Int64(frameCount), timescale: fps)
            let isTransition = (sceneFrames - f) <= crossfadeFrames && img2 != nil
            let blendRatio: Double = isTransition ? Double(crossfadeFrames - (sceneFrames - f)) / Double(crossfadeFrames) : 0.0

            if let buffer = newPixelBuffer(from: img1, image2: isTransition ? img2 : nil, blend: blendRatio) {
                adaptor.append(buffer, withPresentationTime: presentationTime)
            }
            frameCount += 1
        }
    }

    writerInput.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()
    print("Video track written successfully: \(frameCount) frames.")

    // Now merge audio track with AVMutableComposition
    let composition = AVMutableComposition()
    guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        print("Failed to create composition tracks")
        return
    }

    let videoAsset = AVURLAsset(url: outputVideoURL)
    let audioAsset = AVURLAsset(url: audioURL)

    guard let assetVideoTrack = videoAsset.tracks(withMediaType: .video).first else {
        print("No video track found")
        return
    }

    let duration = CMTime(seconds: 20.0, preferredTimescale: fps)
    let timeRange = CMTimeRange(start: .zero, duration: duration)

    try? compVideoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: .zero)

    if let assetAudioTrack = audioAsset.tracks(withMediaType: .audio).first {
        try? compAudioTrack.insertTimeRange(timeRange, of: assetAudioTrack, at: .zero)
    }

    guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        print("Failed to create export session")
        return
    }

    exportSession.outputURL = finalVideoURL
    exportSession.outputFileType = .mp4
    exportSession.timeRange = timeRange

    let exportSemaphore = DispatchSemaphore(value: 0)
    exportSession.exportAsynchronously {
        exportSemaphore.signal()
    }
    exportSemaphore.wait()

    if exportSession.status == .completed {
        print("SUCCESS: brag.mp4 created at: \(finalVideoURL.path)")
        try? FileManager.default.removeItem(at: outputVideoURL)
    } else {
        print("Export failed: \(String(describing: exportSession.error))")
    }
}

createVideo()
