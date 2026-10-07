import CoreMediaIO
import Foundation

let providerSource = CaptainProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
