import Cocoa
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import os.log

// MARK: - Configuration
let appVersion = "1.1.0"
let updateCheckURL = "https://rec-aoh.netlify.app/version.json"
private let log = OSLog(subsystem: "com.rec.app", category: "recorder")

struct AppSettings: Codable {
    var fps: Int = 60
    var resolution: Int = 0 // 0 = Native, 1080, 720
    var bitrate: Int = 0    // 0 = High, 1 = Med, 2 = Low
    var audioSource: Int = 0 // 0=Sys, 1=Mic, 2=Both, 3=None
    var showsClicks: Bool = false
    var saveDirectory: String = ""
    var micID: String = ""
    var recordMode: Int = 0
    var timer: Int = 0
    var cameraID: String = "None"
    var highlightCursor: Bool = false
    var cursorColor: Int = 0
    var mirrorCamera: Bool = true
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
        self.isReleasedWhenClosed = false

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

        NSColor.black.withAlphaComponent(0.4).set()
        dirtyRect.fill()

        if window.holeRect != .zero {
            // holeRect is stored in screen-local coords, which already match
            // this window's local coordinate space (window covers entire screen).
            // No global <-> local conversion needed.
            let localRect = window.holeRect
            NSColor.clear.set()
            localRect.fill(using: .sourceOut)
        }
    }
}


// ============================================================
// Region Selection & Countdown UI
// ============================================================

class CameraOverlayWindow: NSWindow {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var captureSession: AVCaptureSession?
    
    init() {
        let size: CGFloat = 200
        let frame = NSRect(x: 50, y: 50, width: size, height: size)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isReleasedWhenClosed = false
        self.isMovableByWindowBackground = true
        
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = size / 2
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderWidth = 2
        containerView.layer?.borderColor = NSColor.white.cgColor
        
        previewLayer.frame = containerView.bounds
        previewLayer.videoGravity = .resizeAspectFill
        containerView.layer?.addSublayer(previewLayer)
        self.contentView = containerView
    }
    
    func startCamera(deviceID: String) {
        captureSession?.stopRunning()
        captureSession = AVCaptureSession()
        guard let session = captureSession else { return }
        session.sessionPreset = .high
        
        let device: AVCaptureDevice?
        if deviceID.isEmpty || deviceID == "None" {
            device = AVCaptureDevice.default(for: .video)
        } else {
            device = AVCaptureDevice(uniqueID: deviceID)
        }
        
        guard let device = device,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
              
        if session.canAddInput(input) {
            session.addInput(input)
        }
        previewLayer.session = session
        
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = currentSettings.mirrorCamera
        }
        
        session.startRunning()
    }
    
    func stopCamera() {
        captureSession?.stopRunning()
        captureSession = nil
    }
}
class CursorHighlighterWindow: NSWindow {
    var circleView: NSView!
    
    init() {
        let size: CGFloat = 40
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false
        
        circleView = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        circleView.wantsLayer = true
        circleView.layer?.cornerRadius = size / 2
        circleView.layer?.masksToBounds = true
        self.contentView = circleView
        
        updateColor()
    }
    
    func updateColor() {
        let alpha: CGFloat = 0.5
        switch currentSettings.cursorColor {
        case 0: circleView.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(alpha).cgColor
        case 1: circleView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(alpha).cgColor
        case 2: circleView.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(alpha).cgColor
        case 3: circleView.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(alpha).cgColor
        default: circleView.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(alpha).cgColor
        }
    }
    
    func moveTo(point: NSPoint) {
        let size = self.frame.size
        // NSPoint is lower-left origin, so center the window around the mouse
        self.setFrameOrigin(NSPoint(x: point.x - size.width/2, y: point.y - size.height/2))
    }
}

class RegionSelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isReleasedWhenClosed = false

        let selectionView = RegionSelectionView(frame: self.contentView?.bounds ?? .zero)
        selectionView.autoresizingMask = [.width, .height]
        self.contentView = selectionView
    }
}

class RegionSelectionView: NSView {
    var startPoint: NSPoint?
    var currentRect: NSRect = .zero
    var onSelectionComplete: ((NSRect) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.4).set()
        dirtyRect.fill()

        if currentRect != .zero {
            NSColor.clear.set()
            currentRect.fill(using: .sourceOut)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2.0
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, currentPoint.x),
            y: min(start.y, currentPoint.y),
            width: abs(currentPoint.x - start.x),
            height: abs(currentPoint.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onSelectionComplete?(currentRect)
    }
}

class CountdownWindow: NSWindow {
    var label: NSTextField!

    init(screen: NSScreen) {
        let size: CGFloat = 200
        let rect = NSRect(x: screen.frame.midX - size/2, y: screen.frame.midY - size/2, width: size, height: size)
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false

        let containerView = NSView()
        self.contentView = containerView

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 100, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.isBordered = false
        label.drawsBackground = false
        
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 4
        label.shadow = shadow
        
        label.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
    }

    func updateText(_ text: String) {
        label.stringValue = text
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
        onSelect?(apps[sender.tag])
    }
}

// ============================================================
// Recorder Core — FIXED REGION COORDINATE CONVERSION
// ============================================================

