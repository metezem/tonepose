import AudioToolbox
import Foundation
import os

/// Teardown order: stop I/O → destroy IO proc → destroy aggregate → destroy process tap.
struct TapResources {
    private static let log = Logger(subsystem: "dev.tonepose", category: "TapResources")

    var tapID: AudioObjectID = .unknown
    var aggregateDeviceID: AudioObjectID = .unknown
    var deviceProcID: AudioDeviceIOProcID?
    var tapDescription: CATapDescription?

    mutating func destroy() {
        let aggID = aggregateDeviceID
        let tID = tapID

        if aggID.isValid, let procID = deviceProcID {
            let stopErr = AudioDeviceStop(aggID, procID)
            if stopErr != noErr { Self.log.error("AudioDeviceStop failed: \(stopErr)") }
            let dErr = AudioDeviceDestroyIOProcID(aggID, procID)
            if dErr != noErr { Self.log.error("AudioDeviceDestroyIOProcID failed: \(dErr)") }
        }
        deviceProcID = nil

        if aggID.isValid {
            let aggErr = AudioHardwareDestroyAggregateDevice(aggID)
            if aggErr != noErr { Self.log.error("AudioHardwareDestroyAggregateDevice failed: \(aggErr)") }
        }
        aggregateDeviceID = .unknown

        if tID.isValid {
            let tapErr = AudioHardwareDestroyProcessTap(tID)
            if tapErr != noErr { Self.log.error("AudioHardwareDestroyProcessTap failed: \(tapErr)") }
        }
        tapID = .unknown
        tapDescription = nil
    }
}
