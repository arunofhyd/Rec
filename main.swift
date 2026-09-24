import Cocoa
import ScreenCaptureKit
import AVFoundation
import AVKit
import VideoToolbox
import os.log
import SwiftUI
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Configuration
let appVersion: String = {
    if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
        return ver
    }
    return "1.4.9"
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

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
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
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
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isReleasedWhenClosed = false

        let selectionView = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

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
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
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
// Screen Annotation System (Apple Markup & Magic Writer)
// ============================================================

enum AnnotationTool: Int, CaseIterable {
    case pen = 0
    case brush = 1
    case highlighter = 2
    case magicWriter = 3
    case arrow = 4
    case rectangle = 5
    case circle = 6
    case eraser = 7

    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .brush: return "paintbrush.fill"
        case .highlighter: return "highlighter"
        case .magicWriter: return "sparkles"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "square"
        case .circle: return "circle"
        case .eraser: return "eraser.fill"
        }
    }

    var displayName: String {
        switch self {
        case .pen: return "Pen (1)"
        case .brush: return "Brush (2)"
        case .highlighter: return "Highlighter (3)"
        case .magicWriter: return "Magic Writer (4)"
        case .arrow: return "Arrow (5)"
        case .rectangle: return "Rectangle (6)"
        case .circle: return "Oval (7)"
        case .eraser: return "Eraser (8)"
        }
    }
}

enum AnnotationStrokeWidth: Int, CaseIterable {
    case thin = 0
    case medium = 1
    case thick = 2

    func width(for tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .pen:
            switch self {
            case .thin: return 3.0
            case .medium: return 6.0
            case .thick: return 12.0
            }
        case .brush:
            switch self {
            case .thin: return 6.0
            case .medium: return 12.0
            case .thick: return 22.0
            }
        case .highlighter:
            switch self {
            case .thin: return 20.0
            case .medium: return 34.0
            case .thick: return 50.0
            }
        case .magicWriter:
            switch self {
            case .thin: return 4.0
            case .medium: return 8.0
            case .thick: return 14.0
            }
        case .arrow, .rectangle, .circle:
            switch self {
            case .thin: return 3.5
            case .medium: return 6.0
            case .thick: return 10.0
            }
        case .eraser:
            switch self {
            case .thin: return 18.0
            case .medium: return 32.0
            case .thick: return 52.0
            }
        }
    }

    var title: String {
        switch self {
        case .thin: return "Thin"
        case .medium: return "Medium"
        case .thick: return "Thick"
        }
    }
}

struct AnnotationColorItem {
    let name: String
    let color: NSColor
}

let annotationPresetColors: [AnnotationColorItem] = [
    AnnotationColorItem(name: "Red", color: NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)),
    AnnotationColorItem(name: "Orange", color: NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1.0)),
    AnnotationColorItem(name: "Yellow", color: NSColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1.0)),
    AnnotationColorItem(name: "Green", color: NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)),
    AnnotationColorItem(name: "Cyan", color: NSColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 1.0)),
    AnnotationColorItem(name: "Blue", color: NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)),
    AnnotationColorItem(name: "Purple", color: NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1.0)),
    AnnotationColorItem(name: "White", color: NSColor.white),
    AnnotationColorItem(name: "Black", color: NSColor(white: 0.10, alpha: 1.0))
]

class AnnotationStroke {
    var tool: AnnotationTool
    var color: NSColor
    var width: CGFloat
    var points: [NSPoint] = []
    var startPoint: NSPoint = .zero
    var endPoint: NSPoint = .zero
    var createdAt: Date = Date()
    var opacity: CGFloat = 1.0

    init(tool: AnnotationTool, color: NSColor, width: CGFloat) {
        self.tool = tool
        self.color = color
        self.width = width
        self.createdAt = Date()
        self.opacity = 1.0
    }

    func boundingRect(screenOrigin origin: NSPoint) -> NSRect {
        let pad = width * 2.5 + 24.0
        switch tool {
        case .pen, .brush, .highlighter, .magicWriter:
            if points.isEmpty { return .zero }
            var minX = points[0].x, maxX = points[0].x
            var minY = points[0].y, maxY = points[0].y
            for pt in points {
                if pt.x < minX { minX = pt.x }
                if pt.x > maxX { maxX = pt.x }
                if pt.y < minY { minY = pt.y }
                if pt.y > maxY { maxY = pt.y }
            }
            return NSRect(x: minX - origin.x - pad,
                          y: minY - origin.y - pad,
                          width: (maxX - minX) + pad * 2,
                          height: (maxY - minY) + pad * 2)

        case .arrow, .rectangle, .circle:
            let minX = min(startPoint.x, endPoint.x)
            let maxX = max(startPoint.x, endPoint.x)
            let minY = min(startPoint.y, endPoint.y)
            let maxY = max(startPoint.y, endPoint.y)
            return NSRect(x: minX - origin.x - pad,
                          y: minY - origin.y - pad,
                          width: (maxX - minX) + pad * 2,
                          height: (maxY - minY) + pad * 2)

        case .eraser:
            return .zero
        }
    }

    func hitTest(screenPoint: NSPoint, radius: CGFloat) -> Bool {
        let threshold = radius + width / 2.0 + 4.0
        let thresholdSq = threshold * threshold

        switch tool {
        case .pen, .brush, .highlighter, .magicWriter:
            if points.isEmpty { return false }
            if points.count == 1 {
                let dx = screenPoint.x - points[0].x
                let dy = screenPoint.y - points[0].y
                return (dx*dx + dy*dy) <= thresholdSq
            }
            for i in 0..<(points.count - 1) {
                let p1 = points[i]
                let p2 = points[i + 1]
                if distSqToSegment(p: screenPoint, v: p1, w: p2) <= thresholdSq {
                    return true
                }
            }
            return false

        case .arrow:
            return distSqToSegment(p: screenPoint, v: startPoint, w: endPoint) <= thresholdSq

        case .rectangle:
            let rect = NSRect(x: min(startPoint.x, endPoint.x),
                              y: min(startPoint.y, endPoint.y),
                              width: max(1, abs(endPoint.x - startPoint.x)),
                              height: max(1, abs(endPoint.y - startPoint.y)))
            let outer = rect.insetBy(dx: -threshold, dy: -threshold)
            let inner = rect.insetBy(dx: threshold, dy: threshold)
            return outer.contains(screenPoint) && !inner.contains(screenPoint)

        case .circle:
            let rect = NSRect(x: min(startPoint.x, endPoint.x),
                              y: min(startPoint.y, endPoint.y),
                              width: max(1, abs(endPoint.x - startPoint.x)),
                              height: max(1, abs(endPoint.y - startPoint.y)))
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let rx = rect.width / 2.0
            let ry = rect.height / 2.0
            if rx < 2 || ry < 2 { return false }
            let dx = screenPoint.x - center.x
            let dy = screenPoint.y - center.y
            let distNorm = (dx * dx) / ((rx + threshold) * (rx + threshold)) + (dy * dy) / ((ry + threshold) * (ry + threshold))
            let distNormInner = (dx * dx) / (max(1, rx - threshold) * max(1, rx - threshold)) + (dy * dy) / (max(1, ry - threshold) * max(1, ry - threshold))
            return distNorm <= 1.0 && distNormInner >= 1.0

        case .eraser:
            return false
        }
    }

    private func distSqToSegment(p: NSPoint, v: NSPoint, w: NSPoint) -> CGFloat {
        let l2 = (w.x - v.x) * (w.x - v.x) + (w.y - v.y) * (w.y - v.y)
        if l2 == 0 {
            let dx = p.x - v.x
            let dy = p.y - v.y
            return dx * dx + dy * dy
        }
        var t = ((p.x - v.x) * (w.x - v.x) + (p.y - v.y) * (w.y - v.y)) / l2
        t = max(0, min(1, t))
        let projX = v.x + t * (w.x - v.x)
        let projY = v.y + t * (w.y - v.y)
        let dx = p.x - projX
        let dy = p.y - projY
        return dx * dx + dy * dy
    }

    func draw(in view: NSView, screenOrigin origin: NSPoint) {
        let alpha = opacity
        if alpha <= 0.01 { return }

        let toView = { (sp: NSPoint) -> NSPoint in
            return NSPoint(x: sp.x - origin.x, y: sp.y - origin.y)
        }

        switch tool {
        case .pen:
            guard !points.isEmpty else { return }
            let path = NSBezierPath()
            let v0 = toView(points[0])
            if points.count == 1 {
                let dotRect = NSRect(x: v0.x - width/2, y: v0.y - width/2, width: width, height: width)
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                return
            }
            path.move(to: v0)
            if points.count == 2 {
                path.line(to: toView(points[1]))
            } else {
                for i in 1..<(points.count - 1) {
                    let curr = toView(points[i])
                    let next = toView(points[i + 1])
                    let mid = NSPoint(x: (curr.x + next.x) / 2.0, y: (curr.y + next.y) / 2.0)
                    path.curve(to: mid, controlPoint1: curr, controlPoint2: curr)
                }
                if let last = points.last { path.line(to: toView(last)) }
            }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            path.stroke()

        case .brush:
            guard !points.isEmpty else { return }
            let path = NSBezierPath()
            let v0 = toView(points[0])
            if points.count == 1 {
                let dotRect = NSRect(x: v0.x - width*0.75, y: v0.y - width*0.75, width: width*1.5, height: width*1.5)
                color.withAlphaComponent(0.35 * alpha).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                let coreRect = NSRect(x: v0.x - width/2, y: v0.y - width/2, width: width, height: width)
                color.withAlphaComponent(0.9 * alpha).setFill()
                NSBezierPath(ovalIn: coreRect).fill()
                return
            }
            path.move(to: v0)
            if points.count == 2 {
                path.line(to: toView(points[1]))
            } else {
                for i in 1..<(points.count - 1) {
                    let curr = toView(points[i])
                    let next = toView(points[i + 1])
                    let mid = NSPoint(x: (curr.x + next.x) / 2.0, y: (curr.y + next.y) / 2.0)
                    path.curve(to: mid, controlPoint1: curr, controlPoint2: curr)
                }
                if let last = points.last { path.line(to: toView(last)) }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // Soft halo
            path.lineWidth = width * 1.5
            color.withAlphaComponent(0.25 * alpha).setStroke()
            path.stroke()

            // Velvety core
            path.lineWidth = width
            color.withAlphaComponent(0.85 * alpha).setStroke()
            path.stroke()

        case .highlighter:
            guard !points.isEmpty else { return }
            let path = NSBezierPath()
            let v0 = toView(points[0])
            if points.count == 1 {
                let dotRect = NSRect(x: v0.x - width/2, y: v0.y - width/2, width: width, height: width)
                color.withAlphaComponent(0.38 * alpha).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                return
            }
            path.move(to: v0)
            if points.count == 2 {
                path.line(to: toView(points[1]))
            } else {
                for i in 1..<(points.count - 1) {
                    let curr = toView(points[i])
                    let next = toView(points[i + 1])
                    let mid = NSPoint(x: (curr.x + next.x) / 2.0, y: (curr.y + next.y) / 2.0)
                    path.curve(to: mid, controlPoint1: curr, controlPoint2: curr)
                }
                if let last = points.last { path.line(to: toView(last)) }
            }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.withAlphaComponent(0.38 * alpha).setStroke()
            path.stroke()

        case .magicWriter:
            guard !points.isEmpty else { return }
            let path = NSBezierPath()
            let v0 = toView(points[0])
            if points.count == 1 {
                let glowRect = NSRect(x: v0.x - width*1.3, y: v0.y - width*1.3, width: width*2.6, height: width*2.6)
                color.withAlphaComponent(0.4 * alpha).setFill()
                NSBezierPath(ovalIn: glowRect).fill()
                let coreRect = NSRect(x: v0.x - width*0.5, y: v0.y - width*0.5, width: width, height: width)
                NSColor.white.withAlphaComponent(0.95 * alpha).setFill()
                NSBezierPath(ovalIn: coreRect).fill()
                return
            }
            path.move(to: v0)
            if points.count == 2 {
                path.line(to: toView(points[1]))
            } else {
                for i in 1..<(points.count - 1) {
                    let curr = toView(points[i])
                    let next = toView(points[i + 1])
                    let mid = NSPoint(x: (curr.x + next.x) / 2.0, y: (curr.y + next.y) / 2.0)
                    path.curve(to: mid, controlPoint1: curr, controlPoint2: curr)
                }
                if let last = points.last { path.line(to: toView(last)) }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // Pass 1: Neon outer aura
            path.lineWidth = width * 2.4
            color.withAlphaComponent(0.35 * alpha).setStroke()
            path.stroke()

            // Pass 2: Intense laser stroke
            path.lineWidth = width * 1.3
            color.withAlphaComponent(0.85 * alpha).setStroke()
            path.stroke()

            // Pass 3: White hot center laser core
            path.lineWidth = width * 0.45
            NSColor.white.withAlphaComponent(0.95 * alpha).setStroke()
            path.stroke()

        case .arrow:
            let vStart = toView(startPoint)
            let vEnd = toView(endPoint)
            let dx = vEnd.x - vStart.x
            let dy = vEnd.y - vStart.y
            let len = hypot(dx, dy)
            if len < 4 { return }

            let ux = dx / len
            let uy = dy / len
            let px = -uy
            let py = ux

            let headLen = max(16.0, width * 3.2)
            let headHalfWidth = max(9.0, width * 1.8)
            let shaftEnd = NSPoint(x: vEnd.x - headLen * ux * 0.85, y: vEnd.y - headLen * uy * 0.85)

            let shaft = NSBezierPath()
            shaft.move(to: vStart)
            shaft.line(to: shaftEnd)
            shaft.lineWidth = width
            shaft.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            shaft.stroke()

            // Arrow head
            let headPath = NSBezierPath()
            headPath.move(to: vEnd)
            let corner1 = NSPoint(x: vEnd.x - headLen * ux + headHalfWidth * px,
                                  y: vEnd.y - headLen * uy + headHalfWidth * py)
            let corner2 = NSPoint(x: vEnd.x - headLen * ux - headHalfWidth * px,
                                  y: vEnd.y - headLen * uy - headHalfWidth * py)
            headPath.line(to: corner1)
            headPath.line(to: corner2)
            headPath.close()
            color.withAlphaComponent(alpha).setFill()
            headPath.fill()

        case .rectangle:
            let vStart = toView(startPoint)
            let vEnd = toView(endPoint)
            let rect = NSRect(x: min(vStart.x, vEnd.x),
                              y: min(vStart.y, vEnd.y),
                              width: max(1, abs(vEnd.x - vStart.x)),
                              height: max(1, abs(vEnd.y - vStart.y)))
            guard rect.width > 2 && rect.height > 2 else { return }
            let cornerR = min(12.0, min(rect.width, rect.height) / 4.0)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerR, yRadius: cornerR)
            path.lineWidth = width
            color.withAlphaComponent(alpha).setStroke()
            path.stroke()

        case .circle:
            let vStart = toView(startPoint)
            let vEnd = toView(endPoint)
            let rect = NSRect(x: min(vStart.x, vEnd.x),
                              y: min(vStart.y, vEnd.y),
                              width: max(1, abs(vEnd.x - vStart.x)),
                              height: max(1, abs(vEnd.y - vStart.y)))
            guard rect.width > 2 && rect.height > 2 else { return }
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = width
            color.withAlphaComponent(alpha).setStroke()
            path.stroke()

        case .eraser:
            break
        }
    }
}

// MARK: - Annotation Canvas View & Window

class AnnotationCanvasView: NSView {
    var activeStroke: AnnotationStroke?
    var currentMousePoint: NSPoint = .zero
    var isErasing: Bool = false
    private var lastEraserScreenPoint: NSPoint?
    private var trackingAreaRef: NSTrackingArea?
    private var eraserLayer: CALayer?

