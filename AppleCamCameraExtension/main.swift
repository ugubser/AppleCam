import Foundation
import CoreMediaIO

let queue = DispatchQueue(label: "com.vanguardsignals.AppleCam.extension")
let service = try CameraProvider(queue: queue)
CMIOExtensionProvider.startService(provider: service.provider)
CFRunLoopRun()
