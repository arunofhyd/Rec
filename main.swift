import Cocoa
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import os.log

// MARK: - Configuration
let appVersion = "1.0"
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
    var outputFile: URL?

    var sessionStartTime: CMTime = .invalid
    private let writerLock = NSLock()
    private var streamStartHostTime: UInt64 = 0

    var captureRect: CGRect?          // Screen-Local Coords (Bottom-Left Origin)
    var captureScreen: NSScreen?      // The screen the rect belongs to
    var captureApp: SCRunningApplication?

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    func startRecording() {
        if isRecording { return }
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

            if let app = self.captureApp {
                guard let display = content.displays.first else {
                    DispatchQueue.main.async { self.onError?(NSError(domain: "RecorderError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for app"])) }
                    return
                }
                targetDisplay = display
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                // Determine Target Display
                if let screen = self.captureScreen {
                    let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                    targetDisplay = content.displays.first { $0.displayID == screenID } ?? content.displays.first!
                } else {
                    let mainScreen = NSScreen.main
                    let mainID = mainScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                    targetDisplay = content.displays.first { $0.displayID == mainID } ?? content.displays.first!
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

        // ============================================================
        // REGION LOGIC: Global Screen Coords -> Local Display Coords
        // ============================================================
        if let rect = captureRect, rect != .zero, let screen = captureScreen {
            // 1. Verify the screen matches the display we are capturing
            let screenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writerLock.lock()
        let recording = isRecording
        writerLock.unlock()
        guard recording else { return }

        guard let assetWriter = assetWriter else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(pts) > 0 else { return }

        writerLock.lock()
        defer { writerLock.unlock() }

        if sessionStartTime == .invalid {
            if type == .screen {
                sessionStartTime = pts
                assetWriter.startSession(atSourceTime: sessionStartTime)
                os_log("Session Started at PTS: %{public}f", log: log, type: .info, CMTimeGetSeconds(sessionStartTime))
            } else { return }
        }

        if CMTimeCompare(pts, sessionStartTime) < 0 { return }

        if type == .screen {
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData { videoInput.append(sampleBuffer) }
        } else if type == .audio {
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData { audioInput.append(sampleBuffer) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        os_log("Stream Stopped Error: %{public}@", log: log, type: .error, error.localizedDescription)
        DispatchQueue.main.async { self.onError?(error); self.stopRecording() }
    }

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

        if sessionStartTime != .invalid {
            if let micInput = micInput, micInput.isReadyForMoreMediaData { micInput.append(sampleBuffer) }
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
    var closeButton: NSButton!
    var modePopUp: NSPopUpButton!
    let recorder = Recorder()

    var statusItem: NSStatusItem!
    var appSelectionMenu: AppSelectionMenuHandler?
    var aboutWC: AboutWindowController?

    var recordingOverlay: RecordingOverlayWindow?

    // Track menu items for audio popup to manage state easily
    private var audioMainItems: [NSMenuItem] = []
    private var audioMicItems: [NSMenuItem] = []

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

    // ============================================================
    // FIXED: Audio Menu Logic — Mutual Exclusion
    // ============================================================
    @objc func audioChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }

        // Determine group by checking our tracked arrays
        let isMainItem = audioMainItems.contains(sender)
        // let isMicItem = audioMicItems.contains(sender) // Implied by !isMainItem

        let index = menu.index(of: sender)

        if isMainItem {
            // It's a base audio source (System, Mic, Both, None)
            // Only toggle off other base audio source items (index 0 to 3)
            for i in 0..<4 {
                if let item = menu.item(at: i) {
                    item.state = .off
                }
            }
            sender.state = .on
            currentSettings.audioSource = index
            if index == 1, let firstMic = audioMicItems.first, currentSettings.micID.isEmpty {
                currentSettings.micID = firstMic.identifier?.rawValue ?? ""
                firstMic.state = .on
            }
        } else {
            // It's a specific microphone selection
            // Turn off all other microphone items
            for item in audioMicItems {
                item.state = .off
            }
            sender.state = .on
            if audioMainItems.indices.contains(1) {
                audioMainItems[1].state = .on // "Microphone"
            }
            currentSettings.audioSource = 1
            currentSettings.micID = sender.identifier?.rawValue ?? ""
        }
        currentSettings.save()
    }

    @objc func toggleMouseClicks(_ sender: NSMenuItem) {
        currentSettings.showsClicks.toggle()
        currentSettings.save()
        sender.state = currentSettings.showsClicks ? .on : .off
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
        updateButtonImage()

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

        // ---- AUDIO POPUP (FIXED) ----
        let audioPopUp = NSPopUpButton()
        audioPopUp.translatesAutoresizingMaskIntoConstraints = false
        audioPopUp.removeAllItems()
        audioPopUp.isBordered = false
        audioPopUp.imagePosition = .imageOnly

        audioMainItems.removeAll()
        audioMicItems.removeAll()

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
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")], mediaType: .audio, position: .unspecified)

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


        // ---- SETTINGS POPUP ----
        let settingsPopUp = NSPopUpButton()
        settingsPopUp.translatesAutoresizingMaskIntoConstraints = false
        settingsPopUp.removeAllItems()
        settingsPopUp.isBordered = false
        settingsPopUp.imagePosition = .imageOnly
        settingsPopUp.pullsDown = true
        let gearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        gearItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        settingsPopUp.menu?.addItem(gearItem)

        let addSubmenu = { (title: String, symbol: String, items: [(String, Int, Selector)]) -> NSMenuItem in
            let sub = NSMenu()
            for (t, tag, action) in items {
                let i = NSMenuItem(title: t, action: action, keyEquivalent: "")
                i.target = self; i.tag = tag
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            parent.submenu = sub
            settingsPopUp.menu?.addItem(parent)
            return parent
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
            ("Best Quality, Large size", 0, #selector(bitChanged(_:))),
            ("Balanced Quality & size", 1, #selector(bitChanged(_:))),
            ("Low Quality, small size", 2, #selector(bitChanged(_:)))
        ])
        (settingsPopUp.menu?.item(withTitle: "Bitrate")?.submenu?.item(at: currentSettings.bitrate))?.state = .on

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

        let modeItems = [
            ("Entire Screen", "macwindow", 0),
            ("Specific App", "macwindow.badge.plus", 1)
        ]
        for (title, symbol, idx) in modeItems {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
            item.tag = idx
            modePopUp.menu?.addItem(item)
        }

        // ---- STACK VIEW ----
        let stackView = NSStackView(views: [closeButton, settingsPopUp, audioPopUp, modePopUp, recordButton])
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
        recorder.onRecordingStarted = { [weak self] in
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = false
            if let rect = self?.recorder.captureRect, rect != .zero, let screen = self?.recorder.captureScreen {
                self?.recordingOverlay = RecordingOverlayWindow(screen: screen, holeRect: rect)
                self?.recordingOverlay?.makeKeyAndOrderFront(nil)
            }
        }
        recorder.onRecordingStopped = { [weak self] url in
            self?.recordingOverlay?.close(); self?.recordingOverlay = nil
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = true
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
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }



    @objc func toggleRecording() {
        if recorder.isRecording { recorder.stopRecording() }
        else { startRecordingProcess() }
    }

    func startRecordingProcess() {
        let modeIndex = modePopUp.indexOfSelectedItem

        if modeIndex == 1 { // Specific App
            appSelectionMenu = AppSelectionMenuHandler()
            appSelectionMenu?.onSelect = { [weak self] app in
                self?.recorder.captureApp = app
                self?.recorder.captureRect = nil
                self?.recorder.captureScreen = nil
                self?.recorder.startRecording()
            }
            appSelectionMenu?.showMenu(at: modePopUp)
        } else { // Entire Screen
            recorder.captureApp = nil
            recorder.captureRect = nil
            recorder.captureScreen = NSScreen.main
            recorder.startRecording()
        }
    }

    func updateButtonImage() {
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let symbolName = recorder.isRecording ? "stop.circle.fill" : "record.circle"
        if let systemImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = systemImage.size
            let tintedImage = NSImage(size: size)
            tintedImage.lockFocus()

            if symbolName == "record.circle" {
                let scale = size.width / 24.0

                // Draw white outer circle
                NSColor.white.setStroke()
                let outerPath = NSBezierPath(ovalIn: NSRect(x: 2 * scale, y: 2 * scale, width: size.width - 4 * scale, height: size.height - 4 * scale))
                outerPath.lineWidth = 2 * scale
                outerPath.stroke()

                // Draw red inner dot
                NSColor.systemRed.setFill()
                let innerPath = NSBezierPath(ovalIn: NSRect(x: 7 * scale, y: 7 * scale, width: size.width - 14 * scale, height: size.height - 14 * scale))
                innerPath.fill()
            } else {
                // For the square stop button, just draw it normally and tint it white
                systemImage.draw(in: NSRect(origin: .zero, size: size))
                NSColor.white.set()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            }

            tintedImage.unlockFocus()
            recordButton.image = tintedImage
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