    override var isOpaque: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override var acceptsFirstResponder: Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupEraserLayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupEraserLayer() {
        guard let root = self.layer else { return }
        let el = CALayer()
        el.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        el.cornerRadius = 16
        el.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        el.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        el.borderWidth = 1.5
        el.isHidden = true

        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        dot.position = CGPoint(x: 16, y: 16)
        dot.cornerRadius = 2
        dot.backgroundColor = NSColor.white.cgColor
        el.addSublayer(dot)

        root.addSublayer(el)
        self.eraserLayer = el
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(tracking)
        self.trackingAreaRef = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseExited(with event: NSEvent) {
        currentMousePoint = NSPoint(x: -1000, y: -1000)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eraserLayer?.isHidden = true
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        currentMousePoint = pt
        if AnnotationManager.shared.currentTool == .eraser {
            let radius = max(16.0, AnnotationManager.shared.currentWidth.width(for: .eraser) / 2.0)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            eraserLayer?.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            eraserLayer?.cornerRadius = radius
            eraserLayer?.sublayers?.first?.position = CGPoint(x: radius, y: radius)
            eraserLayer?.position = CGPoint(x: pt.x, y: pt.y)
            eraserLayer?.isHidden = false
            CATransaction.commit()
        } else {
            if eraserLayer?.isHidden == false {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                eraserLayer?.isHidden = true
                CATransaction.commit()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let win = self.window else { return }
        let origin = win.frame.origin

        // 1. Draw existing strokes that intersect the dirty rect
        for stroke in AnnotationManager.shared.strokes {
            if stroke.boundingRect(screenOrigin: origin).intersects(dirtyRect) {
                stroke.draw(in: self, screenOrigin: origin)
            }
        }

        // 2. Draw live active stroke if it intersects the dirty rect
        if let live = activeStroke {
            if live.boundingRect(screenOrigin: origin).intersects(dirtyRect) {
                live.draw(in: self, screenOrigin: origin)
            }
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let win = self.window else { return event.locationInWindow }
        return win.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        let sp = screenPoint(for: event)
        currentMousePoint = convert(event.locationInWindow, from: nil)
        let tool = AnnotationManager.shared.currentTool

        if tool == .eraser {
            isErasing = true
            lastEraserScreenPoint = sp
            let radius = max(24.0, AnnotationManager.shared.currentWidth.width(for: .eraser) / 2.0 + 8.0)
            AnnotationManager.shared.eraseStrokes(near: sp, radius: radius)
        } else {
            let width = AnnotationManager.shared.currentWidth.width(for: tool)
            let color = AnnotationManager.shared.currentColor
            let stroke = AnnotationStroke(tool: tool, color: color, width: width)
            stroke.startPoint = sp
            stroke.endPoint = sp
            stroke.points = [sp]
            self.activeStroke = stroke

            guard let origin = window?.frame.origin else { return }
            let pad = width * 2 + 10
            let r = NSRect(x: sp.x - origin.x - pad, y: sp.y - origin.y - pad, width: pad * 2, height: pad * 2)
            setNeedsDisplay(r)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let sp = screenPoint(for: event)
        currentMousePoint = convert(event.locationInWindow, from: nil)
        let tool = AnnotationManager.shared.currentTool

        if tool == .eraser {
            let radius = max(24.0, AnnotationManager.shared.currentWidth.width(for: .eraser) / 2.0 + 8.0)
            if let prev = lastEraserScreenPoint {
                AnnotationManager.shared.eraseStrokesAlongLine(from: prev, to: sp, radius: radius)
            } else {
                AnnotationManager.shared.eraseStrokes(near: sp, radius: radius)
            }
            lastEraserScreenPoint = sp
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            eraserLayer?.position = CGPoint(x: currentMousePoint.x, y: currentMousePoint.y)
            CATransaction.commit()
        } else if let stroke = activeStroke {
            guard let origin = window?.frame.origin else { return }
            switch stroke.tool {
            case .pen, .brush, .highlighter, .magicWriter:
                let prev = stroke.points.last ?? sp
                stroke.points.append(sp)
                let pad = stroke.width * 2 + 16
                let dirty = NSRect(
                    x: min(prev.x - origin.x, sp.x - origin.x) - pad,
                    y: min(prev.y - origin.y, sp.y - origin.y) - pad,
                    width: abs(sp.x - prev.x) + pad * 2,
                    height: abs(sp.y - prev.y) + pad * 2
                )
                setNeedsDisplay(dirty)
            case .arrow, .rectangle, .circle:
                let prevEnd = stroke.endPoint
                stroke.endPoint = sp
                let pad = stroke.width * 2 + 20
                let r1 = NSRect(x: min(stroke.startPoint.x - origin.x, prevEnd.x - origin.x) - pad,
                                y: min(stroke.startPoint.y - origin.y, prevEnd.y - origin.y) - pad,
                                width: abs(prevEnd.x - stroke.startPoint.x) + pad * 2,
                                height: abs(prevEnd.y - stroke.startPoint.y) + pad * 2)
                let r2 = NSRect(x: min(stroke.startPoint.x - origin.x, sp.x - origin.x) - pad,
                                y: min(stroke.startPoint.y - origin.y, sp.y - origin.y) - pad,
                                width: abs(sp.x - stroke.startPoint.x) + pad * 2,
                                height: abs(sp.y - stroke.startPoint.y) + pad * 2)
                setNeedsDisplay(r1.union(r2))
            case .eraser:
                break
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let sp = screenPoint(for: event)
        currentMousePoint = convert(event.locationInWindow, from: nil)
        let tool = AnnotationManager.shared.currentTool

        if tool == .eraser {
            isErasing = false
            lastEraserScreenPoint = nil
        } else if let stroke = activeStroke {
            switch stroke.tool {
            case .pen, .brush, .highlighter, .magicWriter:
                stroke.points.append(sp)
            case .arrow, .rectangle, .circle:
                stroke.endPoint = sp
            case .eraser:
                break
            }
            stroke.createdAt = Date()
            self.activeStroke = nil
            AnnotationManager.shared.addStroke(stroke)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            AnnotationManager.shared.stopAnnotationMode()
        } else {
            super.keyDown(with: event)
        }
    }
}

class AnnotationCanvasWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false

        let canvasView = AnnotationCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvasView.wantsLayer = true
        self.contentView = canvasView
    }
}

// MARK: - Annotation Floating Toolbar (Apple Markup Style)

class AnnotationToolbarButton: NSButton {
    private var trackingAreaObj: NSTrackingArea?
    var isHovered: Bool = false {
        didSet { updateVisualState() }
    }
    var isToolActive: Bool = false {
        didSet { updateVisualState() }
    }

    override var alignmentRectInsets: NSEdgeInsets { return NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { return NSSize(width: 32, height: 32) }
    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.setContentHuggingPriority(.required, for: .horizontal)
        updateVisualState()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaObj { removeTrackingArea(existing) }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        trackingAreaObj = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisualState()
    }

    func updateVisualState() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isToolActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
            contentTintColor = .controlAccentColor
        } else if isHovered {
            layer?.backgroundColor = isDark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.black.withAlphaComponent(0.08).cgColor
            contentTintColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .labelColor
        }
    }
}

class AnnotationColorSwatchView: NSView {
    let color: NSColor
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?

    override var intrinsicContentSize: NSSize { return NSSize(width: 22, height: 22) }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        self.wantsLayer = true
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dotRadius: CGFloat = 8.5
        let dotRect = NSRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // Luminance check to guarantee visibility on dark or light glass
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        if luminance < 0.22 {
            // Dark / Black swatch: crisp frosted white rim so it pops beautifully on dark glass!
            NSColor(white: 1.0, alpha: 0.45).setStroke()
            let rim = NSBezierPath(ovalIn: dotRect)
            rim.lineWidth = 0.75
            rim.stroke()
        } else if luminance > 0.82 {
            // White / bright swatch: subtle dark hairline rim
            NSColor(white: 0.0, alpha: 0.22).setStroke()
            let rim = NSBezierPath(ovalIn: dotRect)
            rim.lineWidth = 0.75
            rim.stroke()
        } else {
            NSColor(white: 0.0, alpha: 0.10).setStroke()
            let rim = NSBezierPath(ovalIn: dotRect)
            rim.lineWidth = 0.5
            rim.stroke()
        }

        if isSelected {
            let ringRadius: CGFloat = 10.5
            let ringRect = NSRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 1.8

            // Every color (including black) uses its OWN color for the spaced selection ring
            color.setStroke()
            ringPath.stroke()

            // For black/very dark colors, add a subtle hairline outer rim so the black ring is clearly defined on dark glass
            if luminance < 0.22 {
                NSColor.white.withAlphaComponent(0.40).setStroke()
                let outerRim = NSBezierPath(ovalIn: ringRect.insetBy(dx: -0.9, dy: -0.9))
                outerRim.lineWidth = 0.6
                outerRim.stroke()
            } else if luminance > 0.82 {
                NSColor.black.withAlphaComponent(0.20).setStroke()
                let outerRim = NSBezierPath(ovalIn: ringRect.insetBy(dx: -0.9, dy: -0.9))
                outerRim.lineWidth = 0.6
                outerRim.stroke()
            }
        }
    }
}

class AnnotationColorPickerButton: NSButton {
    var isCustomSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    override var alignmentRectInsets: NSEdgeInsets { return NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { return NSSize(width: 22, height: 22) }
    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.wantsLayer = true
        self.toolTip = "Custom Color Picker..."
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dotRadius: CGFloat = 8.5
        let dotRect = NSRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        let clipPath = CGPath(ellipseIn: dotRect, transform: nil)
        ctx?.addPath(clipPath)
        ctx?.clip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rainbowColors = [
            NSColor.systemRed.cgColor,
            NSColor.systemOrange.cgColor,
            NSColor.systemYellow.cgColor,
            NSColor.systemGreen.cgColor,
            NSColor.systemTeal.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.systemPurple.cgColor
        ] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: rainbowColors, locations: [0.0, 0.17, 0.33, 0.5, 0.67, 0.83, 1.0]) {
            ctx?.drawLinearGradient(gradient, start: CGPoint(x: dotRect.minX, y: dotRect.minY), end: CGPoint(x: dotRect.maxX, y: dotRect.maxY), options: [])
        }
        ctx?.restoreGState()

        NSColor.white.withAlphaComponent(0.40).setStroke()
        let rim = NSBezierPath(ovalIn: dotRect)
        rim.lineWidth = 0.5
        rim.stroke()

        if isCustomSelected {
            let ringRadius: CGFloat = 10.5
            let ringRect = NSRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 2.0
            NSColor.controlAccentColor.setStroke()
            ringPath.stroke()
        }
    }
}

class AnnotationGripView: NSView {
    override var mouseDownCanMoveWindow: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.toolTip = "Drag to Move Palette"
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dotColor = isDark ? NSColor(white: 1.0, alpha: 0.38) : NSColor(white: 0.0, alpha: 0.32)
        dotColor.setFill()

        // 6 dots: 2 columns of 3 dots (three on left, three on right)
        let col1X = bounds.midX - 3.5
        let col2X = bounds.midX + 3.5
        let centerY = bounds.midY
        let rowYs = [centerY - 6.5, centerY, centerY + 6.5]
        let dotRadius: CGFloat = 1.75

        for x in [col1X, col2X] {
            for y in rowYs {
                let rect = NSRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

class AnnotationActionButton: NSButton {
    private var trackingAreaObj: NSTrackingArea?
    var isHovered: Bool = false {
        didSet { updateAppearance() }
    }

    override var alignmentRectInsets: NSEdgeInsets { return NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { return NSSize(width: 32, height: 32) }
    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.setContentHuggingPriority(.required, for: .horizontal)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaObj { removeTrackingArea(existing) }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        trackingAreaObj = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isHovered {
            layer?.backgroundColor = isDark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.black.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        layer?.borderWidth = 0
        layer?.borderColor = nil
        contentTintColor = .labelColor
    }
}

class AnnotationDoneButton: NSButton {
    private var trackingAreaObj: NSTrackingArea?
    var isHovered: Bool = false {
        didSet { updateAppearance() }
    }

    override var alignmentRectInsets: NSEdgeInsets { return NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { return NSSize(width: 32, height: 32) }
    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.title = ""
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        let checkCfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .bold)
        self.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done (Esc)")?.withSymbolConfiguration(checkCfg)
        self.toolTip = "Done (Esc)"
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.setContentHuggingPriority(.required, for: .horizontal)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaObj { removeTrackingArea(existing) }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        trackingAreaObj = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isHovered {
            layer?.backgroundColor = isDark
                ? NSColor.white.withAlphaComponent(0.16).cgColor
                : NSColor.black.withAlphaComponent(0.08).cgColor
            contentTintColor = .controlAccentColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .labelColor
        }
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }
}

class AnnotationToolbarView: NSView {
    var toolbarEffectView: FloatingToolbarVisualEffectView?
    private var gripIcon: AnnotationGripView?
    private var toolButtons: [AnnotationTool: AnnotationToolbarButton] = [:]
    private var swatchViews: [AnnotationColorSwatchView] = []
    private var colorPickerBtn: AnnotationColorPickerButton!
    private var sizeButton: HoverIconButton!
    private(set) var neededWidth: CGFloat = 860.0

    override var mouseDownCanMoveWindow: Bool { return true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 860, height: 48))
        self.wantsLayer = true
        setupUI()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let height: CGFloat = 48.0

        let makeDivider = { () -> NSBox in
            let div = NSBox()
            div.boxType = .custom
            div.isTransparent = false
            div.borderWidth = 0
            div.fillColor = NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.14)
                    : NSColor.black.withAlphaComponent(0.08)
            })
            div.translatesAutoresizingMaskIntoConstraints = false
            div.widthAnchor.constraint(equalToConstant: 1).isActive = true
            div.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return div
        }

        // 1. Drag Grip (6 Dots: 3 on left, 3 on right with native performDrag)
        let gripIcon = AnnotationGripView(frame: NSRect(x: 0, y: 0, width: 18, height: 30))
        gripIcon.translatesAutoresizingMaskIntoConstraints = false
        gripIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        gripIcon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        // 2. Tool Buttons (All 8 tools evenly spaced, uniform 32x32)
        var toolViews: [NSView] = []
        let toolCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
        for tool in AnnotationTool.allCases {
            let btn = AnnotationToolbarButton(frame: .zero)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.displayName)?.withSymbolConfiguration(toolCfg)
            btn.toolTip = tool.displayName
            btn.target = self
            btn.action = #selector(toolButtonClicked(_:))
            btn.tag = tool.rawValue
            btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            toolButtons[tool] = btn
            toolViews.append(btn)
        }

        let toolStack = NSStackView(views: toolViews)
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        toolStack.orientation = .horizontal
        toolStack.distribution = .fillEqually
        toolStack.spacing = 6
        toolStack.alignment = .centerY

        // 3. Color Swatches + Color Picker
        var swatchList: [NSView] = []
        for item in annotationPresetColors {
            let swatch = AnnotationColorSwatchView(color: item.color)
            swatch.toolTip = item.name
            swatch.onClick = { [weak self] in
                AnnotationManager.shared.currentColor = item.color
                self?.updateColorSelection()
                AnnotationManager.shared.refreshAllCanvases()
            }
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 22).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 22).isActive = true
            swatchViews.append(swatch)
            swatchList.append(swatch)
        }

        // Custom Color Picker Button
        colorPickerBtn = AnnotationColorPickerButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        colorPickerBtn.translatesAutoresizingMaskIntoConstraints = false
        colorPickerBtn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        colorPickerBtn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        colorPickerBtn.target = self
        colorPickerBtn.action = #selector(openColorPicker)
        swatchList.append(colorPickerBtn)

        let colorStack = NSStackView(views: swatchList)
        colorStack.translatesAutoresizingMaskIntoConstraints = false
        colorStack.orientation = .horizontal
        colorStack.distribution = .fillEqually
        colorStack.spacing = 6
        colorStack.alignment = .centerY

        // 4. Size Toggle Button (Uniform 32x32)
        sizeButton = HoverIconButton()
        sizeButton.translatesAutoresizingMaskIntoConstraints = false
        sizeButton.isBordered = false
        sizeButton.imagePosition = .imageOnly
        sizeButton.wantsLayer = true
        sizeButton.layer?.cornerRadius = 8
        sizeButton.target = self
        sizeButton.action = #selector(cycleStrokeWidth)
        sizeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        sizeButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        sizeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeButton.setContentHuggingPriority(.required, for: .horizontal)
        updateSizeButtonIcon()

        // 5. Actions: Undo, Redo, Clear All (Uniform 32x32)
        let actCfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let undoBtn = AnnotationActionButton()
        undoBtn.translatesAutoresizingMaskIntoConstraints = false
        undoBtn.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")?.withSymbolConfiguration(actCfg)
        undoBtn.toolTip = "Undo (⌘Z)"
        undoBtn.target = self
        undoBtn.action = #selector(undoAction)
        undoBtn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        undoBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let redoBtn = AnnotationActionButton()
        redoBtn.translatesAutoresizingMaskIntoConstraints = false
        redoBtn.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")?.withSymbolConfiguration(actCfg)
        redoBtn.toolTip = "Redo (⇧⌘Z)"
        redoBtn.target = self
        redoBtn.action = #selector(redoAction)
        redoBtn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        redoBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let clearBtn = AnnotationActionButton()
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear All")?.withSymbolConfiguration(actCfg)
        clearBtn.toolTip = "Clear All Annotations (⌘K)"
        clearBtn.target = self
        clearBtn.action = #selector(clearAction)
        clearBtn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        clearBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let actionStack = NSStackView(views: [undoBtn, redoBtn, clearBtn])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.distribution = .fillEqually
        actionStack.spacing = 6
        actionStack.alignment = .centerY

        // 6. Done Button (Icon-only checkmark matching theme, uniform 32x32)
        let doneBtn = AnnotationDoneButton()
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.target = self
        doneBtn.action = #selector(doneAction)
        doneBtn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        doneBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        // Master Stack View with comfortable generous spacing
        let masterStack = NSStackView(views: [
            gripIcon,
            makeDivider(),
            toolStack,
            makeDivider(),
            colorStack,
            makeDivider(),
            sizeButton,
            makeDivider(),
            actionStack,
            makeDivider(),
            doneBtn
        ])
        masterStack.translatesAutoresizingMaskIntoConstraints = false
        masterStack.orientation = .horizontal
        masterStack.spacing = 12
        masterStack.alignment = .centerY

        // Compute needed width so nothing is ever squished or cramped
        masterStack.layoutSubtreeIfNeeded()
        let neededWidth = max(ceil(masterStack.fittingSize.width) + 36.0, 860.0)
        self.neededWidth = neededWidth

        // Shadow container matching main FloatingPanel HUD
        let shadowContainer = NSView(frame: NSRect(x: 0, y: 0, width: neededWidth, height: height))
        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.wantsLayer = true
        shadowContainer.layer?.masksToBounds = false
        shadowContainer.layer?.shadowColor = NSColor.black.cgColor
        shadowContainer.layer?.shadowOpacity = 0.10
        shadowContainer.layer?.shadowRadius = 6.0
        shadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -2)

        // Frosted Glass Effect matching main FloatingToolbarVisualEffectView (popover material, 85% opacity in dark/light)
        let effectView = FloatingToolbarVisualEffectView()
        self.toolbarEffectView = effectView
        self.gripIcon = gripIcon
        effectView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor)
        ])

        effectView.addSubview(masterStack)
        NSLayoutConstraint.activate([
            masterStack.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            masterStack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            masterStack.leadingAnchor.constraint(greaterThanOrEqualTo: effectView.leadingAnchor, constant: 16),
            masterStack.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -16)
        ])

        addSubview(shadowContainer)
        NSLayoutConstraint.activate([
            shadowContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            shadowContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            shadowContainer.topAnchor.constraint(equalTo: topAnchor),
            shadowContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateSelection()
    }

    @objc private func openColorPicker() {
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.sharingType = .none
        panel.color = AnnotationManager.shared.currentColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        AnnotationManager.shared.currentColor = sender.color
        updateColorSelection()
        AnnotationManager.shared.refreshAllCanvases()
    }

    @objc private func toolButtonClicked(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        AnnotationManager.shared.currentTool = tool
        updateToolSelection()
        AnnotationManager.shared.refreshAllCanvases()
    }

    @objc private func cycleStrokeWidth() {
        let current = AnnotationManager.shared.currentWidth
        let next: AnnotationStrokeWidth
        switch current {
        case .thin: next = .medium
        case .medium: next = .thick
        case .thick: next = .thin
        }
        AnnotationManager.shared.currentWidth = next
        updateSizeButtonIcon()
        AnnotationManager.shared.refreshAllCanvases()
    }

    @objc private func undoAction() {
        AnnotationManager.shared.undo()
    }

    @objc private func redoAction() {
        AnnotationManager.shared.redo()
    }

    @objc private func clearAction() {
        AnnotationManager.shared.clearAll()
    }

    @objc private func doneAction() {
        AnnotationManager.shared.stopAnnotationMode()
    }

    func updateColors() {
        toolbarEffectView?.updateColors()
        gripIcon?.needsDisplay = true
        for swatch in swatchViews { swatch.needsDisplay = true }
        colorPickerBtn?.needsDisplay = true
        for (_, btn) in toolButtons { btn.updateVisualState() }
    }

    func updateSelection() {
        updateToolSelection()
        updateColorSelection()
        updateSizeButtonIcon()
    }

    func updateToolSelection() {
        let activeTool = AnnotationManager.shared.currentTool
        for (tool, btn) in toolButtons {
            btn.isToolActive = (tool == activeTool)
        }
    }

    func updateColorSelection() {
        let activeColor = AnnotationManager.shared.currentColor
        var matchedPreset = false
        for swatch in swatchViews {
            let matches = (swatch.color == activeColor)
            swatch.isSelected = matches
            if matches { matchedPreset = true }
        }
        colorPickerBtn?.isCustomSelected = !matchedPreset
    }

    func updateSizeButtonIcon() {
        let widthEnum = AnnotationManager.shared.currentWidth
        sizeButton.toolTip = "Stroke Width: \(widthEnum.title) (Click to cycle)"

        let ptSize: CGFloat
        switch widthEnum {
        case .thin: ptSize = 7
        case .medium: ptSize = 11
        case .thick: ptSize = 15
        }
        let dotCfg = NSImage.SymbolConfiguration(pointSize: ptSize, weight: .bold)
        sizeButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: widthEnum.title)?.withSymbolConfiguration(dotCfg)
        sizeButton.contentTintColor = .labelColor
    }
}

// MARK: - Annotation Manager (Coordinator & Controller)

class AnnotationManager {
    static let shared = AnnotationManager()

    var isActive: Bool = false
    var currentTool: AnnotationTool = .pen
    var currentColor: NSColor = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
    var currentWidth: AnnotationStrokeWidth = .medium

