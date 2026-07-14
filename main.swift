import Cocoa
import ScreenCaptureKit
import AVFoundation

// ============================================================
//  Rec
// ============================================================

let appVersion = "1.0"

// MARK: - Recorder

class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var assetWriter: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var audioInput: AVAssetWriterInput?
    var isRecording = false
    var outputFile: URL?

    var sessionStartTime: CMTime = .invalid
    private let writerLock = NSLock()

    // UI Callbacks
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    func startRecording() {
        if isRecording { return }

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

            // Exclude our own app from being recorded
            guard let myApp = content?.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                self.continueStartingRecording(filter: filter, display: display)
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [myApp], exceptingWindows: [])
            self.continueStartingRecording(filter: filter, display: display)
        }
    }

    private func continueStartingRecording(filter: SCContentFilter, display: SCDisplay) {
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.capturesAudio = true

        do {
            self.setupAssetWriter(config: config)

            self.stream = SCStream(filter: filter, configuration: config, delegate: self)
            try self.stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Rec.videoQueue"))
            try self.stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "Rec.audioQueue"))

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

            self.writerLock.lock()
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()

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
                self.sessionStartTime = .invalid
                self.writerLock.unlock()
            }
            self.writerLock.unlock()
        }
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

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height
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
                AVEncoderBitRateKey: 128000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
                assetWriter?.add(audioInput)
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
}

// MARK: - UI Components

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
    let recorder = Recorder()

    // Create an accessory menu so users can quit gracefully
    var statusItem: NSStatusItem!

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
        menu.addItem(NSMenuItem(title: "Show Controls", action: #selector(showPanel), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Rec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupUI() {
        let width: CGFloat = 160
        let height: CGFloat = 60

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        let rect = NSRect(x: (screenFrame.width - width) / 2, y: 100, width: width, height: height)
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

        closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(closeConfig)
        closeButton.target = self
        closeButton.action = #selector(NSApplication.terminate(_:))

        let stackView = NSStackView(views: [recordButton, closeButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 20
        stackView.alignment = .centerY

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        panel.makeKeyAndOrderFront(nil)
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
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            recorder.startRecording()
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
