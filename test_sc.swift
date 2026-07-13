import ScreenCaptureKit
let config = SCStreamConfiguration()
#if compiler(>=5.9)
if #available(macOS 14.0, *) {
    config.capturesMouseClicks = true
}
#endif