    var strokes: [AnnotationStroke] = []
    var redoStack: [[AnnotationStroke]] = []

    var canvasWindows: [AnnotationCanvasWindow] = []
    var toolbarView: AnnotationToolbarView? {
        return (NSApp.delegate as? AppDelegate)?.annotationToolbarView
    }

    private var magicTimer: Timer?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private init() {}

    func startAnnotationMode() {
        guard !isActive else { return }
        isActive = true

        // 1. Create fullscreen canvas overlay for all monitors
        for screen in NSScreen.screens {
            let win = AnnotationCanvasWindow(screen: screen)
            win.orderFrontRegardless()
            canvasWindows.append(win)
        }

        // 2. Attach annotation HUD tier on top of FloatingPanel as one unified entity
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            delegate.panel.orderFrontRegardless()
            delegate.isAnnotationActive = true
            delegate.updateHUDLayout()
            delegate.updateAnnotationButtonState()

            delegate.recorder.annotationCanvasWindowIDs = canvasWindows.compactMap { $0.windowNumber }
            delegate.recorder.updateStreamFilter()
        }

        setupGlobalHotkeys()
    }

    func stopAnnotationMode() {
        guard isActive else { return }
        isActive = false

        for win in canvasWindows {
            win.close()
        }
        canvasWindows.removeAll()

        if NSColorPanel.sharedColorPanelExists {
            NSColorPanel.shared.close()
        }

        magicTimer?.invalidate()
        magicTimer = nil

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.panel.level = .floating
            delegate.isAnnotationActive = false
            delegate.updateHUDLayout()
            delegate.updateAnnotationButtonState()

            delegate.recorder.annotationCanvasWindowIDs.removeAll()
            delegate.recorder.updateStreamFilter()
        }
    }

    func toggleAnnotationMode() {
        if isActive {
            stopAnnotationMode()
        } else {
            startAnnotationMode()
        }
    }

    func addStroke(_ stroke: AnnotationStroke) {
        strokes.append(stroke)
        redoStack.removeAll()
        if stroke.tool == .magicWriter {
            startMagicTimerIfNeeded()
        }
        for win in canvasWindows {
            let origin = win.frame.origin
            let r = stroke.boundingRect(screenOrigin: origin)
            if r != .zero {
                win.contentView?.setNeedsDisplay(r)
            }
        }
    }

    func eraseStrokes(near screenPoint: NSPoint, radius: CGFloat) {
        var hitAny = false
        var remaining: [AnnotationStroke] = []
        var erased: [AnnotationStroke] = []

        for stroke in strokes {
            if stroke.hitTest(screenPoint: screenPoint, radius: radius) {
                hitAny = true
                erased.append(stroke)
            } else {
                remaining.append(stroke)
            }
        }

        if hitAny {
            redoStack.append(erased)
            strokes = remaining
            for win in canvasWindows {
                let origin = win.frame.origin
                var dirty = NSRect.zero
                for s in erased {
                    let r = s.boundingRect(screenOrigin: origin)
                    dirty = (dirty == .zero) ? r : dirty.union(r)
                }
                if dirty != .zero {
                    win.contentView?.setNeedsDisplay(dirty)
                }
            }
        }
    }

    func eraseStrokesAlongLine(from start: NSPoint, to end: NSPoint, radius: CGFloat) {
        let dist = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int(ceil(dist / 8.0)))
        var hitAny = false
        var remaining: [AnnotationStroke] = []
        var erased: [AnnotationStroke] = []

        for stroke in strokes {
            var strokeHit = false
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let pt = NSPoint(x: start.x + t * (end.x - start.x), y: start.y + t * (end.y - start.y))
                if stroke.hitTest(screenPoint: pt, radius: radius) {
                    strokeHit = true
                    break
                }
            }
            if strokeHit {
                hitAny = true
                erased.append(stroke)
            } else {
                remaining.append(stroke)
            }
        }

        if hitAny {
            redoStack.append(erased)
            strokes = remaining
            for win in canvasWindows {
                let origin = win.frame.origin
                var dirty = NSRect.zero
                for s in erased {
                    let r = s.boundingRect(screenOrigin: origin)
                    dirty = (dirty == .zero) ? r : dirty.union(r)
                }
                if dirty != .zero {
                    win.contentView?.setNeedsDisplay(dirty)
                }
            }
        }
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        let popped = strokes.removeLast()
        redoStack.append([popped])
        refreshAllCanvases()
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        let toRestore = redoStack.removeLast()
        strokes.append(contentsOf: toRestore)
        refreshAllCanvases()
    }

    func clearAll() {
        guard !strokes.isEmpty else { return }
        redoStack.append(strokes)
        strokes.removeAll()
        refreshAllCanvases()
    }

    func refreshAllCanvases() {
        for win in canvasWindows {
            win.contentView?.needsDisplay = true
        }
    }

    func handleScreenParametersChanged() {
        guard isActive else { return }
        for win in canvasWindows { win.close() }
        canvasWindows.removeAll()
        for screen in NSScreen.screens {
            let win = AnnotationCanvasWindow(screen: screen)
            win.orderFrontRegardless()
            canvasWindows.append(win)
        }
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.recorder.annotationCanvasWindowIDs = canvasWindows.compactMap { $0.windowNumber }
            delegate.recorder.updateStreamFilter()
        }
        refreshAllCanvases()
    }

    func startMagicTimerIfNeeded() {
        guard magicTimer == nil else { return }
        // 30 FPS timer cuts CPU wakeups in half while maintaining silky-smooth fading trails
        magicTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickMagicWriter()
        }
    }

    private func tickMagicWriter() {
        let now = Date()
        var hasVanishing = false
        var changedStrokes: [AnnotationStroke] = []

        strokes.removeAll { stroke in
            if stroke.tool == .magicWriter {
                let age = now.timeIntervalSince(stroke.createdAt)
                if age >= 2.2 {
                    changedStrokes.append(stroke)
                    return true // Disappear completely
                } else if age >= 1.2 {
                    stroke.opacity = max(0.0, 1.0 - CGFloat((age - 1.2) / 1.0))
                    hasVanishing = true
                    changedStrokes.append(stroke)
                } else {
                    hasVanishing = true
                }
            }
            return false
        }

        if !changedStrokes.isEmpty {
            for win in canvasWindows {
                let origin = win.frame.origin
                var dirty = NSRect.zero
                for s in changedStrokes {
                    let r = s.boundingRect(screenOrigin: origin)
                    dirty = (dirty == .zero) ? r : dirty.union(r)
                }
                if dirty != .zero {
                    win.contentView?.setNeedsDisplay(dirty)
                }
            }
        }

        if !hasVanishing {
            magicTimer?.invalidate()
            magicTimer = nil
        }
    }

    func setupGlobalHotkeys() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                // ⌥A (Option + A, keyCode 0) toggles annotation mode anytime
                if event.modifierFlags.contains(.option) && event.keyCode == 0 {
                    self.toggleAnnotationMode()
                    return nil
                }
                if self.isActive {
                    if event.keyCode == 53 { // Esc
                        self.stopAnnotationMode()
                        return nil
                    }
                    let isCmd = event.modifierFlags.contains(.command)
                    let isShift = event.modifierFlags.contains(.shift)

                    if isCmd && !isShift && event.charactersIgnoringModifiers == "z" {
                        self.undo()
                        return nil
                    }
                    if isCmd && isShift && event.charactersIgnoringModifiers?.lowercased() == "z" {
                        self.redo()
                        return nil
                    }
                    if isCmd && event.charactersIgnoringModifiers == "k" {
                        self.clearAll()
                        return nil
                    }

                    // Keys 1..8 for tools
                    if let chars = event.charactersIgnoringModifiers, let num = Int(chars), (1...8).contains(num) {
                        let tool = AnnotationTool(rawValue: num - 1) ?? .pen
                        self.currentTool = tool
                        self.toolbarView?.updateSelection()
                        self.refreshAllCanvases()
                        return nil
                    }
                }
                return event
            }
        }

        if globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.modifierFlags.contains(.option) && event.keyCode == 0 {
                    DispatchQueue.main.async {
                        self?.toggleAnnotationMode()
                    }
                }
            }
        }
    }

    func removeGlobalHotkeys() {
        if let l = localKeyMonitor {
            NSEvent.removeMonitor(l)
            localKeyMonitor = nil
        }
        if let g = globalKeyMonitor {
            NSEvent.removeMonitor(g)
            globalKeyMonitor = nil
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
    var isPaused = false
    var isMicMuted = false
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
    var annotationCanvasWindowIDs: [Int] = []
    var statusItemWindowID: Int?
    var statusItemFrame: CGRect?
    
    private var targetScreenID: CGDirectDisplayID?
    private var targetScaleFactor: CGFloat = 1.0

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    var onSystemAudioLevel: ((Float) -> Void)?
    var onMicAudioLevel: ((Float) -> Void)?

    func startRecording() {
        if isRecording { return }
        isPaused = false
        isMicMuted = false
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
                if self.annotationCanvasWindowIDs.contains(Int(window.windowID)) { continue }
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
                if self.annotationCanvasWindowIDs.contains(Int(window.windowID)) { continue }
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
            
            // Calculate system audio level for live visual feedback
            if let blockBuffer = CMSampleBufferGetDataBuffer(adjustedBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
                   let dataPointer = dataPointer, length > 0 {
                    let floatCount = length / MemoryLayout<Float>.size
                    if floatCount > 0 {
                        let floatPtr = UnsafeMutableRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
                        var sum: Float = 0
                        let strideVal = max(1, floatCount / 64)
                        var samplesCount = 0
                        for i in stride(from: 0, to: floatCount, by: strideVal) {
                            let val = floatPtr[i]
                            sum += val * val
                            samplesCount += 1
                        }
                        let rms = samplesCount > 0 ? sqrt(sum / Float(samplesCount)) : 0
                        let db: Float = rms > 0.0001 ? 20.0 * log10(rms) : -100.0
                        DispatchQueue.main.async { self.onSystemAudioLevel?(db) }
                    }
                }
            }
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
        let muted = isMicMuted
        let pausedOffset = totalPausedDuration
        writerLock.unlock()
        
        guard recording else { return }
        guard !paused else { return }
        guard assetWriter != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(pts) > 0 else { return }

        guard let adjustedBuffer = adjustSampleBuffer(sampleBuffer, offset: pausedOffset) else { return }

        if muted {
            // Write absolute silence to PCM buffer so timestamps and AV sync remain perfectly locked
            if let blockBuffer = CMSampleBufferGetDataBuffer(adjustedBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
                   let dataPointer = dataPointer {
                    memset(dataPointer, 0, length)
                }
            }
        }

        writerLock.lock()
        defer { writerLock.unlock() }

        if sessionStartTime != .invalid {
            if let micInput = micInput, micInput.isReadyForMoreMediaData { micInput.append(adjustedBuffer) }
        }
        
        if let channel = connection.audioChannels.first {
            let level = muted ? -100.0 : channel.averagePowerLevel
            DispatchQueue.main.async { self.onMicAudioLevel?(level) }
        }
    }

    func toggleMicMute() -> Bool {
        writerLock.lock()
        isMicMuted.toggle()
        let state = isMicMuted
        writerLock.unlock()
        return state
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

class FloatingToolbarVisualEffectView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        material = .popover
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 18
        if #available(macOS 10.15, *) {
            layer?.cornerCurve = .continuous
        }
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        } else {
            // Balanced 85% opacity frosted surface in light mode
            layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.85).cgColor
            layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        }
    }
}

class FloatingHUDContainerView: NSView {
    weak var mainShadowContainer: NSView?
    weak var annotationToolbarView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self {
            return nil
        }
        if let main = mainShadowContainer, let hit = hit, hit.isDescendant(of: main) {
            return hit
        }
        if let annot = annotationToolbarView, let hit = hit, hit.isDescendant(of: annot) {
            return hit
        }
        return nil
    }
}

class FloatingPanel: NSPanel {
    var rootContainer: FloatingHUDContainerView!
    var mainShadowContainer: NSView!
    var toolbarEffectView: FloatingToolbarVisualEffectView?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView], backing: backingStoreType, defer: flag)
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.sharingType = .none
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        let root = FloatingHUDContainerView(frame: contentRect)
        root.wantsLayer = true
        self.rootContainer = root

        let shadowContainer = NSView()
        shadowContainer.wantsLayer = true
        shadowContainer.layer?.masksToBounds = false
        shadowContainer.layer?.shadowColor = NSColor.black.cgColor
        shadowContainer.layer?.shadowOpacity = 0.10
        shadowContainer.layer?.shadowRadius = 6.0
        shadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -2)
        self.mainShadowContainer = shadowContainer

        let effectView = FloatingToolbarVisualEffectView()
        effectView.translatesAutoresizingMaskIntoConstraints = false
        self.toolbarEffectView = effectView

        shadowContainer.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor)
        ])

        root.addSubview(shadowContainer)
        root.mainShadowContainer = shadowContainer

        self.contentView = root
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

enum TrimMode: Int {
    case trimIn = 0   // Keep Selection (standard)
    case trimOut = 1  // Cut Out Section (new)
}

struct TrimBlock: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double

    init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = max(0, start)
        self.end = max(start, end)
    }

    static func == (lhs: TrimBlock, rhs: TrimBlock) -> Bool {
        return lhs.id == rhs.id
    }
}

class TrimRangeSliderView: NSView {
    var trimMode: TrimMode = .trimIn {
        didSet { needsDisplay = true }
    }
    var duration: Double = 1.0 {
        didSet {
            normalizeBlocks()
            needsDisplay = true
        }
    }
    var blocks: [TrimBlock] = [TrimBlock(start: 0.0, end: 1.0)] {
        didSet {
            if activeBlockIndex >= blocks.count {
                activeBlockIndex = max(0, blocks.count - 1)
            }
            needsDisplay = true
        }
    }
    var activeBlockIndex: Int = 0 {
        didSet { needsDisplay = true }
    }

    var startTime: Double {
        get {
            guard activeBlockIndex < blocks.count else { return 0 }
            return blocks[activeBlockIndex].start
        }
        set {
            if blocks.isEmpty {
                blocks = [TrimBlock(start: newValue, end: duration)]
                activeBlockIndex = 0
            } else {
                let idx = min(activeBlockIndex, blocks.count - 1)
                blocks[idx].start = max(0, min(blocks[idx].end - 0.2, newValue))
            }
            needsDisplay = true
        }
    }

    var endTime: Double {
        get {
            guard activeBlockIndex < blocks.count else { return duration }
            return blocks[activeBlockIndex].end
        }
        set {
            if blocks.isEmpty {
                blocks = [TrimBlock(start: 0, end: newValue)]
                activeBlockIndex = 0
            } else {
                let idx = min(activeBlockIndex, blocks.count - 1)
                blocks[idx].end = min(duration, max(blocks[idx].start + 0.2, newValue))
            }
            needsDisplay = true
        }
    }

    var currentTime: Double = 0.0 {
        didSet { needsDisplay = true }
    }

    var onTrimChanged: ((Double, Double) -> Void)?
    var onTrimBlocksChanged: (([TrimBlock], Int) -> Void)?
    var onSeek: ((Double, Bool) -> Void)?
    var onBlockSelected: ((Int) -> Void)?
    var onBlockDeleted: ((Int) -> Void)?
    var onAddBlockRequested: ((Double) -> Void)?

    private enum DragTarget: Equatable {
        case none
        case startHandle(Int)
        case endHandle(Int)
        case blockBody(Int, Double)
        case playhead
    }
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

