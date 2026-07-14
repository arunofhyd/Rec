import Cocoa
import ScreenCaptureKit
import AVFoundation

// ============================================================
//  Rec
// ============================================================

let appVersion = "1.0"

// MARK: - Settings

enum RecordingMode: Int, Codable {
    case entireScreen = 0
    case selectedPortion = 1
    case specificApp = 2
}

enum AudioMode: Int, Codable {
    case system = 0
    case microphone = 1
    case systemAndMic = 2
    case none = 3
}

enum Framerate: Int, Codable {
    case fps60 = 60
    case fps30 = 30
    case fps24 = 24
}

enum Resolution: Int, Codable {
    case native = 0
    case res1080p = 1080
    case res720p = 720
}

enum Bitrate: Int, Codable {
    case high = 0
    case medium = 1
    case low = 2
}

enum TimerCountdown: Int, Codable {
    case none = 0
    case sec5 = 5
    case sec10 = 10
}

struct AppSettings: Codable {
    var mode: RecordingMode = .entireScreen
    var audio: AudioMode = .system
    var framerate: Framerate = .fps60
    var resolution: Resolution = .native
    var bitrate: Bitrate = .high
    var timer: TimerCountdown = .none
    var showMouseClicks: Bool = false
    var saveLocationData: Data? = nil
    var micID: String? = nil

    static var shared: AppSettings {
        get {
            if let data = UserDefaults.standard.data(forKey: "AppSettings"),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                return settings
            }
            return AppSettings()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "AppSettings")
            }
        }
    }
}

// MARK: - Recorder

