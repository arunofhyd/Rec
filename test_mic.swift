import Foundation
import AVFoundation

let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified)
print(session.devices.count)
