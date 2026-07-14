// main.swift
// Rec - Native Screen Recorder
// Fixed: Selected Region Crash, Sync, Race Conditions, Multi-Monitor, Leaks

import Cocoa
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import os.log

// ============================================================
// Globals & Settings
// ============================================================

let appVersion = "1.1"
let updateCheckURL = "https://rec-aoh.netlify.app/version.json"
private let log = OSLog(subsystem: "com.rec.app", category: "recorder")

struct AppSettings: Codable {
    var fps: Int = 60
    var resolution: Int = 0 // 0 = Native, 1080, 720
    var bitrate: Int = 0    // 0 = High, 1 = Med, 2 = Low
    var timer: Int = 0
    var audioSource: Int = 0 // 0=Sys, 1=Mic, 2=Both, 3=None
    var showsClicks: Bool = false
    var saveDirectory: String = ""
    var micID: String = ""

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "RecAppSettings")
        }
    }
    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "RecAppSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return AppSettings()
    }
}

var currentSettings = AppSettings.load()

// ============================================================
// Overlay: Recording Indicator (Hole)
// ============================================================

class RecordingOverlayWindow: NSWindow {
    var holeRect: CGRect = .zero {
        didSet { contentView?.needsDisplay = true }
    }

    init(screen: NSScreen, holeRect: CGRect) {
        self.holeRect = holeRect
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .floating
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let overlayView = RecordingOverlayView(frame: self.contentView?.bounds ?? .zero)
        overlayView.windowRef = self
        overlayView.autoresizingMask = [.width, .height]
        self.contentView = overlayView
    }
}

class RecordingOverlayView: NSView {
    weak var windowRef: RecordingOverlayWindow?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window = windowRef else { return }

        // Dim overlay
        NSColor.black.withAlphaComponent(0.4).set()
        dirtyRect.fill()

        // Clear selected region (hole)
        if window.holeRect != .zero {
            // holeRect is in screen coordinates (bottom-left origin).
            // Convert to this view's coordinates (top-left origin, frame = screen.frame).
            let windowRect = window.convertFromScreen(NSRect(origin: window.holeRect.origin, size: window.holeRect.size))
            let localRect = self.convert(windowRect, from: nil)

            NSColor.clear.set()
            localRect.fill(using: .sourceOut)
        }
    }
}

// ============================================================
// Overlay: Region Selection (Multi-Screen)
// ============================================================

class RegionSelectionManager: NSObject {
    // Manages one window per screen to allow selection on any monitor
    private var windows: [RegionSelectionWindow] = []
    var completion: ((CGRect, NSScreen?) -> Void)?

    func startSelection(completion: @escaping (CGRect, NSScreen?) -> Void) {
        self.completion = completion
        windows.removeAll()

        for screen in NSScreen.screens {
            let win = RegionSelectionWindow(screen: screen, manager: self)
            win.makeKeyAndOrderFront(nil)
            windows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancelAll windows.forEach { $0.close() }
        windows.removeAll()
    }

    filefunc selectionCompleted(rect: CGRect, onScreen screen: NSScreen) {
        completion?(rect, screen)
        cleanup()
    }

    filefunc selectionCancelled() {
        completion?(.zero, nil)
        cleanup()
    }
}

class RegionSelectionWindow: NSWindow {
    weak var manager: RegionSelectionManager?
    var selectionView: SelectionView!
    let screen: NSScreen

    init(screen: NSScreen, manager: RegionSelectionManager) {
        self.screen = screen
        self.manager = manager
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        self.isOpaque = false
        self.hasShadow = false
        // .floating + .fullScreenAuxiliary works on macOS 14+ for capture overlay
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = false

        selectionView = SelectionView(frame: self.contentView!.bounds)
        selectionView.autoresizingMask = [.width, .height]
        self.contentView?.addSubview(selectionView)

        // Instruction Label
        let label = NSTextField(labelWithString: "Click and drag to select a recording region. Press Esc to cancel.")
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: (screen.frame.width - label.frame.width) / 2, y: screen.frame.height / 2)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        self.contentView?.addSubview(label)
    }

    override func mouseDown(with event: NSEvent) {
        selectionView.startPoint = event.locationInWindow
        selectionView.currentRect = .zero
        selectionView.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = selectionView.startPoint else { return }
        let current = event.locationInWindow

        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)

        selectionView.currentRect = CGRect(x: x, y: y, width: w, height: h)
        selectionView.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = selectionView.startPoint else { return }
        let current = event.locationInWindow

        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)

        let rect = CGRect(x: x, y: y, width: w, height: h)

        if w > 50 && h > 50 {
            // Convert window coords (bottom-left) -> screen coords (bottom-left)
            // Window frame = screen frame, so origin is same.
            let screenRect = rect
            manager?.selectionCompleted(rect: screenRect, onScreen: screen)
        } else {
            manager?.selectionCancelled()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            manager?.selectionCancelled()
        }
    }

    override var canBecomeKey: Bool { return true }
}