    private func normalizeBlocks() {
        guard duration > 0 else { return }
        if blocks.isEmpty {
            blocks = [TrimBlock(start: 0, end: duration)]
            activeBlockIndex = 0
            return
        }
        for i in 0..<blocks.count {
            blocks[i].start = max(0, min(duration - 0.2, blocks[i].start))
            blocks[i].end = min(duration, max(blocks[i].start + 0.2, blocks[i].end))
        }
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
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        ctx.fill(b)

        let notchH: CGFloat = 12

        if trimMode == .trimIn {
            // Trim In: Non-kept area is shaded dark
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
            ctx.fill(b)

            // Draw each keep block
            for (idx, block) in blocks.enumerated() {
                let startX = xForTime(block.start) - handleWidth
                let endX = xForTime(block.end) + handleWidth
                let selWidth = max(handleWidth * 2, endX - startX)
                let selRect = NSRect(x: startX, y: 0, width: selWidth, height: b.height)
                let isActive = (idx == activeBlockIndex)

                let yellowColor = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.0, alpha: 1.0)
                let bgAlpha: CGFloat = isActive ? 0.26 : 0.13
                let borderAlpha: CGFloat = isActive ? 1.0 : 0.55
                let lineWidth: CGFloat = isActive ? 2.5 : 1.5

                ctx.setFillColor(yellowColor.withAlphaComponent(bgAlpha).cgColor)
                ctx.fill(selRect)

                ctx.setStrokeColor(yellowColor.withAlphaComponent(borderAlpha).cgColor)
                ctx.setLineWidth(lineWidth)
                ctx.stroke(NSRect(x: startX, y: 1, width: selWidth, height: b.height - 2))

                // Left Handle
                let leftHandleRect = NSRect(x: startX, y: 0, width: handleWidth, height: b.height)
                ctx.setFillColor(yellowColor.withAlphaComponent(isActive ? 1.0 : 0.70).cgColor)
                let leftPath = CGPath(roundedRect: leftHandleRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(leftPath)
                ctx.fillPath()

                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fill(NSRect(x: leftHandleRect.midX - 1, y: (b.height - notchH) / 2, width: 2, height: notchH))

                // Right Handle
                let rightHandleRect = NSRect(x: endX - handleWidth, y: 0, width: handleWidth, height: b.height)
                ctx.setFillColor(yellowColor.withAlphaComponent(isActive ? 1.0 : 0.70).cgColor)
                let rightPath = CGPath(roundedRect: rightHandleRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(rightPath)
                ctx.fillPath()

                ctx.fill(NSRect(x: rightHandleRect.midX - 1, y: (b.height - notchH) / 2, width: 2, height: notchH))

                if selWidth >= 52 {
                    let labelText = (blocks.count > 1 ? "KEEP #\(idx + 1)" : "KEEP") as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                        .foregroundColor: yellowColor.withAlphaComponent(isActive ? 1.0 : 0.75)
                    ]
                    let txtSize = labelText.size(withAttributes: attrs)
                    let txtRect = NSRect(x: selRect.midX - txtSize.width / 2, y: (b.height - txtSize.height) / 2, width: txtSize.width, height: txtSize.height)
                    labelText.draw(in: txtRect, withAttributes: attrs)
                }
            }
        } else {
            // Trim Out Mode (Cut Out): Retained slices in subtle green
            let sortedCuts = blocks.sorted(by: { $0.start < $1.start })
            var currentPos: Double = 0.0
            var keptSlices: [(Double, Double)] = []
            for c in sortedCuts {
                if c.start > currentPos {
                    keptSlices.append((currentPos, c.start))
                }
                currentPos = max(currentPos, c.end)
            }
            if duration > currentPos {
                keptSlices.append((currentPos, duration))
            }

            for slice in keptSlices {
                let kStartX = xForTime(slice.0)
                let kEndX = xForTime(slice.1)
                let kW = max(0, kEndX - kStartX)
                if kW > 0 {
                    let keptRect = NSRect(x: kStartX, y: 0, width: kW, height: b.height)
                    ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.12).cgColor)
                    ctx.fill(keptRect)
                    ctx.setStrokeColor(NSColor.systemGreen.withAlphaComponent(0.50).cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(NSRect(x: kStartX, y: b.height - 2, width: kW, height: 1))
                }
            }

            for (idx, block) in blocks.enumerated() {
                let startX = xForTime(block.start) - handleWidth
                let endX = xForTime(block.end) + handleWidth
                let selWidth = max(handleWidth * 2, endX - startX)
                let selRect = NSRect(x: startX, y: 0, width: selWidth, height: b.height)
                let isActive = (idx == activeBlockIndex)

                let redColor = NSColor(srgbRed: 0.96, green: 0.26, blue: 0.26, alpha: 1.0)
                let bgAlpha: CGFloat = isActive ? 0.26 : 0.14
                let borderAlpha: CGFloat = isActive ? 1.0 : 0.60
                let lineWidth: CGFloat = isActive ? 2.5 : 1.5

                ctx.setFillColor(redColor.withAlphaComponent(bgAlpha).cgColor)
                ctx.fill(selRect)

                ctx.saveGState()
                ctx.clip(to: selRect)
                ctx.setStrokeColor(redColor.withAlphaComponent(isActive ? 0.24 : 0.14).cgColor)
                ctx.setLineWidth(2.0)
                let stripeSpacing: CGFloat = 11.0
                var curX = selRect.minX - selRect.height
                while curX < selRect.maxX + selRect.height {
                    ctx.move(to: CGPoint(x: curX, y: 0))
                    ctx.addLine(to: CGPoint(x: curX + selRect.height, y: selRect.height))
                    curX += stripeSpacing
                }
                ctx.strokePath()

                if selWidth >= 52 {
                    let labelText = (blocks.count > 1 ? "CUT #\(idx + 1)" : "CUT OUT") as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                        .foregroundColor: NSColor(srgbRed: 1.0, green: 0.40, blue: 0.40, alpha: isActive ? 1.0 : 0.75)
                    ]
                    let txtSize = labelText.size(withAttributes: attrs)
                    let txtRect = NSRect(x: selRect.midX - txtSize.width / 2, y: (b.height - txtSize.height) / 2, width: txtSize.width, height: txtSize.height)
                    labelText.draw(in: txtRect, withAttributes: attrs)
                }
                ctx.restoreGState()

                ctx.setStrokeColor(redColor.withAlphaComponent(borderAlpha).cgColor)
                ctx.setLineWidth(lineWidth)
                ctx.stroke(NSRect(x: startX, y: 1, width: selWidth, height: b.height - 2))

                let leftHandleRect = NSRect(x: startX, y: 0, width: handleWidth, height: b.height)
                ctx.setFillColor(redColor.withAlphaComponent(isActive ? 1.0 : 0.70).cgColor)
                let leftPath = CGPath(roundedRect: leftHandleRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(leftPath)
                ctx.fillPath()

                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fill(NSRect(x: leftHandleRect.midX - 1, y: (b.height - notchH) / 2, width: 2, height: notchH))

                let rightHandleRect = NSRect(x: endX - handleWidth, y: 0, width: handleWidth, height: b.height)
                ctx.setFillColor(redColor.withAlphaComponent(isActive ? 1.0 : 0.70).cgColor)
                let rightPath = CGPath(roundedRect: rightHandleRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(rightPath)
                ctx.fillPath()

                ctx.fill(NSRect(x: rightHandleRect.midX - 1, y: (b.height - notchH) / 2, width: 2, height: notchH))
            }
        }

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
    override var acceptsFirstResponder: Bool { return true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)

        // Check if double click on empty area -> request add block
        if event.clickCount == 2 {
            let clickTime = timeForX(loc.x)
            let insideExisting = blocks.contains(where: { clickTime >= $0.start && clickTime <= $0.end })
            if !insideExisting {
                onAddBlockRequested?(clickTime)
                return
            }
        }

        // 1. Check handles of active block first
        if activeBlockIndex < blocks.count {
            let b = blocks[activeBlockIndex]
            let startX = xForTime(b.start)
            let endX = xForTime(b.end)
            if abs(loc.x - (startX - handleWidth / 2)) <= handleWidth + 8 {
                currentDrag = .startHandle(activeBlockIndex)
                return
            } else if abs(loc.x - (endX + handleWidth / 2)) <= handleWidth + 8 {
                currentDrag = .endHandle(activeBlockIndex)
                return
            }
        }

        // 2. Check handles of other blocks
        for (i, b) in blocks.enumerated() {
            if i == activeBlockIndex { continue }
            let startX = xForTime(b.start)
            let endX = xForTime(b.end)
            if abs(loc.x - (startX - handleWidth / 2)) <= handleWidth + 8 {
                activeBlockIndex = i
                currentDrag = .startHandle(i)
                onBlockSelected?(i)
                notifyTrimChanged()
                needsDisplay = true
                return
            } else if abs(loc.x - (endX + handleWidth / 2)) <= handleWidth + 8 {
                activeBlockIndex = i
                currentDrag = .endHandle(i)
                onBlockSelected?(i)
                notifyTrimChanged()
                needsDisplay = true
                return
            }
        }

        // 3. Check inside any block body (for sliding or selecting)
        for (i, b) in blocks.enumerated() {
            let startX = xForTime(b.start) - handleWidth
            let endX = xForTime(b.end) + handleWidth
            if loc.x >= startX && loc.x <= endX {
                activeBlockIndex = i
                onBlockSelected?(i)
                let clickTime = timeForX(loc.x)
                currentDrag = .blockBody(i, clickTime - b.start)
                currentTime = clickTime
                notifyTrimChanged()
                needsDisplay = true
                onSeek?(clickTime, true)
                return
            }
        }

        // 4. Click outside blocks -> scrub playhead
        currentDrag = .playhead
        let t = timeForX(loc.x)
        currentTime = t
        needsDisplay = true
        onSeek?(t, true)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let t = timeForX(loc.x)

        switch currentDrag {
        case .startHandle(let idx):
            guard idx < blocks.count else { break }
            let minStart: Double = idx > 0 ? (blocks[idx - 1].end + 0.1) : 0.0
            let maxStart: Double = blocks[idx].end - 0.2
            let clampedStart = max(minStart, min(maxStart, t))
            blocks[idx].start = clampedStart
            currentTime = clampedStart
            notifyTrimChanged()
            onSeek?(clampedStart, false)

        case .endHandle(let idx):
            guard idx < blocks.count else { break }
            let minEnd: Double = blocks[idx].start + 0.2
            let maxEnd: Double = idx < (blocks.count - 1) ? (blocks[idx + 1].start - 0.1) : duration
            let clampedEnd = min(maxEnd, max(minEnd, t))
            blocks[idx].end = clampedEnd
            currentTime = clampedEnd
            notifyTrimChanged()
            onSeek?(clampedEnd, false)

        case .blockBody(let idx, let offset):
            guard idx < blocks.count else { break }
            let dur = blocks[idx].end - blocks[idx].start
            let desiredStart = t - offset
            let minStart: Double = idx > 0 ? (blocks[idx - 1].end + 0.1) : 0.0
            let maxEnd: Double = idx < (blocks.count - 1) ? (blocks[idx + 1].start - 0.1) : duration
            let maxStart: Double = maxEnd - dur
            if maxStart >= minStart {
                let clampedStart = max(minStart, min(maxStart, desiredStart))
                blocks[idx].start = clampedStart
                blocks[idx].end = clampedStart + dur
                currentTime = clampedStart
                notifyTrimChanged()
                onSeek?(currentTime, false)
            }

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

    override func keyDown(with event: NSEvent) {
        // Delete or Backspace key
        if event.keyCode == 51 || event.keyCode == 117 {
            if blocks.count > 1 {
                onBlockDeleted?(activeBlockIndex)
                return
            }
        }
        // Tab key -> cycle to next block
        if event.keyCode == 48 {
            if !blocks.isEmpty {
                activeBlockIndex = (activeBlockIndex + 1) % blocks.count
                onBlockSelected?(activeBlockIndex)
                notifyTrimChanged()
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }

    private func notifyTrimChanged() {
        guard activeBlockIndex < blocks.count else { return }
        let b = blocks[activeBlockIndex]
        onTrimChanged?(b.start, b.end)
        onTrimBlocksChanged?(blocks, activeBlockIndex)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for b in blocks {
            let startX = xForTime(b.start) - handleWidth
            let endX = xForTime(b.end) + handleWidth
            addCursorRect(NSRect(x: startX - 4, y: 0, width: handleWidth + 8, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: endX - handleWidth - 4, y: 0, width: handleWidth + 8, height: bounds.height), cursor: .resizeLeftRight)
            let bodyW = (endX - handleWidth) - (startX + handleWidth)
            if bodyW > 0 {
                addCursorRect(NSRect(x: startX + handleWidth, y: 0, width: bodyW, height: bounds.height), cursor: .openHand)
            }
        }
    }
}

// ============================================================
// Multi-Clip Sequence Model & Views for Video Stitching
// ============================================================

class VideoClipItem: NSObject {
    let id: UUID = UUID()
    var url: URL
    var title: String
    var duration: Double = 0.0
    var naturalSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var thumbnail: NSImage?
    var startTime: Double = 0.0
    var endTime: Double = 0.0
    var isMuted: Bool = false

    var effectiveDuration: Double {
        if endTime > startTime && endTime <= (duration + 0.05) {
            return endTime - startTime
        }
        return max(0.01, duration)
    }

    init(url: URL) {
        self.url = url
        self.title = url.lastPathComponent
        super.init()
    }
}

class TrimmerContainerView: NSVisualEffectView {
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL
        ])
    }

    private func extractVideoURLs(from sender: NSDraggingInfo) -> [URL] {
        let pboard = sender.draggingPasteboard
        var urls: [URL] = []
        let videoExts = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"])

        if let items = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for u in items {
                if videoExts.contains(u.pathExtension.lowercased()) {
                    urls.append(u)
                }
            }
        }

        if urls.isEmpty, let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for p in paths {
                let u = URL(fileURLWithPath: p)
                if videoExts.contains(u.pathExtension.lowercased()) {
                    urls.append(u)
                }
            }
        }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = extractVideoURLs(from: sender)
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = extractVideoURLs(from: sender)
        return urls.isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !extractVideoURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = extractVideoURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}

class ClipCardView: NSView, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("com.rec.clipcard.index")

    let clip: VideoClipItem
    let clipIndex: Int
    let totalClips: Int
    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    var onSelect: (() -> Void)?
    var onMoveLeft: (() -> Void)?
    var onMoveRight: (() -> Void)?
    var onRemove: (() -> Void)?
    var onDragDropReorder: ((Int, Int) -> Void)?
    var onToggleMute: (() -> Void)?
    var onEditInNewWindow: (() -> Void)?

    private let thumbView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let muteBadge = NSImageView()
    private let moveLeftBtn = NSButton()
    private let moveRightBtn = NSButton()
    private let removeBtn = NSButton()
    private var isHovered: Bool = false
    private var dragStartLocation: NSPoint?

    init(clip: VideoClipItem, index: Int, totalClips: Int, isActive: Bool) {
        self.clip = clip
        self.clipIndex = index
        self.totalClips = totalClips
        self.isActive = isActive
        super.init(frame: .zero)
        setupUI()
        updateAppearance()
        registerForDraggedTypes([ClipCardView.dragType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 180).isActive = true
        heightAnchor.constraint(equalToConstant: 54).isActive = true

        // Thumbnail
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.masksToBounds = true
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        if let thumb = clip.thumbnail {
            thumbView.image = thumb
        } else {
            let symConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            thumbView.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?.withSymbolConfiguration(symConfig)
            thumbView.contentTintColor = .secondaryLabelColor
        }
        addSubview(thumbView)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.stringValue = "#\(clipIndex + 1) \(clip.title)"
        addSubview(titleLabel)

        // Duration
        let mins = Int(clip.duration) / 60
        let secs = Int(clip.duration) % 60
        let tenths = Int((clip.duration.truncatingRemainder(dividingBy: 1)) * 10)
        durationLabel.stringValue = String(format: "%02d:%02d.%01d", mins, secs, tenths)
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        durationLabel.textColor = clip.isMuted ? .systemOrange : .secondaryLabelColor
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(durationLabel)

        // Mute Badge
        muteBadge.translatesAutoresizingMaskIntoConstraints = false
        let muteSym = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        muteBadge.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")?.withSymbolConfiguration(muteSym)
        muteBadge.contentTintColor = .systemOrange
        muteBadge.toolTip = "Audio muted for this clip (Right-click to unmute)"
        muteBadge.isHidden = !clip.isMuted
        addSubview(muteBadge)

        // Buttons
        let btnConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        moveLeftBtn.translatesAutoresizingMaskIntoConstraints = false
        moveLeftBtn.bezelStyle = .inline
        moveLeftBtn.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Move Before")?.withSymbolConfiguration(btnConfig)
        moveLeftBtn.toolTip = "Move clip before"
        moveLeftBtn.target = self
        moveLeftBtn.action = #selector(leftClicked)
        moveLeftBtn.isEnabled = clipIndex > 0
        addSubview(moveLeftBtn)

        moveRightBtn.translatesAutoresizingMaskIntoConstraints = false
        moveRightBtn.bezelStyle = .inline
        moveRightBtn.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Move After")?.withSymbolConfiguration(btnConfig)
        moveRightBtn.toolTip = "Move clip after"
        moveRightBtn.target = self
        moveRightBtn.action = #selector(rightClicked)
        moveRightBtn.isEnabled = clipIndex < (totalClips - 1)
        addSubview(moveRightBtn)

        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .inline
        removeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove Clip")?.withSymbolConfiguration(btnConfig)
        removeBtn.toolTip = "Remove from sequence"
        removeBtn.target = self
        removeBtn.action = #selector(removeClicked)
        removeBtn.isHidden = (totalClips <= 1)
        addSubview(removeBtn)

        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 44),
            thumbView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: removeBtn.leadingAnchor, constant: -4),

            durationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            durationLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 8),

            muteBadge.leadingAnchor.constraint(equalTo: durationLabel.trailingAnchor, constant: 4),
            muteBadge.centerYAnchor.constraint(equalTo: durationLabel.centerYAnchor),
            muteBadge.widthAnchor.constraint(equalToConstant: 12),
            muteBadge.heightAnchor.constraint(equalToConstant: 12),

            removeBtn.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            removeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            removeBtn.widthAnchor.constraint(equalToConstant: 16),
            removeBtn.heightAnchor.constraint(equalToConstant: 16),

            moveLeftBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            moveLeftBtn.trailingAnchor.constraint(equalTo: moveRightBtn.leadingAnchor, constant: -4),
            moveLeftBtn.widthAnchor.constraint(equalToConstant: 16),
            moveLeftBtn.heightAnchor.constraint(equalToConstant: 16),

            moveRightBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            moveRightBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            moveRightBtn.widthAnchor.constraint(equalToConstant: 16),
            moveRightBtn.heightAnchor.constraint(equalToConstant: 16),
        ])

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    private func updateAppearance() {
        if isActive {
            layer?.borderWidth = 2.0
            layer?.borderColor = NSColor.systemTeal.cgColor
            layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
                app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.22, alpha: 0.95)
                    : NSColor(white: 0.96, alpha: 0.98)
            }).cgColor
        } else {
            layer?.borderWidth = 1.0
            layer?.borderColor = isHovered
                ? NSColor.white.withAlphaComponent(0.28).cgColor
                : NSColor.white.withAlphaComponent(0.12).cgColor
            layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
                app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.16, alpha: 0.85)
                    : NSColor(white: 0.92, alpha: 0.90)
            }).cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLocation else { return }
        let current = event.locationInWindow
        let dist = hypot(current.x - start.x, current.y - start.y)
        if dist > 8 {
            dragStartLocation = nil
            let item = NSPasteboardItem()
            item.setString(String(clipIndex), forType: ClipCardView.dragType)
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            dragItem.setDraggingFrame(bounds, contents: self.bitmapImage())
            beginDraggingSession(with: [dragItem], event: event, source: self)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(ClipCardView.dragType) == true {
            layer?.borderColor = NSColor.systemOrange.cgColor
            layer?.borderWidth = 2.0
            return .move
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateAppearance()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateAppearance()
        if let str = sender.draggingPasteboard.string(forType: ClipCardView.dragType),
           let fromIdx = Int(str), fromIdx != clipIndex {
            onDragDropReorder?(fromIdx, clipIndex)
            return true
        }
        return false
    }

    private func bitmapImage() -> NSImage {
        let pdf = dataWithPDF(inside: bounds)
        return NSImage(data: pdf) ?? NSImage(size: bounds.size)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?()
        let menu = NSMenu(title: "Clip Options")

        // Mute / Unmute
        let muteTitle = clip.isMuted ? "Unmute Clip Audio" : "Mute Clip Audio"
        let muteIcon = clip.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(toggleMuteClicked), keyEquivalent: "")
        muteItem.image = NSImage(systemSymbolName: muteIcon, accessibilityDescription: nil)
        muteItem.target = self
        menu.addItem(muteItem)

        // Edit in Separate Window
        let editItem = NSMenuItem(title: "Edit in Separate Window…", action: #selector(editInNewWindowClicked), keyEquivalent: "")
        editItem.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        editItem.target = self
        menu.addItem(editItem)

        menu.addItem(NSMenuItem.separator())

        // Move Left / Before
        let moveLeft = NSMenuItem(title: "Move Earlier / Before", action: #selector(leftClicked), keyEquivalent: "")
        moveLeft.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        moveLeft.target = self
        moveLeft.isEnabled = clipIndex > 0
        menu.addItem(moveLeft)

        // Move Right / After
        let moveRight = NSMenuItem(title: "Move Later / After", action: #selector(rightClicked), keyEquivalent: "")
        moveRight.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        moveRight.target = self
        moveRight.isEnabled = clipIndex < (totalClips - 1)
        menu.addItem(moveRight)

        if totalClips > 1 {
            menu.addItem(NSMenuItem.separator())
            let removeItem = NSMenuItem(title: "Remove from Sequence", action: #selector(removeClicked), keyEquivalent: "")
            removeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            removeItem.target = self
            menu.addItem(removeItem)
        }

        menu.addItem(NSMenuItem.separator())
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinderClicked), keyEquivalent: "")
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        revealItem.target = self
        menu.addItem(revealItem)

        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menu(for: event) {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    @objc private func toggleMuteClicked() { onToggleMute?() }
    @objc private func editInNewWindowClicked() { onEditInNewWindow?() }
    @objc private func revealInFinderClicked() { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
    @objc private func leftClicked() { onMoveLeft?() }
    @objc private func rightClicked() { onMoveRight?() }
    @objc private func removeClicked() { onRemove?() }
}

class ClipsSequenceStripView: NSView {
    var onImport: (() -> Void)?
    var onSelectClip: ((Int) -> Void)?
    var onMoveClipLeft: ((Int) -> Void)?
    var onMoveClipRight: ((Int) -> Void)?
    var onRemoveClip: ((Int) -> Void)?
    var onDragDropReorder: ((Int, Int) -> Void)?
    var onToggleClipMute: ((Int) -> Void)?
    var onEditClipInNewWindow: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "CLIPS (1)")
    private let durationLabel = NSTextField(labelWithString: "Total: 00:00.0")
    private let importBtn = NSButton()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var cards: [ClipCardView] = []

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
        translatesAutoresizingMaskIntoConstraints = false

        // Top bar
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        importBtn.bezelStyle = .rounded
        importBtn.title = "Import Video"
        let symConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        importBtn.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: "Import Video")?.withSymbolConfiguration(symConfig)
        importBtn.imagePosition = .imageLeading
        importBtn.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        importBtn.target = self
        importBtn.action = #selector(importClicked)
        importBtn.translatesAutoresizingMaskIntoConstraints = false
        importBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let headerStack = NSStackView(views: [titleLabel, durationLabel, NSView(), importBtn])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)

        // Scroll View
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStack.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 2),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor, constant: -16),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 4),
        ])
    }

    func reloadData(clips: [VideoClipItem], activeIndex: Int) {
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let totalDuration = clips.reduce(0.0) { $0 + $1.effectiveDuration }
        let mins = Int(totalDuration) / 60
        let secs = Int(totalDuration) % 60
        let tenths = Int((totalDuration.truncatingRemainder(dividingBy: 1)) * 10)
        let timeStr = String(format: "%02d:%02d.%01d", mins, secs, tenths)

        titleLabel.stringValue = "CLIPS (\(clips.count))"
        durationLabel.stringValue = "• Total: \(timeStr)"

        for (idx, clip) in clips.enumerated() {
            let card = ClipCardView(clip: clip, index: idx, totalClips: clips.count, isActive: idx == activeIndex)
            card.onSelect = { [weak self] in self?.onSelectClip?(idx) }
            card.onMoveLeft = { [weak self] in self?.onMoveClipLeft?(idx) }
            card.onMoveRight = { [weak self] in self?.onMoveClipRight?(idx) }
            card.onRemove = { [weak self] in self?.onRemoveClip?(idx) }
            card.onDragDropReorder = { [weak self] fromIdx, toIdx in self?.onDragDropReorder?(fromIdx, toIdx) }
            card.onToggleMute = { [weak self] in self?.onToggleClipMute?(idx) }
            card.onEditInNewWindow = { [weak self] in self?.onEditClipInNewWindow?(idx) }
            cards.append(card)
            stackView.addArrangedSubview(card)

            if idx < clips.count - 1 {
                let arrowView = NSImageView()
                arrowView.translatesAutoresizingMaskIntoConstraints = false
                let symConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                arrowView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(symConfig)
                arrowView.contentTintColor = .tertiaryLabelColor
                stackView.addArrangedSubview(arrowView)
            }
        }
    }

    func setActiveClip(index: Int) {
        for (idx, card) in cards.enumerated() {
            card.isActive = (idx == index)
        }
    }

    @objc private func importClicked() {
        onImport?()
    }
}