class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var assetWriter: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput? // System Audio
    var micAudioInput: AVAssetWriterInput? // Microphone Audio
    var isRecording = false
    var outputFile: URL?

    var sessionStartTime: CMTime = .invalid
    private let writerLock = NSLock()

    // Microphone Capture
    var captureSession: AVCaptureSession?
    var micConnection: AVCaptureConnection?

    // UI Callbacks
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    var activeSelectionWindow: SelectionOverlayWindow?
    var selectedApp: SCRunningApplication?

    func startRecording() {
        if isRecording { return }
        
        let mode = AppSettings.shared.mode
        
        if mode == .selectedPortion {
            DispatchQueue.main.async {
                guard let screen = NSScreen.main else { return }
                let selectionWindow = SelectionOverlayWindow(screen: screen)
                self.activeSelectionWindow = selectionWindow
                
                selectionWindow.selectionView.onSelectionCompleted = { [weak self] rect in
                    self?.activeSelectionWindow?.close()
                    self?.activeSelectionWindow = nil
                    
                    if rect.width > 10 && rect.height > 10 {
                        self?.fetchContentAndStart(sourceRect: rect)
                    }
                }
                
                selectionWindow.selectionView.onCancel = { [weak self] in
                    self?.activeSelectionWindow?.close()
                    self?.activeSelectionWindow = nil
                }
                
                selectionWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            self.fetchContentAndStart(sourceRect: nil)
        }
    }

    private func fetchContentAndStart(sourceRect: NSRect?) {
        let mode = AppSettings.shared.mode

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { self.onError?(error) }
                return
            }

            guard let display = content?.displays.first else {
                DispatchQueue.main.async {
                    self.onError?(NSError(domain: "RecorderError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No display found"]))
                }
                return
            }

            let myApp = content?.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier })
            let excludedApps = myApp != nil ? [myApp!] : []

            let filter: SCContentFilter
            if mode == .specificApp, let selectedApp = self.selectedApp, let app = content?.applications.first(where: { $0.processID == selectedApp.processID }) {
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            }

            self.continueStartingRecording(filter: filter, display: display, sourceRect: sourceRect)
        }
    }

    var activeIndicatorWindow: RecordingIndicatorWindow?

    private func continueStartingRecording(filter: SCContentFilter, display: SCDisplay, sourceRect: NSRect?) {
        let config = SCStreamConfiguration()
        
        let settings = AppSettings.shared
        let fps = settings.framerate.rawValue
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 5

        let scale = CGFloat(display.width) / CGFloat(display.frame.width)

        var finalWidth = display.width
        var finalHeight = display.height
        
        if settings.mode == .selectedPortion, let sRect = sourceRect {
            // Clamp source rect to display bounds
            let clampedRect = sRect.intersection(display.frame)
            if !clampedRect.isEmpty {
                // SCStreamConfiguration's sourceRect expects logical points
                // We must use KVC since sourceRect might not be available in older SDKs natively without warnings.
                config.setValue(clampedRect, forKey: "sourceRect")
                
                finalWidth = Int(clampedRect.width * scale)
                finalHeight = Int(clampedRect.height * scale)

                // Show recording indicator
                DispatchQueue.main.async {
                    guard let screen = NSScreen.main else { return }
                    let indicatorWindow = RecordingIndicatorWindow(screen: screen)
                    indicatorWindow.indicatorView.transparentRect = clampedRect
                    indicatorWindow.makeKeyAndOrderFront(nil)
                    self.activeIndicatorWindow = indicatorWindow
                }
            }
        }
        
        // Ensure even dimensions for HEVC
        if finalWidth % 2 != 0 { finalWidth -= 1 }
        if finalHeight % 2 != 0 { finalHeight -= 1 }

        config.width = finalWidth
        config.height = finalHeight
        
        // System audio
        config.capturesAudio = (settings.audio == .system || settings.audio == .systemAndMic)
        
        // Show mouse clicks
        if settings.showMouseClicks {
            config.setValue(true, forKey: "showsMouseClicks")
        }

        do {
            self.setupAssetWriter(config: config, settings: settings)
            
            // Start microphone capture if needed
            if settings.audio == .microphone || settings.audio == .systemAndMic {
                self.setupMicrophone(settings: settings)
            }

            self.stream = SCStream(filter: filter, configuration: config, delegate: self)
            try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Rec.videoQueue"))
            if config.capturesAudio {
                try self.stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "Rec.audioQueue"))
            }

            self.stream?.startCapture { error in
                if let error = error {
                    DispatchQueue.main.async { self.onError?(error) }
                } else {
                    self.isRecording = true
                    DispatchQueue.main.async { self.onRecordingStarted?() }
                }
            }
        } catch {
            DispatchQueue.main.async { self.onError?(error) }
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        stream?.stopCapture { [weak self] error in
            guard let self = self else { return }
            self.isRecording = false

            if let error = error {
                DispatchQueue.main.async { self.onError?(error) }
            }
            
            DispatchQueue.main.async {
                self.activeIndicatorWindow?.close()
                self.activeIndicatorWindow = nil
            }

            self.writerLock.lock()
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micAudioInput?.markAsFinished()

            self.assetWriter?.finishWriting {
                DispatchQueue.main.async {
                    if let url = self.outputFile {
                        self.onRecordingStopped?(url)
                    }
                }
                self.writerLock.lock()
                self.stream = nil
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.micAudioInput = nil
                
                self.captureSession?.stopRunning()
                self.captureSession = nil
                self.micConnection = nil
                
                self.sessionStartTime = .invalid
                self.writerLock.unlock()
            }
            self.writerLock.unlock()
        }
    }
    
    private func setupMicrophone(settings: AppSettings) {
        let session = AVCaptureSession()
        self.captureSession = session
        
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
        
        var device: AVCaptureDevice? = AVCaptureDevice.default(for: .audio)
        if let micID = settings.micID, let d = devices.first(where: { $0.uniqueID == micID }) {
            device = d
        }
        
        guard let device = device else { return }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "Rec.micQueue"))
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            
            self.micConnection = output.connection(with: .audio)
            session.startRunning()
        } catch {
            print("Microphone setup failed: \(error)")
        }
    }

    private func setupAssetWriter(config: SCStreamConfiguration, settings: AppSettings) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dateString = formatter.string(from: Date())

        var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        
        if let bookmarkData = settings.saveLocationData {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if resolvedURL.startAccessingSecurityScopedResource() {
                    directory = resolvedURL
                }
            }
        }
        
        let fileURL = directory.appendingPathComponent("Screen Recording \(dateString).mov")
        self.outputFile = fileURL

        do {
            assetWriter = try AVAssetWriter(url: fileURL, fileType: .mov)

            var videoWidth = config.width
            var videoHeight = config.height
            
            if settings.resolution == .res1080p {
                let ratio = CGFloat(config.width) / CGFloat(config.height)
                videoHeight = 1080
                videoWidth = Int(CGFloat(1080) * ratio)
            } else if settings.resolution == .res720p {
                let ratio = CGFloat(config.width) / CGFloat(config.height)
                videoHeight = 720
                videoWidth = Int(CGFloat(720) * ratio)
            }
            
            if videoWidth % 2 != 0 { videoWidth -= 1 }
            if videoHeight % 2 != 0 { videoHeight -= 1 }
            
            var compressionProperties: [String: Any] = [:]
            
            let bitsPerPixel: Double
            if settings.bitrate == .high { bitsPerPixel = 0.5 }
            else if settings.bitrate == .medium { bitsPerPixel = 0.25 }
            else { bitsPerPixel = 0.12 }
            
            let fps = Double(settings.framerate.rawValue)
            let estimatedBitrate = Int(Double(videoWidth * videoHeight) * fps * bitsPerPixel)
            compressionProperties[AVVideoAverageBitRateKey] = estimatedBitrate

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: compressionProperties
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
            
            if settings.audio == .system || settings.audio == .systemAndMic {
                audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput?.expectsMediaDataInRealTime = true
                if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
                    assetWriter?.add(audioInput)
                }
            }
            
            if settings.audio == .microphone || settings.audio == .systemAndMic {
                micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                micAudioInput?.expectsMediaDataInRealTime = true
                if let micAudioInput = micAudioInput, assetWriter?.canAdd(micAudioInput) == true {
                    assetWriter?.add(micAudioInput)
                }
            }

            assetWriter?.startWriting()

        } catch {
            DispatchQueue.main.async { self.onError?(error) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording else { return }

        writerLock.lock()
        defer { writerLock.unlock() }

        guard let assetWriter = assetWriter else { return }

        if sessionStartTime == .invalid {
            sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter.startSession(atSourceTime: sessionStartTime)
        }

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
}

extension Recorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        
        writerLock.lock()
        defer { writerLock.unlock() }
        
        if sessionStartTime == .invalid { return }
        
        if let micAudioInput = micAudioInput, micAudioInput.isReadyForMoreMediaData {
            micAudioInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.onError?(error)
            self.stopRecording()
        }
    }
}