class SelectionView: NSView {
    var startPoint: CGPoint?
    var currentRect: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if currentRect != .zero {
            // Clear hole
            NSColor.clear.set()
            currentRect.fill(using: .sourceOut)

            // Draw border
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2
            let dash: [CGFloat] = [5.0, 5.0]
            path.setLineDash(dash, count: 2, phase: 0.0)
            path.stroke()

            // Dimensions label
            let dims = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -3.0
            ]
            let str = NSAttributedString(string: dims, attributes: attrs)
            let textRect = CGRect(x: currentRect.midX - 50, y: currentRect.minY - 28, width: 100, height: 24)
            str.draw(in: textRect)
        }
    }
}

// ============================================================
// App Selection Menu
// ============================================================

class AppSelectionMenuHandler: NSObject {
    var onSelect: ((SCRunningApplication?) -> Void)?
    private var apps: [SCRunningApplication] = []

    func showMenu(at view: NSView) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let content = content else { return }

            let myProcessId = ProcessInfo.processInfo.processIdentifier
            var uniqueApps = [String: SCRunningApplication]()
            for app in content.applications {
                let name = app.applicationName
                if app.processID != myProcessId, !name.isEmpty {
                    // Filter system/internal apps loosely
                    if !name.hasPrefix("com.apple") || name == "Finder" {
                        uniqueApps[name] = app
                    }
                }
            }

            self.apps = uniqueApps.values.sorted(by: { $0.applicationName < $1.applicationName })

            DispatchQueue.main.async {
                let menu = NSMenu()
                let titleItem = NSMenuItem(title: "Select Application to Record:", action: nil, keyEquivalent: "")
                titleItem.isEnabled = false
                menu.addItem(titleItem)
                menu.addItem(NSMenuItem.separator())

                if self.apps.isEmpty {
                    let emptyItem = NSMenuItem(title: "No recordable applications found.", action: nil, keyEquivalent: "")
                    emptyItem.isEnabled = false
                    menu.addItem(emptyItem)
                } else {
                    for (index, app) in self.apps.enumerated() {
                        let item = NSMenuItem(title: app.applicationName, action: #selector(self.appSelected(_:)), keyEquivalent: "")
                        item.target = self
                        item.tag = index

                        if let runningApp = NSRunningApplication(processIdentifier: app.processID),
                           let icon = runningApp.icon {
                            icon.size = NSSize(width: 16, height: 16)
                            item.image = icon
                        }
                        menu.addItem(item)
                    }
                }

                // Robust popup handling
                if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .rightMouseUp {
                    NSMenu.popUpContextMenu(menu, with: event, for: view)
                } else {
                    let pt = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.maxY), to: nil)
                    menu.popUp(positioning: nil, at: pt, in: view)
                }
            }
        }
    }

    @objc func appSelected(_ sender: NSMenuItem) {
        guard sender.tag < apps.count else { return }
        let app = apps[sender.tag]
        onSelect?(app)
    }
}

// ============================================================
// Recorder Core
// ============================================================