// ============================================================
// Native In-App Video Trimmer & Multi-Clip Stitching Window
// ============================================================

class VideoTrimmerWindow: NSWindow, NSWindowDelegate {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    var fileURL: URL
    var clips: [VideoClipItem] = []
    var activeClipIndex: Int = 0
    var player: AVPlayer?
    var playerView: AVPlayerView!
    var clipsStripView: ClipsSequenceStripView!
    var trimSlider: TrimRangeSliderView!
    var totalDuration: Double = 0
    var trimStartSeconds: Double = 0
    var trimEndSeconds: Double = 0
    var timeObserverToken: Any?
    private var isSeeking = false
    private var pendingSeek: (time: CMTime, exact: Bool)?
    var onTrimCompleted: ((URL) -> Void)?
    var onWindowWillClose: ((VideoTrimmerWindow) -> Void)?

    var trimMode: TrimMode = .trimIn
    var trimBlocks: [TrimBlock] = []
    var activeBlockIndex: Int = 0
    var modeSegmentedControl: NSSegmentedControl!
    var addBlockButton: NSButton!
    var removeBlockButton: NSButton!
    var blockPillControl: NSSegmentedControl!
    var modeDescriptionLabel: NSTextField!
    var startTimeLabel: NSTextField!
    var endTimeLabel: NSTextField!
    var durationLabel: NSTextField!
    var exportStatusLabel: NSTextField!
    var playSelectionBtn: NSButton!
    var muteButton: NSButton!
    var fullscreenButton: NSButton!
    var trimButton: NSButton!
    var progressIndicator: NSProgressIndicator!
    var isPlayingSelection: Bool = false
    var hasSkippedCut: Bool = false
    var isAudioMuted: Bool = false
    private var activeExportSession: AVAssetExportSession?

    private var visualEffectView: TrimmerContainerView!
    private var playerTopConstraint: NSLayoutConstraint!
    private let fullscreenSymConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.clips = [VideoClipItem(url: fileURL)]
        self.activeClipIndex = 0

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialWidth = min(1180, max(880, screenFrame.width * 0.78))
        let initialHeight = min(880, max(660, screenFrame.height * 0.82))
        let rect = NSRect(
            x: screenFrame.midX - initialWidth / 2,
            y: screenFrame.midY - initialHeight / 2,
            width: initialWidth,
            height: initialHeight
        )

        super.init(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)

        self.delegate = self
        self.isReleasedWhenClosed = false
        self.titlebarAppearsTransparent = true
        self.title = "Edit Video — \(fileURL.lastPathComponent)"
        self.titleVisibility = .visible
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.center()
        self.level = .normal
        self.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        self.minSize = NSSize(width: 700, height: 520)

