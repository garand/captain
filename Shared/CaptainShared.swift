import Foundation

/// Constants shared by the host app and the camera extension.
enum CaptainShared {
    static let appBundleID = "com.garand.captain"
    static let extensionBundleID = "com.garand.captain.CameraExtension"

    /// Fixed device UID so video apps remember "Captain Camera" between launches.
    static let virtualDeviceUID = "8C3E5A71-4F2B-4D9E-A6C0-1B7D2E9F3A54"
    static let virtualDeviceName = "Captain Camera"
    static let sourceStreamName = "Captain.Video"
    static let sinkStreamName = "Captain.Video.Sink"

    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let frameRate: Int32 = 30
}
