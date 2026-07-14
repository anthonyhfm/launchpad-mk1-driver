import Foundation
import Observation

@MainActor
@Observable
final class LaunchpadConnectionStatus {
    private(set) var connectedLaunchpadCount = 0
    private var observationTask: Task<Void, Never>?

    init(repository: LaunchpadRepository) {
        observationTask = Task { [weak self, repository] in
            for await launchpads in repository.launchpadUpdates() {
                guard let self else { return }
                
                connectedLaunchpadCount = launchpads.count
            }
        }
    }

}