// MARK: - UI Components

class RecordingIndicatorView: NSView {
    var transparentRect: NSRect = .zero {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.0, alpha: 0.2).set()
        dirtyRect.fill()

        if !transparentRect.isEmpty {
            NSColor.clear.set()
            transparentRect.fill(using: .sourceOut)
        }
    }
}

class RecordingIndicatorWindow: NSWindow {
    let indicatorView = RecordingIndicatorView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.contentView = indicatorView
    }
}

class SelectionView: NSView {
    var selectionRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    
    var onSelectionCompleted: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    
    private var startPoint: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.0, alpha: 0.5).set()
        dirtyRect.fill()

        if !selectionRect.isEmpty {
            NSColor.clear.set()
            selectionRect.fill(using: .sourceOut)

            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 2.0
            let dash: [CGFloat] = [5.0, 5.0]
            path.setLineDash(dash, count: 2, phase: 0.0)
            path.stroke()

            let text = String(format: "%.0f × %.0f", selectionRect.width, selectionRect.height)
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .bold)
            ]
            let size = text.size(withAttributes: attributes)
            let textRect = NSRect(x: selectionRect.midX - size.width / 2, y: selectionRect.midY - size.height / 2, width: size.width, height: size.height)
            
            // Draw a subtle background pill for text
            let pillRect = textRect.insetBy(dx: -8, dy: -4)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 8, yRadius: 8)
            NSColor(white: 0.0, alpha: 0.7).setFill()
            pillPath.fill()
            
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(origin: startPoint!, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        startPoint = nil
        onSelectionCompleted?(selectionRect)
    }
    
    override var acceptsFirstResponder: Bool { return true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }
}

class SelectionOverlayWindow: NSWindow {
    let selectionView = SelectionView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.contentView = selectionView
        self.makeFirstResponder(selectionView)
    }
}

class CountdownWindow: NSWindow {
    let label = NSTextField(labelWithString: "")
    
