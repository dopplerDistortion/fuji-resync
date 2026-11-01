import ActivityKit
import Foundation

/// A shooting session's Live Activity: the link, the geotags sent, and the shots fired from resync, shown
/// on the lock screen and in the Dynamic Island. The app updates it locally while the session
/// keeps it running in the background; there is no push server.
struct SessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Link: String, Codable, Hashable { case linked, searching, lost }

        var link: Link
        /// Geotags sent to the camera since the session started.
        var geotags: Int
        var lastGeotag: Date?
        /// Horizontal accuracy of the last geotag, in metres.
        var accuracy: Int?
        /// Frames fired from resync since the session started.
        var frames: Int
        var geotagOn: Bool
    }

    var camera: String
    var startedAt: Date
}
