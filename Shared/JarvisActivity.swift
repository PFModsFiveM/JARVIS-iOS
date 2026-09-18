import ActivityKit
import Foundation

/// JARVIS's Live Activity - the lock screen and the Dynamic Island. Compiled into both the app, which starts and updates
/// it, and the widget extension, which draws it.
struct JarvisActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Mode: String, Codable, Hashable {
            case listening, thinking, speaking, watching, controlling, transfer, power
        }

        var mode: Mode
        /// One short line: "Watching display 2", "Restarting", "Sending photo.jpg".
        var title: String
        /// JARVIS's answer, the network, what is being sent - whatever fills the expanded view.
        var detail: String
        /// 0-1 for a transfer; nil otherwise.
        var progress: Double?
        /// When a countdown ends (a restart or shut-down); nil otherwise.
        var endsAt: Date?

        /// The jarvis:// link the activity's button opens, when it has one.
        var action: URL? {
            switch mode {
            case .power: return URL(string: "jarvis://cancelpower")
            case .watching, .controlling: return URL(string: "jarvis://stopwatch")
            default: return nil
            }
        }

        var actionTitle: String {
            switch mode {
            case .power: return "Cancel"
            case .watching, .controlling: return "Stop"
            default: return ""
            }
        }

        var symbol: String {
            switch mode {
            case .listening: return "waveform"
            case .thinking: return "ellipsis"
            case .speaking: return "text.bubble"
            case .watching: return "display"
            case .controlling: return "hand.point.up.left"
            case .transfer: return "arrow.up.arrow.down"
            case .power: return "power"
            }
        }
    }

    var pcName: String
}
