import Cocoa
import ScreenCaptureKit
import AVFoundation
import AVKit
import VideoToolbox
import os.log
import SwiftUI
import QuartzCore

// MARK: - Configuration
let appVersion: String = {
    if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
        return ver
    }
    return "1.3.8"
}()
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/Rec/main/version.json"
private let log = OSLog(subsystem: "com.aoh.rec", category: "recorder")

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
    var lastRectX: Double?
    var lastRectY: Double?
    var lastRectW: Double?
    var lastRectH: Double?
    var lastScreenDisplayID: UInt32?

    var savedLastRect: NSRect? {
        guard let x = lastRectX, let y = lastRectY, let w = lastRectW, let h = lastRectH,
              w > 5, h > 5 else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    func savedLastScreen() -> NSScreen? {
        if let displayID = lastScreenDisplayID {
            for screen in NSScreen.screens {
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, id == displayID {
                    return screen
                }
            }
        }
        return NSScreen.main
    }

    mutating func saveLastSelectedArea(rect: NSRect, screen: NSScreen) {
        self.lastRectX = Double(rect.origin.x)
        self.lastRectY = Double(rect.origin.y)
        self.lastRectW = Double(rect.size.width)
        self.lastRectH = Double(rect.size.height)
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            self.lastScreenDisplayID = displayID
        }
        self.save()
    }

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

struct ChangelogAlertView: View {
    let changelog: String
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(changelog)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(NSColor.labelColor))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: 360, height: 150)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
}

func createChangelogView(changelog: String) -> NSView {
    let hostingView = NSHostingView(rootView: ChangelogAlertView(changelog: changelog))
    hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 150)
    return hostingView
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

class TapFeedbackWindow: NSWindow {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false
        
        let containerView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        self.contentView = containerView
    }

    func spawnRipple(at screenPoint: NSPoint, isRightClick: Bool = false) {
        guard let view = self.contentView, let rootLayer = view.layer else { return }
        
        // Convert screen coordinate to window coordinate
        let localPoint = self.convertPoint(fromScreen: screenPoint)
        
        // Get theme color: White when highlightCursor is disabled, otherwise the selected cursorColor
        let baseColor: NSColor
        let shadowColor: CGColor
        if !currentSettings.highlightCursor {
            baseColor = isRightClick ? NSColor(white: 0.88, alpha: 1.0) : NSColor.white
            shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        } else {
            switch currentSettings.cursorColor {
            case 0: // Yellow / Gold
                baseColor = isRightClick ? NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1.0) : NSColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1.0)
            case 1: // Red / Coral
                baseColor = isRightClick ? NSColor(red: 1.0, green: 0.18, blue: 0.33, alpha: 1.0) : NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
            case 2: // Green / Emerald
                baseColor = isRightClick ? NSColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 1.0) : NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
            case 3: // Blue / Sapphire
                baseColor = isRightClick ? NSColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1.0) : NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
            default:
                baseColor = NSColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1.0)
            }
            shadowColor = baseColor.cgColor
        }

        let rippleSize: CGFloat = 30.0
        let rippleLayer = CALayer()
        rippleLayer.bounds = CGRect(x: 0, y: 0, width: rippleSize, height: rippleSize)
        rippleLayer.position = CGPoint(x: localPoint.x, y: localPoint.y)
        rippleLayer.cornerRadius = rippleSize / 2
        rippleLayer.backgroundColor = baseColor.withAlphaComponent(0.40).cgColor
        rippleLayer.borderColor = baseColor.withAlphaComponent(0.90).cgColor
        rippleLayer.borderWidth = 2.0
        rippleLayer.shadowColor = shadowColor
        rippleLayer.shadowRadius = 8.0
        rippleLayer.shadowOpacity = 0.55
        rippleLayer.shadowOffset = .zero

        rootLayer.addSublayer(rippleLayer)

        let duration: CFTimeInterval = 0.50
        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.2
        scaleAnim.toValue = isRightClick ? 2.8 : 2.5

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.0

        let borderAnim = CABasicAnimation(keyPath: "borderWidth")
        borderAnim.fromValue = 2.5
        borderAnim.toValue = 0.5

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim, borderAnim]
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        rippleLayer.add(group, forKey: "clickRipple")

        // For right clicks, add an inner/outer secondary accent ring
        if isRightClick {
            let ringLayer = CALayer()
            ringLayer.bounds = CGRect(x: 0, y: 0, width: rippleSize * 0.7, height: rippleSize * 0.7)
            ringLayer.position = CGPoint(x: localPoint.x, y: localPoint.y)
            ringLayer.cornerRadius = (rippleSize * 0.7) / 2
            ringLayer.backgroundColor = NSColor.clear.cgColor
            ringLayer.borderColor = baseColor.withAlphaComponent(0.95).cgColor
            ringLayer.borderWidth = 2.0
            rootLayer.addSublayer(ringLayer)

            let ringScale = CABasicAnimation(keyPath: "transform.scale")
            ringScale.fromValue = 0.3
            ringScale.toValue = 1.8

            let ringOpacity = CABasicAnimation(keyPath: "opacity")
            ringOpacity.fromValue = 1.0
            ringOpacity.toValue = 0.0

            let ringGroup = CAAnimationGroup()
            ringGroup.animations = [ringScale, ringOpacity]
            ringGroup.duration = duration * 0.8
            ringGroup.timingFunction = timing
            ringGroup.fillMode = .forwards
            ringGroup.isRemovedOnCompletion = false

            ringLayer.add(ringGroup, forKey: "ringRipple")

            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
                ringLayer.removeFromSuperlayer()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            rippleLayer.removeFromSuperlayer()
        }
    }
}

class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

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
    var isDragging = false
    var isLastSelectedAreaPreview = false
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { return true }

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

            let w = Int(currentRect.width)
            let h = Int(currentRect.height)
            let titlePrefix = isLastSelectedAreaPreview ? "🎯 Last Selected Area: " : ""
            let text = "\(titlePrefix)\(w) × \(h) px  •  Press Enter/Space or click to confirm  •  Drag to draw new  •  Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let textSize = attrStr.size()
            let textRect = NSRect(
                x: max(10, min(bounds.width - textSize.width - 20, currentRect.midX - textSize.width / 2)),
                y: currentRect.maxY + 8 + textSize.height > bounds.height ? max(10, currentRect.minY - textSize.height - 12) : currentRect.maxY + 8,
                width: textSize.width + 16,
                height: textSize.height + 8
            )
            let bgPath = NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4)
            NSColor.black.withAlphaComponent(0.75).set()
            bgPath.fill()
            attrStr.draw(at: NSPoint(x: textRect.minX + 8, y: textRect.minY + 4))
        } else {
            let text = "Click and drag to select recording area • Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let textSize = attrStr.size()
            let textRect = NSRect(
                x: (bounds.width - textSize.width) / 2 - 10,
                y: (bounds.height - textSize.height) / 2 - 5,
                width: textSize.width + 20,
                height: textSize.height + 10
            )
            let bgPath = NSBezierPath(roundedRect: textRect, xRadius: 6, yRadius: 6)
            NSColor.black.withAlphaComponent(0.75).set()
            bgPath.fill()
            attrStr.draw(at: NSPoint(x: textRect.minX + 10, y: textRect.minY + 5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = abs(currentPoint.x - start.x)
        let dy = abs(currentPoint.y - start.y)
        if dx > 3 || dy > 3 {
            isDragging = true
            currentRect = NSRect(
                x: min(start.x, currentPoint.x),
                y: min(start.y, currentPoint.y),
                width: dx,
                height: dy
            )
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            if currentRect.width > 5 && currentRect.height > 5 {
                onSelectionComplete?(currentRect)
            }
        } else {
            if currentRect.width > 5 && currentRect.height > 5 {
                onSelectionComplete?(currentRect)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return / Enter or Space
            if currentRect.width > 5 && currentRect.height > 5 {
                onSelectionComplete?(currentRect)
            }
        } else if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

class LastAreaPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    init(screen: NSScreen, rect: NSRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false

        let previewView = LastAreaPreviewView(frame: NSRect(origin: .zero, size: screen.frame.size), targetRect: rect)
        self.contentView = previewView
    }

    func startPulseAndDismiss() {
        self.alphaValue = 0.0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.animator().alphaValue = 1.0
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.35
                    self?.animator().alphaValue = 0.0
                }) {
                    self?.close()
                }
            }
        }
    }
}

class LastAreaPreviewView: NSView {
    let targetRect: NSRect

    init(frame: NSRect, targetRect: NSRect) {
        self.targetRect = targetRect
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard targetRect != .zero else { return }

        // Subtle dim background outside targetRect
        NSColor.black.withAlphaComponent(0.28).set()
        dirtyRect.fill()

        NSColor.clear.set()
        targetRect.fill(using: .sourceOut)

        // Accent outline with smooth rounded stroke
        NSColor.systemBlue.withAlphaComponent(0.90).setStroke()
        let path = NSBezierPath(roundedRect: targetRect, xRadius: 4, yRadius: 4)
        path.lineWidth = 2.5
        path.stroke()

        // Badge
        let w = Int(targetRect.width)
        let h = Int(targetRect.height)
        let text = "🎯 Last Selected Area: \(w) × \(h) px"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let textRect = NSRect(
            x: max(10, min(bounds.width - textSize.width - 20, targetRect.midX - textSize.width / 2)),
            y: targetRect.maxY + 8 + textSize.height > bounds.height ? max(10, targetRect.minY - textSize.height - 12) : targetRect.maxY + 8,
            width: textSize.width + 16,
            height: textSize.height + 8
        )
        let bgPath = NSBezierPath(roundedRect: textRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.85).set()
        bgPath.fill()
        attrStr.draw(at: NSPoint(x: textRect.minX + 8, y: textRect.minY + 4))
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
    var tapFeedbackWindowIDs: [Int] = []
    var statusItemWindowID: Int?
    var statusItemFrame: CGRect?
    
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
            
            var windowsToExclude = [SCWindow]()
            let myProcessId = ProcessInfo.processInfo.processIdentifier

            for window in content.windows where window.owningApplication?.processID == myProcessId {
                if let camWinID = self.cameraWindowID, window.windowID == CGWindowID(camWinID) { continue }
                if let cursorWinID = self.cursorWindowID, window.windowID == CGWindowID(cursorWinID) { continue }
                if self.tapFeedbackWindowIDs.contains(Int(window.windowID)) { continue }
                windowsToExclude.append(window)
            }

            if let frame = self.statusItemFrame {
                if let controlCenter = content.applications.first(where: { $0.bundleIdentifier == "com.apple.controlcenter" }) {
                    for window in content.windows where window.owningApplication?.processID == controlCenter.processID {
                        if abs(window.frame.minX - frame.minX) < 2.0 && abs(window.frame.width - frame.width) < 2.0 {
                            windowsToExclude.append(window)
                        }
                    }
                }
            }

            if let app = self.captureApp {
                guard let display = content.displays.first else {
                    DispatchQueue.main.async { self.onError?(NSError(domain: "RecorderError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for app"])) }
                    return
                }
                targetDisplay = display
                var appsToInclude = [app]
                if let myApp = content.applications.first(where: { $0.processID == myProcessId }) {
                    appsToInclude.append(myApp)
                }
                filter = SCContentFilter(display: display, including: appsToInclude, exceptingWindows: windowsToExclude)
            } else {
                if let sID = self.targetScreenID {
                    targetDisplay = content.displays.first { $0.displayID == sID } ?? content.displays.first!
                } else {
                    targetDisplay = content.displays.first!
                }
                filter = SCContentFilter(display: targetDisplay, excludingWindows: windowsToExclude)
            }

