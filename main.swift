import Cocoa
import ScreenCaptureKit
import AVFoundation
import VideoToolbox

// ============================================================
//  Rec
// ============================================================

let appVersion = "1.0"
let updateCheckURL = "https://rec-aoh.netlify.app/version.json" // Note: URL points to old repo structure, ideally update this on github later


// MARK: - Global Settings

struct AppSettings {
    var fps: Int = 60
    var resolution: Int = 0
    var bitrate: Int = 0
    var timer: Int = 0
    var audioSource: Int = 0 // 0 = System Audio, 1 = Microphone, 2 = Both, 3 = None
}

var currentSettings = AppSettings()

// MARK: - Overlay Window for Region Selection

class RegionSelectionWindow: NSWindow {
    var selectionHandler: ((CGRect) -> Void)?
    var selectionView: SelectionView!

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.ignoresMouseEvents = false

        selectionView = SelectionView(frame: self.contentView!.bounds)
        self.contentView?.addSubview(selectionView)

        let label = NSTextField(labelWithString: "Click and drag to select a recording region. Press Esc to cancel.")
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: (screen.frame.width - label.frame.width) / 2, y: screen.frame.height / 2)
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
            selectionHandler?(rect)
        } else {
            selectionHandler?(.zero)
        }
        self.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            selectionHandler?(.zero)
            self.close()
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
            NSColor.clear.set()
            currentRect.fill(using: .sourceOut)

            NSColor.white.setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2
            let dash: [CGFloat] = [5.0, 5.0]
            path.setLineDash(dash, count: 2, phase: 0.0)
            path.stroke()
        }
    }
}

// MARK: - App Selection Menu
class AppSelectionMenuHandler: NSObject {
    var onSelect: ((SCRunningApplication?) -> Void)?
    var apps: [SCRunningApplication] = []

    func showMenu(at view: NSView) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let content = content else { return }

            let myProcessId = ProcessInfo.processInfo.processIdentifier
            var uniqueApps = [String: SCRunningApplication]()
            for app in content.applications {
                let name = app.applicationName
                // Exclude ourselves and empty names
                if app.processID != myProcessId, !name.isEmpty {
                    // Keep it simple so we don't accidentally filter out everything
                    if !name.hasPrefix("com.apple") {
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

                for (index, app) in self.apps.enumerated() {
                    let item = NSMenuItem(title: app.applicationName, action: #selector(self.appSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = index

                    // Fetch app icon for a nice UI
                    if let runningApp = NSRunningApplication(processIdentifier: app.processID),
                       let icon = runningApp.icon {
                        icon.size = NSSize(width: 16, height: 16)
                        item.image = icon
                    }
                    menu.addItem(item)
                }

                if self.apps.isEmpty {
                    let emptyItem = NSMenuItem(title: "No applications found.", action: nil, keyEquivalent: "")
                    emptyItem.isEnabled = false
                    menu.addItem(emptyItem)
                }


                if let event = NSApplication.shared.currentEvent {
                    NSMenu.popUpContextMenu(menu, with: event, for: view)
                } else {
                    menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.width / 2, y: view.bounds.height), in: view)
                }

            }
        }
    }

    @objc func appSelected(_ sender: NSMenuItem) {
        let app = apps[sender.tag]
        onSelect?(app)
    }
}