class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    var micSession: AVCaptureSession?
    var micOutput: AVCaptureAudioDataOutput?

    var stream: SCStream?
    var assetWriter: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput?
    var micInput: AVAssetWriterInput?
    var isRecording = false
    var isPaused = false
    var totalPausedDuration: CMTime = .zero
    var pauseStartTime: CMTime = .invalid
    var outputFile: URL?

    var sessionStartTime: CMTime = .invalid
    private let writerLock = NSLock()
    private var streamStartHostTime: UInt64 = 0

    var captureRect: CGRect?          // Screen-Local Coords (Bottom-Left Origin)
    var captureScreen: NSScreen?      // The screen the rect belongs to
    var captureApp: SCRunningApplication?

    var cameraWindowID: Int?
    var cursorWindowID: Int?
    
    private var targetScreenID: CGDirectDisplayID?
    private var targetScaleFactor: CGFloat = 1.0

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    var onMicAudioLevel: ((Float) -> Void)?

    func startRecording() {
        if isRecording { return }
        isPaused = false
        totalPausedDuration = .zero
        pauseStartTime = .invalid
        
        let screen = captureScreen ?? NSScreen.main
        targetScreenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        targetScaleFactor = screen?.backingScaleFactor ?? 1.0
        
        beginCapture()
    }

    private func beginCapture() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }
            if let error = error { DispatchQueue.main.async { self.onError?(error) }; return }
            guard let content = content else {
                DispatchQueue.main.async { self.onError?(NSError(domain: "RecorderError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No shareable content"])) }
                return
            }

            let filter: SCContentFilter
            let targetDisplay: SCDisplay
            var excepting = [SCWindow]()

            let myProcessId = ProcessInfo.processInfo.processIdentifier
            var exceptingAppWindows = content.windows.filter { $0.owningApplication?.processID == myProcessId }
            
            if let camWinID = self.cameraWindowID { exceptingAppWindows.removeAll(where: { $0.windowID == CGWindowID(camWinID) }) }
            if let cursorWinID = self.cursorWindowID { exceptingAppWindows.removeAll(where: { $0.windowID == CGWindowID(cursorWinID) }) }
            excepting.append(contentsOf: exceptingAppWindows)

            if let app = self.captureApp {
                guard let display = content.displays.first else {
                    DispatchQueue.main.async { self.onError?(NSError(domain: "RecorderError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for app"])) }
                    return
                }
                targetDisplay = display
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: excepting)
            } else {
                if let sID = self.targetScreenID {
                    targetDisplay = content.displays.first { $0.displayID == sID } ?? content.displays.first!
                } else {
                    targetDisplay = content.displays.first!
                }
                filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: excepting)
            }

            self.continueStartingRecording(filter: filter, display: targetDisplay)
        }
    }

    private func continueStartingRecording(filter: SCContentFilter, display: SCDisplay) {
        let config = SCStreamConfiguration()
        let scaleFactor = targetScaleFactor

        var baseWidth = display.width
        var baseHeight = display.height
        var sourceRect: CGRect? = nil

        // ============================================================
        // REGION LOGIC: Global Screen Coords -> Local Display Coords
        // ============================================================
        if let rect = captureRect, rect != .zero {
            // 1. Verify the screen matches the display we are capturing
            let screenDisplayID = targetScreenID
            guard screenDisplayID == display.displayID else {
                DispatchQueue.main.async {
                    self.onError?(NSError(domain: "RecorderError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Selected region screen mismatch. Try selecting region again."]))
                }
                return
            }

            // 2. rect is in SCREEN-LOCAL coordinates (Bottom-Left Origin, 0,0 at screen frame origin of THIS screen).
            //    SCStreamConfig.sourceRect expects DISPLAY-LOCAL coordinates (Top-Left Origin, 0,0 at display top-left).
            //    Since NSScreen.frame == Display bounds (in points), width/height match.
            //    We only need to FLIP Y.

            let displayHeightPoints = CGFloat(display.height) // Points
            let flippedY = displayHeightPoints - rect.maxY // maxY = y + h (Bottom-Left -> Top-Left)

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

            // FIX: Correct os_log format specifiers. Use %{public}@ for String
            // arguments and %d for the integer display ID.
            os_log("Region Capture: ScreenLocalRect=%{public}@ SourceRect(TopLeft)=%{public}@ Display=%d",
                   log: log, type: .info,
                   "\(rect)", "\(sourceRect!)", display.displayID)
        }
        // ============================================================

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
            if sourceRect != nil {
                config.width = Int(CGFloat(baseWidth) * scaleFactor)
                config.height = Int(CGFloat(baseHeight) * scaleFactor)
            } else {
                config.width = display.width * Int(scaleFactor)
                config.height = display.height * Int(scaleFactor)
            }
        }

        let maxPxW = Int(CGFloat(display.width) * scaleFactor)
        let maxPxH = Int(CGFloat(display.height) * scaleFactor)
        config.width = min(config.width, maxPxW)
        config.height = min(config.height, maxPxH)
        if config.width % 2 != 0 { config.width += 1 }
        if config.height % 2 != 0 { config.height += 1 }

        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(currentSettings.fps))
        config.queueDepth = 5
        config.capturesAudio = (currentSettings.audioSource == 0 || currentSettings.audioSource == 2)
        config.showsCursor = true

        if config.responds(to: NSSelectorFromString("setShowsClicks:")) {
            config.setValue(currentSettings.showsClicks, forKey: "showsClicks")
        }
        if config.responds(to: NSSelectorFromString("setCapturesMouseClicks:")) {
            config.setValue(currentSettings.showsClicks, forKey: "capturesMouseClicks")
        }
        if config.responds(to: NSSelectorFromString("setShowMouseClicks:")) {
            config.setValue(currentSettings.showsClicks, forKey: "showMouseClicks")
        }
        if config.responds(to: NSSelectorFromString("setShowsMouseClicks:")) {
            config.setValue(currentSettings.showsClicks, forKey: "showsMouseClicks")
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
                if let error = error { DispatchQueue.main.async { self.onError?(error) } }
                else {
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

    private func setupMic() throws {
        guard currentSettings.audioSource == 1 || currentSettings.audioSource == 2 else { return }
        micSession = AVCaptureSession()

        var selectedMic: AVCaptureDevice? = nil
        if !currentSettings.micID.isEmpty { selectedMic = AVCaptureDevice(uniqueID: currentSettings.micID) }
        if selectedMic == nil { selectedMic = AVCaptureDevice.default(for: .audio) }

        guard let mic = selectedMic, let input = try? AVCaptureDeviceInput(device: mic) else { return }
        if micSession?.canAddInput(input) == true { micSession?.addInput(input) }

        micOutput = AVCaptureAudioDataOutput()
        if let out = micOutput, micSession?.canAddOutput(out) == true { micSession?.addOutput(out) }

        micOutput?.setSampleBufferDelegate(self, queue: DispatchQueue(label: "Rec.micQueue"))
        micSession?.startRunning()
    }

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
        if let videoInput = videoInput, assetWriter?.canAdd(videoInput) == true { assetWriter?.add(videoInput) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 320000
        ]

        if currentSettings.audioSource == 0 || currentSettings.audioSource == 2 {
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true { assetWriter?.add(audioInput) }
        }
        if currentSettings.audioSource == 1 || currentSettings.audioSource == 2 {
            micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            micInput?.expectsMediaDataInRealTime = true
            if let micInput = micInput, assetWriter?.canAdd(micInput) == true { assetWriter?.add(micInput) }
        }

        guard assetWriter?.startWriting() == true else {
            throw NSError(domain: "RecorderError", code: -3, userInfo: [NSLocalizedDescriptionKey: "AssetWriter failed to start writing."])
        }
    }
    func togglePause() {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard isRecording else { return }
        
        if isPaused {
            isPaused = false
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if pauseStartTime != .invalid {
                let pausedDuration = CMTimeSubtract(now, pauseStartTime)
                totalPausedDuration = CMTimeAdd(totalPausedDuration, pausedDuration)
                pauseStartTime = .invalid
            }
        } else {
            isPaused = true
            pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    private func adjustSampleBuffer(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sampleBuffer }
        
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }
        
        var timingInfos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfos, entriesNeededOut: &count)
        
        for i in 0..<Int(count) {
            timingInfos[i].presentationTimeStamp = CMTimeSubtract(timingInfos[i].presentationTimeStamp, offset)
            if timingInfos[i].decodeTimeStamp != .invalid {
                timingInfos[i].decodeTimeStamp = CMTimeSubtract(timingInfos[i].decodeTimeStamp, offset)
            }
        }
        
        var newSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &timingInfos,
                                              sampleBufferOut: &newSampleBuffer)
        return newSampleBuffer ?? sampleBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writerLock.lock()
        let recording = isRecording
        let paused = isPaused
        let pausedOffset = totalPausedDuration
        writerLock.unlock()
        
        guard recording else { return }
        guard !paused else { return }
        guard let assetWriter = assetWriter else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(pts) > 0 else { return }

        guard let adjustedBuffer = adjustSampleBuffer(sampleBuffer, offset: pausedOffset) else { return }
        let adjustedPTS = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)

        writerLock.lock()
        defer { writerLock.unlock() }

        if sessionStartTime == .invalid {
            if type == .screen {
                sessionStartTime = adjustedPTS
                assetWriter.startSession(atSourceTime: sessionStartTime)
                os_log("Session Started at PTS: %{public}f", log: log, type: .info, CMTimeGetSeconds(sessionStartTime))
            } else { return }
        }

        if CMTimeCompare(adjustedPTS, sessionStartTime) < 0 { return }

        if type == .screen {
            guard CMSampleBufferGetImageBuffer(adjustedBuffer) != nil else { return }
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData { videoInput.append(adjustedBuffer) }
        } else if type == .audio {
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData { audioInput.append(adjustedBuffer) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        os_log("Stream Stopped Error: %{public}@", log: log, type: .error, error.localizedDescription)
        DispatchQueue.main.async { self.onError?(error); self.stopRecording() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writerLock.lock()
        let recording = isRecording
        let paused = isPaused
        let pausedOffset = totalPausedDuration
        writerLock.unlock()
        
        guard recording else { return }
        guard !paused else { return }
        guard assetWriter != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(pts) > 0 else { return }

        guard let adjustedBuffer = adjustSampleBuffer(sampleBuffer, offset: pausedOffset) else { return }

        writerLock.lock()
        defer { writerLock.unlock() }

        if sessionStartTime != .invalid {
            if let micInput = micInput, micInput.isReadyForMoreMediaData { micInput.append(adjustedBuffer) }
        }
        
        if let channel = connection.audioChannels.first {
            let level = channel.averagePowerLevel
            DispatchQueue.main.async { self.onMicAudioLevel?(level) }
        }
    }

    func stopRecording() {
        writerLock.lock()
        let wasRecording = isRecording
        isRecording = false
        writerLock.unlock()

        guard wasRecording else { return }

        micSession?.stopRunning()
        micSession = nil
        micOutput = nil

        stream?.stopCapture { [weak self] error in
            guard let self = self else { return }
            if let error = error { DispatchQueue.main.async { self.onError?(error) } }

            self.writerLock.lock()
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micInput?.markAsFinished()

            self.assetWriter?.finishWriting { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { if let url = self.outputFile { self.onRecordingStopped?(url) } }
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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        if let ctx = NSGraphicsContext.current?.cgContext {
            let scale = size.width / 120.0
            ctx.scaleBy(x: scale, y: scale)

            let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 120, height: 120), xRadius: 27, yRadius: 27)
            let topColor = NSColor(red: 51/255.0, green: 51/255.0, blue: 51/255.0, alpha: 1.0)
            let botColor = NSColor(red: 26/255.0, green: 26/255.0, blue: 26/255.0, alpha: 1.0)
            NSGradient(starting: topColor, ending: botColor)?.draw(in: bgPath, angle: -90)

            let shineRect = CGRect(x: 1, y: 1, width: 118, height: 118)
            let cgPath = CGPath(roundedRect: shineRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
            ctx.saveGState()
            ctx.addPath(cgPath)
            ctx.setLineWidth(2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let shineGradient = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.6),
    NSColor.white.withAlphaComponent(0.0),
    NSColor.white.withAlphaComponent(0.0),
    NSColor.white.withAlphaComponent(0.6)
], atLocations: [0.0, 0.3, 0.7, 1.0], colorSpace: .deviceRGB)
            shineGradient?.draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: -45)
            ctx.restoreGState()

            let outerPath = NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 60, height: 60))
            outerPath.lineWidth = 6
            NSColor.white.setStroke()
            outerPath.stroke()

            let innerPath = NSBezierPath(ovalIn: NSRect(x: 40, y: 40, width: 40, height: 40))
            NSColor(red: 1.0, green: 59/255.0, blue: 48/255.0, alpha: 1.0).setFill()
            innerPath.fill()
        }
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

        let desc2 = NSTextField(labelWithString: "Completely free and open-source.")
        desc2.alignment = .center
        desc2.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(desc2)

        let githubButton = NSButton(title: " GitHub Repository", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .rounded
        githubButton.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        stackView.addArrangedSubview(githubButton)

        updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        stackView.addArrangedSubview(updateButton)

        updateStatus = NSTextField(labelWithString: "")
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.font = .systemFont(ofSize: 11)
        stackView.addArrangedSubview(updateStatus)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 240).isActive = true
        stackView.addArrangedSubview(sep)
        
        let shortcutsTitle = NSTextField(labelWithString: "Global Shortcuts")
        shortcutsTitle.font = .boldSystemFont(ofSize: 12)
        stackView.addArrangedSubview(shortcutsTitle)
        
        let shortcutsGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Record / Stop:"), NSTextField(labelWithString: "⌘ ⇧ R")],
            [NSTextField(labelWithString: "Pause / Resume:"), NSTextField(labelWithString: "⌘ ⇧ P")],
            [NSTextField(labelWithString: "Toggle Camera:"), NSTextField(labelWithString: "⌘ ⇧ C")]
        ])
        shortcutsGrid.rowAlignment = .lastBaseline
        shortcutsGrid.column(at: 0).xPlacement = .trailing
        shortcutsGrid.column(at: 1).xPlacement = .leading
        for row in 0..<shortcutsGrid.numberOfRows {
            if let label = shortcutsGrid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField {
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: 11)
            }
            if let tf = shortcutsGrid.cell(atColumnIndex: 1, rowIndex: row).contentView as? NSTextField {
                tf.textColor = .labelColor
                tf.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            }
        }
        stackView.addArrangedSubview(shortcutsGrid)
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/arunofhyd/Rec") {
            NSWorkspace.shared.open(url)
        }
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
                        if version.compare(appVersion, options: .numeric) == .orderedDescending {
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
// App Delegate — FIXED AUDIO MENU LOGIC
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var recordButton: NSButton!
    var pauseButton: NSButton!
    var closeButton: NSButton!
    var modePopUp: NSPopUpButton!
    var audioPopUp: NSPopUpButton!
    var timerPopUp: NSPopUpButton!
    var cameraPopUp: NSPopUpButton!
    var settingsPopUp: NSPopUpButton!
    let recorder = Recorder()

    var statusItem: NSStatusItem!
    var appSelectionMenu: AppSelectionMenuHandler?
    var aboutWC: AboutWindowController?

    var cameraWindow: CameraOverlayWindow?

    var recordingOverlay: RecordingOverlayWindow?

    var regionSelectionWindows: [RegionSelectionWindow] = []
    var countdownTimer: Timer?
    var highlighterWindow: CursorHighlighterWindow?
    var highlighterTimer: Timer?
    var countdownWindow: CountdownWindow?

    // Track menu items for audio popup to manage state easily
    private var audioMainItems: [NSMenuItem] = []
    private var audioMicItems: [NSMenuItem] = []
    private var cameraItems: [NSMenuItem] = []

    var globalEventMonitor: Any?
    var localEventMonitor: Any?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
        setupUI()
        setupRecorder()
        setupShortcuts()
        checkPermissions()
        setupCameraIfNeeded()
    }

    func setupCameraIfNeeded() {
        if currentSettings.cameraID != "None" && !currentSettings.cameraID.isEmpty {
            cameraWindow = CameraOverlayWindow()
            cameraWindow?.makeKeyAndOrderFront(nil)
            recorder.cameraWindowID = cameraWindow?.windowNumber
            cameraWindow?.startCamera(deviceID: currentSettings.cameraID)
        }
    }
    
    @objc func toggleCameraHotkey() {
        if let window = cameraWindow, window.isVisible {
            window.stopCamera()
            window.orderOut(nil)
            cameraWindow = nil
        } else {
            let devID = (currentSettings.cameraID == "None" || currentSettings.cameraID.isEmpty) ? AVCaptureDevice.default(for: .video)?.uniqueID ?? "" : currentSettings.cameraID
            if !devID.isEmpty && devID != "None" {
                if cameraWindow == nil {
                    cameraWindow = CameraOverlayWindow()
                    recorder.cameraWindowID = cameraWindow?.windowNumber
                }
                cameraWindow?.makeKeyAndOrderFront(nil)
                cameraWindow?.startCamera(deviceID: devID)
            }
        }
    }

    func setupShortcuts() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            // Cmd + Shift + R -> 15
            // Cmd + Shift + P -> 35
            // Cmd + Shift + C -> 8
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] {
                if event.keyCode == 15 {
                    DispatchQueue.main.async { self?.toggleRecording() }
                } else if event.keyCode == 35 {
                    DispatchQueue.main.async { self?.togglePause() }
                } else if event.keyCode == 8 {
                    DispatchQueue.main.async { self?.toggleCameraHotkey() }
                }
            }
        }
        
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        
        if accessEnabled {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    func checkPermissions() {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            CGRequestScreenCaptureAccess()
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

    @objc func showPanel() { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func hidePanel() { panel.orderOut(nil) }
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
    @objc func timerChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        let val = sender.tag
        currentSettings.timer = (val == 0 ? 0 : (val == 1 ? 5 : 10))
        currentSettings.save()
    }

    // ============================================================
    // FIXED: Audio Menu Logic — Mutual Exclusion
    // ============================================================
    @objc func audioChanged(_ sender: NSMenuItem) {
        // Determine group by checking our tracked arrays
        let isMainItem = audioMainItems.contains(sender)

        if isMainItem {
            // It's a base audio source (System, Mic, Both, None)
            for item in audioMainItems {
                item.state = .off
            }
            sender.state = .on
            currentSettings.audioSource = sender.tag
            if sender.tag == 1, let firstMic = audioMicItems.first, currentSettings.micID.isEmpty {
                currentSettings.micID = firstMic.identifier?.rawValue ?? ""
                firstMic.state = .on
            }
        } else {
            // It's a specific microphone selection
            for item in audioMicItems {
                item.state = .off
            }
            for item in audioMainItems {
                item.state = .off
            }
            sender.state = .on
            if audioMainItems.indices.contains(1) {
                audioMainItems[1].state = .on // "Microphone"
            }
            currentSettings.audioSource = 1
            currentSettings.micID = sender.identifier?.rawValue ?? ""
        }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let initialAudioSymbols = ["speaker.wave.2", "mic", "mic.and.signal.meter", "speaker.slash"]
        let symbol = (0...3).contains(currentSettings.audioSource) ? initialAudioSymbols[currentSettings.audioSource] : "speaker.wave.2"

        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        audioPopUp.layer?.add(transition, forKey: "fade")
        audioPopUp.menu?.item(at: 0)?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)

        currentSettings.save()
    }

    @objc func cameraChanged(_ sender: NSMenuItem) {
        for item in cameraItems { item.state = .off }
        sender.state = .on
        
        let deviceID = sender.identifier?.rawValue ?? "None"
        currentSettings.cameraID = deviceID
        currentSettings.save()
        
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = deviceID == "None" ? "video.slash" : "video.fill"
        cameraPopUp.menu?.item(at: 0)?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        
        if deviceID == "None" {
            cameraWindow?.close()
            cameraWindow = nil
            recorder.cameraWindowID = nil
        } else {
            if cameraWindow == nil {
                cameraWindow = CameraOverlayWindow()
                cameraWindow?.makeKeyAndOrderFront(nil)
                recorder.cameraWindowID = cameraWindow?.windowNumber
            }
            cameraWindow?.startCamera(deviceID: deviceID)
        }
    }

    @objc func modeChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        for item in menu.items {
            item.state = .off
        }
        sender.state = .on

        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        modePopUp.layer?.add(transition, forKey: "fade")
        modePopUp.menu?.item(at: 0)?.image = sender.image

        currentSettings.recordMode = sender.tag
        currentSettings.save()
    }

    @objc func toggleMouseClicks(_ sender: NSMenuItem) {
        currentSettings.showsClicks.toggle()
        currentSettings.save()
        sender.state = currentSettings.showsClicks ? .on : .off
    }

    @objc func toggleCursorHighlight(_ sender: NSMenuItem) {
        currentSettings.highlightCursor.toggle()
        currentSettings.save()
        sender.state = currentSettings.highlightCursor ? .on : .off
    }

    @objc func cursorColorChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        for item in menu.items { item.state = .off }
        sender.state = .on
        currentSettings.cursorColor = sender.tag
        currentSettings.save()
        highlighterWindow?.updateColor()
    }

    @objc func toggleMirrorCamera(_ sender: NSMenuItem) {
        currentSettings.mirrorCamera.toggle()
        currentSettings.save()
        sender.state = currentSettings.mirrorCamera ? .on : .off
        
        if let window = cameraWindow {
            let shouldMirror = currentSettings.mirrorCamera
            window.previewLayer.connection?.isVideoMirrored = shouldMirror
        }
    }
    @objc func chooseSaveLocation(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
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
        recordButton.action = #selector(toggleRecording)

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

        // ---- AUDIO POPUP (FIXED) ----
        audioPopUp = NSPopUpButton()
        audioPopUp.translatesAutoresizingMaskIntoConstraints = false
        audioPopUp.removeAllItems()
        audioPopUp.isBordered = false
        audioPopUp.imagePosition = .imageOnly
        audioPopUp.pullsDown = true
        audioPopUp.wantsLayer = true
        audioPopUp.widthAnchor.constraint(equalToConstant: 38).isActive = true
        audioPopUp.heightAnchor.constraint(equalToConstant: 24).isActive = true

        audioMainItems.removeAll()
        audioMicItems.removeAll()

        let audioGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        let initialAudioSymbols = ["speaker.wave.2", "mic", "mic.and.signal.meter", "speaker.slash"]
        let initialAudioSymbol = (0...3).contains(currentSettings.audioSource) ? initialAudioSymbols[currentSettings.audioSource] : "speaker.wave.2"
        audioGearItem.image = NSImage(systemSymbolName: initialAudioSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        audioPopUp.menu?.addItem(audioGearItem)

        let audioMainData = [
            ("System Audio", "speaker.wave.2", 0),
            ("Microphone", "mic", 1),
            ("System + Mic", "mic.and.signal.meter", 2),
            ("None", "speaker.slash", 3)
        ]
        for (title, symbol, idx) in audioMainData {
            let item = NSMenuItem(title: title, action: #selector(audioChanged(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            item.target = self; item.tag = idx
            if currentSettings.audioSource == idx { item.state = .on }
            audioPopUp.menu?.addItem(item)
            audioMainItems.append(item)
        }
        audioPopUp.menu?.addItem(NSMenuItem.separator())

        // Mic List (Modern API with external mic fallback)
        let micSubmenu = NSMenu()
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")], mediaType: .audio, position: .unspecified)

        if session.devices.isEmpty {
            let emptyItem = NSMenuItem(title: "No Microphones Found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            micSubmenu.addItem(emptyItem)
        } else {
            for device in session.devices {
                let item = NSMenuItem(title: device.localizedName, action: #selector(audioChanged(_:)), keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(device.uniqueID)
                item.target = self
                if currentSettings.micID == device.uniqueID { item.state = .on }
                micSubmenu.addItem(item)
                audioMicItems.append(item)
            }
        }

        // Attach the submenu to the "Microphone" item
        if audioMainItems.indices.contains(1) {
            audioMainItems[1].submenu = micSubmenu
        }

        // If "Microphone" mode (1) is selected but no mic item checked, check first one
        if currentSettings.audioSource == 1, audioMicItems.first?.state == .off, let firstMic = audioMicItems.first {
            firstMic.state = .on
            currentSettings.micID = firstMic.identifier?.rawValue ?? ""
            currentSettings.save()
        }


        // ---- SETTINGS (GEAR) ----
        settingsPopUp = NSPopUpButton()
        settingsPopUp.translatesAutoresizingMaskIntoConstraints = false
        settingsPopUp.removeAllItems()
        settingsPopUp.isBordered = false
        settingsPopUp.imagePosition = .imageOnly
        settingsPopUp.pullsDown = true
        settingsPopUp.wantsLayer = true
        settingsPopUp.widthAnchor.constraint(equalToConstant: 38).isActive = true
        settingsPopUp.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let gearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        gearItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        settingsPopUp.menu?.addItem(gearItem)

        let addSubmenu = { [weak self] (title: String, symbol: String, items: [(String, Int, Selector)]) -> Void in
            let sub = NSMenu()
            for (t, tag, action) in items {
                let i = NSMenuItem(title: t, action: action, keyEquivalent: "")
                i.target = self; i.tag = tag
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            parent.submenu = sub
            self?.settingsPopUp.menu?.addItem(parent)
        }

        addSubmenu("Framerate", "film", [
            ("60 FPS", 60, #selector(fpsChanged(_:))),
            ("30 FPS", 30, #selector(fpsChanged(_:))),
            ("24 FPS", 24, #selector(fpsChanged(_:)))
        ])
        if currentSettings.fps == 60 { (settingsPopUp.menu?.item(withTitle: "Framerate")?.submenu?.item(withTitle: "60 FPS"))?.state = .on }
        else if currentSettings.fps == 30 { (settingsPopUp.menu?.item(withTitle: "Framerate")?.submenu?.item(withTitle: "30 FPS"))?.state = .on }
        else { (settingsPopUp.menu?.item(withTitle: "Framerate")?.submenu?.item(withTitle: "24 FPS"))?.state = .on }

        addSubmenu("Resolution", "display", [
            ("Native", 0, #selector(resChanged(_:))),
            ("1080p", 1080, #selector(resChanged(_:))),
            ("720p", 720, #selector(resChanged(_:)))
        ])
        if currentSettings.resolution == 0 { (settingsPopUp.menu?.item(withTitle: "Resolution")?.submenu?.item(withTitle: "Native"))?.state = .on }
        else if currentSettings.resolution == 1080 { (settingsPopUp.menu?.item(withTitle: "Resolution")?.submenu?.item(withTitle: "1080p"))?.state = .on }
        else { (settingsPopUp.menu?.item(withTitle: "Resolution")?.submenu?.item(withTitle: "720p"))?.state = .on }

        addSubmenu("Bitrate", "speedometer", [
            ("High (Best Quality)", 0, #selector(bitChanged(_:))),
            ("Medium (Balanced)", 1, #selector(bitChanged(_:))),
            ("Low (Space Saver)", 2, #selector(bitChanged(_:)))
        ])
        (settingsPopUp.menu?.item(withTitle: "Bitrate")?.submenu?.item(at: currentSettings.bitrate))?.state = .on



        settingsPopUp.menu?.addItem(NSMenuItem.separator())
        
        let cursorMenu = NSMenu()
        let nativeClickItem = NSMenuItem(title: "Show Native Clicks", action: #selector(toggleMouseClicks(_:)), keyEquivalent: "")
        nativeClickItem.target = self
        nativeClickItem.state = currentSettings.showsClicks ? .on : .off
        cursorMenu.addItem(nativeClickItem)
        
        let highlightItem = NSMenuItem(title: "Highlight Cursor", action: #selector(toggleCursorHighlight(_:)), keyEquivalent: "")
        highlightItem.target = self
        highlightItem.state = currentSettings.highlightCursor ? .on : .off
        cursorMenu.addItem(highlightItem)
        
        cursorMenu.addItem(NSMenuItem.separator())
        
        let colorMenu = NSMenu()
        let colors = ["Yellow", "Red", "Green", "Blue"]
        for (idx, colorName) in colors.enumerated() {
            let item = NSMenuItem(title: colorName, action: #selector(cursorColorChanged(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            if currentSettings.cursorColor == idx { item.state = .on }
            colorMenu.addItem(item)
        }
        let colorSubItem = NSMenuItem(title: "Highlight Color", action: nil, keyEquivalent: "")
        colorSubItem.submenu = colorMenu
        cursorMenu.addItem(colorSubItem)
        
        let cursorParent = NSMenuItem(title: "Cursor Settings", action: nil, keyEquivalent: "")
        cursorParent.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: nil)
        cursorParent.submenu = cursorMenu
        settingsPopUp.menu?.addItem(cursorParent)

        let locationItem = NSMenuItem(title: "Save Location...", action: #selector(chooseSaveLocation(_:)), keyEquivalent: "")
        locationItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        locationItem.target = self
        settingsPopUp.menu?.addItem(locationItem)

        // ---- CLOSE BUTTON ----
        closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        closeButton.target = self
        closeButton.action = #selector(hidePanel)

        // ---- MODE POPUP ----
        modePopUp = NSPopUpButton()
        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        modePopUp.removeAllItems()
        modePopUp.isBordered = false
        modePopUp.imagePosition = .imageOnly
        modePopUp.pullsDown = true
        modePopUp.wantsLayer = true
        modePopUp.widthAnchor.constraint(equalToConstant: 38).isActive = true
        modePopUp.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let modeGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        let initialModeSymbols = ["macwindow", "macwindow.badge.plus", "crop"]
        let initialModeSymbol = (0...2).contains(currentSettings.recordMode) ? initialModeSymbols[currentSettings.recordMode] : "macwindow"
        modeGearItem.image = NSImage(systemSymbolName: initialModeSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        modePopUp.menu?.addItem(modeGearItem)

        let modeItems = [
            ("Entire Screen", "macwindow", 0),
            ("Specific App", "macwindow.badge.plus", 1),
            ("Select Area", "crop", 2)
        ]
        for (title, symbol, idx) in modeItems {
            let item = NSMenuItem(title: title, action: #selector(modeChanged(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
            item.tag = idx
            item.target = self
            if currentSettings.recordMode == idx { item.state = .on }
            modePopUp.menu?.addItem(item)
        }

        // ---- TIMER POPUP ----
        timerPopUp = NSPopUpButton()
        timerPopUp.translatesAutoresizingMaskIntoConstraints = false
        timerPopUp.removeAllItems()
        timerPopUp.isBordered = false
        timerPopUp.imagePosition = .imageOnly
        timerPopUp.pullsDown = true
        timerPopUp.wantsLayer = true
        timerPopUp.widthAnchor.constraint(equalToConstant: 38).isActive = true
        timerPopUp.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let timerGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        timerGearItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        timerPopUp.menu?.addItem(timerGearItem)

        let timerItems = [
            ("None", 0),
            ("5 Seconds", 1),
            ("10 Seconds", 2)
        ]
        for (title, idx) in timerItems {
            let item = NSMenuItem(title: title, action: #selector(timerChanged(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            if currentSettings.timer == (idx == 0 ? 0 : (idx == 1 ? 5 : 10)) { item.state = .on }
            timerPopUp.menu?.addItem(item)
        }

        // ---- CAMERA POPUP ----
        cameraPopUp = NSPopUpButton()
        cameraPopUp.translatesAutoresizingMaskIntoConstraints = false
        cameraPopUp.removeAllItems()
        cameraPopUp.isBordered = false
        cameraPopUp.imagePosition = .imageOnly
        cameraPopUp.pullsDown = true
        cameraPopUp.wantsLayer = true
        cameraPopUp.widthAnchor.constraint(equalToConstant: 38).isActive = true
        cameraPopUp.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let cameraGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let camSymbol = currentSettings.cameraID == "None" ? "video.slash" : "video.fill"
        cameraGearItem.image = NSImage(systemSymbolName: camSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        cameraPopUp.menu?.addItem(cameraGearItem)

        let noCamItem = NSMenuItem(title: "None", action: #selector(cameraChanged(_:)), keyEquivalent: "")
        noCamItem.target = self
        noCamItem.identifier = NSUserInterfaceItemIdentifier("None")
        if currentSettings.cameraID == "None" || currentSettings.cameraID.isEmpty {
            noCamItem.state = .on
        }
        cameraItems.append(noCamItem)
        cameraPopUp.menu?.addItem(noCamItem)
        
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        for dev in devices {
            let item = NSMenuItem(title: dev.localizedName, action: #selector(cameraChanged(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(dev.uniqueID)
            item.target = self
            if currentSettings.cameraID == dev.uniqueID { item.state = .on }
            cameraItems.append(item)
            cameraPopUp.menu?.addItem(item)
        }
        
        cameraPopUp.menu?.addItem(NSMenuItem.separator())
        let mirrorItem = NSMenuItem(title: "Mirror Camera", action: #selector(toggleMirrorCamera(_:)), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = currentSettings.mirrorCamera ? .on : .off
        cameraPopUp.menu?.addItem(mirrorItem)

        // ---- PAUSE BUTTON ----
        pauseButton = NSButton()
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.bezelStyle = .regularSquare
        pauseButton.isBordered = false
        pauseButton.imagePosition = .imageOnly
        pauseButton.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.isHidden = true // Only visible when recording

        // ---- STACK VIEW ----
        let stackView = NSStackView(views: [closeButton, settingsPopUp, cameraPopUp, audioPopUp, timerPopUp, modePopUp])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 16
        stackView.alignment = .centerY

        let actionStackView = NSStackView(views: [pauseButton, recordButton])
        actionStackView.translatesAutoresizingMaskIntoConstraints = false
        actionStackView.orientation = .horizontal
        actionStackView.spacing = 12
        actionStackView.alignment = .centerY

        contentView.addSubview(stackView)
        contentView.addSubview(actionStackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            actionStackView.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 16),
            actionStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            actionStackView.centerYAnchor.constraint(equalTo: stackView.centerYAnchor)
        ])

        stackView.layoutSubtreeIfNeeded()
        updateButtonImage()
        let fittingSize = contentView.fittingSize
        panel.setContentSize(fittingSize)
        panel.setFrameOrigin(NSPoint(x: (screen.frame.width - fittingSize.width) / 2, y: 100))
        panel.makeKeyAndOrderFront(nil)
    }

    func setupRecorder() {
        recorder.onRecordingStarted = { [weak self] in
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = false
            self?.audioPopUp.isEnabled = false
            self?.timerPopUp.isEnabled = false
            self?.cameraPopUp.isEnabled = false
            self?.settingsPopUp.isEnabled = false
            if let rect = self?.recorder.captureRect, rect != .zero, let screen = self?.recorder.captureScreen {
                self?.recordingOverlay = RecordingOverlayWindow(screen: screen, holeRect: rect)
                self?.recordingOverlay?.makeKeyAndOrderFront(nil)
            }
        }
        recorder.onRecordingStopped = { [weak self] url in
            self?.recordingOverlay?.close(); self?.recordingOverlay = nil
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = true
            self?.audioPopUp.isEnabled = true
            self?.timerPopUp.isEnabled = true
            self?.cameraPopUp.isEnabled = true
            self?.settingsPopUp.isEnabled = true
            let alert = NSAlert()
            alert.messageText = "Recording Saved"
            alert.informativeText = "Saved to \(url.lastPathComponent)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        recorder.onError = { [weak self] error in
            self?.recordingOverlay?.close(); self?.recordingOverlay = nil
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = true
            self?.audioPopUp.isEnabled = true
            self?.timerPopUp.isEnabled = true
            self?.cameraPopUp.isEnabled = true
            self?.settingsPopUp.isEnabled = true
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
        
        var isMicActive = false
        recorder.onMicAudioLevel = { [weak self] level in
            guard let self = self else { return }
            let isActive = level > -35.0
            if isActive != isMicActive {
                isMicActive = isActive
                let baseSymbol: String
                switch currentSettings.audioSource {
                case 0: baseSymbol = "speaker.wave.2"
                case 1: baseSymbol = "mic"
                case 2: baseSymbol = "mic.and.signal.meter"
                case 3: baseSymbol = "speaker.slash"
                default: baseSymbol = "speaker.wave.2"
                }
                
                let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                guard let img = NSImage(systemSymbolName: baseSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
                
                if isActive && (currentSettings.audioSource == 1 || currentSettings.audioSource == 2) {
                    let size = img.size
                    let tinted = NSImage(size: size)
                    tinted.lockFocus()
                    img.draw(in: NSRect(origin: .zero, size: size))
                    NSColor.systemGreen.set()
                    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
                    tinted.unlockFocus()
                    self.audioPopUp.menu?.item(at: 0)?.image = tinted
                } else {
                    self.audioPopUp.menu?.item(at: 0)?.image = img
                }
            }
        }
    }



    @objc func togglePause() {
        recorder.togglePause()
        updateButtonImage()
    }

    @objc func toggleRecording() {
        if !regionSelectionWindows.isEmpty {
            for window in regionSelectionWindows { window.close() }
            regionSelectionWindows.removeAll()
            return
        }
        if let timer = countdownTimer, timer.isValid {
            timer.invalidate()
            countdownWindow?.close()
            countdownWindow = nil
            return
        }
        if recorder.isRecording { recorder.stopRecording() }
        else { startRecordingProcess() }
    }

    func startRecordingProcess() {
        let modeIndex = currentSettings.recordMode

        if modeIndex == 1 { // Specific App
            appSelectionMenu = AppSelectionMenuHandler()
            appSelectionMenu?.onSelect = { [weak self] app in
                self?.recorder.captureApp = app
                self?.recorder.captureRect = nil
                self?.recorder.captureScreen = nil
                self?.startCountdownAndRecord()
            }
            appSelectionMenu?.showMenu(at: modePopUp)
        } else if modeIndex == 2 { // Select Area
            for window in regionSelectionWindows { window.close() }
            regionSelectionWindows.removeAll()

            for screen in NSScreen.screens {
                let window = RegionSelectionWindow(screen: screen)
                if let view = window.contentView as? RegionSelectionView {
                    view.onSelectionComplete = { [weak self] rect in
                        guard let self = self else { return }
                        self.recorder.captureApp = nil
                        self.recorder.captureRect = rect
                        self.recorder.captureScreen = screen
                        
                        for w in self.regionSelectionWindows { w.close() }
                        self.regionSelectionWindows.removeAll()
                        
                        self.startCountdownAndRecord()
                    }
                }
                regionSelectionWindows.append(window)
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        } else { // Entire Screen
            recorder.captureApp = nil
            recorder.captureRect = nil
            recorder.captureScreen = NSScreen.main
            startCountdownAndRecord()
        }
    }

    func startCountdownAndRecord() {
        if currentSettings.timer > 0 {
            startCountdown(seconds: currentSettings.timer) { [weak self] in
                self?.recorder.startRecording()
            }
        } else {
            recorder.startRecording()
        }
    }

    func startCountdown(seconds: Int, completion: @escaping () -> Void) {
        countdownTimer?.invalidate()
        countdownWindow?.close()

        guard let screen = NSScreen.main else {
            completion()
            return
        }

        countdownWindow = CountdownWindow(screen: screen)
        countdownWindow?.makeKeyAndOrderFront(nil)
        countdownWindow?.updateText("\(seconds)")

        var remaining = seconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining > 0 {
                self?.countdownWindow?.updateText("\(remaining)")
            } else {
                timer.invalidate()
                self?.countdownWindow?.close()
                self?.countdownWindow = nil
                completion()
            }
        }
    }

    func updateButtonImage() {
        pauseButton.isHidden = !recorder.isRecording
        
        let pauseSymbol = recorder.isPaused ? "play.circle.fill" : "pause.circle.fill"
        let pauseConfig = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        if let pauseImg = NSImage(systemSymbolName: pauseSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(pauseConfig) {
            let size = pauseImg.size
            let tinted = NSImage(size: size)
            tinted.lockFocus()
            pauseImg.draw(in: NSRect(origin: .zero, size: size))
            NSColor.white.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            pauseButton.image = tinted
        }

        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        let symbolName = recorder.isRecording ? "stop.circle.fill" : "record.circle"
        if let systemImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = systemImage.size
            let tintedImage = NSImage(size: size)
            tintedImage.lockFocus()

            if symbolName == "record.circle" {
                if let ctx = NSGraphicsContext.current?.cgContext {
                    let scale = size.width / 120.0
                    ctx.scaleBy(x: scale, y: scale)

                    let outerPath = NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 60, height: 60))
                    outerPath.lineWidth = 6
                    NSColor.white.setStroke()
                    outerPath.stroke()

                    let innerPath = NSBezierPath(ovalIn: NSRect(x: 40, y: 40, width: 40, height: 40))
                    NSColor(red: 1.0, green: 59/255.0, blue: 48/255.0, alpha: 1.0).setFill()
                    innerPath.fill()
                }
            } else {
                // For the square stop button, just draw it normally and tint it white
                systemImage.draw(in: NSRect(origin: .zero, size: size))
                NSColor.white.set()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            }

            tintedImage.unlockFocus()
            recordButton.image = tintedImage
        }
        
        // Re-layout panel to fix UI gap when pause button is hidden
        if let contentView = panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let newSize = contentView.fittingSize
            if panel.frame.size != newSize {
                var newFrame = panel.frame
                newFrame.size = newSize
                panel.setFrame(newFrame, display: true, animate: true)
            }
        }
        
        // Handle Cursor Highlighter lifecycle
        if recorder.isRecording && currentSettings.highlightCursor {
            if highlighterWindow == nil {
                highlighterWindow = CursorHighlighterWindow()
                highlighterWindow?.makeKeyAndOrderFront(nil)
                highlighterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    let mouseLoc = NSEvent.mouseLocation
                    self?.highlighterWindow?.moveTo(point: mouseLoc)
                }
            }
        } else {
            highlighterTimer?.invalidate()
            highlighterTimer = nil
            highlighterWindow?.close()
            highlighterWindow = nil
        }
    }

    deinit {
        recordingOverlay?.close()
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