            self.continueStartingRecording(filter: filter, display: targetDisplay)
        }
    }

    func updateStreamFilter() {
        guard let stream = stream, isRecording else { return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let content = content else { return }
            var windowsToExclude = [SCWindow]()
            let myProcessId = ProcessInfo.processInfo.processIdentifier

            for window in content.windows where window.owningApplication?.processID == myProcessId {
                if let camWinID = self.cameraWindowID, window.windowID == CGWindowID(camWinID) { continue }
                if let cursorWinID = self.cursorWindowID, window.windowID == CGWindowID(cursorWinID) { continue }
                if self.tapFeedbackWindowIDs.contains(Int(window.windowID)) { continue }
                windowsToExclude.append(window)
            }

            if let frame = self.statusItemFrame {
                if let controlCenter = content.applications.first(where: { $0.bundleIdentifier == "com.apple.controlcenter" }) {
                    for window in content.windows where window.owningApplication?.processID == controlCenter.processID {
                        if abs(window.frame.minX - frame.minX) < 2.0 && abs(window.frame.width - frame.width) < 2.0 {
                            windowsToExclude.append(window)
                        }
                    }
                }
            }
            
            let filter: SCContentFilter
            if let app = self.captureApp {
                let targetDisplay = content.displays.first { $0.displayID == self.targetScreenID } ?? content.displays.first!
                var appsToInclude = [app]
                if let myApp = content.applications.first(where: { $0.processID == myProcessId }) {
                    appsToInclude.append(myApp)
                }
                filter = SCContentFilter(display: targetDisplay, including: appsToInclude, exceptingWindows: windowsToExclude)
            } else {
                let targetDisplay = content.displays.first { $0.displayID == self.targetScreenID } ?? content.displays.first!
                filter = SCContentFilter(display: targetDisplay, excludingWindows: windowsToExclude)
            }
            
            stream.updateContentFilter(filter) { error in
                if let error = error {
                    os_log("Failed to update content filter: %{public}@", log: log, type: .error, error.localizedDescription)
                }
            }
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
        } else if currentSettings.resolution == 480 {
            let ratio = CGFloat(baseWidth) / CGFloat(baseHeight)
            config.width = 854
            config.height = Int(854 / ratio)
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

        // Disable ScreenCaptureKit native click circles (replaced with custom TapFeedbackWindow)
        if config.responds(to: NSSelectorFromString("setShowsClicks:")) {
            config.setValue(false, forKey: "showsClicks")
        }
        if config.responds(to: NSSelectorFromString("setCapturesMouseClicks:")) {
            config.setValue(false, forKey: "capturesMouseClicks")
        }
        if config.responds(to: NSSelectorFromString("setShowMouseClicks:")) {
            config.setValue(false, forKey: "showMouseClicks")
        }
        if config.responds(to: NSSelectorFromString("setShowsMouseClicks:")) {
            config.setValue(false, forKey: "showsMouseClicks")
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
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(adjustedBuffer) else { return }
            maskStatusItem(pixelBuffer: pixelBuffer)
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData { videoInput.append(adjustedBuffer) }
        } else if type == .audio {
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData { audioInput.append(adjustedBuffer) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        os_log("Stream Stopped Error: %{public}@", log: log, type: .error, error.localizedDescription)
        DispatchQueue.main.async { self.onError?(error); self.stopRecording() }
    }

    private func maskStatusItem(pixelBuffer: CVPixelBuffer) {
        guard let statusFrame = statusItemFrame, statusFrame != .zero else { return }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0)) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        guard let mainScreen = NSScreen.main else { return }
        let screenBounds = mainScreen.frame
        let scale = targetScaleFactor
        
        let pxX = max(0, Int(statusFrame.origin.x * scale))
        let pxWidth = min(width - pxX, Int(statusFrame.size.width * scale))
        
        let topYInPoints = screenBounds.height - (statusFrame.origin.y + statusFrame.size.height)
        let pxY = max(0, Int(topYInPoints * scale))
        let pxHeight = min(height - pxY, Int(statusFrame.size.height * scale))
        
        guard pxWidth > 0, pxHeight > 0, pxX + pxWidth <= width, pxY + pxHeight <= height else { return }
        
        let sampleX = max(0, pxX - 6)
        let sampleY = pxY + pxHeight / 2
        let samplePixelPtr = baseAddress.advanced(by: sampleY * bytesPerRow + sampleX * 4).assumingMemoryBound(to: UInt32.self)
        let sampleColor = samplePixelPtr.pointee
        
        let pixelPtr = baseAddress.assumingMemoryBound(to: UInt32.self)
        let stride32 = bytesPerRow / 4
        for y in pxY..<(pxY + pxHeight) {
            let rowOffset = y * stride32
            for x in pxX..<(pxX + pxWidth) {
                pixelPtr[rowOffset + x] = sampleColor
            }
        }
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
        self.isOpaque = false
        self.hasShadow = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        if #available(macOS 10.15, *) {
            visualEffectView.layer?.cornerCurve = .continuous
        }
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.12)
        }).cgColor
        self.contentView = visualEffectView
    }
}

// ============================================================
// Interactive Hover Controls for Floating Toolbar
// ============================================================
// MARK: - Hover PopUp & Icon Buttons (HUD Style)
// ============================================================

class HoverIconButton: NSButton {
    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if bounds.contains(localPoint) && !isHidden && alphaValue > 0 {
            return self
        }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 7
    }
}

class HoverPopUpButton: NSPopUpButton {
    override var mouseDownCanMoveWindow: Bool {
        return false
    }
    private var trackingAreaObj: NSTrackingArea?
    private let iconImageView = NSImageView()
    private let arrowImageView = NSImageView()

    override init(frame frameRect: NSRect, pullsDown flag: Bool) {
        super.init(frame: frameRect, pullsDown: flag)
        setupViews()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, pullsDown: true)
        setupViews()
    }

    convenience init() {
        self.init(frame: .zero, pullsDown: true)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        title = ""
        isBordered = false
        imagePosition = .noImage
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = .labelColor
        iconImageView.wantsLayer = true

        arrowImageView.translatesAutoresizingMaskIntoConstraints = false
        arrowImageView.imageScaling = .scaleProportionallyDown
        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 5.0, weight: .bold)
        arrowImageView.image = NSImage(systemSymbolName: "arrowtriangle.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(arrowConfig)
        arrowImageView.contentTintColor = .secondaryLabelColor
        arrowImageView.alphaValue = 0.65
        arrowImageView.wantsLayer = true

        addSubview(iconImageView)
        addSubview(arrowImageView)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 17),
            iconImageView.heightAnchor.constraint(equalToConstant: 17),

            arrowImageView.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 3),
            arrowImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            arrowImageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            arrowImageView.widthAnchor.constraint(equalToConstant: 6),
            arrowImageView.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        // Suppress NSPopUpButtonCell default text & icon drawing to eliminate duplicate/ghosted rendering
    }

    func setMainIcon(_ image: NSImage?, tint: NSColor? = nil) {
        iconImageView.image = image
        iconImageView.contentTintColor = tint ?? .labelColor
    }

    func setIconTintColor(_ tint: NSColor) {
        iconImageView.contentTintColor = tint
    }

    func setArrowTintColor(_ tint: NSColor) {
        arrowImageView.contentTintColor = tint
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaObj { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaObj = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        arrowImageView.animator().alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        arrowImageView.animator().alphaValue = 0.6
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if bounds.contains(localPoint) && !isHidden && alphaValue > 0 {
            return self
        }
        return nil
    }
}

class HoverRecordButton: NSButton {
    private var trackingAreaObj: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaObj { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaObj = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.layer?.shadowColor = NSColor.systemRed.cgColor
            self.layer?.shadowOpacity = 0.85
            self.layer?.shadowRadius = 8
            self.layer?.shadowOffset = .zero
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.layer?.shadowOpacity = 0.0
        }
    }
}

// ============================================================
// Native Interactive Video Trim Range Slider (QuickTime style)
// ============================================================

class TrimRangeSliderView: NSView {
    var duration: Double = 1.0 {
        didSet { needsDisplay = true }
    }
    var startTime: Double = 0.0 {
        didSet { needsDisplay = true }
    }
    var endTime: Double = 1.0 {
        didSet { needsDisplay = true }
    }
    var currentTime: Double = 0.0 {
        didSet { needsDisplay = true }
    }

    var onTrimChanged: ((Double, Double) -> Void)?
    var onSeek: ((Double, Bool) -> Void)?

    private enum DragTarget { case none, startHandle, endHandle, playhead }
    private var currentDrag: DragTarget = .none
    private let handleWidth: CGFloat = 16.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    private func xForTime(_ t: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        let clamped = max(0, min(duration, t))
        let trackWidth = bounds.width - (handleWidth * 2)
        return handleWidth + CGFloat(clamped / duration) * trackWidth
    }

    private func timeForX(_ x: CGFloat) -> Double {
        let trackWidth = bounds.width - (handleWidth * 2)
        guard trackWidth > 0 else { return 0 }
        let relX = max(0, min(trackWidth, x - handleWidth))
        return (Double(relX) / Double(trackWidth)) * duration
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let b = bounds
        // Background track
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(b)

        let startX = xForTime(startTime) - handleWidth
        let endX = xForTime(endTime) + handleWidth
        let selWidth = max(handleWidth * 2, endX - startX)
        let selRect = NSRect(x: startX, y: 0, width: selWidth, height: b.height)

        // Yellow selection highlight (QuickTime style)
        let yellowColor = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.0, alpha: 1.0)
        ctx.setFillColor(yellowColor.withAlphaComponent(0.22).cgColor)
        ctx.fill(selRect)

        // Top & bottom border lines for trim box
        ctx.setStrokeColor(yellowColor.cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(NSRect(x: startX, y: 1, width: selWidth, height: b.height - 2))

        // Left Handle (Start)
        let leftHandleRect = NSRect(x: startX, y: 0, width: handleWidth, height: b.height)
        ctx.setFillColor(yellowColor.cgColor)
        let leftPath = CGPath(roundedRect: leftHandleRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(leftPath)
        ctx.fillPath()

        // Left handle grip notch
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        let notchH: CGFloat = 12
        ctx.fill(NSRect(x: leftHandleRect.midX - 1, y: (b.height - notchH) / 2, width: 2, height: notchH))

        // Right Handle (End)
        let rightHandleRect = NSRect(x: endX - handleWidth, y: 0, width: handleWidth, height: b.height)
        ctx.setFillColor(yellowColor.cgColor)
        let rightPath = CGPath(roundedRect: rightHandleRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(rightPath)
        ctx.fillPath()

        // Right handle grip notch
        ctx.fill(NSRect(x: rightHandleRect.midX - 1, y: (b.height - notchH) / 2, width: 2, height: notchH))

        // Current Playhead Needle (always visible anywhere along timeline)
        let playheadX = xForTime(currentTime)
        if playheadX >= 0 && playheadX <= b.width {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(NSRect(x: playheadX - 1, y: 0, width: 2, height: b.height))
            ctx.fillEllipse(in: NSRect(x: playheadX - 4, y: b.height - 6, width: 8, height: 6))
        }
    }

    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let startX = xForTime(startTime)
        let endX = xForTime(endTime)

        if abs(loc.x - (startX - handleWidth / 2)) <= handleWidth + 10 {
            currentDrag = .startHandle
        } else if abs(loc.x - (endX + handleWidth / 2)) <= handleWidth + 10 {
            currentDrag = .endHandle
        } else {
            currentDrag = .playhead
            let t = timeForX(loc.x)
            currentTime = t
            needsDisplay = true
            onSeek?(t, true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let t = timeForX(loc.x)

        switch currentDrag {
        case .startHandle:
            startTime = max(0, min(endTime - 0.2, t))
            currentTime = startTime
            onTrimChanged?(startTime, endTime)
            onSeek?(startTime, false)
        case .endHandle:
            endTime = min(duration, max(startTime + 0.2, t))
            currentTime = endTime
            onTrimChanged?(startTime, endTime)
            onSeek?(endTime, false)
        case .playhead:
            currentTime = max(0, min(duration, t))
            onSeek?(currentTime, false)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if currentDrag != .none {
            let t = currentTime
            onSeek?(t, true)
            currentDrag = .none
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let startX = xForTime(startTime) - handleWidth
        let endX = xForTime(endTime) + handleWidth
        addCursorRect(NSRect(x: startX - 6, y: 0, width: handleWidth + 12, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: endX - handleWidth - 6, y: 0, width: handleWidth + 12, height: bounds.height), cursor: .resizeLeftRight)
    }
}

// ============================================================
// Native In-App Video Trimmer Window
// ============================================================

class VideoTrimmerWindow: NSWindow {
    let fileURL: URL
    var player: AVPlayer?
    var playerView: AVPlayerView!
    var trimSlider: TrimRangeSliderView!
    var totalDuration: Double = 0
    var trimStartSeconds: Double = 0
    var trimEndSeconds: Double = 0
    var timeObserverToken: Any?
    private var isSeeking = false
    private var pendingSeek: (time: CMTime, exact: Bool)?
    var onTrimCompleted: ((URL) -> Void)?
    
    var startTimeLabel: NSTextField!
    var endTimeLabel: NSTextField!
    var durationLabel: NSTextField!
    var exportStatusLabel: NSTextField!
    var playSelectionBtn: NSButton!
    var muteButton: NSButton!
    var trimButton: NSButton!
    var progressIndicator: NSProgressIndicator!
    var isPlayingSelection: Bool = false
    var isAudioMuted: Bool = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        let rect = NSRect(x: 0, y: 0, width: 720, height: 530)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)

        self.isReleasedWhenClosed = false
        self.titlebarAppearsTransparent = true
        self.title = "Edit Video — \(fileURL.lastPathComponent)"
        self.titleVisibility = .visible
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.center()
        self.level = .floating
        self.minSize = NSSize(width: 580, height: 440)

        let visualEffectView = NSVisualEffectView(frame: rect)
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.2)
                : NSColor.black.withAlphaComponent(0.12)
        }).cgColor
        self.contentView = visualEffectView

        setupUI(in: visualEffectView)
        loadAsset()
    }