class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Mic
    var micSession: AVCaptureSession?
    var micOutput: AVCaptureAudioDataOutput?

    // ScreenCaptureKit
    var stream: SCStream?
    var assetWriter: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput?   // System Audio
    var micInput: AVAssetWriterInput?     // Microphone
    var isRecording = false
    var outputFile: URL?

    // Sync
    var sessionStartTime: CMTime = .invalid
    private let writerLock = NSLock()
    private var streamStartHostTime: UInt64 = 0 // CACurrentMediaTime at stream start

    // Config
    var captureRect: CGRect?          // In screen coordinates (bottom-left origin)
    var captureScreen: NSScreen?      // The screen the rect belongs to
    var captureApp: SCRunningApplication?

    // Callbacks
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    var onCountdownUpdate: ((Int) -> Void)?

    func startRecording() {
        if isRecording { return }

        if currentSettings.timer > 0 {
            startCountdown(currentSettings.timer)
        } else {
            beginCapture()
        }
    }

    private func startCountdown(_ seconds: Int) {
        var remaining = seconds
        onCountdownUpdate?(remaining)

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining > 0 {
                self?.onCountdownUpdate?(remaining)
            } else {
                timer.invalidate()
                self?.beginCapture()
            }
        }
    }

    private func beginCapture() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.onError?(error) }
                return
            }
            guard let content = content else {
                DispatchQueue.main.async { self.onError?(NSError(domain: "RecorderError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No shareable content"])) }
                return
            }

            // Determine Filter
            let filter: SCContentFilter
            let targetDisplay: SCDisplay

            if let app = self.captureApp {
                // App mode: find display containing app (heuristic: first display)
                guard let display = content.displays.first else {
                    DispatchQueue.main.async { self.onError?(NSError(domain: "RecorderError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for app"])) }
                    return
                }
                targetDisplay = display
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                // Screen / Region mode: Must match captureScreen to SCDisplay
                if let screen = self.captureScreen {
                    // Match by displayID
                    targetDisplay = content.displays.first { $0.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) } ?? content.displays.first!
                } else {
                    // Entire screen: default to main screen's display
                    let mainScreen = NSScreen.main
                    targetDisplay = content.displays.first { $0.displayID == (mainScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) } ?? content.displays.first!
                }

                let myProcessId = ProcessInfo.processInfo.processIdentifier
                guard let myApp = content.applications.first(where: { $0.processID == myProcessId }) else {
                    filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: [])
                    self.continueStartingRecording(filter: filter, display: targetDisplay)
                    return
                }
                filter = SCContentFilter(display: targetDisplay, excludingApplications: [myApp], exceptingWindows: [])
            }

            self.continueStartingRecording(filter: filter, display: targetDisplay)
        }
    }

    private func continueStartingRecording(filter: SCContentFilter, display: SCDisplay) {
        let config = SCStreamConfiguration()
        let scaleFactor = captureScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0

        var baseWidth = display.width
        var baseHeight = display.height
        var sourceRect: CGRect? = nil

        // ---- REGION LOGIC ----
        if let rect = captureRect, rect != .zero, let screen = captureScreen {
            // 1. Verify screen matches display
            let screenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard screenDisplayID == display.displayID else {
                DispatchQueue.main.async {
                    self.onError?(NSError(domain: "RecorderError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Selected region screen mismatch. Try selecting region again."]))
                }
                return
            }

            // 2. Convert rect: Screen Coords (Bottom-Left) -> Display Coords (Top-Left, Points)
            // rect.origin is relative to screen.frame.origin (which is global bottom-left).
            // SCStream sourceRect origin is Top-Left of display in Points.
            let displayHeightPoints = CGFloat(display.height)
            let flippedY = displayHeightPoints - rect.maxY // maxY = y + h

            // 3. Clamp to display bounds (Points)
            let x = max(0, min(Int(rect.origin.x), display.width - 2))
            let y = max(0, min(Int(flippedY), display.height - 2))
            var w = max(2, min(Int(rect.width), display.width - x))
            var h = max(2, min(Int(rect.height), display.height - y))

            // 4. Ensure Even Dimensions (HEVC Requirement)
            if w % 2 != 0 { w -= 1 }
            if h % 2 != 0 { h -= 1 }

            guard w >= 2, h >= 2 else {
                DispatchQueue.main.async {
                    self.onError?(NSError(domain: "RecorderError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Selected region too small after clamping (min 2x2 points)."]))
                }
                return
            }

            sourceRect = CGRect(x: x, y: y, width: w, height: h)
            config.sourceRect = sourceRect!
            baseWidth = w
            baseHeight = h

            os_log("Region Capture: ScreenRect=%{public} SourceRect=%{public} Display=%{public}d", log: log, type: .info,
                   "\(rect)", "\(sourceRect!)", display.displayID)
        }
        // ----------------------

        // Output Resolution (Pixels)
        if currentSettings.resolution == 1080 {
            let ratio = CGFloat(baseWidth) / CGFloat(baseHeight)
            config.width = 1920
            config.height = Int(1920 / ratio)
        } else if currentSettings.resolution == 720 {
            let ratio = CGFloat(baseWidth) / CGFloat(baseHeight)
            config.width = 1280
            config.height = Int(1280 / ratio)
        } else {
            // Native: Output Pixels = Source Points * Scale
            if sourceRect != nil {
                config.width = Int(CGFloat(baseWidth) * scaleFactor)
                config.height = Int(CGFloat(baseHeight) * scaleFactor)
            } else {
                config.width = display.width * Int(scaleFactor)
                config.height = display.height * Int(scaleFactor)
            }
        }

        // Clamp to display pixel limits
        let maxPxW = Int(CGFloat(display.width) * scaleFactor)
        let maxPxH = Int(CGFloat(display.height) * scaleFactor)
        config.width = min(config.width, maxPxW)
        config.height = min(config.height, maxPxH)
        if config.width % 2 != 0 { config.width += 1 }
        if config.height % 2 != 0 { config.height += 1 }

        // Stream Config
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(currentSettings.fps))
        config.queueDepth = 5
        config.capturesAudio = (currentSettings.audioSource == 0 || currentSettings.audioSource == 2)
        config.showsCursor = true
        // Shows Clicks (Private API, best effort)
        let clickKey = "showsClicks"
        if config.responds(to: Selector(("set\(clickKey.capitalized):"))) {
            config.setValue(currentSettings.showsClicks, forKey: clickKey)
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            try setupMic()
            try setupAssetWriter(config: config)

            self.stream = SCStream(filter: filter, configuration: config, delegate: self)

            try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Rec.videoQueue"))
            if currentSettings.audioSource == 0 || currentSettings.audioSource == 2 {
                try self.stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "Rec.audioQueue"))
            }

            self.stream?.startCapture { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    DispatchQueue.main.async { self.onError?(error) }
                } else {
                    // SYNC ANCHOR: Capture host time exactly when capture starts
                    self.streamStartHostTime = mach_absolute_time()
                    self.writerLock.lock()
                    self.isRecording = true
                    self.writerLock.unlock()
                    DispatchQueue.main.async { self.onRecordingStarted?() }
                }
            }
        } catch {
            DispatchQueue.main.async { self.onError?(error) }
        }
    }

    // MARK: - Mic Setup
    private func setupMic() throws {
        guard currentSettings.audioSource == 1 || currentSettings.audioSource == 2 else { return }

        micSession = AVCaptureSession()

        var selectedMic: AVCaptureDevice? = nil
        if !currentSettings.micID.isEmpty {
            selectedMic = AVCaptureDevice(uniqueID: currentSettings.micID)
        }
        if selectedMic == nil {
            selectedMic = AVCaptureDevice.default(for: .audio)
        }

        guard let mic = selectedMic,
              let input = try? AVCaptureDeviceInput(device: mic) else { return }

        if micSession?.canAddInput(input) == true {
            micSession?.addInput(input)
        }

        micOutput = AVCaptureAudioDataOutput()
        if let out = micOutput, micSession?.canAddOutput(out) == true {
            micSession?.addOutput(out)
        }

        micOutput?.setSampleBufferDelegate(self, queue: DispatchQueue(label: "Rec.micQueue"))
        micSession?.startRunning()
    }

    // MARK: - Asset Writer
    private func setupAssetWriter(config: SCStreamConfiguration) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dateString = formatter.string(from: Date())

        var directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        if !currentSettings.saveDirectory.isEmpty {
            let customURL = URL(fileURLWithPath: currentSettings.saveDirectory)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: customURL.path, isDirectory: &isDir), isDir.boolValue {
                directoryURL = customURL
            }
        }

        let fileURL = directoryURL.appendingPathComponent("Screen Recording \(dateString).mov")
        self.outputFile = fileURL

        assetWriter = try AVAssetWriter(url: fileURL, fileType: .mov)

        var bitrate = config.width * config.height * 2
        if currentSettings.bitrate == 1 { bitrate = config.width * config.height }
        if currentSettings.bitrate == 2 { bitrate = (config.width * config.height) / 2 }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        if let videoInput = videoInput, assetWriter?.canAdd(videoInput) == true {
            assetWriter?.add(videoInput)
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 320000
        ]

        if currentSettings.audioSource == 0 || currentSettings.audioSource == 2 {
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
                assetWriter?.add(audioInput)
            }
        }
        if currentSettings.audioSource == 1 || currentSettings.audioSource == 2 {
            micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            micInput?.expectsMediaDataInRealTime = true
            if let micInput = micInput, assetWriter?.canAdd(micInput) == true {
                assetWriter?.add(micInput)
            }
        }

        // Start Writing Session (Header)
        guard assetWriter?.startWriting() == true else {
            throw NSError(domain: "RecorderError", code: -3, userInfo: [NSLocalizedDescriptionKey: "AssetWriter failed to start writing."])
        }
        // Note: startSession(atSourceTime:) called on first valid sample buffer
    }

    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Early exit if not recording
        writerLock.lock()
        let recording = isRecording
        writerLock.unlock()
        guard recording else { return }

        guard let assetWriter = assetWriter else { return }

        // Validate PTS
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(pts) > 0 else { return }

        writerLock.lock()
        defer { writerLock.unlock() }

        // Initialize Session Start Time (Monotonic Host Clock -> PTS mapping)
        // We use the FIRST video frame PTS as the timeline anchor.
        if sessionStartTime == .invalid {
            // Only anchor on Video to avoid audio drift starting earlier/later
            if type == .screen {
                sessionStartTime = pts
                assetWriter.startSession(atSourceTime: sessionStartTime)
                os_log("Session Started at PTS: %{public}f", log: log, type: .info, CMTimeGetSeconds(sessionStartTime))
            } else {
                // Drop audio until video starts
                writerLock.unlock()
                return
            }
        }

        // Gate: Drop frames before session start (shouldn't happen but safe)
        if CMTimeCompare(pts, sessionStartTime) < 0 { return }

        if type == .screen {
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        } else if type == .audio {
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        os_log("Stream Stopped Error: %{public}@", log: log, type: .error, error.localizedDescription)
        DispatchQueue.main.async {
            self.onError?(error)
            self.stopRecording()
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (Mic)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writerLock.lock()
        let recording = isRecording
        writerLock.unlock()
        guard recording else { return }

        guard let assetWriter = assetWriter else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(pts) > 0 else { return }

        writerLock.lock()
        defer { writerLock.unlock() }

        // Mic Clock Domain: AVCapture uses Device Clock. SCStream uses Host Clock.
        // Without explicit clock sync (CMClock), Mic will drift.
        // WORKAROUND: If sessionStartTime valid, append. Drift is unavoidable without sync.
        if sessionStartTime != .invalid {
            if let micInput = micInput, micInput.isReadyForMoreMediaData {
                micInput.append(sampleBuffer)
            }
        }
    }

    // MARK: - Stop Recording
    func stopRecording() {
        // Atomic check-and-set
        writerLock.lock()
        let wasRecording = isRecording
        isRecording = false
        writerLock.unlock()

        guard wasRecording else { return }

        // Stop Mic immediately
        micSession?.stopRunning()
        micSession = nil
        micOutput = nil

        // Stop SCStream
        stream?.stopCapture { [weak self] error in
            guard let self = self else { return }
            if let error = error { DispatchQueue.main.async { self.onError?(error) } }

            self.writerLock.lock()
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micInput?.markAsFinished()

            self.assetWriter?.finishWriting { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if let url = self.outputFile { self.onRecordingStopped?(url) }
                }
                // Cleanup
                self.writerLock.lock()
                self.stream = nil
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.micInput = nil
                self.sessionStartTime = .invalid
                self.streamStartHostTime = 0
                self.writerLock.unlock()
            }
            self.writerLock.unlock()
        }
    }
}