// MARK: - Recorder

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

    var captureRect: CGRect?
    var captureApp: SCRunningApplication?

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
            guard let display = content?.displays.first else {
                DispatchQueue.main.async {
                    self.onError?(NSError(domain: "RecorderError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No display found"]))
                }
                return
            }

            let filter: SCContentFilter
            if let app = self.captureApp {
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                let myProcessId = ProcessInfo.processInfo.processIdentifier
                guard let myApp = content?.applications.first(where: { $0.processID == myProcessId }) else {
                    filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    self.continueStartingRecording(filter: filter, display: display)
                    return
                }
                filter = SCContentFilter(display: display, excludingApplications: [myApp], exceptingWindows: [])
            }

            self.continueStartingRecording(filter: filter, display: display)
        }
    }

    private func continueStartingRecording(filter: SCContentFilter, display: SCDisplay) {
        let config = SCStreamConfiguration()
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0

        var baseWidth = display.width
        var baseHeight = display.height

        if let rect = captureRect, rect != .zero {
            // ScreenCaptureKit sourceRect uses logical points in the display's coordinate space (origin top-left).
            // NSWindow / NSEvent gives us coordinates where origin is bottom-left of the main screen.
            // But we already mapped the selection relative to the NSScreen frame.

            // To be safe with AVAssetWriter HEVC, width/height must be EVEN numbers.
            let safeWidth = Int(rect.width) % 2 == 0 ? Int(rect.width) : Int(rect.width) + 1
            let safeHeight = Int(rect.height) % 2 == 0 ? Int(rect.height) : Int(rect.height) + 1

            let flippedY = display.height - Int(rect.origin.y) - safeHeight

            // Clamp mapping to display bounds to prevent SCStream from crashing with out-of-bounds exceptions
            let x = max(0, min(Int(rect.origin.x), display.width - 2))
            let y = max(0, min(flippedY, display.height - 2))
            let clampedWidth = min(safeWidth, display.width - x)
            let clampedHeight = min(safeHeight, display.height - y)

            // Re-enforce even dimensions after clamping
            let finalWidth = clampedWidth % 2 == 0 ? clampedWidth : clampedWidth - 1
            let finalHeight = clampedHeight % 2 == 0 ? clampedHeight : clampedHeight - 1

            let mappedRect = CGRect(x: x, y: y, width: finalWidth, height: finalHeight).intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))

            config.sourceRect = mappedRect
            baseWidth = finalWidth
            baseHeight = finalHeight
        }

        if currentSettings.resolution == 1080 {
            let ratio = CGFloat(baseWidth) / CGFloat(baseHeight)
            config.width = 1920
            config.height = Int(1920 / ratio)
        } else if currentSettings.resolution == 720 {
            let ratio = CGFloat(baseWidth) / CGFloat(baseHeight)
            config.width = 1280
            config.height = Int(1280 / ratio)
        } else {
            config.width = Int(CGFloat(baseWidth) * scaleFactor)
            config.height = Int(CGFloat(baseHeight) * scaleFactor)
        }

        // HEVC requires even dimensions
        if config.width % 2 != 0 { config.width += 1 }
        if config.height % 2 != 0 { config.height += 1 }

        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(currentSettings.fps))
        config.queueDepth = 5
        config.capturesAudio = true
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            self.setupMic()

            self.setupAssetWriter(config: config)
            self.stream = SCStream(filter: filter, configuration: config, delegate: self)
            try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Rec.videoQueue"))
                        if currentSettings.audioSource == 0 || currentSettings.audioSource == 2 {
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
        isRecording = false // Set synchronously to avoid double-clicks

                self.micSession?.stopRunning()
        self.micSession = nil
        self.micOutput = nil

        stream?.stopCapture { [weak self] error in
            guard let self = self else { return }

            if let error = error { DispatchQueue.main.async { self.onError?(error) } }

            self.writerLock.lock()
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            self.assetWriter?.finishWriting {
                DispatchQueue.main.async { if let url = self.outputFile { self.onRecordingStopped?(url) } }
                self.writerLock.lock()
                self.stream = nil
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.micInput = nil
                self.sessionStartTime = .invalid
                self.writerLock.unlock()
            }
            self.writerLock.unlock()
        }
    }


    private func setupMic() {
        guard currentSettings.audioSource == 1 || currentSettings.audioSource == 2 else { return }

        micSession = AVCaptureSession()
        guard let mic = AVCaptureDevice.default(for: .audio),
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

    private func setupAssetWriter(config: SCStreamConfiguration) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dateString = formatter.string(from: Date())
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let fileURL = downloadsDirectory.appendingPathComponent("Screen Recording \(dateString).mov")
        self.outputFile = fileURL

        do {
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

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.onError?(error)
            self.stopRecording()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        writerLock.lock()
        defer { writerLock.unlock() }
        guard let assetWriter = assetWriter else { return }

        if sessionStartTime == .invalid {
            sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter.startSession(atSourceTime: sessionStartTime)
        }

        if let micInput = micInput, micInput.isReadyForMoreMediaData {
            micInput.append(sampleBuffer)
        }
    }
}