    private func setupUI(in container: NSView) {
        // AVPlayerView
        playerView = AVPlayerView()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.showsSharingServiceButton = false
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 10
        playerView.layer?.masksToBounds = true
        playerView.layer?.borderWidth = 1.0
        playerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Interactive Visual Trim Slider
        trimSlider = TrimRangeSliderView()
        trimSlider.translatesAutoresizingMaskIntoConstraints = false
        trimSlider.onTrimChanged = { [weak self] start, end in
            guard let self = self else { return }
            self.trimStartSeconds = start
            self.trimEndSeconds = end
            self.stopSelectionPlaybackIfNeeded()
            self.updateLabels()
        }
        trimSlider.onSeek = { [weak self] time, exact in
            guard let self = self else { return }
            self.stopSelectionPlaybackIfNeeded()
            let cm = CMTime(seconds: time, preferredTimescale: 600)
            self.smoothSeek(to: cm, exact: exact)
        }

        // Left Controls (Start)
        let setStartBtn = NSButton(title: "Set Start", target: self, action: #selector(setStartToCurrent))
        setStartBtn.bezelStyle = .rounded
        setStartBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        setStartBtn.translatesAutoresizingMaskIntoConstraints = false
        setStartBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true

        startTimeLabel = NSTextField(labelWithString: "Start: 00:00.0")
        startTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        startTimeLabel.textColor = .labelColor
        startTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [setStartBtn, startTimeLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        // Center Duration (Dead-centered with high-contrast emerald/forest green)
        durationLabel = NSTextField(labelWithString: "Selected: 00:00.0")
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
        durationLabel.textColor = NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.22, green: 0.90, blue: 0.44, alpha: 1.0)
                : NSColor(red: 0.08, green: 0.56, blue: 0.20, alpha: 1.0)
        })
        durationLabel.alignment = .center
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        // Right Controls (End)
        endTimeLabel = NSTextField(labelWithString: "End: 00:00.0")
        endTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        endTimeLabel.textColor = .labelColor
        endTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        let setEndBtn = NSButton(title: "Set End", target: self, action: #selector(setEndToCurrent))
        setEndBtn.bezelStyle = .rounded
        setEndBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        setEndBtn.translatesAutoresizingMaskIntoConstraints = false
        setEndBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let rightStack = NSStackView(views: [endTimeLabel, setEndBtn])
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        // Bottom Action Bar
        playSelectionBtn = NSButton()
        playSelectionBtn.bezelStyle = .rounded
        playSelectionBtn.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        playSelectionBtn.title = "Play Selection"
        playSelectionBtn.target = self
        playSelectionBtn.action = #selector(togglePlaySelection)
        playSelectionBtn.translatesAutoresizingMaskIntoConstraints = false
        playSelectionBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetTrim))
        resetBtn.bezelStyle = .rounded
        resetBtn.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        muteButton = NSButton()
        muteButton.bezelStyle = .rounded
        muteButton.title = " Mute Audio"
        muteButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let muteSymConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute Audio")?.withSymbolConfiguration(muteSymConfig)
        muteButton.imagePosition = .imageLeading
        muteButton.imageHugsTitle = true
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        exportStatusLabel = NSTextField(labelWithString: "")
        exportStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        exportStatusLabel.textColor = .secondaryLabelColor
        exportStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        trimButton = NSButton()
        trimButton.bezelStyle = .rounded
        trimButton.title = "Save Edited Video"
        trimButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        trimButton.keyEquivalent = "\r"
        trimButton.target = self
        trimButton.action = #selector(performTrim)
        trimButton.translatesAutoresizingMaskIntoConstraints = false
        trimButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let bottomStack = NSStackView(views: [playSelectionBtn, resetBtn, muteButton, progressIndicator, exportStatusLabel, NSView(), trimButton])
        bottomStack.orientation = .horizontal
        bottomStack.alignment = .centerY
        bottomStack.spacing = 10
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(playerView)
        container.addSubview(trimSlider)
        container.addSubview(leftStack)
        container.addSubview(durationLabel)
        container.addSubview(rightStack)
        container.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            trimSlider.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 12),
            trimSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            trimSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            trimSlider.heightAnchor.constraint(equalToConstant: 36),

            leftStack.topAnchor.constraint(equalTo: trimSlider.bottomAnchor, constant: 10),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            rightStack.topAnchor.constraint(equalTo: trimSlider.bottomAnchor, constant: 10),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            durationLabel.centerYAnchor.constraint(equalTo: leftStack.centerYAnchor),
            durationLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            bottomStack.topAnchor.constraint(equalTo: leftStack.bottomAnchor, constant: 12),
            bottomStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            bottomStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    private func smoothSeek(to time: CMTime, exact: Bool) {
        if isSeeking {
            pendingSeek = (time, exact)
            return
        }
        isSeeking = true
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.02, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            guard let self = self else { return }
            self.isSeeking = false
            if let next = self.pendingSeek {
                self.pendingSeek = nil
                self.smoothSeek(to: next.time, exact: next.exact)
            }
        }
    }

    private func loadAsset() {
        let asset = AVURLAsset(url: fileURL)
        let playerItem = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: playerItem)
        p.isMuted = self.isAudioMuted
        self.player = p
        self.playerView.player = p

        // Observe playback time at ultra-smooth 60 FPS (1/60s)
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let sec = CMTimeGetSeconds(time)
            self.trimSlider.currentTime = sec

            if self.isPlayingSelection && sec >= self.trimEndSeconds {
                self.player?.pause()
                self.isPlayingSelection = false
                self.updatePlaySelectionButton()
                let startCM = CMTime(seconds: self.trimStartSeconds, preferredTimescale: 600)
                self.player?.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        Task {
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                await MainActor.run {
                    self.totalDuration = seconds > 0 ? seconds : 1.0
                    self.trimStartSeconds = 0.0
                    self.trimEndSeconds = self.totalDuration
                    self.trimSlider.duration = self.totalDuration
                    self.trimSlider.startTime = 0.0
                    self.trimSlider.endTime = self.totalDuration
                    self.updateLabels()
                }
            }
        }
    }

    private func stopSelectionPlaybackIfNeeded() {
        if isPlayingSelection {
            player?.pause()
            isPlayingSelection = false
            updatePlaySelectionButton()
        }
    }

    @objc private func togglePlaySelection() {
        guard let p = player else { return }
        if isPlayingSelection {
            p.pause()
            isPlayingSelection = false
            updatePlaySelectionButton()
        } else {
            let startCM = CMTime(seconds: trimStartSeconds, preferredTimescale: 600)
            p.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else { return }
                self.player?.play()
                self.isPlayingSelection = true
                self.updatePlaySelectionButton()
            }
        }
    }

    private func updatePlaySelectionButton() {
        playSelectionBtn.title = isPlayingSelection ? "Pause Preview" : "Play Selection"
    }

    @objc private func toggleMute() {
        isAudioMuted = !isAudioMuted
        player?.isMuted = isAudioMuted
        updateMuteButton()
    }

    private func updateMuteButton() {
        let symName = isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let title = isAudioMuted ? " Unmute Audio" : " Mute Audio"
        let symConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        muteButton.image = NSImage(systemSymbolName: symName, accessibilityDescription: "Mute")?.withSymbolConfiguration(symConfig)
        muteButton.title = title
        muteButton.contentTintColor = isAudioMuted ? .systemOrange : nil
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let tenths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", mins, secs, tenths)
    }

    private func updateLabels() {
        startTimeLabel.stringValue = "Start: \(formatTime(trimStartSeconds))"
        endTimeLabel.stringValue = "End: \(formatTime(trimEndSeconds))"
        let dur = max(0, trimEndSeconds - trimStartSeconds)
        durationLabel.stringValue = "Selected: \(formatTime(dur))"
    }

    @objc private func setStartToCurrent() {
        guard let p = player else { return }
        stopSelectionPlaybackIfNeeded()
        let current = CMTimeGetSeconds(p.currentTime())
        if current < trimEndSeconds {
            trimStartSeconds = max(0, current)
            trimSlider.startTime = trimStartSeconds
            updateLabels()
        }
    }

    @objc private func setEndToCurrent() {
        guard let p = player else { return }
        stopSelectionPlaybackIfNeeded()
        let current = CMTimeGetSeconds(p.currentTime())
        if current > trimStartSeconds {
            trimEndSeconds = min(totalDuration, current)
            trimSlider.endTime = trimEndSeconds
            updateLabels()
        }
    }

    @objc private func resetTrim() {
        stopSelectionPlaybackIfNeeded()
        trimStartSeconds = 0.0
        trimEndSeconds = totalDuration
        trimSlider.startTime = 0.0
        trimSlider.endTime = totalDuration
        updateLabels()
        player?.seek(to: .zero)
    }

    @objc private func performTrim() {
        trimButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        exportStatusLabel.stringValue = "Editing video..."

        let asset = AVURLAsset(url: fileURL)
        let startCM = CMTime(seconds: trimStartSeconds, preferredTimescale: 600)
        let endCM = CMTime(seconds: trimEndSeconds, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startCM, duration: CMTimeSubtract(endCM, startCM))

        let ext = fileURL.pathExtension
        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent(".temp_trim_\(UUID().uuidString).\(ext)")

        // Remove if existing
        try? FileManager.default.removeItem(at: tempURL)

        Task {
            let exportAsset: AVAsset
            let exportPreset: String

            if self.isAudioMuted {
                let comp = AVMutableComposition()
                let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                if let assetVideoTrack = tracks.first,
                   let compVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? compVideoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: .zero)
                    if let transform = try? await assetVideoTrack.load(.preferredTransform) {
                        compVideoTrack.preferredTransform = transform
                    }
                }
                exportAsset = comp
                exportPreset = AVAssetExportPresetHighestQuality
            } else {
                exportAsset = asset
                exportPreset = AVAssetExportPresetPassthrough
            }

            guard let exportSession = AVAssetExportSession(asset: exportAsset, presetName: exportPreset) else {
                await MainActor.run {
                    self.exportStatusLabel.stringValue = "Export failed."
                    self.progressIndicator.stopAnimation(nil)
                    self.trimButton.isEnabled = true
                }
                return
            }

            exportSession.outputURL = tempURL
            exportSession.outputFileType = self.fileURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
            if !self.isAudioMuted {
                exportSession.timeRange = timeRange
            }

            exportSession.exportAsynchronously { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.progressIndicator.stopAnimation(nil)
                    self.trimButton.isEnabled = true

                    if exportSession.status == .completed {
                        // Release player reference so file is not locked
                        self.player?.pause()
                        self.player?.replaceCurrentItem(with: nil)
                        self.player = nil

                        // Replace original file in-place with the trimmed video
                        do {
                            _ = try FileManager.default.replaceItemAt(self.fileURL, withItemAt: tempURL)
                        } catch {
                            try? FileManager.default.removeItem(at: self.fileURL)
                            try? FileManager.default.moveItem(at: tempURL, to: self.fileURL)
                        }

                        self.exportStatusLabel.stringValue = "Edit saved!"
                        self.onTrimCompleted?(self.fileURL)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            self.closeWindow()
                        }
                    } else {
                        try? FileManager.default.removeItem(at: tempURL)
                        self.exportStatusLabel.stringValue = "Export error: \(exportSession.error?.localizedDescription ?? "Unknown")"
                    }
                }
            }
        }
    }

    @objc private func closeWindow() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        self.orderOut(nil)
        self.close()
    }
}

// ============================================================
// Post-Recording HUD Toast Window (Bottom-Right Floating Notification)
// ============================================================

class RecordingToastWindow: NSWindow {
    var fileURL: URL
    var onDismiss: (() -> Void)?
    var autoDismissTimer: Timer?
    var trimmerWindow: VideoTrimmerWindow?

    var thumbnailView: NSImageView!
    var titleLabel: NSTextField!
    var fileNameLabel: NSTextField!
    var metaLabel: NSTextField!
    var isHovered: Bool = false

    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let toastWidth: CGFloat = 330
        let toastHeight: CGFloat = 80

        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSPointInRect(mouseLoc, $0.frame) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let marginX: CGFloat = 24
        let marginY: CGFloat = 24
        let targetX = visibleFrame.maxX - toastWidth - marginX
        let targetY = visibleFrame.minY + marginY
        let initialRect = NSRect(
            x: targetX,
            y: targetY,
            width: toastWidth,
            height: toastHeight
        )

        super.init(contentRect: initialRect, styleMask: .borderless, backing: .buffered, defer: false)

        self.setFrame(initialRect, display: true)
        self.isReleasedWhenClosed = false
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.appearance = NSAppearance(named: .vibrantDark)