        visualEffectView = TrimmerContainerView(frame: rect)
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
        visualEffectView.layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 0.85)
                : NSColor(white: 0.98, alpha: 0.85)
        }).cgColor
        visualEffectView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.10)
        }).cgColor

        visualEffectView.onFilesDropped = { [weak self] urls in
            self?.addVideos(urls: urls)
        }

        self.contentView = visualEffectView

        setupUI(in: visualEffectView)
        loadInitialAsset()
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

        // Clips Strip View
        clipsStripView = ClipsSequenceStripView()
        clipsStripView.onImport = { [weak self] in self?.importVideoFiles() }
        clipsStripView.onSelectClip = { [weak self] idx in self?.selectClip(at: idx) }
        clipsStripView.onMoveClipLeft = { [weak self] idx in self?.moveClipLeft(at: idx) }
        clipsStripView.onMoveClipRight = { [weak self] idx in self?.moveClipRight(at: idx) }
        clipsStripView.onRemoveClip = { [weak self] idx in self?.removeClip(at: idx) }
        clipsStripView.onDragDropReorder = { [weak self] fromIdx, toIdx in self?.reorderClip(from: fromIdx, to: toIdx) }
        clipsStripView.onToggleClipMute = { [weak self] idx in self?.toggleClipMute(at: idx) }
        clipsStripView.onEditClipInNewWindow = { [weak self] idx in self?.editClipInSeparateWindow(at: idx) }

        // Mode Segmented Control (Trim In vs Trim Out)
        modeSegmentedControl = NSSegmentedControl(labels: ["Trim In (Keep)", "Trim Out (Cut)"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeSegmentedControl.selectedSegment = 0
        modeSegmentedControl.segmentStyle = .texturedRounded
        modeSegmentedControl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        let symConfig = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)
        modeSegmentedControl.setImage(NSImage(systemSymbolName: "arrow.left.and.right.to.inner", accessibilityDescription: "Trim In")?.withSymbolConfiguration(symConfig), forSegment: 0)
        modeSegmentedControl.setImage(NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim Out")?.withSymbolConfiguration(symConfig), forSegment: 1)

        // Add Block Button
        addBlockButton = NSButton(title: " + Add Keep", target: self, action: #selector(addNewTrimBlock))
        addBlockButton.bezelStyle = .texturedRounded
        addBlockButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let plusConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addBlockButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add Block")?.withSymbolConfiguration(plusConfig)
        addBlockButton.imagePosition = .imageLeading
        addBlockButton.translatesAutoresizingMaskIntoConstraints = false
        addBlockButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Remove Block Button
        removeBlockButton = NSButton(title: " Remove", target: self, action: #selector(removeCurrentTrimBlock))
        removeBlockButton.bezelStyle = .texturedRounded
        removeBlockButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let trashConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        removeBlockButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove Block")?.withSymbolConfiguration(trashConfig)
        removeBlockButton.imagePosition = .imageLeading
        removeBlockButton.isEnabled = false
        removeBlockButton.translatesAutoresizingMaskIntoConstraints = false
        removeBlockButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Block Pill Control
        blockPillControl = NSSegmentedControl(labels: ["#1"], trackingMode: .selectOne, target: self, action: #selector(blockPillChanged(_:)))
        blockPillControl.segmentStyle = .texturedRounded
        blockPillControl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        blockPillControl.selectedSegment = 0
        blockPillControl.translatesAutoresizingMaskIntoConstraints = false
        blockPillControl.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let blockControlsStack = NSStackView(views: [addBlockButton, removeBlockButton, blockPillControl])
        blockControlsStack.orientation = .horizontal
        blockControlsStack.spacing = 6
        blockControlsStack.alignment = .centerY
        blockControlsStack.translatesAutoresizingMaskIntoConstraints = false

        modeDescriptionLabel = NSTextField(labelWithString: "Output preserves the highlighted section")
        modeDescriptionLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        modeDescriptionLabel.textColor = .secondaryLabelColor
        modeDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let modeBar = NSStackView(views: [modeSegmentedControl, blockControlsStack, NSView(), modeDescriptionLabel])
        modeBar.orientation = .horizontal
        modeBar.alignment = .centerY
        modeBar.spacing = 10
        modeBar.translatesAutoresizingMaskIntoConstraints = false

        // Interactive Visual Trim Slider
        trimSlider = TrimRangeSliderView()
        trimSlider.translatesAutoresizingMaskIntoConstraints = false
        trimSlider.trimMode = self.trimMode
        trimSlider.onTrimBlocksChanged = { [weak self] blocks, activeIdx in
            guard let self = self else { return }
            self.trimBlocks = blocks
            self.activeBlockIndex = activeIdx
            if activeIdx < blocks.count {
                self.trimStartSeconds = blocks[activeIdx].start
                self.trimEndSeconds = blocks[activeIdx].end
            }
            self.stopSelectionPlaybackIfNeeded()
            self.updateBlockControls()
            self.updateLabels()
            self.updateTrimButtonTitle()
        }
        trimSlider.onBlockSelected = { [weak self] idx in
            guard let self = self else { return }
            self.activeBlockIndex = idx
            self.updateBlockControls()
            self.updateLabels()
            self.updateTrimButtonTitle()
        }
        trimSlider.onBlockDeleted = { [weak self] _ in
            guard let self = self else { return }
            self.removeCurrentTrimBlock()
        }
        trimSlider.onAddBlockRequested = { [weak self] clickTime in
            guard let self = self else { return }
            self.addNewBlockAround(clickTime)
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

        // Center Duration
        durationLabel = NSTextField(labelWithString: "Keep: 00:00.0")
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
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
        trimButton.title = "Save Trimmed Video"
        trimButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        trimButton.keyEquivalent = "\r"
        trimButton.target = self
        trimButton.action = #selector(performTrim)
        trimButton.translatesAutoresizingMaskIntoConstraints = false
        trimButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        fullscreenButton = NSButton()
        fullscreenButton.bezelStyle = .rounded
        fullscreenButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        fullscreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full Screen")?.withSymbolConfiguration(fullscreenSymConfig)
        fullscreenButton.imagePosition = .imageOnly
        fullscreenButton.toolTip = "Toggle Full Screen (Fn-F)"
        fullscreenButton.target = self
        fullscreenButton.action = #selector(toggleFullScreenAction)
        fullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        fullscreenButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        fullscreenButton.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let bottomStack = NSStackView(views: [playSelectionBtn, resetBtn, muteButton, fullscreenButton, progressIndicator, exportStatusLabel, NSView(), trimButton])
        bottomStack.orientation = .horizontal
        bottomStack.alignment = .centerY
        bottomStack.spacing = 10
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(playerView)
        container.addSubview(clipsStripView)
        container.addSubview(modeBar)
        container.addSubview(trimSlider)
        container.addSubview(leftStack)
        container.addSubview(durationLabel)
        container.addSubview(rightStack)
        container.addSubview(bottomStack)

        playerTopConstraint = playerView.topAnchor.constraint(equalTo: container.topAnchor, constant: 36)

        NSLayoutConstraint.activate([
            playerTopConstraint,
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            clipsStripView.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 8),
            clipsStripView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            clipsStripView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            clipsStripView.heightAnchor.constraint(equalToConstant: 104),

            modeBar.topAnchor.constraint(equalTo: clipsStripView.bottomAnchor, constant: 8),
            modeBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            modeBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            modeBar.heightAnchor.constraint(equalToConstant: 26),

            trimSlider.topAnchor.constraint(equalTo: modeBar.bottomAnchor, constant: 6),
            trimSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            trimSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            trimSlider.heightAnchor.constraint(equalToConstant: 36),

            leftStack.topAnchor.constraint(equalTo: trimSlider.bottomAnchor, constant: 8),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            rightStack.topAnchor.constraint(equalTo: trimSlider.bottomAnchor, constant: 8),
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            durationLabel.centerYAnchor.constraint(equalTo: leftStack.centerYAnchor),
            durationLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            bottomStack.topAnchor.constraint(equalTo: leftStack.bottomAnchor, constant: 10),
            bottomStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            bottomStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Asset & Composition Loading

    private func loadInitialAsset() {
        guard let firstClip = clips.first else { return }
        Task {
            await self.loadMetadataAndThumbnail(for: firstClip)
            await self.buildCompositionAndRefreshUI()
            await MainActor.run {
                if firstClip.naturalSize.width > 0 && firstClip.naturalSize.height > 0 {
                    self.adjustWindowSizeToFitVideo(naturalSize: firstClip.naturalSize)
                }
            }
        }
    }

    private func loadMetadataAndThumbnail(for clip: VideoClipItem) async {
        let asset = AVURLAsset(url: clip.url)
        let dur = try? await asset.load(.duration)
        let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var size = CGSize.zero
        var transform = CGAffineTransform.identity
        if let track = vTracks.first {
            size = (try? await track.load(.naturalSize)) ?? .zero
            transform = (try? await track.load(.preferredTransform)) ?? .identity
        }

        let seconds = dur != nil ? CMTimeGetSeconds(dur!) : 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 120)
        let snapTime = CMTime(seconds: min(1.0, max(0.1, seconds * 0.1)), preferredTimescale: 600)
        var thumbImg: NSImage? = nil
        if let cgImg = try? generator.copyCGImage(at: snapTime, actualTime: nil) {
            thumbImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        }

        await MainActor.run {
            clip.duration = seconds > 0 ? seconds : 1.0
            clip.naturalSize = size
            clip.preferredTransform = transform
            clip.startTime = 0.0
            clip.endTime = clip.duration
            clip.thumbnail = thumbImg
        }
    }

    private func buildCompositionAndRefreshUI(preserveTrimRange: Bool = false) async {
        guard !clips.isEmpty else { return }

        var maxW: CGFloat = 0
        var maxH: CGFloat = 0
        for c in clips {
            let orientedRect = CGRect(origin: .zero, size: c.naturalSize).applying(c.preferredTransform)
            let w = abs(orientedRect.width)
            let h = abs(orientedRect.height)
            if w > maxW { maxW = w }
            if h > maxH { maxH = h }
        }
        if maxW <= 0 || maxH <= 0 {
            maxW = 1920
            maxH = 1080
        }
        let renderSize = CGSize(width: maxW, height: maxH)

        let comp = AVMutableComposition()
        let compVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var currentTrackTime: CMTime = .zero

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let assetVideoTrack = vTracks.first else { continue }

            let durSec = clip.effectiveDuration
            let clipDur = CMTime(seconds: durSec, preferredTimescale: 600)
            let clipStart = CMTime(seconds: clip.startTime, preferredTimescale: 600)
            let clipRange = CMTimeRange(start: clipStart, duration: clipDur)

            try? compVideoTrack?.insertTimeRange(clipRange, of: assetVideoTrack, at: currentTrackTime)

            if !self.isAudioMuted && !clip.isMuted, let assetAudioTrack = aTracks.first {
                try? compAudioTrack?.insertTimeRange(clipRange, of: assetAudioTrack, at: currentTrackTime)
            }

            if let compVideoTrack = compVideoTrack {
                let layerInst = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
                let transform = VideoTrimmerWindow.calculateAspectFitTransform(
                    naturalSize: clip.naturalSize,
                    preferredTransform: clip.preferredTransform,
                    renderSize: renderSize
                )
                layerInst.setTransform(transform, at: currentTrackTime)

                let inst = AVMutableVideoCompositionInstruction()
                inst.timeRange = CMTimeRange(start: currentTrackTime, duration: clipDur)
                inst.layerInstructions = [layerInst]
                instructions.append(inst)
            }

            currentTrackTime = CMTimeAdd(currentTrackTime, clipDur)
        }

        videoComp.instructions = instructions
        let newTotalDuration = max(0.1, CMTimeGetSeconds(currentTrackTime))

        await MainActor.run {
            self.totalDuration = newTotalDuration
            if !preserveTrimRange || self.trimBlocks.isEmpty || (self.trimBlocks.last?.end ?? 0) > self.totalDuration {
                if self.trimMode == .trimIn {
                    self.trimBlocks = [TrimBlock(start: 0.0, end: self.totalDuration)]
                } else {
                    let cutStart = round(self.totalDuration * 0.25 * 10) / 10
                    let cutEnd = round(self.totalDuration * 0.75 * 10) / 10
                    self.trimBlocks = [TrimBlock(start: cutStart, end: cutEnd)]
                }
                self.activeBlockIndex = 0
            }
            self.trimSlider.duration = self.totalDuration
            self.syncBlocksToSlider()
            self.updateBlockControls()

            let playerItem = AVPlayerItem(asset: comp)
            playerItem.videoComposition = videoComp

            if self.player == nil {
                let p = AVPlayer(playerItem: playerItem)
                p.isMuted = self.isAudioMuted
                self.player = p
                self.playerView.player = p
                self.setupTimeObserver(for: p)
            } else {
                self.player?.replaceCurrentItem(with: playerItem)
            }

            self.clipsStripView.reloadData(clips: self.clips, activeIndex: self.activeClipIndex)
            self.updateWindowTitle()
            self.updateLabels()
            self.updateTrimButtonTitle()
        }
    }

    private func setupTimeObserver(for p: AVPlayer) {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }

        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let sec = CMTimeGetSeconds(time)
            self.trimSlider.currentTime = sec

            // Sync active card in strip with playback playhead
            var accum: Double = 0
            for (idx, clip) in self.clips.enumerated() {
                let dur = clip.effectiveDuration
                if sec >= accum && sec < (accum + dur) {
                    if self.activeClipIndex != idx {
                        self.activeClipIndex = idx
                        self.clipsStripView.setActiveClip(index: idx)
                    }
                    break
                }
                accum += dur
            }

            if self.isPlayingSelection {
                let keptRanges = self.computeKeptRanges()
                guard !keptRanges.isEmpty else {
                    self.player?.pause()
                    self.isPlayingSelection = false
                    self.updatePlaySelectionButton()
                    return
                }

                var inRangeIndex: Int? = nil
                for (idx, r) in keptRanges.enumerated() {
                    let startS = CMTimeGetSeconds(r.start)
                    let endS = CMTimeGetSeconds(CMTimeRangeGetEnd(r))
                    if sec >= (startS - 0.05) && sec < endS {
                        inRangeIndex = idx
                        break
                    }
                }

                if let idx = inRangeIndex {
                    let currentRange = keptRanges[idx]
                    let endS = CMTimeGetSeconds(CMTimeRangeGetEnd(currentRange))
                    if sec >= (endS - 0.06) {
                        if idx + 1 < keptRanges.count {
                            let nextStart = keptRanges[idx + 1].start
                            self.player?.seek(to: nextStart, toleranceBefore: .zero, toleranceAfter: .zero)
                        } else {
                            self.player?.pause()
                            self.isPlayingSelection = false
                            self.updatePlaySelectionButton()
                            let firstStart = keptRanges[0].start
                            self.player?.seek(to: firstStart, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                } else {
                    var foundNext = false
                    for r in keptRanges {
                        let startS = CMTimeGetSeconds(r.start)
                        if startS > sec {
                            self.player?.seek(to: r.start, toleranceBefore: .zero, toleranceAfter: .zero)
                            foundNext = true
                            break
                        }
                    }
                    if !foundNext {
                        self.player?.pause()
                        self.isPlayingSelection = false
                        self.updatePlaySelectionButton()
                        let firstStart = keptRanges[0].start
                        self.player?.seek(to: firstStart, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
        }
    }

    static func calculateAspectFitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedWidth = abs(orientedRect.width)
        let orientedHeight = abs(orientedRect.height)

        guard orientedWidth > 0 && orientedHeight > 0 else {
            return preferredTransform
        }

        let scaleX = renderSize.width / orientedWidth
        let scaleY = renderSize.height / orientedHeight
        let scale = min(scaleX, scaleY)

        let scaledW = orientedWidth * scale
        let scaledH = orientedHeight * scale
        let tx = (renderSize.width - scaledW) / 2.0
        let ty = (renderSize.height - scaledH) / 2.0

        let minX = min(orientedRect.minX, orientedRect.maxX)
        let minY = min(orientedRect.minY, orientedRect.maxY)

        var t = preferredTransform
        t = t.concatenating(CGAffineTransform(translationX: -minX, y: -minY))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
        return t
    }

    private func adjustWindowSizeToFitVideo(naturalSize: CGSize) {
        guard !self.styleMask.contains(.fullScreen) else { return }
        let screenFrame = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let chromeHeight: CGFloat = 280.0
        let chromeWidth: CGFloat = 32.0

        let maxW = min(1380.0, screenFrame.width * 0.88)
        let maxH = min(940.0, screenFrame.height * 0.88)
        let availW = max(500.0, maxW - chromeWidth)
        let availH = max(400.0, maxH - chromeHeight)

        let aspect = (naturalSize.width > 0 && naturalSize.height > 0) ? (naturalSize.width / naturalSize.height) : (16.0 / 9.0)
        var videoW: CGFloat
        var videoH: CGFloat

        if aspect >= (availW / availH) {
            videoW = availW
            videoH = round(videoW / aspect)
        } else {
            videoH = availH
            videoW = round(videoH * aspect)
        }

        let targetW = max(880.0, min(maxW, videoW + chromeWidth))
        let targetH = max(660.0, min(maxH, videoH + chromeHeight))

        let newX = round(screenFrame.midX - targetW / 2.0)
        let newY = round(screenFrame.midY - targetH / 2.0)
        let newRect = NSRect(x: newX, y: newY, width: targetW, height: targetH)

        self.setFrame(newRect, display: true, animate: true)
    }

    // MARK: - Multi-Clip Management & Reordering

    func addVideos(urls: [URL]) {
        let validExts = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"])
        let filtered = urls.filter { validExts.contains($0.pathExtension.lowercased()) }
        guard !filtered.isEmpty else { return }

        stopSelectionPlaybackIfNeeded()
        let newClips = filtered.map { VideoClipItem(url: $0) }
        self.clips.append(contentsOf: newClips)

        exportStatusLabel.stringValue = "Importing \(filtered.count) video(s)..."
        progressIndicator.startAnimation(nil)

        Task {
            for clip in newClips {
                await self.loadMetadataAndThumbnail(for: clip)
            }
            await self.buildCompositionAndRefreshUI()
            await MainActor.run {
                self.progressIndicator.stopAnimation(nil)
                self.exportStatusLabel.stringValue = "Added \(filtered.count) clip(s)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.exportStatusLabel.stringValue.starts(with: "Added") {
                        self.exportStatusLabel.stringValue = ""
                    }
                }
            }
        }
    }

    @objc func importVideoFiles() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Video Files to Stitch"
        openPanel.prompt = "Add to Sequence"
        openPanel.showsHiddenFiles = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = true
        if #available(macOS 11.0, *) {
            openPanel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        } else {
            openPanel.allowedFileTypes = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
        }
        openPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        NSApp.activate(ignoringOtherApps: true)
        if openPanel.runModal() == .OK {
            self.addVideos(urls: openPanel.urls)
        }
    }

    func moveClipLeft(at index: Int) {
        guard index > 0 && index < clips.count else { return }
        stopSelectionPlaybackIfNeeded()
        clips.swapAt(index, index - 1)
        activeClipIndex = index - 1
        Task {
            await self.buildCompositionAndRefreshUI()
        }
    }

    func moveClipRight(at index: Int) {
        guard index >= 0 && index < clips.count - 1 else { return }
        stopSelectionPlaybackIfNeeded()
        clips.swapAt(index, index + 1)
        activeClipIndex = index + 1
        Task {
            await self.buildCompositionAndRefreshUI()
        }
    }

    func reorderClip(from: Int, to: Int) {
        guard from >= 0 && from < clips.count && to >= 0 && to < clips.count && from != to else { return }
        stopSelectionPlaybackIfNeeded()
        let item = clips.remove(at: from)
        clips.insert(item, at: to)
        activeClipIndex = to
        Task {
            await self.buildCompositionAndRefreshUI()
        }
    }

    func removeClip(at index: Int) {
        guard clips.count > 1 && index >= 0 && index < clips.count else { return }
        stopSelectionPlaybackIfNeeded()
        clips.remove(at: index)
        if activeClipIndex >= clips.count {
            activeClipIndex = clips.count - 1
        }
        Task {
            await self.buildCompositionAndRefreshUI()
        }
    }

    func selectClip(at index: Int) {
        guard index >= 0 && index < clips.count else { return }
        stopSelectionPlaybackIfNeeded()
        activeClipIndex = index
        clipsStripView.setActiveClip(index: index)

        let offset = clips.prefix(index).reduce(0.0) { $0 + $1.effectiveDuration }
        let cm = CMTime(seconds: offset, preferredTimescale: 600)
        smoothSeek(to: cm, exact: true)
    }

    func toggleClipMute(at index: Int) {
        guard index >= 0 && index < clips.count else { return }
        let clip = clips[index]
        clip.isMuted.toggle()
        let isMuted = clip.isMuted
        let name = clip.title

        Task {
            await self.buildCompositionAndRefreshUI(preserveTrimRange: true)
            await MainActor.run {
                self.exportStatusLabel.stringValue = isMuted ? "Muted audio for \"\(name)\"" : "Unmuted audio for \"\(name)\""
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.exportStatusLabel.stringValue.contains(name) {
                        self.exportStatusLabel.stringValue = ""
                    }
                }
            }
        }
    }

    func editClipInSeparateWindow(at index: Int) {
        guard index >= 0 && index < clips.count else { return }
        let clip = clips[index]
        let clipId = clip.id

        // If there's already a separate trimmer open for this clip, bring it front
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let existing = appDelegate.openTrimmers.first(where: { $0 !== self && $0.fileURL == clip.url }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let childTrimmer = VideoTrimmerWindow(fileURL: clip.url)

        let currentOrigin = self.frame.origin
        childTrimmer.setFrameOrigin(NSPoint(x: currentOrigin.x + 40, y: currentOrigin.y - 40))

        childTrimmer.onTrimCompleted = { [weak self] updatedURL in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleEditedClipSaved(clipId: clipId, updatedURL: updatedURL)
            }
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openTrimmers.append(childTrimmer)
            childTrimmer.onWindowWillClose = { [weak appDelegate, weak childTrimmer] win in
                guard let appDelegate = appDelegate, let win = childTrimmer else { return }
                appDelegate.openTrimmers.removeAll(where: { $0 === win })
                if appDelegate.openTrimmers.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        childTrimmer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        exportStatusLabel.stringValue = "Opened \"\(clip.title)\" in separate editor"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.exportStatusLabel.stringValue.starts(with: "Opened") {
                self.exportStatusLabel.stringValue = ""
            }
        }
    }

    func handleEditedClipSaved(clipId: UUID, updatedURL: URL) {
        self.stopSelectionPlaybackIfNeeded()
        self.player?.pause()

        guard let idx = clips.firstIndex(where: { $0.id == clipId }) else { return }
        let clip = clips[idx]
        clip.url = updatedURL
        clip.title = updatedURL.lastPathComponent
        clip.startTime = 0.0
        clip.endTime = 0.0

        if idx == 0 {
            self.fileURL = updatedURL
        }

        Task {
            await self.loadMetadataAndThumbnail(for: clip)
            await self.buildCompositionAndRefreshUI(preserveTrimRange: false)
            await MainActor.run {
                self.exportStatusLabel.stringValue = "Updated Clip #\(idx + 1) with edited video"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if self.exportStatusLabel.stringValue.starts(with: "Updated Clip") {
                        self.exportStatusLabel.stringValue = ""
                    }
                }
            }
        }
    }

    private func updateWindowTitle() {
        if clips.count <= 1 {
            self.title = "Edit Video — \(clips.first?.title ?? fileURL.lastPathComponent)"
        } else {
            self.title = "Edit Video — \(clips.first?.title ?? fileURL.lastPathComponent) (\(clips.count) clips stitched)"
        }
    }

    // MARK: - Playback Controls & Mode

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        stopSelectionPlaybackIfNeeded()
        let oldMode = trimMode
        trimMode = sender.selectedSegment == 1 ? .trimOut : .trimIn
        trimSlider.trimMode = trimMode

        if trimMode == .trimOut && oldMode == .trimIn {
            if trimBlocks.count == 1 && trimBlocks[0].start <= 0.05 && trimBlocks[0].end >= totalDuration - 0.05 {
                let cutStart = round(totalDuration * 0.25 * 10) / 10
                let cutEnd = round(totalDuration * 0.75 * 10) / 10
                trimBlocks = [TrimBlock(start: cutStart, end: cutEnd)]
                activeBlockIndex = 0
            }
        } else if trimMode == .trimIn && oldMode == .trimOut {
            if trimBlocks.count == 1 {
                trimBlocks = [TrimBlock(start: 0.0, end: totalDuration)]
                activeBlockIndex = 0
            }
        }

        syncBlocksToSlider()
        updateBlockControls()
        updateLabels()
        updatePlaySelectionButton()
        updateTrimButtonTitle()
    }

    private func updateTrimButtonTitle() {
        let blockCount = trimBlocks.count
        if clips.count > 1 {
            if trimMode == .trimIn {
                trimButton.title = "Save Trimmed Stitched Video (\(clips.count) Clips)"
            } else {
                trimButton.title = blockCount > 1 ? "Cut Out (\(blockCount) Cuts) & Save Stitched Video" : "Cut Out & Save Stitched Video"
            }
        } else {
            if trimMode == .trimIn {
                trimButton.title = blockCount > 1 ? "Save Trimmed Video (\(blockCount) Segments)" : "Save Trimmed Video"
            } else {
                trimButton.title = blockCount > 1 ? "Cut Out (\(blockCount) Cuts) & Save Video" : "Cut Out & Save Video"
            }
        }
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

    private func stopSelectionPlaybackIfNeeded() {
        if isPlayingSelection {
            player?.pause()
            isPlayingSelection = false
            hasSkippedCut = false
            updatePlaySelectionButton()
        }
    }

    @objc private func togglePlaySelection() {
        guard let p = player else { return }
        if isPlayingSelection {
            p.pause()
            isPlayingSelection = false
            hasSkippedCut = false
            updatePlaySelectionButton()
        } else {
            let keptRanges = computeKeptRanges()
            guard !keptRanges.isEmpty else { return }

            let curSec = CMTimeGetSeconds(p.currentTime())
            var startSeek = keptRanges[0].start

            for r in keptRanges {
                let startS = CMTimeGetSeconds(r.start)
                let endS = CMTimeGetSeconds(CMTimeRangeGetEnd(r))
                if curSec >= (startS - 0.05) && curSec < (endS - 0.1) {
                    startSeek = p.currentTime()
                    break
                } else if startS > curSec {
                    startSeek = r.start
                    break
                }
            }

            p.seek(to: startSeek, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else { return }
                self.player?.play()
                self.isPlayingSelection = true
                self.updatePlaySelectionButton()
            }
        }
    }

    private func updatePlaySelectionButton() {
        if trimMode == .trimIn {
            playSelectionBtn.title = isPlayingSelection ? "Pause Preview" : "Play Selection"
        } else {
            playSelectionBtn.title = isPlayingSelection ? "Pause Preview" : "Preview Cut"
        }
    }

    @objc private func toggleMute() {
        isAudioMuted = !isAudioMuted
        player?.isMuted = isAudioMuted
        updateMuteButton()
        Task {
            await self.buildCompositionAndRefreshUI(preserveTrimRange: true)
        }
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
        if activeBlockIndex < trimBlocks.count {
            let b = trimBlocks[activeBlockIndex]
            trimStartSeconds = b.start
            trimEndSeconds = b.end
            let blockNum = activeBlockIndex + 1
            startTimeLabel.stringValue = "Block #\(blockNum) Start: \(formatTime(b.start))"
            endTimeLabel.stringValue = "End: \(formatTime(b.end))"
        } else {
            startTimeLabel.stringValue = "Start: \(formatTime(trimStartSeconds))"
            endTimeLabel.stringValue = "End: \(formatTime(trimEndSeconds))"
        }

        let keptRanges = computeKeptRanges()
        let finalKeptSec = keptRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }

        if trimMode == .trimIn {
            let countStr = trimBlocks.count == 1 ? "1 keep segment" : "\(trimBlocks.count) keep segments"
            durationLabel.stringValue = "Kept Total: \(formatTime(finalKeptSec)) (\(countStr))"
            modeDescriptionLabel.stringValue = "Output preserves \(countStr)"
            durationLabel.textColor = NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0.22, green: 0.90, blue: 0.44, alpha: 1.0)
                    : NSColor(red: 0.08, green: 0.56, blue: 0.20, alpha: 1.0)
            })
        } else {
            let totalCutSec = max(0, totalDuration - finalKeptSec)
            let cutsCount = trimBlocks.count
            let cutsStr = cutsCount == 1 ? "1 cut" : "\(cutsCount) cuts"
            durationLabel.stringValue = "Cut: \(formatTime(totalCutSec)) (\(cutsStr))  ➔  Final: \(formatTime(finalKeptSec))"
            modeDescriptionLabel.stringValue = "Output cuts \(cutsStr) & stitches remaining segments"
            durationLabel.textColor = NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 1.0, green: 0.45, blue: 0.40, alpha: 1.0)
                    : NSColor(red: 0.85, green: 0.20, blue: 0.15, alpha: 1.0)
            })
        }
    }

    @objc private func setStartToCurrent() {
        guard let p = player, activeBlockIndex < trimBlocks.count else { return }
        stopSelectionPlaybackIfNeeded()
        let current = CMTimeGetSeconds(p.currentTime())
        let b = trimBlocks[activeBlockIndex]
        let minStart = activeBlockIndex > 0 ? (trimBlocks[activeBlockIndex - 1].end + 0.1) : 0.0
        let maxStart = b.end - 0.2
        if current < b.end && current >= minStart {
            trimBlocks[activeBlockIndex].start = max(minStart, min(maxStart, current))
            syncBlocksToSlider()
            updateLabels()
            updateTrimButtonTitle()
        }
    }

    @objc private func setEndToCurrent() {
        guard let p = player, activeBlockIndex < trimBlocks.count else { return }
        stopSelectionPlaybackIfNeeded()
        let current = CMTimeGetSeconds(p.currentTime())
        let b = trimBlocks[activeBlockIndex]
        let minEnd = b.start + 0.2
        let maxEnd = activeBlockIndex < (trimBlocks.count - 1) ? (trimBlocks[activeBlockIndex + 1].start - 0.1) : totalDuration
        if current > b.start && current <= maxEnd {
            trimBlocks[activeBlockIndex].end = min(maxEnd, max(minEnd, current))
            syncBlocksToSlider()
            updateLabels()
            updateTrimButtonTitle()
        }
    }

    @objc private func resetTrim() {
        stopSelectionPlaybackIfNeeded()
        if trimMode == .trimIn {
            trimBlocks = [TrimBlock(start: 0.0, end: totalDuration)]
        } else {
            let cutStart = round(totalDuration * 0.25 * 10) / 10
            let cutEnd = round(totalDuration * 0.75 * 10) / 10
            trimBlocks = [TrimBlock(start: cutStart, end: cutEnd)]
        }
        activeBlockIndex = 0
        syncBlocksToSlider()
        updateBlockControls()
        updateLabels()
        updateTrimButtonTitle()
        player?.seek(to: .zero)
    }

    // MARK: - Multi-Block Management

    func computeKeptRanges() -> [CMTimeRange] {
        guard totalDuration > 0 else { return [] }
        let sortedBlocks = trimBlocks
            .map { TrimBlock(start: max(0, min(totalDuration, $0.start)), end: max(0, min(totalDuration, $0.end))) }
            .sorted(by: { $0.start < $1.start })

        if trimMode == .trimIn {
            var merged: [(start: Double, end: Double)] = []
            for b in sortedBlocks {
                guard b.end > b.start + 0.05 else { continue }
                if let last = merged.last, b.start <= last.end + 0.05 {
                    merged[merged.count - 1].end = max(last.end, b.end)
                } else {
                    merged.append((b.start, b.end))
                }
            }
            return merged.compactMap {
                let startCM = CMTime(seconds: $0.start, preferredTimescale: 600)
                let durCM = CMTime(seconds: max(0.01, $0.end - $0.start), preferredTimescale: 600)
                return CMTimeRange(start: startCM, duration: durCM)
            }
        } else {
            var cuts: [(start: Double, end: Double)] = []
            for b in sortedBlocks {
                guard b.end > b.start + 0.05 else { continue }
                if let last = cuts.last, b.start <= last.end + 0.05 {
                    cuts[cuts.count - 1].end = max(last.end, b.end)
                } else {
                    cuts.append((b.start, b.end))
                }
            }

            guard !cuts.isEmpty else {
                return [CMTimeRange(start: .zero, duration: CMTime(seconds: totalDuration, preferredTimescale: 600))]
            }

            var kept: [(start: Double, end: Double)] = []
            var currentPos: Double = 0.0

            for cut in cuts {
                if cut.start > currentPos + 0.05 {
                    kept.append((currentPos, cut.start))
                }
                currentPos = max(currentPos, cut.end)
            }
            if totalDuration > currentPos + 0.05 {
                kept.append((currentPos, totalDuration))
            }

            return kept.compactMap {
                let startCM = CMTime(seconds: $0.start, preferredTimescale: 600)
                let durCM = CMTime(seconds: max(0.01, $0.end - $0.start), preferredTimescale: 600)
                return CMTimeRange(start: startCM, duration: durCM)
            }
        }
    }

    func syncBlocksToSlider() {
        trimSlider.blocks = trimBlocks
        trimSlider.activeBlockIndex = activeBlockIndex
        if activeBlockIndex < trimBlocks.count {
            trimStartSeconds = trimBlocks[activeBlockIndex].start
            trimEndSeconds = trimBlocks[activeBlockIndex].end
        }
    }

    func updateBlockControls() {
        removeBlockButton.isEnabled = trimBlocks.count > 1
        let actionWord = trimMode == .trimOut ? "Cut" : "Keep"
        addBlockButton.title = " + Add \(actionWord)"

        blockPillControl.segmentCount = trimBlocks.count
        for i in 0..<trimBlocks.count {
            blockPillControl.setLabel("#\(i + 1)", forSegment: i)
            blockPillControl.setWidth(34, forSegment: i)
        }
        if activeBlockIndex < trimBlocks.count {
            blockPillControl.selectedSegment = activeBlockIndex
        }
    }

    @objc func blockPillChanged(_ sender: NSSegmentedControl) {
        let sel = sender.selectedSegment
        guard sel >= 0 && sel < trimBlocks.count else { return }
        selectBlock(at: sel)
    }

    func selectBlock(at index: Int) {
        guard index >= 0 && index < trimBlocks.count else { return }
        stopSelectionPlaybackIfNeeded()
        activeBlockIndex = index
        syncBlocksToSlider()
        updateBlockControls()
        updateLabels()
        updateTrimButtonTitle()

        let startSec = trimBlocks[index].start
        let cm = CMTime(seconds: startSec, preferredTimescale: 600)
        smoothSeek(to: cm, exact: true)
    }

    @objc func addNewTrimBlock() {
        guard totalDuration > 0 else { return }
        stopSelectionPlaybackIfNeeded()
        let curTime = player != nil ? CMTimeGetSeconds(player!.currentTime()) : 0.0
        addNewBlockAround(curTime)
    }

    func addNewBlockAround(_ targetTime: Double) {
        let sorted = trimBlocks.sorted(by: { $0.start < $1.start })
        let defaultDur = min(4.0, max(0.5, totalDuration * 0.15))

        var placed = false
        var newStart = 0.0
        var newEnd = 0.0

        var gaps: [(start: Double, end: Double)] = []
        var pos = 0.0
        for b in sorted {
            if b.start > pos + 0.2 {
                gaps.append((pos, b.start))
            }
            pos = max(pos, b.end)
        }
        if totalDuration > pos + 0.2 {
            gaps.append((pos, totalDuration))
        }

        for gap in gaps {
            if targetTime >= gap.start && targetTime <= gap.end {
                let avail = gap.end - gap.start
                let dur = min(defaultDur, max(0.3, avail * 0.8))
                newStart = max(gap.start + 0.05, min(targetTime, gap.end - dur - 0.05))
                newEnd = min(gap.end - 0.05, newStart + dur)
                placed = true
                break
            }
        }

        if !placed {
            if let largestGap = gaps.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }), (largestGap.end - largestGap.start) >= 0.4 {
                let avail = largestGap.end - largestGap.start
                let dur = min(defaultDur, avail * 0.7)
                newStart = largestGap.start + (avail - dur) / 2.0
                newEnd = newStart + dur
                placed = true
            }
        }

        guard placed else {
            exportStatusLabel.stringValue = "No space left on timeline for another block."
            return
        }

        let newBlock = TrimBlock(start: round(newStart * 10) / 10, end: round(newEnd * 10) / 10)
        trimBlocks.append(newBlock)
        trimBlocks.sort(by: { $0.start < $1.start })
        if let newIdx = trimBlocks.firstIndex(of: newBlock) {
            activeBlockIndex = newIdx
        }

        syncBlocksToSlider()
        updateBlockControls()
        updateLabels()
        updateTrimButtonTitle()

        let cm = CMTime(seconds: newBlock.start, preferredTimescale: 600)
        smoothSeek(to: cm, exact: true)

        let actionWord = trimMode == .trimOut ? "Cut" : "Keep"
        exportStatusLabel.stringValue = "Added \(actionWord) Block #\(activeBlockIndex + 1)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.exportStatusLabel.stringValue.starts(with: "Added") ?? false {
                self?.exportStatusLabel.stringValue = ""
            }
        }
    }

    @objc func removeCurrentTrimBlock() {
        guard trimBlocks.count > 1 else {
            exportStatusLabel.stringValue = "At least one trim block is required."
            return
        }
        stopSelectionPlaybackIfNeeded()
        let removedIdx = activeBlockIndex
        trimBlocks.remove(at: removedIdx)
        if activeBlockIndex >= trimBlocks.count {
            activeBlockIndex = trimBlocks.count - 1
        }
        syncBlocksToSlider()
        updateBlockControls()
        updateLabels()
        updateTrimButtonTitle()

        let actionWord = trimMode == .trimOut ? "Cut" : "Keep"
        exportStatusLabel.stringValue = "Removed \(actionWord) Block #\(removedIdx + 1)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.exportStatusLabel.stringValue.starts(with: "Removed") ?? false {
                self?.exportStatusLabel.stringValue = ""
            }
        }
    }

    // MARK: - Export & Saving (Single vs Multi-Clip Stitched)

    @objc private func performTrim() {
        if clips.count > 1 {
            promptSaveStitchedVideo()
        } else {
            performSingleTrim()
        }
    }

    private func performSingleTrim() {
        trimButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        exportStatusLabel.stringValue = "Processing video..."

        let asset = AVURLAsset(url: fileURL)
        let ext = fileURL.pathExtension
        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent(".temp_trim_\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: tempURL)

        Task {
            let isMutedSingle = self.isAudioMuted || (self.clips.first?.isMuted ?? false)
            let keptRanges = self.computeKeptRanges()

            guard !keptRanges.isEmpty else {
                await MainActor.run {
                    self.exportStatusLabel.stringValue = "Cannot cut entire video."
                    self.progressIndicator.stopAnimation(nil)
                    self.trimButton.isEnabled = true
                }
                return
            }

            let exportAsset: AVAsset
            let exportPreset: String
            var exportTimeRange: CMTimeRange? = nil

            if keptRanges.count == 1 && !isMutedSingle {
                let singleRange = keptRanges[0]
                exportAsset = asset
                exportPreset = AVAssetExportPresetPassthrough
                exportTimeRange = singleRange
            } else {
                let comp = AVMutableComposition()
                let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                guard let assetVideoTrack = videoTracks.first,
                      let compVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    await MainActor.run {
                        self.exportStatusLabel.stringValue = "Failed to access video track."
                        self.progressIndicator.stopAnimation(nil)
                        self.trimButton.isEnabled = true
                    }
                    return
                }

                if let transform = try? await assetVideoTrack.load(.preferredTransform) {
                    compVideoTrack.preferredTransform = transform
                }

                let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                let assetAudioTrack = audioTracks.first
                let compAudioTrack = (!isMutedSingle && assetAudioTrack != nil) ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

                var trackTime: CMTime = .zero
                for r in keptRanges {
                    do {
                        try compVideoTrack.insertTimeRange(r, of: assetVideoTrack, at: trackTime)
                        if let compAudioTrack = compAudioTrack, let assetAudioTrack = assetAudioTrack {
                            try compAudioTrack.insertTimeRange(r, of: assetAudioTrack, at: trackTime)
                        }
                    } catch {
                        await MainActor.run {
                            self.exportStatusLabel.stringValue = "Composition error: \(error.localizedDescription)"
                            self.progressIndicator.stopAnimation(nil)
                            self.trimButton.isEnabled = true
                        }
                        return
                    }
                    trackTime = CMTimeAdd(trackTime, r.duration)
                }

                exportAsset = comp
                exportPreset = AVAssetExportPresetHighestQuality
            }

            guard let exportSession = AVAssetExportSession(asset: exportAsset, presetName: exportPreset) else {
                await MainActor.run {
                    self.exportStatusLabel.stringValue = "Export session failed."
                    self.progressIndicator.stopAnimation(nil)
                    self.trimButton.isEnabled = true
                }
                return
            }

            exportSession.outputURL = tempURL
            exportSession.outputFileType = self.fileURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
            if let tr = exportTimeRange {
                exportSession.timeRange = tr
            }

            self.activeExportSession = exportSession

            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }

            let status = exportSession.status
            let exportError = exportSession.error

            await MainActor.run {
                self.activeExportSession = nil
                self.progressIndicator.stopAnimation(nil)
                self.trimButton.isEnabled = true

                if status == .completed {
                    self.player?.pause()
                    self.player?.replaceCurrentItem(with: nil)
                    self.player = nil

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
                    self.exportStatusLabel.stringValue = "Export error: \(exportError?.localizedDescription ?? "Unknown")"
                }
            }
        }
    }

    private func promptSaveStitchedVideo() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Stitched Video"
        savePanel.prompt = "Export Stitched"
        savePanel.canCreateDirectories = true
        let firstURL = clips.first?.url ?? fileURL
        savePanel.directoryURL = firstURL.deletingLastPathComponent()
        let baseName = firstURL.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(baseName)_stitched.mp4"
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        } else {
            savePanel.allowedFileTypes = ["mp4", "mov"]
        }
        savePanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        NSApp.activate(ignoringOtherApps: true)
        if savePanel.runModal() == .OK, let destURL = savePanel.url {
            self.exportStitchedVideo(to: destURL)
        }
    }

    private func exportStitchedVideo(to destURL: URL) {
        trimButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        exportStatusLabel.stringValue = "Stitching \(clips.count) videos..."

        try? FileManager.default.removeItem(at: destURL)

        Task {
            let keptRanges = self.computeKeptRanges()
            guard !keptRanges.isEmpty else {
                await MainActor.run {
                    self.exportStatusLabel.stringValue = "Cannot cut entire sequence."
                    self.progressIndicator.stopAnimation(nil)
                    self.trimButton.isEnabled = true
                }
                return
            }

            var maxW: CGFloat = 0
            var maxH: CGFloat = 0
            for c in self.clips {
                let orientedRect = CGRect(origin: .zero, size: c.naturalSize).applying(c.preferredTransform)
                let w = abs(orientedRect.width)
                let h = abs(orientedRect.height)
                if w > maxW { maxW = w }
                if h > maxH { maxH = h }
            }
            if maxW <= 0 || maxH <= 0 {
                maxW = 1920
                maxH = 1080
            }
            let renderSize = CGSize(width: maxW, height: maxH)

            let comp = AVMutableComposition()
            let compVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            let compAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

            let videoComp = AVMutableVideoComposition()
            videoComp.renderSize = renderSize
            videoComp.frameDuration = CMTime(value: 1, timescale: 30)

            var instructions: [AVMutableVideoCompositionInstruction] = []
            var currentTrackTime: CMTime = .zero
            var timelinePos: Double = 0.0

            for clip in self.clips {
                let asset = AVURLAsset(url: clip.url)
                let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                guard let assetVideoTrack = vTracks.first else { continue }

                let clipDur = clip.effectiveDuration
                let clipStart = timelinePos
                let clipEnd = timelinePos + clipDur
                timelinePos += clipDur

                for r in keptRanges {
                    let kStart = CMTimeGetSeconds(r.start)
                    let kEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(r))

                    let overlapStart = max(clipStart, kStart)
                    let overlapEnd = min(clipEnd, kEnd)

                    guard overlapEnd > overlapStart + 0.01 else { continue }

                    let segDur = overlapEnd - overlapStart
                    let segStartInClip = clip.startTime + (overlapStart - clipStart)

                    let segStartCM = CMTime(seconds: segStartInClip, preferredTimescale: 600)
                    let segDurCM = CMTime(seconds: segDur, preferredTimescale: 600)
                    let segRange = CMTimeRange(start: segStartCM, duration: segDurCM)

                    try? compVideoTrack?.insertTimeRange(segRange, of: assetVideoTrack, at: currentTrackTime)
                    if !self.isAudioMuted && !clip.isMuted, let assetAudioTrack = aTracks.first {
                        try? compAudioTrack?.insertTimeRange(segRange, of: assetAudioTrack, at: currentTrackTime)
                    }

                    if let compVideoTrack = compVideoTrack {
                        let layerInst = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
                        let transform = VideoTrimmerWindow.calculateAspectFitTransform(
                            naturalSize: clip.naturalSize,
                            preferredTransform: clip.preferredTransform,
                            renderSize: renderSize
                        )
                        layerInst.setTransform(transform, at: currentTrackTime)

                        let inst = AVMutableVideoCompositionInstruction()
                        inst.timeRange = CMTimeRange(start: currentTrackTime, duration: segDurCM)
                        inst.layerInstructions = [layerInst]
                        instructions.append(inst)
                    }

                    currentTrackTime = CMTimeAdd(currentTrackTime, segDurCM)
                }
            }

            videoComp.instructions = instructions

            guard let exportSession = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
                await MainActor.run {
                    self.exportStatusLabel.stringValue = "Export session failed."
                    self.progressIndicator.stopAnimation(nil)
                    self.trimButton.isEnabled = true
                }
                return
            }

            exportSession.videoComposition = videoComp
            exportSession.outputURL = destURL
            exportSession.outputFileType = destURL.pathExtension.lowercased() == "mov" ? .mov : .mp4

            self.activeExportSession = exportSession

            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }

            let status = exportSession.status
            let exportError = exportSession.error

            await MainActor.run {
                self.activeExportSession = nil
                self.progressIndicator.stopAnimation(nil)
                self.trimButton.isEnabled = true

                if status == .completed {
                    self.exportStatusLabel.stringValue = "Stitched video saved!"
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
                    self.onTrimCompleted?(destURL)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.closeWindow()
                    }
                } else {
                    try? FileManager.default.removeItem(at: destURL)
                    self.exportStatusLabel.stringValue = "Export failed: \(exportError?.localizedDescription ?? "Unknown error")"
                }
            }
        }
    }

    // MARK: - Full Screen & Window Delegate

    func windowDidEnterFullScreen(_ notification: Notification) {
        visualEffectView?.layer?.cornerRadius = 0
        visualEffectView?.layer?.borderWidth = 0
        playerTopConstraint?.constant = 14
        fullscreenButton?.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Exit Full Screen")?.withSymbolConfiguration(fullscreenSymConfig)
        fullscreenButton?.toolTip = "Exit Full Screen (Fn-F or ⎋)"
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        visualEffectView?.layer?.cornerRadius = 18
        visualEffectView?.layer?.borderWidth = 1.0
        playerTopConstraint?.constant = 36
        fullscreenButton?.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Enter Full Screen")?.withSymbolConfiguration(fullscreenSymConfig)
        fullscreenButton?.toolTip = "Enter Full Screen (Fn-F)"
    }

    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) {
            toggleFullScreen(nil)
        }
    }

    @objc private func toggleFullScreenAction() {
        self.toggleFullScreen(nil)
    }

    override func close() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        activeExportSession?.cancelExport()
        activeExportSession = nil
        onWindowWillClose?(self)
        super.close()

        if (NSApp.delegate as? AppDelegate)?.openTrimmers.isEmpty ?? true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func closeWindow() {
        activeExportSession?.cancelExport()
        activeExportSession = nil
        if styleMask.contains(.fullScreen) {
            toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.orderOut(nil)
                self?.close()
            }
        } else {
            self.orderOut(nil)
            self.close()
        }
    }
}

