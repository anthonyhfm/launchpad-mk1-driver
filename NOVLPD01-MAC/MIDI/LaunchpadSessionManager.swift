import Foundation

@MainActor
final class LaunchpadSessionManager {
    private let repository: LaunchpadRepository
    private let midiClient: CoreMIDIClient?
    private var observationTask: Task<Void, Never>?
    private var sessions: [UInt64: LaunchpadSession] = [:]
    private var assignedNumbers: [UInt64: Int] = [:]

    init(repository: LaunchpadRepository) {
        self.repository = repository

        do {
            midiClient = try CoreMIDIClient(name: "NOVLPD01-MAC")
        } catch {
            midiClient = nil
            print("[MIDI] Could not create CoreMIDI client: \(error.localizedDescription)")
        }

        observationTask = Task { [weak self, repository] in
            for await launchpads in repository.launchpadUpdates() {
                guard let self else { return }
                synchronize(with: launchpads)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil

        for session in sessions.values {
            session.stopSynchronously()
        }
        sessions.removeAll()
        assignedNumbers.removeAll()
    }

    private func synchronize(with launchpads: [LaunchpadDevice]) {
        guard let midiClient else { return }

        let connectedIDs = Set(launchpads.map(\.id))
        let removedIDs = Set(sessions.keys).subtracting(connectedIDs)

        for id in removedIDs {
            sessions.removeValue(forKey: id)?.stopSynchronously()
            assignedNumbers.removeValue(forKey: id)
        }

        let addedDevices = launchpads
            .filter { sessions[$0.id] == nil }
            .sorted {
                ($0.locationID, $0.id) < ($1.locationID, $1.id)
            }

        for device in addedDevices {
            let number = nextAvailableNumber()
            let session = LaunchpadSession(
                device: device,
                number: number,
                midiClient: midiClient
            )
            assignedNumbers[device.id] = number
            sessions[device.id] = session
            session.start()
        }
    }

    private func nextAvailableNumber() -> Int {
        let usedNumbers = Set(assignedNumbers.values)
        var candidate = 1
        while usedNumbers.contains(candidate) {
            candidate += 1
        }
        return candidate
    }
}