        let visualEffectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialRect.size))
        visualEffectView.appearance = NSAppearance(named: .vibrantDark)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        if #available(macOS 10.15, *) {
            visualEffectView.layer?.cornerCurve = .continuous
        }
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        self.contentView = visualEffectView

        setupUI(in: visualEffectView)
        setupTrackingArea(in: visualEffectView)
        startAutoDismissTimer(seconds: 7.0)
    }

    private func setupUI(in container: NSView) {
        // 1. Thumbnail on left
        thumbnailView = NSImageView()
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 8
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.borderWidth = 1.0
        thumbnailView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown

        let filmConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        thumbnailView.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(filmConfig)
        thumbnailView.contentTintColor = .systemRed

        extractThumbnail()

        // 2. Header text: checkmark + "Recording Saved"
        let checkConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let checkIcon = NSImageView()
        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Saved")?.withSymbolConfiguration(checkConfig)
        checkIcon.contentTintColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0)

        titleLabel = NSTextField(labelWithString: "Recording Saved")
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [checkIcon, titleLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 5
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // 3. File name (Strictly truncated with low compression resistance so it never expands window)
        fileNameLabel = NSTextField(labelWithString: fileURL.lastPathComponent)
        fileNameLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        fileNameLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.cell?.wraps = false
        fileNameLabel.cell?.isScrollable = false
        fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        // 4. Meta + right-click hint
        var sizeStr = "0 MB"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let bytes = attrs[.size] as? Int64 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            sizeStr = String(format: "%.1f MB", mb)
        }
        metaLabel = NSTextField(labelWithString: "\(sizeStr)  •  Right-click for options")
        metaLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        metaLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [headerRow, fileNameLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        // 5. Dismiss button
        let closeBtn = NSButton()
        closeBtn.bezelStyle = .regularSquare
        closeBtn.isBordered = false
        closeBtn.title = ""
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        closeBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?.withSymbolConfiguration(closeConfig)
        closeBtn.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        closeBtn.target = self
        closeBtn.action = #selector(dismissAnimated)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.widthAnchor.constraint(equalToConstant: 18).isActive = true
        closeBtn.heightAnchor.constraint(equalToConstant: 18).isActive = true

        container.addSubview(thumbnailView)
        container.addSubview(textStack)
        container.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            thumbnailView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 78),
            thumbnailView.heightAnchor.constraint(equalToConstant: 56),

            textStack.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -6),

            closeBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8)
        ])
    }

    private func setupTrackingArea(in view: NSView) {
        let trackingArea = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        startAutoDismissTimer(seconds: 4.0)
    }

    override func mouseDown(with event: NSEvent) {
        NSWorkspace.shared.open(fileURL)
        dismissAnimated()
    }

    override func rightMouseDown(with event: NSEvent) {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        let menu = NSMenu()

        func addMenuItem(title: String, symbol: String, action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
            menu.addItem(item)
        }

        addMenuItem(title: "Play Video", symbol: "play.fill", action: #selector(menuPlay))
        addMenuItem(title: "Edit Video...", symbol: "scissors", action: #selector(menuTrim))
        addMenuItem(title: "Copy File", symbol: "doc.on.doc", action: #selector(menuCopy))
        addMenuItem(title: "Share...", symbol: "square.and.arrow.up", action: #selector(menuShare))
        addMenuItem(title: "Rename...", symbol: "pencil", action: #selector(menuRename))
        addMenuItem(title: "Show in Finder", symbol: "folder", action: #selector(menuFinder))
        menu.addItem(NSMenuItem.separator())
        addMenuItem(title: "Open Full Window...", symbol: "macwindow", action: #selector(menuFullModal))
        menu.addItem(NSMenuItem.separator())
        let delItem = NSMenuItem(title: "Move to Trash", action: #selector(menuDelete), keyEquivalent: "")
        delItem.target = self
        let delCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        delItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")?.withSymbolConfiguration(delCfg)
        menu.addItem(delItem)

        let point = event.locationInWindow
        menu.popUp(positioning: nil, at: point, in: self.contentView)
    }

    private func extractThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, fileURL = self.fileURL] in
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 180)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let cgImg = try? generator.copyCGImage(at: time, actualTime: nil) {
                let img = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                DispatchQueue.main.async {
                    self?.thumbnailView.image = img
                    self?.thumbnailView.contentTintColor = nil
                }
            }
        }
    }

    private func startAutoDismissTimer(seconds: Double) {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, !self.isHovered else { return }
            self.dismissAnimated()
        }
    }

    @objc func dismissAnimated() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
            self.close()
            self.onDismiss?()
        })
    }

    // Context Menu Actions
    @objc private func menuPlay() {
        NSWorkspace.shared.open(fileURL)
        dismissAnimated()
    }

    @objc private func menuTrim() {
        let trimmer = VideoTrimmerWindow(fileURL: fileURL)
        trimmer.onTrimCompleted = { [weak self] updatedURL in
            guard let self = self else { return }
            self.fileURL = updatedURL
            self.refreshToast(with: updatedURL)
        }
        self.trimmerWindow = trimmer
        trimmer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func menuCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        metaLabel.stringValue = "✓ Copied to Clipboard!"
        metaLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.metaLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
            self.refreshToast(with: self.fileURL)
        }
    }

    @objc private func menuShare() {
        let picker = NSSharingServicePicker(items: [fileURL])
        if let cv = self.contentView {
            picker.show(relativeTo: cv.bounds, of: cv, preferredEdge: .minY)
        }
    }

    @objc private func menuRename() {
        let alert = NSAlert()
        alert.messageText = "Rename Recording"
        alert.informativeText = "Enter a new name for this video:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = fileURL.deletingPathExtension().lastPathComponent
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            var rawName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else { return }
            rawName = rawName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let ext = fileURL.pathExtension
            let fullName = rawName.hasSuffix(".\(ext)") ? rawName : "\(rawName).\(ext)"
            let newURL = fileURL.deletingLastPathComponent().appendingPathComponent(fullName)

            if newURL.path != fileURL.path {
                do {
                    try FileManager.default.moveItem(at: fileURL, to: newURL)
                    self.fileURL = newURL
                    refreshToast(with: newURL)
                } catch {
                    // keep original
                }
            }
        }
    }

    @objc private func menuFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func menuFullModal() {
        let fullWin = RecordingFinishedWindow(fileURL: fileURL)
        fullWin.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dismissAnimated()
    }

    @objc private func menuDelete() {
        let alert = NSAlert()
        alert.messageText = "Move Recording to Trash?"
        alert.informativeText = "Are you sure you want to delete \(fileURL.lastPathComponent)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            dismissAnimated()
        }
    }

    func refreshToast(with url: URL) {
        fileNameLabel.stringValue = url.lastPathComponent
        var sizeStr = "0 MB"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            sizeStr = String(format: "%.1f MB", mb)
        }
        metaLabel.stringValue = "\(sizeStr)  •  Right-click for options"
        extractThumbnail()
    }
}

// ============================================================
// Post-Recording Action Window (Play, Edit/Trim, Share, Finder, Delete)
// ============================================================

class RecordingFinishedWindow: NSWindow {
    var fileURL: URL
    var onDismiss: (() -> Void)?
    var trimmerWindow: VideoTrimmerWindow?

    var thumbnailView: NSImageView!
    var fileNameLabel: NSTextField!
    var metaLabel: NSTextField!
    var locationLabel: NSTextField!

    init(fileURL: URL) {
        self.fileURL = fileURL
        let rect = NSRect(x: 0, y: 0, width: 480, height: 288)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        
        self.isReleasedWhenClosed = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.center()
        self.level = .floating

        let visualEffectView = NSVisualEffectView(frame: rect)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        if #available(macOS 10.15, *) {
            visualEffectView.layer?.cornerCurve = .continuous
        }
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.12)
        }).cgColor
        self.contentView = visualEffectView

        setupUI(in: visualEffectView)
    }

    private func setupUI(in container: NSView) {
        // ---- 1. HEADER SECTION ----
        let checkConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let checkIcon = NSImageView()
        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Saved")?.withSymbolConfiguration(checkConfig)
        checkIcon.contentTintColor = .systemGreen

        let titleLabel = NSTextField(labelWithString: "Recording Saved")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subTitleLabel = NSTextField(labelWithString: "Your video is ready to preview, edit, share, or manage.")
        subTitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subTitleLabel.textColor = .secondaryLabelColor
        subTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerTextStack = NSStackView(views: [titleLabel, subTitleLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 0
        headerTextStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [checkIcon, headerTextStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // ---- 2. PREVIEW CARD BOX ----
        let previewBox = NSBox()
        previewBox.boxType = .custom
        previewBox.borderWidth = 1.0
        previewBox.borderColor = NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.1)
                : NSColor.black.withAlphaComponent(0.08)
        })
        previewBox.fillColor = NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(0.35)
                : NSColor.white.withAlphaComponent(0.6)
        })
        previewBox.cornerRadius = 12
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        thumbnailView = NSImageView()
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 8
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.borderWidth = 1.0
        thumbnailView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown

        let filmConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        thumbnailView.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(filmConfig)
        thumbnailView.contentTintColor = .systemRed

        fileNameLabel = NSTextField(labelWithString: fileURL.lastPathComponent)
        fileNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        fileNameLabel.textColor = .labelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.isSelectable = true
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel = NSTextField(labelWithString: "0 MB  •  QuickTime Video")
        metaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        locationLabel = NSTextField(labelWithString: "Saved to \(fileURL.deletingLastPathComponent().lastPathComponent)")
        locationLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        locationLabel.textColor = .tertiaryLabelColor
        locationLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshPreviewCard(with: fileURL)

        let cardTextStack = NSStackView(views: [fileNameLabel, metaLabel, locationLabel])
        cardTextStack.orientation = .vertical
        cardTextStack.alignment = .leading
        cardTextStack.spacing = 3
        cardTextStack.translatesAutoresizingMaskIntoConstraints = false

        let cardContentStack = NSStackView(views: [thumbnailView, cardTextStack])
        cardContentStack.orientation = .horizontal
        cardContentStack.alignment = .centerY
        cardContentStack.spacing = 14
        cardContentStack.translatesAutoresizingMaskIntoConstraints = false

        previewBox.contentView = cardContentStack

        // ---- 3. ACTION BUTTONS (Top Row: 4 Equal-Width Action Buttons) ----
        func makeActionButton(title: String, symbol: String) -> NSButton {
            let btn = NSButton()
            btn.bezelStyle = .rounded
            btn.title = " \(title)"
            btn.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let symConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(symConfig)
            btn.imagePosition = .imageLeading
            btn.imageHugsTitle = true
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            return btn
        }

        let playBtn = makeActionButton(title: "Play", symbol: "play.fill")
        playBtn.target = self
        playBtn.action = #selector(playClicked)

        let editBtn = makeActionButton(title: "Edit", symbol: "scissors")
        editBtn.target = self
        editBtn.action = #selector(trimClicked)

        let shareBtn = makeActionButton(title: "Share", symbol: "square.and.arrow.up")
        shareBtn.target = self
        shareBtn.action = #selector(shareClicked(_:))

        let finderBtn = makeActionButton(title: "Finder", symbol: "folder")
        finderBtn.target = self
        finderBtn.action = #selector(finderClicked)

        let actionsRow = NSStackView(views: [playBtn, editBtn, shareBtn, finderBtn])
        actionsRow.orientation = .horizontal
        actionsRow.distribution = .fillEqually
        actionsRow.spacing = 8
        actionsRow.translatesAutoresizingMaskIntoConstraints = false

        // ---- 4. FOOTER ROW (Bottom Row: Delete, Copy, Rename under Share, Done) ----
        let deleteBtn = makeActionButton(title: "Delete", symbol: "trash")
        deleteBtn.contentTintColor = .systemRed
        deleteBtn.target = self
        deleteBtn.action = #selector(deleteClicked)

        let copyBtn = makeActionButton(title: "Copy", symbol: "doc.on.doc")
        copyBtn.target = self
        copyBtn.action = #selector(copyClicked(_:))

        let renameBtn = makeActionButton(title: "Rename", symbol: "pencil")
        renameBtn.target = self
        renameBtn.action = #selector(renameClicked)

        let okBtn = NSButton()
        okBtn.bezelStyle = .rounded
        okBtn.title = "Done"
        okBtn.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        okBtn.keyEquivalent = "\r"
        okBtn.target = self
        okBtn.action = #selector(doneClicked)
        okBtn.translatesAutoresizingMaskIntoConstraints = false
        okBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let bottomRow = NSStackView(views: [deleteBtn, copyBtn, renameBtn, okBtn])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 8
        bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerStack)
        container.addSubview(previewBox)
        container.addSubview(actionsRow)
        container.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            checkIcon.widthAnchor.constraint(equalToConstant: 24),
            checkIcon.heightAnchor.constraint(equalToConstant: 24),

            previewBox.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 2),
            previewBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            previewBox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            previewBox.heightAnchor.constraint(equalToConstant: 84),

            cardContentStack.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 10),
            cardContentStack.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -10),
            cardContentStack.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 8),
            cardContentStack.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -8),

            thumbnailView.widthAnchor.constraint(equalToConstant: 92),
            thumbnailView.heightAnchor.constraint(equalToConstant: 64),

            actionsRow.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 18),
            actionsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            actionsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            bottomRow.topAnchor.constraint(equalTo: actionsRow.bottomAnchor, constant: 8),
            bottomRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            bottomRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            bottomRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])
    }

    @objc private func renameClicked() {
        let alert = NSAlert()
        alert.messageText = "Rename Recording"
        alert.informativeText = "Enter a new name for this video:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = fileURL.deletingPathExtension().lastPathComponent
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            var rawName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else { return }
            rawName = rawName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let ext = fileURL.pathExtension
            let fullName = rawName.hasSuffix(".\(ext)") ? rawName : "\(rawName).\(ext)"
            let newURL = fileURL.deletingLastPathComponent().appendingPathComponent(fullName)

            if newURL.path != fileURL.path {
                do {
                    try FileManager.default.moveItem(at: fileURL, to: newURL)
                    self.fileURL = newURL
                    refreshPreviewCard(with: newURL)
                } catch {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Failed to Rename"
                    errAlert.informativeText = error.localizedDescription
                    errAlert.alertStyle = .warning
                    errAlert.runModal()
                }
            }
        }
    }

    func refreshPreviewCard(with url: URL) {
        fileNameLabel.stringValue = url.lastPathComponent
        locationLabel.stringValue = "Saved to \(url.deletingLastPathComponent().lastPathComponent)"

        var sizeStr = "0 MB"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            sizeStr = String(format: "%.1f MB", mb)
        }
        metaLabel.stringValue = "\(sizeStr)  •  QuickTime Video"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 240)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let cgImg = try? generator.copyCGImage(at: time, actualTime: nil) {
                let img = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                DispatchQueue.main.async {
                    self?.thumbnailView.image = img
                    self?.thumbnailView.contentTintColor = nil
                }
            }
        }
    }

    @objc private func playClicked() {
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func copyClicked(_ sender: NSButton) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let originalTitle = sender.title
        let originalImage = sender.image
        let symConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        sender.title = " Copied!"
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(symConfig)
        sender.contentTintColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.title = originalTitle
            sender.image = originalImage
            sender.contentTintColor = nil
        }
    }

    @objc private func trimClicked() {
        let trimmer = VideoTrimmerWindow(fileURL: fileURL)
        trimmer.onTrimCompleted = { [weak self] updatedURL in
            guard let self = self else { return }
            self.refreshPreviewCard(with: updatedURL)
        }
        self.trimmerWindow = trimmer
        trimmer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func shareClicked(_ sender: NSButton) {
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func finderClicked() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func deleteClicked() {
        let alert = NSAlert()
        alert.messageText = "Move Recording to Trash?"
        alert.informativeText = "Are you sure you want to delete \(fileURL.lastPathComponent)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            self.orderOut(nil)
            self.close()
        }
    }

    @objc private func doneClicked() {
        self.orderOut(nil)
        self.close()
        onDismiss?()
    }
}

// ============================================================
// Menu Bar Pill View
// ============================================================

class MenuBarPillView: NSView {
    let dotImageView = NSImageView()
    let timeLabel = NSTextField(labelWithString: "00:00")
    let pauseButton = NSButton()
    let stopButton = NSButton()
    
    var onClickPill: (() -> Void)?
    var onRightClickPill: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    private var isPausedState: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor

        let dotConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        dotImageView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Recording")?.withSymbolConfiguration(dotConfig)
        dotImageView.contentTintColor = .systemRed
        dotImageView.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        timeLabel.textColor = .labelColor
        timeLabel.isEditable = false
        timeLabel.isSelectable = false
        timeLabel.isBordered = false
        timeLabel.drawsBackground = false
        timeLabel.alignment = .center
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        pauseButton.isBordered = false
        pauseButton.setButtonType(.momentaryPushIn)
        pauseButton.imagePosition = .imageOnly
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.toolTip = "Pause / Resume Recording"
        pauseButton.translatesAutoresizingMaskIntoConstraints = false