    init(screen: NSScreen) {
        let size: CGFloat = 200
        let rect = NSRect(x: screen.frame.midX - size/2, y: screen.frame.midY - size/2, width: size, height: size)
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        
        self.isOpaque = false
        self.backgroundColor = NSColor(white: 0.0, alpha: 0.7)
        self.hasShadow = true
        self.level = .screenSaver
        self.ignoresMouseEvents = true
        
        // Make it circular
        let contentView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = size / 2
        contentView.layer?.masksToBounds = true
        
        label.font = NSFont.systemFont(ofSize: 120, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        
        self.contentView = contentView
    }
}

class FloatingPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        // Added .closable mask and other necessary styles
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView], backing: backingStoreType, defer: flag)

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear

        // Hide standard window buttons
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var recordButton: NSButton!
    var closeButton: NSButton!
    var modeDropdown: NSPopUpButton!
    var audioDropdown: NSPopUpButton!
    var timerDropdown: NSPopUpButton!
    var settingsButton: NSButton!
    
    let recorder = Recorder()

    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
        setupUI()
        setupRecorder()
        checkPermissions()
    }

    func checkPermissions() {
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText = "Rec requires screen recording permissions to function properly. Please grant access in System Settings."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Quit")
                
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                NSApplication.shared.terminate(nil)
            }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rec")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Controls", action: #selector(showPanel), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "About Rec", action: #selector(showAboutWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Rec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    var aboutWindow: NSWindow?

    @objc func showAboutWindow() {
        if aboutWindow != nil {
            aboutWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 300
        let height: CGFloat = 200
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.center()
        window.title = "About Rec"
        window.titlebarAppearsTransparent = true

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let titleLabel = NSTextField(labelWithString: "Rec")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let versionLabel = NSTextField(labelWithString: "Version \(appVersion)")
        versionLabel.font = NSFont.systemFont(ofSize: 14)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        updateButton.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView(views: [titleLabel, versionLabel, updateButton])
        stackView.orientation = .vertical
        stackView.spacing = 10
        stackView.alignment = .centerX
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        window.contentView = contentView
        self.aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkForUpdates() {
        guard let url = URL(string: "https://rec-aoh.netlify.app/version.json") else { return }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latestVersion = json["version"] as? String else { return }

            DispatchQueue.main.async {
                if latestVersion != appVersion {
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "Version \(latestVersion) is available."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        if let downloadURL = URL(string: "https://rec-aoh.netlify.app") {
                            NSWorkspace.shared.open(downloadURL)
                        }
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Up to Date"
                    alert.informativeText = "You are running the latest version of Rec."
                    alert.runModal()
                }
            }
        }.resume()
    }

    @objc func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupUI() {
        let width: CGFloat = 280
        let height: CGFloat = 60

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        let rect = NSRect(x: (screenFrame.width - width) / 2, y: 100, width: width, height: height)
        panel = FloatingPanel(contentRect: rect, styleMask: [], backing: .buffered, defer: false)

        guard let contentView = panel.contentView else { return }

        // Setup Buttons and Dropdowns
        
        let config24 = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let config18 = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)

        closeButton = createIconOnlyButton(symbolName: "xmark.circle.fill", config: config18, action: #selector(NSApplication.terminate(_:)))
        
        settingsButton = createIconOnlyButton(symbolName: "gearshape.fill", config: config18, action: #selector(showSettings))
        
        timerDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        timerDropdown.isBordered = false
        timerDropdown.imagePosition = .imageOnly
        timerDropdown.target = self
        timerDropdown.action = #selector(timerChanged)
        updateTimerDropdown()
        
        audioDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        audioDropdown.isBordered = false
        audioDropdown.imagePosition = .imageOnly
        audioDropdown.target = self
        audioDropdown.action = #selector(audioChanged)
        updateAudioDropdown()
        
        modeDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        modeDropdown.isBordered = false
        modeDropdown.imagePosition = .imageOnly
        modeDropdown.target = self
        modeDropdown.action = #selector(modeChanged)
        updateModeDropdown()
        
        recordButton = NSButton()
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.bezelStyle = .regularSquare
        recordButton.isBordered = false
        recordButton.imagePosition = .imageOnly
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        updateButtonImage()

        let stackView = NSStackView(views: [closeButton, settingsButton, timerDropdown, audioDropdown, modeDropdown, recordButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 16
        stackView.alignment = .centerY

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        panel.makeKeyAndOrderFront(nil)
    }

    private func createIconOnlyButton(symbolName: String, config: NSImage.SymbolConfiguration, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        button.target = self
        button.action = action
        return button
    }

    @objc func timerChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.shared
        if sender.indexOfSelectedItem == 1 {
            settings.timer = .sec5
        } else if sender.indexOfSelectedItem == 2 {
            settings.timer = .sec10
        } else {
            settings.timer = .none
        }
        AppSettings.shared = settings
    }
    
    @objc func audioChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.shared
        if sender.indexOfSelectedItem == 0 {
            settings.audio = .system
        } else if sender.indexOfSelectedItem == 1 {
            settings.audio = .microphone
        } else if sender.indexOfSelectedItem == 2 {
            settings.audio = .systemAndMic
        } else {
            settings.audio = .none
        }
        AppSettings.shared = settings
    }
    
    @objc func modeChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.shared
        if sender.indexOfSelectedItem == 0 {
            settings.mode = .entireScreen
        } else if sender.indexOfSelectedItem == 1 {
            settings.mode = .selectedPortion
        } else if sender.indexOfSelectedItem == 2 {
            settings.mode = .specificApp
            showAppPicker()
        }
        AppSettings.shared = settings
    }
    
    func showAppPicker() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let apps = content?.applications else { return }
            
            DispatchQueue.main.async {
                let menu = NSMenu()
                for app in apps {
                    // Ignore Finder and system apps generally by ignoring those without a bundle ID or standard Apple ones
                    guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier, bundleID != "com.apple.finder" else { continue }
                    
                    let item = NSMenuItem(title: app.applicationName, action: #selector(self.appSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = app
                    
                    if let iconPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let icon = NSWorkspace.shared.icon(forFile: iconPath.path)
                        icon.size = NSSize(width: 16, height: 16)
                        item.image = icon
                    }
                    menu.addItem(item)
                }
                
                let location = self.modeDropdown.window?.convertPoint(toScreen: self.modeDropdown.convert(NSPoint(x: 0, y: 0), to: nil)) ?? NSEvent.mouseLocation
                menu.popUp(positioning: nil, at: location, in: nil)
            }
        }
    }
    
    @objc func appSelected(_ sender: NSMenuItem) {
        if let app = sender.representedObject as? SCRunningApplication {
            self.recorder.selectedApp = app
        }
    }

    var settingsWindow: NSWindow?
    
    @objc func showSettings() {
        if settingsWindow != nil {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 300
        let height: CGFloat = 200
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.center()
        window.title = "Settings"

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        
        let settings = AppSettings.shared

        let showClicksBtn = NSButton(checkboxWithTitle: "Show Mouse Clicks", target: self, action: #selector(toggleMouseClicks(_:)))
        showClicksBtn.state = settings.showMouseClicks ? .on : .off
        showClicksBtn.translatesAutoresizingMaskIntoConstraints = false

        let fpsLabel = NSTextField(labelWithString: "Framerate:")
        let fpsDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsDropdown.addItems(withTitles: ["60 FPS", "30 FPS", "24 FPS"])
        if settings.framerate == .fps60 { fpsDropdown.selectItem(at: 0) }
        else if settings.framerate == .fps30 { fpsDropdown.selectItem(at: 1) }
        else { fpsDropdown.selectItem(at: 2) }
        fpsDropdown.target = self
        fpsDropdown.action = #selector(fpsChanged(_:))
        let fpsStack = NSStackView(views: [fpsLabel, fpsDropdown])
        fpsStack.orientation = .horizontal
        
        let resLabel = NSTextField(labelWithString: "Resolution:")
        let resDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        resDropdown.addItems(withTitles: ["Native", "1080p", "720p"])
        if settings.resolution == .native { resDropdown.selectItem(at: 0) }
        else if settings.resolution == .res1080p { resDropdown.selectItem(at: 1) }
        else { resDropdown.selectItem(at: 2) }
        resDropdown.target = self
        resDropdown.action = #selector(resChanged(_:))
        let resStack = NSStackView(views: [resLabel, resDropdown])
        resStack.orientation = .horizontal

        let bitLabel = NSTextField(labelWithString: "Bitrate:")
        let bitDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
        bitDropdown.addItems(withTitles: ["High", "Medium", "Low"])
        if settings.bitrate == .high { bitDropdown.selectItem(at: 0) }
        else if settings.bitrate == .medium { bitDropdown.selectItem(at: 1) }
        else { bitDropdown.selectItem(at: 2) }
        bitDropdown.target = self
        bitDropdown.action = #selector(bitChanged(_:))
        let bitStack = NSStackView(views: [bitLabel, bitDropdown])
        bitStack.orientation = .horizontal
        
        let saveLocationBtn = NSButton(title: "Choose Save Location", target: self, action: #selector(chooseSaveLocation))

        let stackView = NSStackView(views: [showClicksBtn, fpsStack, resStack, bitStack, saveLocationBtn])
        stackView.orientation = .vertical
        stackView.spacing = 15
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20)
        ])

        window.contentView = contentView
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func toggleMouseClicks(_ sender: NSButton) {
        var settings = AppSettings.shared
        settings.showMouseClicks = (sender.state == .on)
        AppSettings.shared = settings
    }
    
    @objc func fpsChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.shared
        if sender.indexOfSelectedItem == 0 { settings.framerate = .fps60 }
        else if sender.indexOfSelectedItem == 1 { settings.framerate = .fps30 }
        else { settings.framerate = .fps24 }
        AppSettings.shared = settings
    }
    
    @objc func resChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.shared
        if sender.indexOfSelectedItem == 0 { settings.resolution = .native }
        else if sender.indexOfSelectedItem == 1 { settings.resolution = .res1080p }
        else { settings.resolution = .res720p }
        AppSettings.shared = settings
    }

    @objc func bitChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.shared
        if sender.indexOfSelectedItem == 0 { settings.bitrate = .high }
        else if sender.indexOfSelectedItem == 1 { settings.bitrate = .medium }
        else { settings.bitrate = .low }
        AppSettings.shared = settings
    }

    @objc func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Save Location"
        
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            if let url = panel.url {
                var settings = AppSettings.shared
                if let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    settings.saveLocationData = bookmarkData
                    AppSettings.shared = settings
                }
            }
        }
    }

    private func updateTimerDropdown() {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        timerDropdown.menu?.removeAllItems()
        let menu = NSMenu()
        menu.addItem(withTitle: "No Timer", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "5 Seconds", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "10 Seconds", action: nil, keyEquivalent: "")
        timerDropdown.menu = menu
        timerDropdown.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func updateAudioDropdown() {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        audioDropdown.menu?.removeAllItems()
        let menu = NSMenu()
        menu.addItem(withTitle: "System Audio", action: nil, keyEquivalent: "")
        
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
        let micMenu = NSMenu()
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(self.micSelected(_:)), keyEquivalent: "")
            item.representedObject = device.uniqueID
            item.target = self
            micMenu.addItem(item)
        }
        
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)
        
        menu.addItem(withTitle: "System + Mic", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "None", action: nil, keyEquivalent: "")
        
        audioDropdown.menu = menu
        audioDropdown.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    @objc func micSelected(_ sender: NSMenuItem) {
        if let micID = sender.representedObject as? String {
            var settings = AppSettings.shared
            settings.micID = micID
            
            // Set audio mode to Microphone or System + Mic based on user intention. For simplicity, set to Microphone if selected from here.
            settings.audio = .microphone
            
            AppSettings.shared = settings
        }
    }

    private func updateModeDropdown() {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        modeDropdown.menu?.removeAllItems()
        let menu = NSMenu()
        menu.addItem(withTitle: "Entire Screen", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Selected Portion", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Specific App", action: nil, keyEquivalent: "")
        modeDropdown.menu = menu
        modeDropdown.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    func setupRecorder() {
        recorder.onRecordingStarted = { [weak self] in
            self?.updateButtonImage()
        }

        recorder.onRecordingStopped = { [weak self] url in
            self?.updateButtonImage()
            let alert = NSAlert()
            alert.messageText = "Recording Saved"
            alert.informativeText = "Saved to \(url.lastPathComponent) in Downloads folder."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        recorder.onError = { [weak self] error in
            self?.updateButtonImage()
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    @objc func toggleRecording() {
        let settings = AppSettings.shared
        
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            if settings.timer == .none {
                recorder.startRecording()
            } else {
                startCountdownAndRecord(seconds: settings.timer.rawValue)
            }
        }
    }
    
    var countdownWindow: CountdownWindow?
    var countdownTimer: Timer?
    var secondsRemaining = 0
    
    func startCountdownAndRecord(seconds: Int) {
        guard let screen = NSScreen.main else { return }
        
        secondsRemaining = seconds
        let window = CountdownWindow(screen: screen)
        window.label.stringValue = "\(secondsRemaining)"
        window.makeKeyAndOrderFront(nil)
        self.countdownWindow = window
        
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            self.secondsRemaining -= 1
            if self.secondsRemaining > 0 {
                self.countdownWindow?.label.stringValue = "\(self.secondsRemaining)"
            } else {
                timer.invalidate()
                self.countdownWindow?.close()
                self.countdownWindow = nil
                self.recorder.startRecording()
            }
        }
    }

    func updateButtonImage() {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let symbolName = recorder.isRecording ? "stop.circle.fill" : "record.circle"

        if let systemImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {

            // To safely tint a system symbol image without lockFocus crashing
            let size = systemImage.size
            let tintedImage = NSImage(size: size)
            tintedImage.lockFocus()
            systemImage.draw(in: NSRect(origin: .zero, size: size))
            NSColor.systemRed.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tintedImage.unlockFocus()

            recordButton.image = tintedImage
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Still an accessory app, but with Menu Bar item to quit
app.run()