// MARK: - UI Components

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
                            if let dlURL = URL(string: "https://github.com/arunofhyd/Rec") {
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var recordButton: NSButton!
    var closeButton: NSButton!
    var modePopUp: NSPopUpButton!
    let recorder = Recorder()

    var statusItem: NSStatusItem!
    var appSelectionMenu: AppSelectionMenuHandler?
    var aboutWC: AboutWindowController?

    var countdownLabel: NSTextField?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
        setupUI()
        setupRecorder()
        checkPermissions()
    }

    func checkPermissions() {
        CGRequestScreenCaptureAccess()
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

    @objc func fpsChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        let index = menu.index(of: sender)
        if index == 0 { currentSettings.fps = 60 }
        else if index == 1 { currentSettings.fps = 30 }
        else { currentSettings.fps = 24 }
    }
    @objc func resChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        let index = menu.index(of: sender)
        if index == 0 { currentSettings.resolution = 0 }
        else if index == 1 { currentSettings.resolution = 1080 }
        else { currentSettings.resolution = 720 }
    }
    @objc func bitChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        currentSettings.bitrate = menu.index(of: sender)
    }
    @objc func audioChanged(_ sender: NSPopUpButton) { currentSettings.audioSource = sender.indexOfSelectedItem }
    @objc func timerChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 { currentSettings.timer = 0 }
        else if sender.indexOfSelectedItem == 1 { currentSettings.timer = 5 }
        else { currentSettings.timer = 10 }
    }

    func setupUI() {
        guard let screen = NSScreen.main else { return }
        // We'll set a tiny initial rect; Auto Layout will resize it if we pin constraints
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
        audioPopUp.menu?.addItem(audioSystemItem)
        audioPopUp.menu?.addItem(audioMicItem)
        audioPopUp.menu?.addItem(audioBothItem)
        audioPopUp.menu?.addItem(audioNoneItem)
        audioPopUp.selectItem(at: currentSettings.audioSource)
        audioPopUp.action = #selector(audioChanged(_:))
        audioPopUp.target = self

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

        closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        closeButton.target = self
        closeButton.action = #selector(hidePanel)

        modePopUp = NSPopUpButton()
        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        // Remove the default empty item
        modePopUp.removeAllItems()

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

        // Hide the popup button's arrows to make it look like a clean icon toggle
        modePopUp.isBordered = false
        modePopUp.imagePosition = .imageOnly

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
            // FIX: Close window properly instead of just removing view
            self?.countdownLabel?.window?.close()
            self?.countdownLabel = nil
            self?.updateButtonImage()
            self?.modePopUp.isEnabled = false
        }

        recorder.onRecordingStopped = { [weak self] url in
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
            self?.countdownLabel?.window?.close()
            self?.countdownLabel = nil
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
        if countdownLabel == nil {
            countdownLabel = NSTextField(labelWithString: "")
            countdownLabel?.font = .systemFont(ofSize: 120, weight: .bold)
            countdownLabel?.textColor = .white
            countdownLabel?.backgroundColor = NSColor.black.withAlphaComponent(0.5)
            countdownLabel?.drawsBackground = true
            countdownLabel?.isBordered = false
            countdownLabel?.alignment = .center
            countdownLabel?.translatesAutoresizingMaskIntoConstraints = false
            countdownLabel?.layer?.cornerRadius = 20

            if let _ = panel.contentView?.window?.screen?.visibleFrame {
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
                win.isOpaque = false
                win.backgroundColor = .clear
                win.level = .floating
                win.ignoresMouseEvents = true
                win.contentView?.addSubview(countdownLabel!)
                countdownLabel?.frame = win.contentView!.bounds
                win.center()
                win.makeKeyAndOrderFront(nil)
            }
        }
        countdownLabel?.stringValue = "\(seconds)"
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
                self?.recorder.startRecording()
            }
            appSelectionMenu?.showMenu(at: modePopUp)
        } else if modeIndex == 1 { // Selected Portion
            guard let screen = NSScreen.main else { return }
            let overlay = RegionSelectionWindow(screen: screen)
            overlay.makeKeyAndOrderFront(nil)
            self.panel.orderOut(nil)
            overlay.selectionHandler = { [weak self] rect in
                guard let self = self else { return }
                self.panel.makeKeyAndOrderFront(nil)
                if rect != .zero {
                    self.recorder.captureApp = nil
                    self.recorder.captureRect = rect
                    self.recorder.startRecording()
                }
            }
        } else {
            recorder.captureApp = nil
            recorder.captureRect = nil
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
                // Draw white outer circle
                NSColor.white.setStroke()
                let outerPath = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4))
                outerPath.lineWidth = 2
                outerPath.stroke()

                // Draw red inner dot
                NSColor.systemRed.setFill()
                let innerPath = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: size.width - 14, height: size.height - 14))
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
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