        stopButton.isBordered = false
        stopButton.setButtonType(.momentaryPushIn)
        stopButton.imagePosition = .imageOnly
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop Recording"
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        updatePauseButton(isPaused: false)
        updateStopButton()

        let stack = NSStackView(views: [dotImageView, timeLabel, pauseButton, stopButton])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            dotImageView.widthAnchor.constraint(equalToConstant: 10),
            dotImageView.heightAnchor.constraint(equalToConstant: 10),
            pauseButton.widthAnchor.constraint(equalToConstant: 22),
            pauseButton.heightAnchor.constraint(equalToConstant: 22),
            stopButton.widthAnchor.constraint(equalToConstant: 22),
            stopButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func updatePauseButton(isPaused: Bool) {
        isPausedState = isPaused
        let appearance = effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bgPath = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        let bgColor: NSColor
        if isPaused {
            bgColor = NSColor.systemOrange.withAlphaComponent(0.3)
        } else {
            bgColor = isDark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.14)
        }
        bgColor.setFill()
        bgPath.fill()
        
        let symbolName = isPaused ? "play.fill" : "pause.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        if let sysImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pause/Resume")?.withSymbolConfiguration(config) {
            let iconSize = sysImg.size
            let iconRect = NSRect(
                x: (size.width - iconSize.width) / 2 + (isPaused ? 1 : 0),
                y: (size.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            sysImg.draw(in: iconRect)
            let iconColor: NSColor = isPaused ? .systemOrange : (isDark ? .white : .black)
            iconColor.set()
            iconRect.fill(using: .sourceAtop)
        }
        
        img.unlockFocus()
        img.isTemplate = false
        pauseButton.image = img
        dotImageView.contentTintColor = isPaused ? .systemOrange : .systemRed
    }

    func updateStopButton() {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bgPath = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        NSColor(red: 1.0, green: 59/255.0, blue: 48/255.0, alpha: 1.0).setFill()
        bgPath.fill()
        
        let squareSize: CGFloat = 8
        let squareRect = NSRect(
            x: (size.width - squareSize) / 2,
            y: (size.height - squareSize) / 2,
            width: squareSize,
            height: squareSize
        )
        let squarePath = NSBezierPath(roundedRect: squareRect, xRadius: 1.5, yRadius: 1.5)
        NSColor.white.setFill()
        squarePath.fill()
        
        img.unlockFocus()
        img.isTemplate = false
        stopButton.image = img
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePauseButton(isPaused: isPausedState)
        updateStopButton()
        (NSApp.delegate as? AppDelegate)?.recorder.updateStreamFilter()
    }

    func updateTime(_ timeString: String) {
        if timeLabel.stringValue != timeString {
            timeLabel.stringValue = timeString
        }
    }

    @objc private func pauseClicked() {
        onPause?()
    }

    @objc private func stopClicked() {
        onStop?()
    }

    override func mouseDown(with event: NSEvent) {
        onClickPill?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClickPill?()
    }
}


