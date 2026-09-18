import Foundation
import Network

/// Whether the phone is on mobile data, so live view can ask the PC for lighter frames. Watches for changes, so walking
/// out of Wi-Fi range mid-stream switches quality rather than stalling.
@MainActor
final class NetworkWatch: ObservableObject {
    @Published private(set) var cellular = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let onCellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self, self.cellular != onCellular else { return }
                self.cellular = onCellular
                AppModel.shared.networkChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "jarvis.network"))
    }
}