// ============================================================
// UI Components
// ============================================================

class FloatingPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView], backing: backingStoreType, defer: flag)
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear

        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true
        self.contentView = visualEffectView
    }
}

// MARK: - About Window
class AboutWindowController: NSWindowController {
    var updateButton: NSButton!
    var updateStatus: NSTextField!

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "About Rec"
        win.center()
        self.init(window: win)

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        win.contentView = stackView

        let iconView = NSImageView()
        let size = NSSize(width: 64, height: 64)
        let customImage = NSImage(size: size)
        customImage.lockFocus()
        NSColor.white.setStroke()
        let outerPath = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4))
        outerPath.lineWidth = 2
        outerPath.stroke()
        NSColor.systemRed.setFill()
        let innerPath = NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: size.width - 28, height: size.height - 28))
        innerPath.fill()
        customImage.unlockFocus()
        iconView.image = customImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stackView.addArrangedSubview(iconView)

        let title = NSTextField(labelWithString: "Rec")
        title.font = .boldSystemFont(ofSize: 24)
        stackView.addArrangedSubview(title)

        let ver = NSTextField(labelWithString: "Version \(appVersion)")
        ver.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(ver)

        let desc = NSTextField(labelWithString: "A clean, native screen and internal audio recorder.")
        desc.alignment = .center
        desc.lineBreakMode = .byWordWrapping
        desc.preferredMaxLayoutWidth = 260
        stackView.addArrangedSubview(desc)

        updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        stackView.addArrangedSubview(updateButton)

        updateStatus = NSTextField(labelWithString: "")
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.font = .systemFont(ofSize: 11)
        stackView.addArrangedSubview(updateStatus)
    }

    @objc func checkForUpdates() {
        updateButton.isEnabled = false
        updateStatus.stringValue = "Checking..."

        guard let url = URL(string: updateCheckURL) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.updateButton.isEnabled = true
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    self?.updateStatus.stringValue = "Update server unreachable (\(httpResponse.statusCode))."
                    return
                }
                guard let data = data, error == nil else {
                    self?.updateStatus.stringValue = "Failed to check for updates."
                    return
                }
                do {
                    if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let version = json["version"] as? String {
                        if version != appVersion {
                            self?.updateStatus.stringValue = "Update available: v\(version)!"
                            if let dlURL = URL(string: "https://rec-aoh.netlify.app/#installc") {
                                NSWorkspace.shared.open(dlURL)
                            }
                        } else {
                            self?.updateStatus.stringValue = "You are on the latest version."
                        }
                    } else {
                        self?.updateStatus.stringValue = "Invalid update data."
                    }
                } catch {
                    self?.updateStatus.stringValue = "Failed to parse update info."
                }
            }
        }.resume()
    }
}