// ============================================================
// App Delegate — FIXED AUDIO MENU LOGIC
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var recordButton: HoverRecordButton!
    var pauseButton: HoverIconButton!
    var closeButton: HoverIconButton!
    var modePopUp: HoverPopUpButton!
    var audioPopUp: HoverPopUpButton!
    var cameraPopUp: HoverPopUpButton!
    var cameraRecordButton: HoverIconButton!
    var audioRecordIndicator: HoverIconButton!
    var liveTimerStack: NSStackView!
    var liveTimerDot: NSImageView!
    var liveTimerLabel: NSTextField!
    var idleDivider1: NSBox!
    var idleDivider2: NSBox!
    var idleDivider3: NSBox!
    var idleDivider4: NSBox!
    var recDivider1: NSBox!
    var recDivider2: NSBox!
    var settingsPopUp: HoverPopUpButton!
    let recorder = Recorder()

    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var pillView: MenuBarPillView?
    var recordingTimer: Timer?
    var recordingStartTime: Date?
    var pausedAccumulatedTime: TimeInterval = 0
    var pauseStartDate: Date?

    var appSelectionMenu: AppSelectionMenuHandler?
    var aboutWindow: NSWindow?
    var toastWindow: RecordingToastWindow?
    var finishedWindow: RecordingFinishedWindow?
    var permissionsWindow: NSWindow?
    var permissionButtons: [NSButton] = []
    var permissionsTimer: Timer?

    var cameraWindow: CameraOverlayWindow?

    var recordingOverlay: RecordingOverlayWindow?

    var regionSelectionWindows: [RegionSelectionWindow] = []
    var countdownTimer: Timer?
    var highlighterWindow: CursorHighlighterWindow?
    var highlighterTimer: Timer?
    var countdownWindow: CountdownWindow?
    var tapFeedbackWindows: [TapFeedbackWindow] = []
    var globalMouseMonitor: Any?
    var localMouseMonitor: Any?

    // Track menu items for audio popup to manage state easily
    private var audioMainItems: [NSMenuItem] = []
    private var audioMicItems: [NSMenuItem] = []
    private var cameraItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
        setupUI()
        setupRecorder()
        checkPermissions()
        setupCameraIfNeeded()
        
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.recorder.isRecording && currentSettings.showsClicks {
                for win in self.tapFeedbackWindows { win.close() }
                self.tapFeedbackWindows.removeAll()
                for screen in NSScreen.screens {
                    let win = TapFeedbackWindow(screen: screen)
                    win.orderFrontRegardless()
                    self.tapFeedbackWindows.append(win)
                }
                self.recorder.tapFeedbackWindowIDs = self.tapFeedbackWindows.compactMap { $0.windowNumber }
                self.recorder.updateStreamFilter()
            }
        }
        
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.updateButtonImage()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !panel.isVisible {
            showPanel()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func setupCameraIfNeeded() {
        if currentSettings.cameraID != "None" && !currentSettings.cameraID.isEmpty {
            cameraWindow = CameraOverlayWindow()
            cameraWindow?.makeKeyAndOrderFront(nil)
            recorder.cameraWindowID = cameraWindow?.windowNumber
            cameraWindow?.startCamera(deviceID: currentSettings.cameraID)
            updateButtonImage()
        }
    }
    
    @objc func toggleCameraHotkey() {
        if let window = cameraWindow, window.isVisible {
            window.stopCamera()
            window.orderOut(nil)
            cameraWindow = nil
            recorder.cameraWindowID = nil
            currentSettings.cameraID = "None"
            currentSettings.save()
            for item in cameraItems {
                item.state = (item.identifier?.rawValue == "None") ? .on : .off
            }
        } else {
            let devID = (currentSettings.cameraID == "None" || currentSettings.cameraID.isEmpty) ? AVCaptureDevice.default(for: .video)?.uniqueID ?? "" : currentSettings.cameraID
            if !devID.isEmpty && devID != "None" {
                currentSettings.cameraID = devID
                currentSettings.save()
                for item in cameraItems {
                    item.state = (item.identifier?.rawValue == devID) ? .on : .off
                }
                if cameraWindow == nil {
                    cameraWindow = CameraOverlayWindow()
                    recorder.cameraWindowID = cameraWindow?.windowNumber
                }
                cameraWindow?.makeKeyAndOrderFront(nil)
                cameraWindow?.startCamera(deviceID: devID)
            }
        }
        updateButtonImage()
    }

    func checkPermissions() {
        let hasSeenKey = "hasSeenPermissionsGuide_v1"
        let hasSeen = UserDefaults.standard.bool(forKey: hasSeenKey)
        if !hasSeen {
            UserDefaults.standard.set(true, forKey: hasSeenKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showPermissionsGuide(isFirstLaunch: true)
            }
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "RecStatusItem"
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rec")
            img?.isTemplate = true
            button.image = img
        }

        statusMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Rec", action: #selector(showAboutAction), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        statusMenu.addItem(aboutItem)
        
        let permItem = NSMenuItem(title: "Permissions & Settings...", action: #selector(showPermissionsAction), keyEquivalent: "")
        permItem.image = NSImage(systemSymbolName: "hand.raised.square", accessibilityDescription: nil)
        permItem.target = self
        statusMenu.addItem(permItem)

        let update = NSMenuItem(title: "Check for Updates...", action: #selector(manualUpdateCheck), keyEquivalent: "")
        update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        update.target = self
        statusMenu.addItem(update)
        
        statusMenu.addItem(NSMenuItem.separator())

        let showControlsItem = NSMenuItem(title: "Show Controls", action: #selector(showPanel), keyEquivalent: "s")
        showControlsItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        statusMenu.addItem(showControlsItem)

        statusMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Rec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        statusMenu.addItem(quitItem)
        statusItem.menu = statusMenu
        statusItem.isVisible = false
    }

    func updateMenuBarPill() {
        guard let button = statusItem.button else { return }

        if recorder.isRecording {
            statusItem.menu = nil
            let isNewPill = (pillView == nil)
            if pillView == nil {
                let pill = MenuBarPillView()
                pill.alphaValue = 0.0
                pill.onClickPill = { [weak self] in
                    self?.showPanel()
                }
                pill.onRightClickPill = { [weak self] in
                    guard let self = self, let btn = self.statusItem.button else { return }
                    self.statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
                }
                pill.onPause = { [weak self] in
                    self?.togglePause()
                }
                pill.onStop = { [weak self] in
                    self?.toggleRecording()
                }
                pillView = pill
            }

            pillView?.updatePauseButton(isPaused: recorder.isPaused)
            updateRecordingTimeDisplay()

            if pillView?.superview != button {
                button.subviews.forEach { $0.removeFromSuperview() }
                button.image = nil
                button.title = ""
                button.addSubview(pillView!)
                pillView?.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    pillView!.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
                    pillView!.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                    pillView!.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
                    pillView!.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1)
                ])
            }

            pillView?.layoutSubtreeIfNeeded()
            let targetWidth = (pillView?.fittingSize.width ?? 110) + 6

            if isNewPill {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    statusItem.length = targetWidth
                    pillView?.animator().alphaValue = 1.0
                })
            } else {
                statusItem.length = targetWidth
            }
            recorder.updateStreamFilter()
        } else {
            if let pill = pillView {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    pill.animator().alphaValue = 0.0
                    statusItem.length = NSStatusItem.squareLength
                }, completionHandler: { [weak self] in
                    pill.removeFromSuperview()
                    self?.pillView = nil
                    let recImg = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rec")
                    recImg?.isTemplate = true
                    button.image = recImg
                    button.title = ""
                    self?.statusItem.menu = self?.statusMenu
                })
            } else {
                let recImg2 = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rec")
                recImg2?.isTemplate = true
                button.image = recImg2
                button.title = ""
                statusItem.menu = statusMenu
                statusItem.length = NSStatusItem.squareLength
            }
        }
    }

    func updateRecordingTimeDisplay() {
        guard recorder.isRecording else { return }
        var elapsed: TimeInterval = 0
        if let startTime = recordingStartTime {
            if recorder.isPaused, let pauseStart = pauseStartDate {
                elapsed = pauseStart.timeIntervalSince(startTime) - pausedAccumulatedTime
            } else {
                elapsed = Date().timeIntervalSince(startTime) - pausedAccumulatedTime
            }
        }
        if elapsed < 0 { elapsed = 0 }

        let totalSeconds = Int(elapsed)
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600

        let timeString: String
        if hours > 0 {
            timeString = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            timeString = String(format: "%02d:%02d", minutes, seconds)
        }

        pillView?.updateTime(timeString)
        liveTimerLabel?.stringValue = timeString
        
        if let pill = pillView {
            pill.layoutSubtreeIfNeeded()
            let requiredWidth = pill.fittingSize.width + 6
            if abs(statusItem.length - requiredWidth) > 1 {
                statusItem.length = requiredWidth
            }
        }
    }

    @objc func showPanel() {
        statusItem.isVisible = false
        updateButtonImage()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func hidePanel() {
        panel.orderOut(nil)
        statusItem.isVisible = true
    }
    @objc func showAboutAction() { showAbout(onLaunch: false) }
    func showAbout(onLaunch: Bool) {
        if aboutWindow != nil {
            aboutWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        struct RecAboutFeature {
            let symbol: String
            let color: NSColor
            let title: String
            let desc: String
        }

        let features: [RecAboutFeature] = [
            RecAboutFeature(symbol: "record.circle", color: .systemRed, title: "Native Screen Capture", desc: "Records full screen, single windows, or cropped regions with ScreenCaptureKit."),
            RecAboutFeature(symbol: "speaker.wave.3.fill", color: .systemPurple, title: "Internal System Audio", desc: "Direct hardware capture for crystal-clear system audio without loopback drivers."),
            RecAboutFeature(symbol: "scissors", color: .systemIndigo, title: "In-App Video Editor", desc: "Trim recordings with smooth timeline scrubbing, mute audio tracks, and save edits in-place."),
            RecAboutFeature(symbol: "sparkles", color: .systemTeal, title: "HUD Toast & Quick Actions", desc: "Non-intrusive floating toast with 1-click clipboard copy, in-place renaming, and right-click actions."),
            RecAboutFeature(symbol: "bolt.fill", color: .systemOrange, title: "Fast & Lightweight", desc: "Hardware-accelerated Apple Silicon encoding with up to 120 FPS ProMotion capture."),
            RecAboutFeature(symbol: "chevron.left.forwardslash.chevron.right", color: .systemPink, title: "Free & Open Source", desc: "Rec is completely free and open source. Check out the repository on GitHub.")
        ]

        let width: CGFloat = 460
        let textWidth: CGFloat = width - 115
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let textFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

        var featureHeights: [CGFloat] = []
        var totalFeaturesHeight: CGFloat = 0
        for f in features {
            let attr = NSAttributedString(string: f.desc, attributes: [
                .font: textFont,
                .paragraphStyle: para
            ])
            let measured = attr.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = ceil(measured.height) + 24
            featureHeights.append(h)
            totalFeaturesHeight += h + 16
        }
        totalFeaturesHeight -= 16

        let headerHeight: CGFloat = 204
        let bottomSpaceNeeded: CGFloat = 124
        let finalHeight = headerHeight + totalFeaturesHeight + bottomSpaceNeeded

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: finalHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: finalHeight))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        
        let icon = NSImageView(frame: NSRect(x: (width - 64)/2, y: finalHeight - 88, width: 64, height: 64))
        icon.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(icon)

        let title = NSTextField(labelWithString: "Rec")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: finalHeight - 124, width: width, height: 28)
        bg.addSubview(title)

        let ver = NSTextField(labelWithString: "Version \(appVersion)")
        ver.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        ver.textColor = .tertiaryLabelColor
        ver.alignment = .center
        ver.frame = NSRect(x: 0, y: finalHeight - 144, width: width, height: 15)
        bg.addSubview(ver)
        
        let sub = NSTextField(labelWithString: "A clean, native screen and internal audio recorder.")
        sub.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 16, y: finalHeight - 168, width: width - 32, height: 16)
        bg.addSubview(sub)

        var currentY = finalHeight - headerHeight
        for (i, f) in features.enumerated() {
            let itemH = featureHeights[i]
            let itemY = currentY - itemH

            let symSize: CGFloat = 24
            let symView = NSImageView(frame: NSRect(x: 36, y: itemY + (itemH - symSize)/2 + 2, width: symSize, height: symSize))
            let symCfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            symView.image = NSImage(systemSymbolName: f.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symCfg)
            symView.contentTintColor = f.color
            bg.addSubview(symView)

            let hLabel = NSTextField(labelWithString: f.title)
            hLabel.font = titleFont
            hLabel.frame = NSRect(x: 74, y: itemY + itemH - 20, width: textWidth, height: 18)
            bg.addSubview(hLabel)

            let attr = NSAttributedString(string: f.desc, attributes: [
                .font: textFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para
            ])
            let dLabel = NSTextField(labelWithAttributedString: attr)
            dLabel.frame = NSRect(x: 74, y: itemY, width: textWidth, height: itemH - 22)
            dLabel.lineBreakMode = .byWordWrapping
            dLabel.maximumNumberOfLines = 0
            dLabel.isEditable = false
            dLabel.drawsBackground = false
            dLabel.isBordered = false
            bg.addSubview(dLabel)

            currentY = itemY - 16
        }

        // Author Note
        let credit = NSTextField(labelWithString: "Built by Arun Thomas")
        credit.frame = NSRect(x: 0, y: 78, width: width, height: 16)
        credit.alignment = .center
        credit.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        credit.textColor = .secondaryLabelColor
        bg.addSubview(credit)

        // Action Buttons
        let buttonsY: CGFloat = 26
        let contactW: CGFloat = 110
        let gitW: CGFloat = 110
        let spacing: CGFloat = 14
        let totalW = contactW + gitW + spacing
        let startX = (width - totalW) / 2
        
        let contact = NSButton(title: "Contact", target: self, action: #selector(contactDeveloper))
        contact.frame = NSRect(x: startX, y: buttonsY, width: contactW, height: 34)
        contact.isBordered = false
        contact.wantsLayer = true
        contact.layer?.backgroundColor = NSColor.white.cgColor
        contact.layer?.cornerRadius = 17
        contact.layer?.masksToBounds = true
        contact.attributedTitle = NSAttributedString(string: "Contact", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
        ])
        bg.addSubview(contact)

        let github = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        github.frame = NSRect(x: startX + contactW + spacing, y: buttonsY, width: gitW, height: 34)
        github.isBordered = false
        github.wantsLayer = true
        github.layer?.backgroundColor = NSColor.black.cgColor
        github.layer?.cornerRadius = 17
        github.layer?.masksToBounds = true
        github.attributedTitle = NSAttributedString(string: "GitHub", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
        ])
        bg.addSubview(github)

        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.aboutWindow = win
    }

    @objc func showPermissionsAction() {
        showPermissionsGuide(isFirstLaunch: false)
    }

    func showPermissionsGuide(isFirstLaunch: Bool) {
        if permissionsWindow != nil {
            permissionsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 480
        let height: CGFloat = 530
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active

        // App Icon
        let icon = NSImageView(frame: NSRect(x: (width - 56)/2, y: 424, width: 56, height: 56))
        icon.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(icon)

        // Title
        let title = NSTextField(labelWithString: "Permissions & Setup")
        title.font = NSFont.systemFont(ofSize: 21, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 382, width: width, height: 28)
        bg.addSubview(title)

        // Subtitle
        let sub = NSTextField(labelWithString: "Enable permissions and menu bar access for smooth recording on macOS.")
        sub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 20, y: 356, width: width - 40, height: 18)
        bg.addSubview(sub)

        struct PermItem {
            let symbol: String
            let color: NSColor
            let title: String
            let desc: String
            let action: Selector
        }

        let items: [PermItem] = [
            PermItem(
                symbol: "record.circle.fill",
                color: .systemRed,
                title: "Screen Recording (Required)",
                desc: "Allows capturing screen video, audio, and windows.",
                action: #selector(openScreenRecordingSettings)
            ),
            PermItem(
                symbol: "menubar.rectangle",
                color: .systemBlue,
                title: "Menu Bar Icon (macOS Tahoe+)",
                desc: "Keep Rec visible in the menu bar when closed.",
                action: #selector(openMenuBarSettings)
            ),
            PermItem(
                symbol: "hand.point.up.left.fill",
                color: .systemPurple,
                title: "Accessibility (Optional)",
                desc: "Enables cursor click effects and global hotkeys.",
                action: #selector(openAccessibilitySettings)
            ),
            PermItem(
                symbol: "mic.fill",
                color: .systemOrange,
                title: "Microphone (Optional)",
                desc: "Record external voice narration and microphone.",
                action: #selector(openMicrophoneSettings)
            )
        ]

        let rowHeight: CGFloat = 48
        let rowYPositions: [CGFloat] = [282, 218, 154, 90]

        self.permissionButtons = []

        for (idx, item) in items.enumerated() {
            let rowY = rowYPositions[idx]

            // Icon
            let symView = NSImageView(frame: NSRect(x: 32, y: rowY + (rowHeight - 26)/2, width: 26, height: 26))
            let symCfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            symView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symCfg)
            symView.contentTintColor = item.color
            bg.addSubview(symView)

            // Text
            let textWidth = width - 68 - 115
            let hLabel = NSTextField(labelWithString: item.title)
            hLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            hLabel.frame = NSRect(x: 68, y: rowY + 24, width: textWidth, height: 18)
            bg.addSubview(hLabel)

            let dLabel = NSTextField(labelWithString: item.desc)
            dLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            dLabel.textColor = .secondaryLabelColor
            dLabel.lineBreakMode = .byTruncatingTail
            dLabel.frame = NSRect(x: 68, y: rowY + 4, width: textWidth, height: 18)
            bg.addSubview(dLabel)

            // Action Button
            let btn = NSButton(title: "Open", target: self, action: item.action)
            btn.frame = NSRect(x: width - 32 - 70, y: rowY + (rowHeight - 28)/2, width: 70, height: 28)
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            bg.addSubview(btn)
            permissionButtons.append(btn)
        }

        // Done Button (Crisp contrast pill)
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(closePermissionsGuide))
        doneBtn.frame = NSRect(x: (width - 150)/2, y: 26, width: 150, height: 36)
        doneBtn.isBordered = false
        doneBtn.wantsLayer = true
        doneBtn.layer?.backgroundColor = NSColor.white.cgColor
        doneBtn.layer?.cornerRadius = 18
        doneBtn.layer?.masksToBounds = true
        doneBtn.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        ])
        bg.addSubview(doneBtn)

        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.permissionsWindow = win

        // Initial check and auto-polling timer for live updates
        checkPermissionsStatus()
        permissionsTimer?.invalidate()
        let t = Timer(timeInterval: 0.8, target: self, selector: #selector(checkPermissionsStatus), userInfo: nil, repeats: true)
        RunLoop.current.add(t, forMode: .common)
        self.permissionsTimer = t
    }

    @objc func checkPermissionsStatus() {
        guard permissionsWindow != nil, permissionButtons.count >= 4 else { return }

        // Row 0: Screen Recording
        let screenOk = CGPreflightScreenCaptureAccess()
        updatePermissionButton(permissionButtons[0], isGranted: screenOk)

        // Row 1: Menu Bar Icon
        let menuBarOk = (statusItem != nil)
        updatePermissionButton(permissionButtons[1], isGranted: menuBarOk)

        // Row 2: Accessibility
        let axOk = AXIsProcessTrusted()
        updatePermissionButton(permissionButtons[2], isGranted: axOk)

        // Row 3: Microphone
        let micOk = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        updatePermissionButton(permissionButtons[3], isGranted: micOk)
    }

    func updatePermissionButton(_ btn: NSButton, isGranted: Bool) {
        if isGranted {
            if btn.title != "✓" {
                btn.title = "✓"
                btn.font = NSFont.systemFont(ofSize: 13, weight: .bold)
                btn.contentTintColor = .systemGreen
                btn.toolTip = "Granted (Click to open settings)"
            }
        } else {
            if btn.title != "Open" {
                btn.title = "Open"
                btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                btn.contentTintColor = nil
                btn.toolTip = "Click to open settings"
            }
        }
    }

    @objc func closePermissionsGuide() {
        permissionsTimer?.invalidate()
        permissionsTimer = nil
        permissionButtons = []
        UserDefaults.standard.set(true, forKey: "hasSeenPermissionsGuide_v1")
        permissionsWindow?.close()
        permissionsWindow = nil
        showPanel()
    }

    @objc func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPermissionsStatus()
        }
    }

    @objc func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPermissionsStatus()
        }
    }

    @objc func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPermissionsStatus()
        }
    }


    @objc func toggleHideAbout(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideAbout")
    }

    @objc func contactDeveloper() {
        let subject = "Rec feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        if let url = URL(string: "mailto:arunthomas04042001@gmail.com?subject=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/arunofhyd/Rec") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func closeAbout() { 
        aboutWindow?.close()
        aboutWindow = nil 
        if let button = statusItem?.button {
            button.performClick(nil)
        }
    }

    @objc func manualUpdateCheck() { checkForUpdates(silentIfCurrent: false) }

    func checkForUpdates(silentIfCurrent: Bool) {
        let now = Date()
        if silentIfCurrent {
            if let lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheckDate") as? Date,
               now.timeIntervalSince(lastCheck) < 86400 {
                return // Only check once per 24 hours on automatic launch
            }
        }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheckDate")

        URLCache.shared.removeAllCachedResponses()
        let ts = Int(now.timeIntervalSince1970)
        let urlStr = updateCheckURL.contains("?") ? "\(updateCheckURL)&t=\(ts)" : "\(updateCheckURL)?t=\(ts)"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.addValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.addValue("no-cache", forHTTPHeaderField: "Pragma")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = json["version"] as? String else {
                if !silentIfCurrent {
                    DispatchQueue.main.async { self.showUpdateResult(nil, changelog: "", newer: false) }
                }
                return
            }
            let dl = (json["downloadURL"] as? String) ?? "https://rec-aoh.netlify.app/#install"
            var notes = ""
            if let logs = json["changelog"] as? [[String: Any]] {
                let unreadEntries = logs.filter { entry in
                    if let v = entry["version"] as? String {
                        return self.isNewer(v, than: appVersion)
                    }
                    return false
                }
                notes = unreadEntries.compactMap { entry -> String? in
                    guard let v = entry["version"] as? String,
                          let changes = entry["changes"] as? [String] else { return nil }
                    let changeList = changes.map { "•  \($0)" }.joined(separator: "\n")
                    return "Version \(v):\n\(changeList)"
                }.joined(separator: "\n\n")
            }
            let newer = self.isNewer(remote, than: appVersion)
            DispatchQueue.main.async {
                if newer {
                    self.showUpdateResult(remote, changelog: notes, newer: true, downloadURL: dl)
                } else if !silentIfCurrent {
                    self.showUpdateResult(remote, changelog: notes, newer: false)
                }
            }
        }
        task.resume()
    }

    func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    func showUpdateResult(_ remote: String?, changelog: String, newer: Bool, downloadURL: String = "https://rec-aoh.netlify.app/#install") {
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        
        alert.icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        if newer, let remote = remote {
            alert.messageText = "Rec \(remote) is available"
            alert.informativeText = "You have v\(appVersion). Here's what's new:"
            if !changelog.isEmpty {
                alert.accessoryView = createChangelogView(changelog: changelog)
            }
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                downloadAndInstallUpdate()
            }
        } else if remote != nil {
            alert.messageText = "You're up to date"
            alert.informativeText = "Rec v\(appVersion) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Please check your internet connection and try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func downloadAndInstallUpdate() {
        let commandURL = "https://raw.githubusercontent.com/arunofhyd/Rec/refs/heads/main/install-rec.command"
        guard let url = URL(string: commandURL) else { return }
        
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    let err = NSAlert()
                    err.alertStyle = .warning
                    err.messageText = "Download Failed"
                    err.informativeText = "Could not download the update:\n\(error.localizedDescription)\n\nPlease check your internet connection and try again."
                    err.addButton(withTitle: "OK")
                    err.runModal()
                    return
                }
                
                guard let tempURL = tempURL else { return }
                
                let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let destURL = downloadsDir.appendingPathComponent("install-rec.command")
                
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.copyItem(at: tempURL, to: destURL)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o755)],
                        ofItemAtPath: destURL.path
                    )
                    NSWorkspace.shared.open(destURL)
                } catch {
                    let err = NSAlert()
                    err.alertStyle = .warning
                    err.messageText = "Could Not Save Installer"
                    err.informativeText = "The installer was downloaded but couldn't be saved:\n\(error.localizedDescription)"
                    err.addButton(withTitle: "OK")
                    err.runModal()
                }
            }
        }
        task.resume()
    }

    // MARK: - Settings Actions
    @objc func fpsChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        currentSettings.fps = sender.tag
        currentSettings.save()
    }
    @objc func resChanged(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        menu.items.forEach { $0.state = .off }
        sender.state = .on
        currentSettings.resolution = sender.tag
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
        currentSettings.timer = sender.tag
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

        let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
        let initialAudioSymbols = ["speaker.wave.2", "mic", "mic.and.signal.meter", "speaker.slash"]
        let symbol = (0...3).contains(currentSettings.audioSource) ? initialAudioSymbols[currentSettings.audioSource] : "speaker.wave.2"
        let audioImg = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)

        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        audioPopUp.layer?.add(transition, forKey: "fade")
        audioPopUp.setMainIcon(audioImg)

        currentSettings.save()
    }

    @objc func cameraChanged(_ sender: NSMenuItem) {
        for item in cameraItems { item.state = .off }
        sender.state = .on
        
        let deviceID = sender.identifier?.rawValue ?? "None"
        currentSettings.cameraID = deviceID
        currentSettings.save()
        
        if deviceID == "None" {
            cameraWindow?.stopCamera()
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
        updateButtonImage()
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
        modePopUp.setMainIcon(sender.image)

        currentSettings.recordMode = sender.tag
        currentSettings.save()

        if sender.tag == 3 {
            showLastSelectedAreaPreview()
        }
    }

    func showLastSelectedAreaPreview() {
        guard let savedScreen = currentSettings.savedLastScreen(),
              let savedRect = currentSettings.savedLastRect else { return }
        
        let previewWin = LastAreaPreviewWindow(screen: savedScreen, rect: savedRect)
        previewWin.orderFrontRegardless()
        previewWin.startPulseAndDismiss()
    }

    @objc func toggleMouseClicks(_ sender: NSMenuItem) {
        currentSettings.showsClicks.toggle()
        currentSettings.save()
        sender.state = currentSettings.showsClicks ? .on : .off
        updateTapFeedbackLifecycle()
        if currentSettings.showsClicks && !recorder.isRecording {
            if let screen = NSScreen.main {
                let previewWin = TapFeedbackWindow(screen: screen)
                previewWin.orderFrontRegardless()
                previewWin.spawnRipple(at: NSEvent.mouseLocation, isRightClick: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    previewWin.close()
                }
            }
        }
    }

    @objc func toggleCursorHighlight(_ sender: NSMenuItem) {
        currentSettings.highlightCursor.toggle()
        currentSettings.save()
        sender.state = currentSettings.highlightCursor ? .on : .off
        updateButtonImage()
    }

    func updateTapFeedbackLifecycle() {
        if recorder.isRecording && currentSettings.showsClicks {
            if tapFeedbackWindows.isEmpty {
                for screen in NSScreen.screens {
                    let win = TapFeedbackWindow(screen: screen)
                    win.orderFrontRegardless()
                    tapFeedbackWindows.append(win)
                }
                recorder.tapFeedbackWindowIDs = tapFeedbackWindows.compactMap { $0.windowNumber }
                recorder.updateStreamFilter()
                
                if globalMouseMonitor == nil {
                    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                        self?.handleMouseEvent(event)
                    }
                }
                if localMouseMonitor == nil {
                    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                        self?.handleMouseEvent(event)
                        return event
                    }
                }
            }
        } else {
            if let g = globalMouseMonitor { NSEvent.removeMonitor(g); globalMouseMonitor = nil }
            if let l = localMouseMonitor { NSEvent.removeMonitor(l); localMouseMonitor = nil }
            for win in tapFeedbackWindows { win.close() }
            tapFeedbackWindows.removeAll()
            recorder.tapFeedbackWindowIDs.removeAll()
        }
    }

    func handleMouseEvent(_ event: NSEvent) {
        guard recorder.isRecording && currentSettings.showsClicks else { return }
        let mouseLoc = NSEvent.mouseLocation
        let isRight = (event.type == .rightMouseDown)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.recorder.isRecording && currentSettings.showsClicks else { return }
            var handled = false
            for window in self.tapFeedbackWindows {
                if window.frame.contains(mouseLoc) {
                    window.spawnRipple(at: mouseLoc, isRightClick: isRight)
                    handled = true
                    break
                }
            }
            if !handled, let fallbackWin = self.tapFeedbackWindows.first {
                fallbackWin.spawnRipple(at: mouseLoc, isRightClick: isRight)
            }
        }
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

        recordButton = HoverRecordButton()
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.bezelStyle = .regularSquare
        recordButton.isBordered = false
        recordButton.imagePosition = .imageOnly
        recordButton.wantsLayer = true
        recordButton.layer?.cornerRadius = 16
        recordButton.toolTip = "Start Recording (⌘R)"
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)

        let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
        let gearConfig = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)

        // ---- AUDIO POPUP (FIXED) ----
        audioPopUp = HoverPopUpButton()
        audioPopUp.translatesAutoresizingMaskIntoConstraints = false
        audioPopUp.removeAllItems()
        audioPopUp.isBordered = false
        audioPopUp.imagePosition = .imageOnly
        audioPopUp.pullsDown = true
        (audioPopUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        audioPopUp.wantsLayer = true
        audioPopUp.toolTip = "Audio Input Source"
        audioPopUp.widthAnchor.constraint(equalToConstant: 28).isActive = true
        audioPopUp.heightAnchor.constraint(equalToConstant: 22).isActive = true

        audioMainItems.removeAll()
        audioMicItems.removeAll()

        let audioGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        let initialAudioSymbols = ["speaker.wave.2", "mic", "mic.and.signal.meter", "speaker.slash"]
        let initialAudioSymbol = (0...3).contains(currentSettings.audioSource) ? initialAudioSymbols[currentSettings.audioSource] : "speaker.wave.2"
        let initialAudioImg = NSImage(systemSymbolName: initialAudioSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        audioPopUp.setMainIcon(initialAudioImg)
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
        settingsPopUp = HoverPopUpButton()
        settingsPopUp.translatesAutoresizingMaskIntoConstraints = false
        settingsPopUp.removeAllItems()
        settingsPopUp.isBordered = false
        settingsPopUp.imagePosition = .imageOnly
        settingsPopUp.pullsDown = true
        (settingsPopUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        settingsPopUp.wantsLayer = true
        settingsPopUp.toolTip = "Settings & Video Quality"
        settingsPopUp.widthAnchor.constraint(equalToConstant: 28).isActive = true
        settingsPopUp.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let gearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let gearImg = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?.withSymbolConfiguration(gearConfig)
        settingsPopUp.setMainIcon(gearImg)
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
            ("120 FPS (Ultra Smooth)", 120, #selector(fpsChanged(_:))),
            ("90 FPS", 90, #selector(fpsChanged(_:))),
            ("60 FPS", 60, #selector(fpsChanged(_:))),
            ("30 FPS", 30, #selector(fpsChanged(_:))),
            ("24 FPS (Cinematic)", 24, #selector(fpsChanged(_:))),
            ("15 FPS", 15, #selector(fpsChanged(_:)))
        ])
        if let sub = settingsPopUp.menu?.item(withTitle: "Framerate")?.submenu {
            for item in sub.items {
                item.state = (item.tag == currentSettings.fps) ? .on : .off
            }
        }

        addSubmenu("Resolution", "display", [
            ("Native", 0, #selector(resChanged(_:))),
            ("1080p", 1080, #selector(resChanged(_:))),
            ("720p", 720, #selector(resChanged(_:))),
            ("480p", 480, #selector(resChanged(_:)))
        ])
        if let sub = settingsPopUp.menu?.item(withTitle: "Resolution")?.submenu {
            for item in sub.items {
                item.state = (item.tag == currentSettings.resolution) ? .on : .off
            }
        }

        addSubmenu("Bitrate", "speedometer", [
            ("High (Best Quality)", 0, #selector(bitChanged(_:))),
            ("Medium (Balanced)", 1, #selector(bitChanged(_:))),
            ("Low (Space Saver)", 2, #selector(bitChanged(_:)))
        ])
        (settingsPopUp.menu?.item(withTitle: "Bitrate")?.submenu?.item(at: currentSettings.bitrate))?.state = .on

        addSubmenu("Countdown Timer", "timer", [
            ("None", 0, #selector(timerChanged(_:))),
            ("3 Seconds", 3, #selector(timerChanged(_:))),
            ("5 Seconds", 5, #selector(timerChanged(_:))),
            ("10 Seconds", 10, #selector(timerChanged(_:))),
            ("15 Seconds", 15, #selector(timerChanged(_:))),
            ("30 Seconds", 30, #selector(timerChanged(_:))),
            ("60 Seconds", 60, #selector(timerChanged(_:)))
        ])
        if let sub = settingsPopUp.menu?.item(withTitle: "Countdown Timer")?.submenu {
            for item in sub.items {
                item.state = (item.tag == currentSettings.timer) ? .on : .off
            }
        }



        settingsPopUp.menu?.addItem(NSMenuItem.separator())
        
        let cursorMenu = NSMenu()
        let nativeClickItem = NSMenuItem(title: "Show Tap Feedback", action: #selector(toggleMouseClicks(_:)), keyEquivalent: "")
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
        
        settingsPopUp.menu?.addItem(NSMenuItem.separator())
        
        let permItem = NSMenuItem(title: "Permissions & Settings...", action: #selector(showPermissionsAction), keyEquivalent: "")
        permItem.image = NSImage(systemSymbolName: "hand.raised.square", accessibilityDescription: nil)
        permItem.target = self
        settingsPopUp.menu?.addItem(permItem)

        let aboutItem = NSMenuItem(title: "About Rec", action: #selector(showAboutAction), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        aboutItem.target = self
        settingsPopUp.menu?.addItem(aboutItem)
        
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(manualUpdateCheck), keyEquivalent: "")
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.target = self
        settingsPopUp.menu?.addItem(updateItem)
        
        settingsPopUp.menu?.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Rec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        settingsPopUp.menu?.addItem(quitItem)


        // ---- CLOSE BUTTON ----
        closeButton = HoverIconButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 7
        closeButton.toolTip = "Hide Toolbar"
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide Toolbar")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(hidePanel)
        closeButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // ---- MODE POPUP ----
        modePopUp = HoverPopUpButton()
        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        modePopUp.removeAllItems()
        modePopUp.isBordered = false
        modePopUp.imagePosition = .imageOnly
        modePopUp.pullsDown = true
        (modePopUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        modePopUp.wantsLayer = true
        modePopUp.toolTip = "Recording Area & Mode"
        modePopUp.widthAnchor.constraint(equalToConstant: 28).isActive = true
        modePopUp.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let modeGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        let initialModeSymbols = ["macwindow", "macwindow.badge.plus", "crop", "rectangle.dashed"]
        let initialModeSymbol = (0...3).contains(currentSettings.recordMode) ? initialModeSymbols[currentSettings.recordMode] : "macwindow"
        let initialModeImg = NSImage(systemSymbolName: initialModeSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        modePopUp.setMainIcon(initialModeImg)
        modePopUp.menu?.addItem(modeGearItem)

        let modeItems = [
            ("Entire Screen", "macwindow", 0),
            ("Specific App", "macwindow.badge.plus", 1),
            ("Select Area", "crop", 2),
            ("Last Selected Area", "rectangle.dashed", 3)
        ]
        for (title, symbol, idx) in modeItems {
            let item = NSMenuItem(title: title, action: #selector(modeChanged(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
            item.tag = idx
            item.target = self
            if currentSettings.recordMode == idx { item.state = .on }
            modePopUp.menu?.addItem(item)
        }

        // ---- CAMERA POPUP ----
        cameraPopUp = HoverPopUpButton()
        cameraPopUp.translatesAutoresizingMaskIntoConstraints = false
        cameraPopUp.removeAllItems()
        cameraPopUp.isBordered = false
        cameraPopUp.imagePosition = .imageOnly
        cameraPopUp.pullsDown = true
        (cameraPopUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        cameraPopUp.wantsLayer = true
        cameraPopUp.toolTip = "Camera Overlay & Face Cam"
        cameraPopUp.widthAnchor.constraint(equalToConstant: 28).isActive = true
        cameraPopUp.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let cameraGearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let camIsActive = (cameraWindow != nil && cameraWindow!.isVisible)
        let camSymbol = camIsActive ? "video.fill" : "video.slash"
        let initialCamImg = NSImage(systemSymbolName: camSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        cameraPopUp.setMainIcon(initialCamImg)
        cameraPopUp.setIconTintColor(camIsActive ? .systemGreen : .labelColor)
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
        pauseButton = HoverIconButton()
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.bezelStyle = .regularSquare
        pauseButton.isBordered = false
        pauseButton.imagePosition = .imageOnly
        pauseButton.wantsLayer = true
        pauseButton.layer?.cornerRadius = 7
        pauseButton.toolTip = "Pause / Resume Recording"
        pauseButton.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        pauseButton.contentTintColor = .labelColor
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.isHidden = true // Only visible when recording
        
        cameraRecordButton = HoverIconButton()
        cameraRecordButton.translatesAutoresizingMaskIntoConstraints = false
        cameraRecordButton.isBordered = false
        cameraRecordButton.imagePosition = .imageOnly
        cameraRecordButton.wantsLayer = true
        cameraRecordButton.layer?.cornerRadius = 7
        cameraRecordButton.toolTip = "Toggle Camera"
        cameraRecordButton.target = self
        cameraRecordButton.action = #selector(toggleCameraHotkey)
        cameraRecordButton.isHidden = true
        cameraRecordButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        cameraRecordButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        audioRecordIndicator = HoverIconButton()
        audioRecordIndicator.translatesAutoresizingMaskIntoConstraints = false
        audioRecordIndicator.isBordered = false
        audioRecordIndicator.imagePosition = .imageOnly
        audioRecordIndicator.wantsLayer = true
        audioRecordIndicator.layer?.cornerRadius = 7
        audioRecordIndicator.toolTip = "Audio Recording Active"
        audioRecordIndicator.isHidden = true
        audioRecordIndicator.widthAnchor.constraint(equalToConstant: 32).isActive = true
        audioRecordIndicator.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // ---- LIVE TIMER STACK (Floating Bar) ----
        liveTimerDot = NSImageView()
        liveTimerDot.translatesAutoresizingMaskIntoConstraints = false
        let dotConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        liveTimerDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(dotConfig)
        liveTimerDot.contentTintColor = .systemRed
        liveTimerDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        liveTimerDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        liveTimerLabel = NSTextField(labelWithString: "00:00")
        liveTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        liveTimerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        liveTimerLabel.textColor = .labelColor
        liveTimerLabel.isBordered = false
        liveTimerLabel.drawsBackground = false
        liveTimerLabel.alignment = .center

        liveTimerStack = NSStackView(views: [liveTimerDot, liveTimerLabel])
        liveTimerStack.translatesAutoresizingMaskIntoConstraints = false
        liveTimerStack.orientation = .horizontal
        liveTimerStack.spacing = 6
        liveTimerStack.alignment = .centerY
        liveTimerStack.isHidden = true

        // ---- HAIRLINE DIVIDERS ----
        let makeDivider = { () -> NSBox in
            let div = NSBox()
            div.boxType = .custom
            div.isTransparent = false
            div.borderWidth = 0
            div.fillColor = NSColor.separatorColor
            div.translatesAutoresizingMaskIntoConstraints = false
            div.widthAnchor.constraint(equalToConstant: 1).isActive = true
            div.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return div
        }

        idleDivider1 = makeDivider()
        idleDivider2 = makeDivider()
        idleDivider3 = makeDivider()
        idleDivider4 = makeDivider()
        recDivider1 = makeDivider()
        recDivider2 = makeDivider()

        // ---- STACK VIEW ----
        let stackView = NSStackView(views: [
            closeButton,
            idleDivider1,
            settingsPopUp,
            idleDivider2,
            cameraPopUp,
            audioPopUp,
            idleDivider3,
            modePopUp,
            idleDivider4,
            cameraRecordButton,
            audioRecordIndicator,
            recDivider1,
            liveTimerStack,
            recDivider2
        ])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 14
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

            actionStackView.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 18),
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
            guard let self = self else { return }
            self.recordingStartTime = Date()
            self.pausedAccumulatedTime = 0
            self.pauseStartDate = nil
            
            self.recordingTimer?.invalidate()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updateRecordingTimeDisplay()
            }

            self.updateButtonImage()
            self.updateMenuBarPill()
            self.updateRecordingTimeDisplay()
            if let rect = self.recorder.captureRect, rect != .zero, let screen = self.recorder.captureScreen {
                self.recordingOverlay = RecordingOverlayWindow(screen: screen, holeRect: rect)
                self.recordingOverlay?.makeKeyAndOrderFront(nil)
            }
        }
        recorder.onRecordingStopped = { [weak self] url in
            guard let self = self else { return }
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingStartTime = nil
            self.pauseStartDate = nil

            self.recordingOverlay?.close(); self.recordingOverlay = nil
            self.updateButtonImage()
            self.updateMenuBarPill()

            self.toastWindow?.close()
            let toast = RecordingToastWindow(fileURL: url)
            toast.onDismiss = { [weak self] in
                self?.toastWindow = nil
            }
            self.toastWindow = toast
            toast.alphaValue = 0.0
            toast.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toast.animator().alphaValue = 1.0
            }
        }
        recorder.onError = { [weak self] error in
            guard let self = self else { return }
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingStartTime = nil
            self.pauseStartDate = nil

            self.recordingOverlay?.close(); self.recordingOverlay = nil
            self.updateButtonImage()
            self.updateMenuBarPill()
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
                if currentSettings.audioSource == 1 || currentSettings.audioSource == 2 {
                    self.audioRecordIndicator?.contentTintColor = isActive ? .systemGreen : .systemCyan
                }
            }
        }
    }

    @objc func togglePause() {
        recorder.togglePause()
        if recorder.isPaused {
            pauseStartDate = Date()
        } else {
            if let pauseStart = pauseStartDate {
                pausedAccumulatedTime += Date().timeIntervalSince(pauseStart)
                pauseStartDate = nil
            }
        }
        updateButtonImage()
        updateMenuBarPill()
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

            let savedDisplayID = currentSettings.lastScreenDisplayID

            for screen in NSScreen.screens {
                let window = RegionSelectionWindow(screen: screen)
                if let view = window.contentView as? RegionSelectionView {
                    let screenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                    
                    let isSavedScreen = (savedDisplayID != nil && screenDisplayID == savedDisplayID) ||
                                       (savedDisplayID == nil && screen == NSScreen.main)
                    
                    if isSavedScreen, let lastRect = currentSettings.savedLastRect {
                        view.currentRect = lastRect
                    }

                    view.onCancel = { [weak self] in
                        for w in self?.regionSelectionWindows ?? [] { w.close() }
                        self?.regionSelectionWindows.removeAll()
                    }

                    view.onSelectionComplete = { [weak self] rect in
                        guard let self = self else { return }
                        self.recorder.captureApp = nil
                        self.recorder.captureRect = rect
                        self.recorder.captureScreen = screen
                        
                        currentSettings.saveLastSelectedArea(rect: rect, screen: screen)

                        for w in self.regionSelectionWindows { w.close() }
                        self.regionSelectionWindows.removeAll()
                        
                        self.startCountdownAndRecord()
                    }
                }
                regionSelectionWindows.append(window)
                window.makeKeyAndOrderFront(nil)
                if let view = window.contentView as? RegionSelectionView {
                    window.makeFirstResponder(view)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        } else if modeIndex == 3 { // Last Selected Area
            if let savedScreen = currentSettings.savedLastScreen(),
               let savedRect = currentSettings.savedLastRect {
                for window in regionSelectionWindows { window.close() }
                regionSelectionWindows.removeAll()

                let window = RegionSelectionWindow(screen: savedScreen)
                if let view = window.contentView as? RegionSelectionView {
                    view.currentRect = savedRect
                    view.isLastSelectedAreaPreview = true

                    view.onCancel = { [weak self] in
                        for w in self?.regionSelectionWindows ?? [] { w.close() }
                        self?.regionSelectionWindows.removeAll()
                    }

                    view.onSelectionComplete = { [weak self] rect in
                        guard let self = self else { return }
                        self.recorder.captureApp = nil
                        self.recorder.captureRect = rect
                        self.recorder.captureScreen = savedScreen

                        currentSettings.saveLastSelectedArea(rect: rect, screen: savedScreen)

                        for w in self.regionSelectionWindows { w.close() }
                        self.regionSelectionWindows.removeAll()

                        self.startCountdownAndRecord()
                    }
                }
                regionSelectionWindows.append(window)
                window.makeKeyAndOrderFront(nil)
                if let view = window.contentView as? RegionSelectionView {
                    window.makeFirstResponder(view)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                currentSettings.recordMode = 2
                startRecordingProcess()
            }
        } else { // Entire Screen
            recorder.captureApp = nil
            recorder.captureRect = nil
            recorder.captureScreen = NSScreen.main
            startCountdownAndRecord()
        }
    }

    func startCountdownAndRecord() {
        updateMenuBarPill()
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
        let isRec = recorder.isRecording

        // Hide configuration controls and dividers that cannot be modified during recording
        closeButton.isHidden = isRec
        idleDivider1?.isHidden = isRec
        settingsPopUp.isHidden = isRec
        idleDivider2?.isHidden = isRec
        cameraPopUp.isHidden = isRec
        audioPopUp.isHidden = isRec
        idleDivider3?.isHidden = isRec
        modePopUp.isHidden = isRec
        idleDivider4?.isHidden = isRec

        // Show live recording controls and dividers
        cameraRecordButton.isHidden = !isRec
        audioRecordIndicator.isHidden = !isRec
        recDivider1?.isHidden = !isRec
        liveTimerStack.isHidden = !isRec
        recDivider2?.isHidden = !isRec
        pauseButton.isHidden = !isRec

        let audioConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
        let audioSymbol: String
        let audioTitle: String
        switch currentSettings.audioSource {
        case 0:
            audioSymbol = "speaker.wave.2"
            audioTitle = "System Audio"
        case 1:
            audioSymbol = "mic"
            audioTitle = "Microphone"
        case 2:
            audioSymbol = "mic.and.signal.meter"
            audioTitle = "System Audio + Mic"
        case 3:
            audioSymbol = "speaker.slash"
            audioTitle = "No Audio (Muted)"
        default:
            audioSymbol = "speaker.wave.2"
            audioTitle = "System Audio"
        }
        audioRecordIndicator?.image = NSImage(systemSymbolName: audioSymbol, accessibilityDescription: audioTitle)?.withSymbolConfiguration(audioConfig)
        let isAudioCapturing = (currentSettings.audioSource != 3)
        audioRecordIndicator?.contentTintColor = isAudioCapturing ? .systemCyan : .tertiaryLabelColor
        audioRecordIndicator?.toolTip = "Recording Audio: \(audioTitle)"

        if !isRec {
            liveTimerLabel.stringValue = "00:00"
            liveTimerDot.contentTintColor = .systemRed
            liveTimerLabel.textColor = .labelColor
        } else {
            if recorder.isPaused {
                liveTimerDot.contentTintColor = .systemOrange
                liveTimerLabel.textColor = .systemOrange
            } else {
                liveTimerDot.contentTintColor = .systemRed
                liveTimerLabel.textColor = .labelColor
            }
        }
        
        let pauseSymbol = recorder.isPaused ? "play.circle.fill" : "pause.circle.fill"
        let pauseConfig = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        pauseButton.image = NSImage(systemSymbolName: pauseSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(pauseConfig)
        pauseButton.contentTintColor = .labelColor

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
                    let isDark = (self.panel?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    if isDark {
                        NSColor.white.setStroke()
                    } else {
                        NSColor(white: 0.20, alpha: 0.85).setStroke()
                    }
                    outerPath.stroke()

                    let innerPath = NSBezierPath(ovalIn: NSRect(x: 40, y: 40, width: 40, height: 40))
                    NSColor(red: 1.0, green: 59/255.0, blue: 48/255.0, alpha: 1.0).setFill()
                    innerPath.fill()
                }
            } else {
                let bgPath = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
                NSColor(red: 1.0, green: 59/255.0, blue: 48/255.0, alpha: 1.0).setFill()
                bgPath.fill()
                
                let squareSize = size.width * 0.38
                let squareRect = NSRect(
                    x: (size.width - squareSize) / 2,
                    y: (size.height - squareSize) / 2,
                    width: squareSize,
                    height: squareSize
                )
                let squarePath = NSBezierPath(roundedRect: squareRect, xRadius: 2.5, yRadius: 2.5)
                NSColor.white.setFill()
                squarePath.fill()
            }

            tintedImage.unlockFocus()
            recordButton.image = tintedImage
        }
        
        let camConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
        let camIsActive = (cameraWindow != nil && cameraWindow!.isVisible)
        let camSymbol = camIsActive ? "video.fill" : "video.slash"
        let camImage = NSImage(systemSymbolName: camSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(camConfig)
        
        cameraRecordButton.image = camImage
        cameraRecordButton.contentTintColor = camIsActive ? .systemGreen : .labelColor
        cameraRecordButton.toolTip = camIsActive ? "Hide Camera Overlay" : "Show Camera Overlay"
        
        cameraPopUp?.setMainIcon(camImage)
        cameraPopUp?.setIconTintColor(camIsActive ? .systemGreen : .labelColor)
        cameraPopUp?.selectItem(at: 0)
        cameraPopUp?.synchronizeTitleAndSelectedItem()
        cameraPopUp?.needsDisplay = true

        let activeCamID = camIsActive ? currentSettings.cameraID : "None"
        for item in cameraItems {
            item.state = (item.identifier?.rawValue == activeCamID) ? .on : .off
        }

        recordButton.toolTip = isRec ? "Stop and Save Recording (⌘R)" : "Start Recording (⌘R)"
        pauseButton.toolTip = recorder.isPaused ? "Resume Recording" : "Pause Recording"

        // Re-layout panel to adapt size with smooth animation
        if let contentView = panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let newSize = contentView.fittingSize
            if panel.frame.size != newSize {
                var newFrame = panel.frame
                let diffX = newSize.width - newFrame.width
                newFrame.origin.x -= diffX / 2.0
                newFrame.size = newSize
                panel.setFrame(newFrame, display: true, animate: true)
            }
        }

        // Handle Cursor Highlighter lifecycle
        if recorder.isRecording && currentSettings.highlightCursor {
            if highlighterWindow == nil {
                let hw = CursorHighlighterWindow()
                hw.makeKeyAndOrderFront(nil)
                highlighterWindow = hw
                recorder.cursorWindowID = hw.windowNumber
                recorder.updateStreamFilter()
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
            recorder.cursorWindowID = nil
        }

        // Handle Tap Feedback lifecycle
        updateTapFeedbackLifecycle()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if let g = globalMouseMonitor { NSEvent.removeMonitor(g); globalMouseMonitor = nil }
        if let l = localMouseMonitor { NSEvent.removeMonitor(l); localMouseMonitor = nil }
        for win in tapFeedbackWindows { win.close() }
        tapFeedbackWindows.removeAll()
        highlighterTimer?.invalidate()
        highlighterWindow?.close()
        cameraWindow?.close()
        recordingOverlay?.close()
    }

    deinit {
        recordingOverlay?.close()
        for win in tapFeedbackWindows { win.close() }
        if let g = globalMouseMonitor { NSEvent.removeMonitor(g) }
        if let l = localMouseMonitor { NSEvent.removeMonitor(l) }
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