// ============================================================
// Post-Recording HUD Toast Window (Bottom-Right Floating Notification)
// ============================================================

extension NSAlert {
    @discardableResult
    func runModalOnTop() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        
        let canvasWindows = AnnotationManager.shared.canvasWindows
        canvasWindows.forEach { $0.ignoresMouseEvents = true }
        defer {
            canvasWindows.forEach { $0.ignoresMouseEvents = false }
        }

        self.layout()
        self.window.center()
        self.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4)
        return self.runModal()
    }
}

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
        self.hasShadow = false
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let shadowContainer = NSView(frame: NSRect(origin: .zero, size: initialRect.size))
        shadowContainer.wantsLayer = true
        shadowContainer.layer?.masksToBounds = false
        shadowContainer.layer?.cornerRadius = 14
        if #available(macOS 10.15, *) {
            shadowContainer.layer?.cornerCurve = .continuous
        }
        shadowContainer.layer?.shadowColor = NSColor.black.cgColor
        shadowContainer.layer?.shadowOpacity = 0.16
        shadowContainer.layer?.shadowRadius = 8.0
        shadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowContainer.layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: initialRect.size), cornerWidth: 14, cornerHeight: 14, transform: nil)

        let visualEffectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialRect.size))
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        if #available(macOS 10.15, *) {
            visualEffectView.layer?.cornerCurve = .continuous
        }
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1.0
        visualEffectView.layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 0.85)
                : NSColor(white: 0.98, alpha: 0.85)
        }).cgColor
        visualEffectView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.10)
        }).cgColor

        shadowContainer.addSubview(visualEffectView)
        self.contentView = shadowContainer

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
        thumbnailView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.20)
                : NSColor.black.withAlphaComponent(0.10)
        }).cgColor
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
        titleLabel.textColor = .labelColor
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
        fileNameLabel.textColor = .labelColor
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
        metaLabel.textColor = .secondaryLabelColor
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
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openVideoTrimmer(for: fileURL) { [weak self] updatedURL in
                guard let self = self else { return }
                self.fileURL = updatedURL
                self.refreshToast(with: updatedURL)
            }
        } else {
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

        if alert.runModalOnTop() == .alertFirstButtonReturn {
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
        if alert.runModalOnTop() == .alertFirstButtonReturn {
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
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

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
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

        let visualEffectView = NSVisualEffectView(frame: rect)
        visualEffectView.autoresizingMask = [.width, .height]
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
        visualEffectView.layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 0.85)
                : NSColor(white: 0.98, alpha: 0.85)
        }).cgColor
        visualEffectView.layer?.borderColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.10)
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

        if alert.runModalOnTop() == .alertFirstButtonReturn {
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
                    errAlert.runModalOnTop()
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
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openVideoTrimmer(for: fileURL) { [weak self] updatedURL in
                guard let self = self else { return }
                self.refreshPreviewCard(with: updatedURL)
            }
        } else {
            let trimmer = VideoTrimmerWindow(fileURL: fileURL)
            trimmer.onTrimCompleted = { [weak self] updatedURL in
                guard let self = self else { return }
                self.refreshPreviewCard(with: updatedURL)
            }
            self.trimmerWindow = trimmer
            trimmer.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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
        if alert.runModalOnTop() == .alertFirstButtonReturn {
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
    var systemAudioRecordIndicator: HoverIconButton!
    var micRecordButton: HoverIconButton!
    var liveTimerStack: NSStackView!
    var liveTimerDot: NSImageView!
    var liveTimerLabel: NSTextField!
    var idleDivider1: NSBox!
    var idleDivider2: NSBox!
    var idleDivider3: NSBox!
    var idleDivider4: NSBox!
    var idleAnnotateButton: HoverIconButton!
    var recAnnotateButton: HoverIconButton!
    var idleDivider5: NSBox!
    var recDivider1: NSBox!
    var recDivider2: NSBox!
    var settingsPopUp: HoverPopUpButton!
    var annotationToolbarView: AnnotationToolbarView?
    var isAnnotationActive: Bool = false
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
    var openTrimmers: [VideoTrimmerWindow] = []

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
        AnnotationManager.shared.setupGlobalHotkeys()
        setupCameraIfNeeded()
        
        // Check if launched with video file arguments via CLI or Finder cold start
        let videoExts = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
        var cliURLs: [URL] = []
        for arg in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: arg)
            if videoExts.contains(url.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: url.path) {
                cliURLs.append(url)
            }
        }
        if let first = cliURLs.first {
            openVideoTrimmer(for: first)
            if cliURLs.count > 1, let trimmer = openTrimmers.last {
                trimmer.addVideos(urls: Array(cliURLs.dropFirst()))
            }
        }
        
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
            if AnnotationManager.shared.isActive {
                AnnotationManager.shared.handleScreenParametersChanged()
            }
        }
        
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.panel?.toolbarEffectView?.updateColors()
            self?.updateButtonImage()
            AnnotationManager.shared.toolbarView?.updateColors()
        }
    }

    func activeScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSPointInRect(mouseLoc, $0.frame) }) ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    func centerPanel(on targetScreen: NSScreen) {
        guard let panel = panel else { return }
        let visibleFrame = targetScreen.visibleFrame
        let width = panel.frame.width
        let height = panel.frame.height
        let newX = round(visibleFrame.minX + (visibleFrame.width - width) / 2.0)
        let newY = max(round(visibleFrame.minY + 30.0), round(targetScreen.frame.minY + 80.0))
        panel.setFrame(NSRect(x: newX, y: newY, width: width, height: height), display: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let currentScreen = activeScreen()
        if panel.screen != currentScreen || !panel.frame.intersects(currentScreen.visibleFrame) {
            centerPanel(on: currentScreen)
        }
        showPanel()
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

        let openVideoItem = NSMenuItem(title: "Open Video to Edit...", action: #selector(openVideoFileDialog), keyEquivalent: "o")
        let scissorsConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        openVideoItem.image = NSImage(systemSymbolName: "scissors.badge.ellipsis", accessibilityDescription: "Open Video to Edit")?.withSymbolConfiguration(scissorsConfig)
        openVideoItem.target = self
        statusMenu.addItem(openVideoItem)

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

    func openVideoTrimmer(for fileURL: URL, onTrimCompleted: ((URL) -> Void)? = nil) {
        if let existing = openTrimmers.first(where: { $0.fileURL == fileURL }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let trimmer = VideoTrimmerWindow(fileURL: fileURL)
        if let onTrimCompleted = onTrimCompleted {
            trimmer.onTrimCompleted = onTrimCompleted
        }
        trimmer.onWindowWillClose = { [weak self, weak trimmer] win in
            guard let self = self, let win = trimmer else { return }
            self.openTrimmers.removeAll(where: { $0 === win })
            if self.openTrimmers.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        openTrimmers.append(trimmer)
        trimmer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let existing = openTrimmers.first {
            existing.addVideos(urls: [url])
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openVideoTrimmer(for: url)
        }
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let videoExts = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"])
        let urls = filenames.map { URL(fileURLWithPath: $0) }.filter { videoExts.contains($0.pathExtension.lowercased()) }
        guard let first = urls.first else { return }

        if let existing = openTrimmers.first {
            existing.addVideos(urls: urls)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openVideoTrimmer(for: first)
            if urls.count > 1, let trimmer = openTrimmers.last {
                trimmer.addVideos(urls: Array(urls.dropFirst()))
            }
        }
    }

    @objc func openVideoFileDialog() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Video(s) to Edit or Stitch"
        openPanel.prompt = "Edit Video"
        openPanel.showsHiddenFiles = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = true
        if #available(macOS 11.0, *) {
            openPanel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        } else {
            openPanel.allowedFileTypes = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
        }
        openPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        NSApp.activate(ignoringOtherApps: true)
        if openPanel.runModal() == .OK, let first = openPanel.urls.first {
            if let existing = openTrimmers.first {
                existing.addVideos(urls: openPanel.urls)
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openVideoTrimmer(for: first)
                if openPanel.urls.count > 1, let trimmer = openTrimmers.last {
                    trimmer.addVideos(urls: Array(openPanel.urls.dropFirst()))
                }
            }
        }
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
        let currentScreen = activeScreen()
        if panel.screen != currentScreen || !panel.frame.intersects(currentScreen.visibleFrame) {
            centerPanel(on: currentScreen)
        }
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
            RecAboutFeature(symbol: "pencil.tip.crop.circle", color: .systemCyan, title: "Live Screen Annotations", desc: "Apple Markup style floating palette with Pen, Brush, Highlighter, Magic Laser Writer, Shapes, and Eraser."),
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
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 0.85)
                : NSColor(white: 0.98, alpha: 0.85)
        }).cgColor
        
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
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
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
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(name: nil, dynamicProvider: { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.12, alpha: 0.85)
                : NSColor(white: 0.98, alpha: 0.85)
        }).cgColor

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
        win.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.permissionsWindow = win

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            self?.permissionsTimer?.invalidate()
            self?.permissionsTimer = nil
            self?.permissionButtons = []
            self?.permissionsWindow = nil
        }

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
            let newer = self.isNewer(remote, than: appVersion)
            var notes = ""
            if let logs = json["changelog"] as? [[String: Any]] {
                let targetEntries: [[String: Any]]
                if newer {
                    targetEntries = logs.filter { entry in
                        if let v = entry["version"] as? String {
                            return self.isNewer(v, than: appVersion)
                        }
                        return false
                    }
                } else {
                    targetEntries = Array(logs.prefix(2))
                }
                notes = targetEntries.compactMap { entry -> String? in
                    guard let v = entry["version"] as? String,
                          let changes = entry["changes"] as? [String] else { return nil }
                    let changeList = changes.map { "•  \($0)" }.joined(separator: "\n")
                    return "Version \(v):\n\(changeList)"
                }.joined(separator: "\n\n")
            }
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
            if alert.runModalOnTop() == .alertFirstButtonReturn {
                downloadAndInstallUpdate()
            }
        } else if remote != nil {
            alert.messageText = "You're Up to Date!"
            alert.informativeText = "Rec v\(appVersion) is the latest version. Recent updates:"
            if !changelog.isEmpty {
                alert.accessoryView = createChangelogView(changelog: changelog)
            }
            alert.addButton(withTitle: "OK")
            alert.runModalOnTop()
        } else {
            alert.messageText = "Couldn't Check for Updates"
            alert.informativeText = "Please check your internet connection and try again."
            alert.addButton(withTitle: "OK")
            alert.runModalOnTop()
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
                    err.runModalOnTop()
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
                    err.runModalOnTop()
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4)
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
        let screen = activeScreen()
        let rect = NSRect(x: screen.visibleFrame.midX - 5, y: screen.visibleFrame.minY + 50, width: 10, height: 10)
        panel = FloatingPanel(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
        guard let contentView = panel.toolbarEffectView ?? panel.contentView else { return }

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

        // ---- SYSTEM AUDIO RECORD INDICATOR ----
        systemAudioRecordIndicator = HoverIconButton()
        systemAudioRecordIndicator.translatesAutoresizingMaskIntoConstraints = false
        systemAudioRecordIndicator.isBordered = false
        systemAudioRecordIndicator.imagePosition = .imageOnly
        systemAudioRecordIndicator.wantsLayer = true
        systemAudioRecordIndicator.layer?.cornerRadius = 7
        systemAudioRecordIndicator.toolTip = "Recording System Audio"
        systemAudioRecordIndicator.isHidden = true
        systemAudioRecordIndicator.widthAnchor.constraint(equalToConstant: 28).isActive = true
        systemAudioRecordIndicator.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // ---- MIC RECORD BUTTON (LIVE MUTE TOGGLE) ----
        micRecordButton = HoverIconButton()
        micRecordButton.translatesAutoresizingMaskIntoConstraints = false
        micRecordButton.isBordered = false
        micRecordButton.imagePosition = .imageOnly
        micRecordButton.wantsLayer = true
        micRecordButton.layer?.cornerRadius = 7
        micRecordButton.target = self
        micRecordButton.action = #selector(toggleMicMute)
        micRecordButton.toolTip = "Microphone Active (Click to Mute)"
        micRecordButton.isHidden = true
        micRecordButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        micRecordButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

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

        // ---- ANNOTATION BUTTON (IDLE) ----
        idleAnnotateButton = HoverIconButton()
        idleAnnotateButton.translatesAutoresizingMaskIntoConstraints = false
        idleAnnotateButton.isBordered = false
        idleAnnotateButton.imagePosition = .imageOnly
        idleAnnotateButton.wantsLayer = true
        idleAnnotateButton.layer?.cornerRadius = 7
        idleAnnotateButton.toolTip = "Screen Annotation (⌥A)"
        let penCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
        idleAnnotateButton.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Annotate Screen")?.withSymbolConfiguration(penCfg)
        idleAnnotateButton.target = self
        idleAnnotateButton.action = #selector(toggleAnnotationHotkey)
        idleAnnotateButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        idleAnnotateButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // ---- ANNOTATION BUTTON (RECORDING) ----
        recAnnotateButton = HoverIconButton()
        recAnnotateButton.translatesAutoresizingMaskIntoConstraints = false
        recAnnotateButton.isBordered = false
        recAnnotateButton.imagePosition = .imageOnly
        recAnnotateButton.wantsLayer = true
        recAnnotateButton.layer?.cornerRadius = 7
        recAnnotateButton.toolTip = "Screen Annotation (⌥A)"
        recAnnotateButton.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Annotate Screen")?.withSymbolConfiguration(penCfg)
        recAnnotateButton.target = self
        recAnnotateButton.action = #selector(toggleAnnotationHotkey)
        recAnnotateButton.isHidden = true
        recAnnotateButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        recAnnotateButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // ---- HAIRLINE DIVIDERS ----
        let makeDivider = { () -> NSBox in
            let div = NSBox()
            div.boxType = .custom
            div.isTransparent = false
            div.borderWidth = 0
            div.fillColor = NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.12)
                    : NSColor.black.withAlphaComponent(0.08)
            })
            div.translatesAutoresizingMaskIntoConstraints = false
            div.widthAnchor.constraint(equalToConstant: 1).isActive = true
            div.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return div
        }

        idleDivider1 = makeDivider()
        idleDivider2 = makeDivider()
        idleDivider3 = makeDivider()
        idleDivider4 = makeDivider()
        idleDivider5 = makeDivider()
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
            idleAnnotateButton,
            idleDivider5,
            cameraRecordButton,
            systemAudioRecordIndicator,
            micRecordButton,
            recAnnotateButton,
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
        let bottomWidth = ceil(contentView.fittingSize.width)
        let initialX = round(screen.visibleFrame.minX + (screen.visibleFrame.width - bottomWidth) / 2.0)
        let initialY = max(round(screen.visibleFrame.minY + 30.0), round(screen.frame.minY + 80.0))
        let initialRect = NSRect(x: initialX, y: initialY, width: bottomWidth, height: 48.0)
        panel.setFrame(initialRect, display: true)
        panel.mainShadowContainer.frame = NSRect(x: 0, y: 0, width: bottomWidth, height: 48.0)
        updateButtonImage()
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
            toast.orderFrontRegardless()
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
            alert.runModalOnTop()
        }
        
        var isSysAudioActive = false
        recorder.onSystemAudioLevel = { [weak self] level in
            guard let self = self else { return }
            guard self.recorder.isRecording else { return }
            let hasSysAudio = (currentSettings.audioSource == 0 || currentSettings.audioSource == 2)
            guard hasSysAudio else { return }
            
            let isActive = level > -45.0
            if isActive != isSysAudioActive {
                isSysAudioActive = isActive
                self.systemAudioRecordIndicator?.contentTintColor = isActive ? .systemGreen : .systemCyan
            }
        }

        var isMicActive = false
        recorder.onMicAudioLevel = { [weak self] level in
            guard let self = self else { return }
            guard self.recorder.isRecording else { return }
            let isMicEnabled = (currentSettings.audioSource == 1 || currentSettings.audioSource == 2)
            guard isMicEnabled else { return }
            
            if self.recorder.isMicMuted {
                if isMicActive {
                    isMicActive = false
                    self.micRecordButton?.contentTintColor = .systemRed
                }
                return
            }
            
            let isActive = level > -38.0
            if isActive != isMicActive {
                isMicActive = isActive
                self.micRecordButton?.contentTintColor = isActive ? .systemGreen : .systemCyan
            }
        }
    }

    @objc func toggleMicMute() {
        guard recorder.isRecording else { return }
        if currentSettings.audioSource == 1 || currentSettings.audioSource == 2 {
            _ = recorder.toggleMicMute()
            updateButtonImage()
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

    @objc func toggleAnnotationHotkey() {
        AnnotationManager.shared.toggleAnnotationMode()
    }

    func updateHUDLayout() {
        guard let panel = panel, let root = panel.rootContainer, let mainShadow = panel.mainShadowContainer, let effectView = panel.toolbarEffectView else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }

        effectView.layoutSubtreeIfNeeded()
        let bottomWidth = ceil(effectView.fittingSize.width)
        let bottomHeight: CGFloat = 48.0

        if isAnnotationActive {
            if annotationToolbarView == nil {
                let toolbar = AnnotationToolbarView()
                root.addSubview(toolbar)
                root.annotationToolbarView = toolbar
                self.annotationToolbarView = toolbar
            }
            annotationToolbarView?.isHidden = false

            let annotWidth = annotationToolbarView?.neededWidth ?? 860.0
            let annotHeight: CGFloat = 48.0
            let gap: CGFloat = 8.0

            let totalWidth = max(bottomWidth, annotWidth)
            let totalHeight = bottomHeight + gap + annotHeight

            let mainX = (totalWidth - bottomWidth) / 2.0
            let annotX = (totalWidth - annotWidth) / 2.0

            let currentCenter = panel.frame.midX
            let currentBottom = panel.frame.minY
            var newOriginX = currentCenter - totalWidth / 2.0
            var newOriginY = currentBottom

            let screenBounds = screen.visibleFrame
            if newOriginY + totalHeight > screenBounds.maxY {
                newOriginY = screenBounds.maxY - totalHeight
            }
            if newOriginX < screenBounds.minX {
                newOriginX = screenBounds.minX
            } else if newOriginX + totalWidth > screenBounds.maxX {
                newOriginX = screenBounds.maxX - totalWidth
            }

            mainShadow.frame = NSRect(x: mainX, y: 0, width: bottomWidth, height: bottomHeight)
            annotationToolbarView?.frame = NSRect(x: annotX, y: bottomHeight + gap, width: annotWidth, height: annotHeight)
            let newWindowFrame = NSRect(x: newOriginX, y: newOriginY, width: totalWidth, height: totalHeight)
            panel.setFrame(newWindowFrame, display: true, animate: false)
        } else {
            annotationToolbarView?.isHidden = true

            let totalWidth = bottomWidth
            let totalHeight = bottomHeight

            let currentCenter = panel.frame.midX
            let currentBottom = panel.frame.minY
            var newOriginX = currentCenter - totalWidth / 2.0
            let newOriginY = currentBottom

            let screenBounds = screen.visibleFrame
            if newOriginX < screenBounds.minX {
                newOriginX = screenBounds.minX
            } else if newOriginX + totalWidth > screenBounds.maxX {
                newOriginX = screenBounds.maxX - totalWidth
            }

            mainShadow.frame = NSRect(x: 0, y: 0, width: bottomWidth, height: bottomHeight)
            let newWindowFrame = NSRect(x: newOriginX, y: newOriginY, width: totalWidth, height: totalHeight)
            panel.setFrame(newWindowFrame, display: true, animate: false)
        }
    }

    func updateAnnotationButtonState() {
        let active = AnnotationManager.shared.isActive
        let activeColor = NSColor.systemBlue
        let normalIdle = NSColor.labelColor
        let normalRec = NSColor.systemCyan

        idleAnnotateButton?.contentTintColor = active ? activeColor : normalIdle
        recAnnotateButton?.contentTintColor = active ? activeColor : normalRec

        let penConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: active ? .semibold : .regular)
        let symName = active ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
        idleAnnotateButton?.image = NSImage(systemSymbolName: symName, accessibilityDescription: "Annotate Screen")?.withSymbolConfiguration(penConfig)
        recAnnotateButton?.image = NSImage(systemSymbolName: symName, accessibilityDescription: "Annotate Screen")?.withSymbolConfiguration(penConfig)
    }

    @objc func toggleRecording() {
        if !regionSelectionWindows.isEmpty {
            for window in regionSelectionWindows {
                if let view = window.contentView as? RegionSelectionView,
                   view.currentRect.width > 5 && view.currentRect.height > 5 {
                    view.onSelectionComplete?(view.currentRect)
                    return
                }
            }
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
                window.orderFrontRegardless()
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
                window.orderFrontRegardless()
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
        idleAnnotateButton?.isHidden = isRec
        idleDivider5?.isHidden = isRec

        // Show live recording controls and dividers
        cameraRecordButton.isHidden = !isRec
        recAnnotateButton?.isHidden = !isRec
        updateAnnotationButtonState()
        recDivider1?.isHidden = !isRec
        liveTimerStack.isHidden = !isRec
        recDivider2?.isHidden = !isRec
        pauseButton.isHidden = !isRec

        let isSysAudioEnabled = (currentSettings.audioSource == 0 || currentSettings.audioSource == 2)
        let isMicEnabled = (currentSettings.audioSource == 1 || currentSettings.audioSource == 2)
        let isMutedSource = (currentSettings.audioSource == 3)

        // 1. System Audio Indicator
        if isSysAudioEnabled {
            systemAudioRecordIndicator.isHidden = !isRec
            let sysConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
            systemAudioRecordIndicator.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "System Audio Active")?.withSymbolConfiguration(sysConfig)
            systemAudioRecordIndicator.contentTintColor = .systemCyan
            systemAudioRecordIndicator.toolTip = "Recording System Audio"
        } else if isMutedSource {
            systemAudioRecordIndicator.isHidden = !isRec
            let sysConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
            systemAudioRecordIndicator.image = NSImage(systemSymbolName: "speaker.slash", accessibilityDescription: "Audio Muted")?.withSymbolConfiguration(sysConfig)
            systemAudioRecordIndicator.contentTintColor = .tertiaryLabelColor
            systemAudioRecordIndicator.toolTip = "No Audio Recording"
        } else {
            systemAudioRecordIndicator.isHidden = true
        }

        // 2. Microphone Indicator & Live Mute Toggle
        if isMicEnabled {
            micRecordButton.isHidden = !isRec
            if recorder.isMicMuted {
                let mutedConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
                micRecordButton.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone Muted")?.withSymbolConfiguration(mutedConfig)
                micRecordButton.contentTintColor = .systemRed
                micRecordButton.toolTip = "Microphone Muted (Click to Unmute)"
            } else {
                let micConfig = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .regular)
                micRecordButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone Active")?.withSymbolConfiguration(micConfig)
                micRecordButton.contentTintColor = .systemCyan
                micRecordButton.toolTip = "Microphone Active (Click to Mute)"
            }
        } else {
            micRecordButton.isHidden = true
        }

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

        // Re-layout panel to adapt size with smooth animation, preserving exact uniform 48pt height
        updateHUDLayout()

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
        AnnotationManager.shared.stopAnnotationMode()
        AnnotationManager.shared.removeGlobalHotkeys()
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