// ============================================================
// App Delegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var recordButton: NSButton!
    var closeButton: NSButton!
    var modePopUp: NSPopUpButton!
    let recorder = Recorder()

    var statusItem: NSStatusItem!
    var appSelectionMenu: AppSelectionMenuHandler?
    var aboutWC: AboutWindowController?

    var countdownWindow: NSWindow?
    var countdownLabel: NSTextField?
    var recordingOverlay: RecordingOverlayWindow?
    var regionSelectionManager: RegionSelectionManager?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
        setupUI()
        setupRecorder()
        checkPermissions()
    }

    func checkPermissions() {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            CGRequestScreenCaptureAccess()
            // Optionally poll or show alert
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Rec needs Screen Recording permission in System Settings > Privacy & Security > Screen Recording. Please grant access and restart the app."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            NSApp.terminate(nil)
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rec")
        }

        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Rec", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())

        let showControlsItem = NSMenuItem(title: "Show Controls", action: #selector(showPanel), keyEquivalent: "s")
        showControlsItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(showControlsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Rec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func hidePanel() {
        panel.orderOut(nil)
    }
    @objc func showAbout() {
        if aboutWC == nil { aboutWC = AboutWindowController() }
        aboutWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings Actions
    @objc func fpsChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        let index = menu.index(of: sender)
        if index == 0 { currentSettings.fps = 60 }
        else if index == 1 { currentSettings.fps = 30 }
        else { currentSettings.fps = 24 }
        currentSettings.save()
    }
    @objc func resChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        let index = menu.index(of: sender)
        if index == 0 { currentSettings.resolution = 0 }
        else if index == 1 { currentSettings.resolution = 1080 }
        else { currentSettings.resolution = 720 }
        currentSettings.save()
    }
    @objc func bitChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        currentSettings.bitrate = menu.index(of: sender)
        currentSettings.save()
    }
    @objc func audioChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }

        let index = menu.index(of: sender)

        if index < 4 {
            for i in 0..<4 {
                if let item = menu.item(at: i) { item.state = .off }
            }
            sender.state = .on
            currentSettings.audioSource = index
        } else {
            for i in 5..<menu.numberOfItems {
                if let item = menu.item(at: i) { item.state = .off }
            }
            sender.state = .on
            currentSettings.micID = sender.identifier?.rawValue ?? ""
        }
        currentSettings.save()
    }
    @objc func timerChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 { currentSettings.timer = 0 }
        else if sender.indexOfSelectedItem == 1 { currentSettings.timer = 5 }
        else { currentSettings.timer = 10 }
        currentSettings.save()
    }

    @objc func toggleMouseClicks(_ sender: NSMenuItem) {
        currentSettings.showsClicks.toggle()
        currentSettings.save()
        sender.state = currentSettings.showsClicks ? .on : .off
    }

    @objc func chooseSaveLocation(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Save Location"

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                currentSettings.saveDirectory = url.path
                currentSettings.save()
            }
        }
    }

    // MARK: - UI Setup
    func setupUI() {
        guard let screen = NSScreen.main else { return }
        let rect = NSRect(x: screen.frame.width / 2, y: 100, width: 10, height: 10)
        panel = FloatingPanel(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
        guard let contentView = panel.contentView else { return }

        recordButton = NSButton()
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.bezelStyle = .regularSquare
        recordButton.isBordered = false
        recordButton.imagePosition = .imageOnly
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)

        updateButtonImage()

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

        // Audio Popup
        let audioPopUp = NSPopUpButton()
        audioPopUp.translatesAutoresizingMaskIntoConstraints = false
        audioPopUp.removeAllItems()
        audioPopUp.isBordered = false
        audioPopUp.imagePosition = .imageOnly
        let audioSystemItem = NSMenuItem(title: "System Audio", action: nil, keyEquivalent: "")
        audioSystemItem.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let audioMicItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        audioMicItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let audioBothItem = NSMenuItem(title: "System + Mic", action: nil, keyEquivalent: "")
        audioBothItem.image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let audioNoneItem = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        audioNoneItem.image = NSImage(systemSymbolName: "speaker.slash", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        audioSystemItem.target = self; audioSystemItem.action = #selector(audioChanged(_:))
        audioMicItem.target = self; audioMicItem.action = #selector(audioChanged(_:))
        audioBothItem.target = self; audioBothItem.action = #selector(audioChanged(_:))
        audioNoneItem.target = self; audioNoneItem.action = #selector(audioChanged(_:))

        if currentSettings.audioSource == 0 { audioSystemItem.state = .on }
        else if currentSettings.audioSource == 1 { audioMicItem.state = .on }
        else if currentSettings.audioSource == 2 { audioBothItem.state = .on }
        else { audioNoneItem.state = .on }

        audioPopUp.menu?.addItem(audioSystemItem)
        audioPopUp.menu?.addItem(audioMicItem)
        audioPopUp.menu?.addItem(audioBothItem)
        audioPopUp.menu?.addItem(audioNoneItem)
        audioPopUp.menu?.addItem(NSMenuItem.separator())

        // Mic List
        let deviceType = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeBuiltInMicrophone")
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [deviceType], mediaType: .audio, position: .unspecified)
        for device in session.devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(audioChanged(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(device.uniqueID)
            item.target = self
            item.indentationLevel = 1
            if currentSettings.micID == device.uniqueID { item.state = .on }
            audioPopUp.menu?.addItem(item)
        }

        // Timer Popup
        let timerPopUp = NSPopUpButton()
        timerPopUp.translatesAutoresizingMaskIntoConstraints = false
        timerPopUp.removeAllItems()
        timerPopUp.isBordered = false
        timerPopUp.imagePosition = .imageOnly
        let timerNoneItem = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        timerNoneItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let timer5sItem = NSMenuItem(title: "5 Seconds", action: nil, keyEquivalent: "")
        timer5sItem.image = NSImage(systemSymbolName: "5.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let timer10sItem = NSMenuItem(title: "10 Seconds", action: nil, keyEquivalent: "")
        timer10sItem.image = NSImage(systemSymbolName: "10.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        timerPopUp.menu?.addItem(timerNoneItem)
        timerPopUp.menu?.addItem(timer5sItem)
        timerPopUp.menu?.addItem(timer10sItem)
        if currentSettings.timer == 0 { timerPopUp.selectItem(at: 0) }
        else if currentSettings.timer == 5 { timerPopUp.selectItem(at: 1) }
        else { timerPopUp.selectItem(at: 2) }
        timerPopUp.action = #selector(timerChanged(_:))
        timerPopUp.target = self

        // Settings Popup
        let settingsPopUp = NSPopUpButton()
        settingsPopUp.translatesAutoresizingMaskIntoConstraints = false
        settingsPopUp.removeAllItems()
        settingsPopUp.isBordered = false
        settingsPopUp.imagePosition = .imageOnly
        settingsPopUp.pullsDown = true
        let gearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        gearItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        settingsPopUp.menu?.addItem(gearItem)

        let fpsMenu = NSMenu(title: "Framerate")
        let fps60 = fpsMenu.addItem(withTitle: "60 FPS", action: #selector(fpsChanged(_:)), keyEquivalent: ""); fps60.target = self
        let fps30 = fpsMenu.addItem(withTitle: "30 FPS", action: #selector(fpsChanged(_:)), keyEquivalent: ""); fps30.target = self
        let fps24 = fpsMenu.addItem(withTitle: "24 FPS", action: #selector(fpsChanged(_:)), keyEquivalent: ""); fps24.target = self
        if currentSettings.fps == 60 { fps60.state = .on }
        else if currentSettings.fps == 30 { fps30.state = .on }
        else { fps24.state = .on }
        let fpsItem = NSMenuItem(title: "Framerate", action: nil, keyEquivalent: "")
        fpsItem.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        fpsItem.submenu = fpsMenu
        settingsPopUp.menu?.addItem(fpsItem)

        let resMenu = NSMenu(title: "Resolution")
        let resNat = resMenu.addItem(withTitle: "Native", action: #selector(resChanged(_:)), keyEquivalent: ""); resNat.target = self
        let res1080 = resMenu.addItem(withTitle: "1080p", action: #selector(resChanged(_:)), keyEquivalent: ""); res1080.target = self
        let res720 = resMenu.addItem(withTitle: "720p", action: #selector(resChanged(_:)), keyEquivalent: ""); res720.target = self
        if currentSettings.resolution == 0 { resNat.state = .on }
        else if currentSettings.resolution == 1080 { res1080.state = .on }
        else { res720.state = .on }
        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        resItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        resItem.submenu = resMenu
        settingsPopUp.menu?.addItem(resItem)

        let bitMenu = NSMenu(title: "Bitrate")
        let bitHigh = bitMenu.addItem(withTitle: "High", action: #selector(bitChanged(_:)), keyEquivalent: ""); bitHigh.target = self
        let bitMed = bitMenu.addItem(withTitle: "Medium", action: #selector(bitChanged(_:)), keyEquivalent: ""); bitMed.target = self
        let bitLow = bitMenu.addItem(withTitle: "Low", action: #selector(bitChanged(_:)), keyEquivalent: ""); bitLow.target = self
        if currentSettings.bitrate == 0 { bitHigh.state = .on }
        else if currentSettings.bitrate == 1 { bitMed.state = .on }
        else { bitLow.state = .on }
        let bitItem = NSMenuItem(title: "Bitrate", action: nil, keyEquivalent: "")
        bitItem.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
        bitItem.submenu = bitMenu
        settingsPopUp.menu?.addItem(bitItem)

        settingsPopUp.menu?.addItem(NSMenuItem.separator())
        let clickItem = NSMenuItem(title: "Show Mouse Clicks", action: #selector(toggleMouseClicks(_:)), keyEquivalent: "")
        clickItem.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: nil)
        clickItem.target = self
        clickItem.state = currentSettings.showsClicks ? .on : .off
        settingsPopUp.menu?.addItem(clickItem)

        let locationItem = NSMenuItem(title: "Save Location...", action: #selector(chooseSaveLocation(_:)), keyEquivalent: "")
        locationItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        locationItem.target = self
        settingsPopUp.menu?.addItem(locationItem)

        // Close Button
        closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        closeButton.target = self
        closeButton.action = #selector(hidePanel)

        // Mode Popup
        modePopUp = NSPopUpButton()
        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        modePopUp.removeAllItems()
        modePopUp.isBordered = false
        modePopUp.imagePosition = .imageOnly

        let screenItem = NSMenuItem(title: "Entire Screen", action: nil, keyEquivalent: "")
        screenItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Entire Screen")?.withSymbolConfiguration(config)
        screenItem.toolTip = "Entire Screen"

        let portionItem = NSMenuItem(title: "Selected Portion", action: nil, keyEquivalent: "")
        portionItem.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "Selected Portion")?.withSymbolConfiguration(config)
        portionItem.toolTip = "Selected Portion"

        let appItem = NSMenuItem(title: "Specific App", action: nil, keyEquivalent: "")
        appItem.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "Specific App")?.withSymbolConfiguration(config)
        appItem.toolTip = "Specific App"

        modePopUp.menu?.addItem(screenItem)
        modePopUp.menu?.addItem(portionItem)
        modePopUp.menu?.addItem(appItem)

        // Stack View
        let stackView = NSStackView(views: [closeButton, settingsPopUp, timerPopUp, audioPopUp, modePopUp, recordButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 16
        stackView.alignment = .centerY

        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])

        stackView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        panel.setContentSize(fittingSize)
        panel.setFrameOrigin(NSPoint(x: (screen.frame.width - fittingSize.width) / 2, y: 100))

        panel.makeKeyAndOrderFront(nil)
    }

    func setupRecorder() {
        recorder.onCountdownUpdate = { [weak self] seconds in
            self?.showCountdown(seconds)
        }

        recorder.onRecordingStarted = { [weak self] in
            self?.hideCountdown()
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = false

            if let rect = self?.recorder.captureRect, rect != .zero, let screen = self?.recorder.captureScreen {
                self?.recordingOverlay = RecordingOverlayWindow(screen: screen, holeRect: rect)
                self?.recordingOverlay?.makeKeyAndOrderFront(nil)
            }
        }

        recorder.onRecordingStopped = { [weak self] url in
            self?.recordingOverlay?.close()
            self?.recordingOverlay = nil
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = true
            let alert = NSAlert()
            alert.messageText = "Recording Saved"
            alert.informativeText = "Saved to \(url.lastPathComponent) in Downloads folder."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }

        recorder.onError = { [weak self] error in
            self?.recordingOverlay?.close()
            self?.recordingOverlay = nil
            self?.hideCountdown()
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = true
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    func showCountdown(_ seconds: Int) {
        if countdownWindow == nil {
            countdownLabel = NSTextField(labelWithString: "")
            countdownLabel?.font = .systemFont(ofSize: 120, weight: .bold)
            countdownLabel?.textColor = .white
            countdownLabel?.backgroundColor = NSColor.black.withAlphaComponent(0.5)
            countdownLabel?.drawsBackground = true
            countdownLabel?.isBordered = false
            countdownLabel?.alignment = .center
            countdownLabel?.layer?.cornerRadius = 20
            countdownLabel?.layer?.masksToBounds = true
            countdownLabel?.translatesAutoresizingMaskIntoConstraints = false

            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .floating
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .stationary]
            win.contentView?.addSubview(countdownLabel!)
            NSLayoutConstraint.activate([
                countdownLabel!.centerXAnchor.constraint(equalTo: win.contentView!.centerXAnchor),
                countdownLabel!.centerYAnchor.constraint(equalTo: win.contentView!.centerYAnchor),
                countdownLabel!.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
                countdownLabel!.heightAnchor.constraint(lessThanOrEqualToConstant: 180)
            ])
            win.center()
            countdownWindow = win
        }
        countdownLabel?.stringValue = "\(seconds)"
        countdownWindow?.makeKeyAndOrderFront(nil)
    }

    func hideCountdown() {
        countdownWindow?.close()
        countdownWindow = nil
        countdownLabel = nil
    }

    @objc func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            startRecordingProcess()
        }
    }

    func startRecordingProcess() {
        let modeIndex = modePopUp.indexOfSelectedItem

        if modeIndex == 2 { // Specific App
            appSelectionMenu = AppSelectionMenuHandler()
            appSelectionMenu?.onSelect = { [weak self] app in
                self?.recorder.captureApp = app
                self?.recorder.captureRect = nil
                self?.recorder.captureScreen = nil
                self?.recorder.startRecording()
            }
            appSelectionMenu?.showMenu(at: modePopUp)
        } else if modeIndex == 1 { // Selected Portion
            // Hide panel during selection
            self.panel.orderOut(nil)

            regionSelectionManager = RegionSelectionManager()
            regionSelectionManager?.startSelection { [weak self] rect, screen in
                guard let self = self else { return }
                self.panel.makeKeyAndOrderFront(nil)

                if rect != .zero, let screen = screen {
                    self.recorder.captureApp = nil
                    self.recorder.captureRect = rect
                    self.recorder.captureScreen = screen
                    self.recorder.startRecording()
                }
            }
        } else { // Entire Screen
            recorder.captureApp = nil
            recorder.captureRect = nil
            recorder.captureScreen = NSScreen.main // Default to main for full screen
            recorder.startRecording()
        }
    }

    func updateButtonImage() {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let symbolName = recorder.isRecording ? "stop.circle.fill" : "record.circle"
        if let systemImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = systemImage.size
            let tintedImage = NSImage(size: size)
            tintedImage.lockFocus()

            if symbolName == "record.circle" {
                NSColor.white.setStroke()
                let outerPath = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4))
                outerPath.lineWidth = 2
                outerPath.stroke()

                NSColor.systemRed.setFill()
                let innerPath = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: size.width - 14, height: size.height - 14))
                innerPath.fill()
            } else {
                systemImage.draw(in: NSRect(origin: .zero, size: size))
                NSColor.white.set()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            }

            tintedImage.unlockFocus()
            recordButton.image = tintedImage
        }
    }

    deinit {
        // Cleanup windows
        recordingOverlay?.close()
        countdownWindow?.close()
        regionSelectionManager = nil
    }
}

// ============================================================
// Entry Point
// ============================================================

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
