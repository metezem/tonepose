import AudioToolbox
import Darwin
import Foundation
import os

/// Core Audio process tap → aggregate device → HAL I/O with optional New Time Pitch.
final class TransposeTapEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "dev.tonepose", category: "Engine")
    private let queue = DispatchQueue(label: "dev.tonepose.hal", qos: .userInitiated)

    private var resources = TapResources()
    private var activated = false
    private let pitch = NewTimePitchProcessor()

    private nonisolated(unsafe) var stereoLeft: Int = 0
    private nonisolated(unsafe) var stereoRight: Int = 1
    private nonisolated(unsafe) var bypassPitch: Bool = true

    private var callbackGeneration: UInt32 = 0
    private nonisolated(unsafe) var activeCallbackGeneration: UInt32 = 0

    var isRunning: Bool { activated }

    func updateSemitones(_ semitones: Float) {
        let bypass = abs(semitones) < 0.01
        bypassPitch = bypass
        pitch.setSemitones(semitones)
    }

    func stop() {
        resources.destroy()
        pitch.teardown()
        activated = false
        callbackGeneration &+= 1
    }

    func activate(processObjectIDs: [AudioObjectID], outputDeviceUID: String, semitones: Float) throws {
        stop()
        guard !processObjectIDs.isEmpty else {
            throw NSError(domain: "tonepose", code: -3, userInfo: [NSLocalizedDescriptionKey: "No process IDs for tap"])
        }

        let mixdownTap = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        mixdownTap.uuid = UUID()
        mixdownTap.muteBehavior = .mutedWhenTapped

        var tapID: AudioObjectID = .unknown
        let tapErr = AudioHardwareCreateProcessTap(mixdownTap, &tapID)
        guard tapErr == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(tapErr), userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateProcessTap failed"])
        }

        resources.tapDescription = mixdownTap
        resources.tapID = tapID

        let tapFormat = try tapID.readAudioTapStreamBasicDescription()

        let aggDesc = Self.buildAggregateDescription(outputUIDs: [outputDeviceUID], tapUUID: mixdownTap.uuid)
        var aggID: AudioObjectID = .unknown
        var err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard err == noErr else {
            resources.destroy()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Aggregate device failed"])
        }
        resources.aggregateDeviceID = aggID

        guard resources.aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            resources.destroy()
            throw NSError(domain: "tonepose", code: -4, userInfo: [NSLocalizedDescriptionKey: "Aggregate device not ready"])
        }

        let devID = try outputDeviceUIDToID(outputDeviceUID)
        let ch = devID.preferredStereoChannelIndices()
        stereoLeft = ch.left
        stereoRight = ch.right

        try pitch.prepare(tapASBD: tapFormat)

        bypassPitch = abs(semitones) < 0.01
        pitch.setSemitones(semitones)

        callbackGeneration &+= 1
        let cbGen = callbackGeneration
        activeCallbackGeneration = cbGen

        err = AudioDeviceCreateIOProcIDWithBlock(&resources.deviceProcID, resources.aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else {
                Self.zeroOutput(outOutputData)
                return
            }
            self.render(inInputData: inInputData, outOutputData: outOutputData, generation: cbGen)
        }

        guard err == noErr else {
            resources.destroy()
            pitch.teardown()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcIDWithBlock failed"])
        }

        err = AudioDeviceStart(resources.aggregateDeviceID, resources.deviceProcID)
        guard err == noErr else {
            resources.destroy()
            pitch.teardown()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed"])
        }

        activated = true
        log.info("Tap engine active (\(processObjectIDs.count) process object(s)) → \(outputDeviceUID, privacy: .public)")
    }

    private nonisolated func render(
        inInputData: UnsafePointer<AudioBufferList>?,
        outOutputData: UnsafeMutablePointer<AudioBufferList>?,
        generation: UInt32
    ) {
        guard generation == activeCallbackGeneration, let inInputData, let outOutputData else {
            Self.zeroOutput(outOutputData)
            return
        }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)

        let frameCount = Self.frameCount(input: inputBuffers, output: outputBuffers)
        guard frameCount > 0 else {
            Self.zeroOutput(outOutputData)
            return
        }

        if bypassPitch {
            Self.copyBuffers(inputBuffers: inputBuffers, outputBuffers: outputBuffers, frameCount: frameCount, left: stereoLeft, right: stereoRight)
        } else {
            // Full dry routing first so every output buffer matches bypass (avoids wrong `inputIndex` when faking a 1-buffer output).
            Self.copyBuffers(inputBuffers: inputBuffers, outputBuffers: outputBuffers, frameCount: frameCount, left: stereoLeft, right: stereoRight)
            _ = pitch.process(
                input: inputBuffers,
                output: outputBuffers,
                frameCount: frameCount,
                left: stereoLeft,
                right: stereoRight
            )
        }
    }

    private nonisolated static func frameCount(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var minIn = Int.max
        for i in 0..<input.count {
            let ch = max(1, Int(input[i].mNumberChannels))
            let bytes = Int(input[i].mDataByteSize)
            let frames = bytes / (ch * MemoryLayout<Float>.size)
            minIn = min(minIn, frames)
        }
        if minIn == Int.max { minIn = 0 }

        var minOut = Int.max
        for i in 0..<output.count {
            let ch = max(1, Int(output[i].mNumberChannels))
            let bytes = Int(output[i].mDataByteSize)
            let frames = bytes / (ch * MemoryLayout<Float>.size)
            minOut = min(minOut, frames)
        }
        if minOut == Int.max { minOut = 0 }
        return max(0, min(minIn, minOut))
    }

    /// Stereo pair that `copyBuffers` would send to **output buffer 0** (same `inputIndex` as `oi == 0`, using the real HAL output buffer count).
    nonisolated static func extractStereoForFirstOutput(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        referenceOutputBuffers: UnsafeMutableAudioBufferListPointer,
        dest: UnsafeMutablePointer<Float>,
        frameCount: Int,
        left: Int,
        right: Int
    ) {
        let inputBufferCount = inputBuffers.count
        let outputBufferCount = referenceOutputBuffers.count
        let byteStereo = frameCount * 2 * MemoryLayout<Float>.size
        guard outputBufferCount > 0 else {
            memset(dest, 0, byteStereo)
            return
        }

        let outChRef = max(1, Int(referenceOutputBuffers[0].mNumberChannels))

        if inputBufferCount == 2,
           outputBufferCount == 1,
           inputBuffers[0].mNumberChannels == 1,
           inputBuffers[1].mNumberChannels == 1,
           let l = inputBuffers[0].mData,
           let r = inputBuffers[1].mData
        {
            let lf = l.assumingMemoryBound(to: Float.self)
            let rf = r.assumingMemoryBound(to: Float.self)
            for f in 0..<frameCount {
                dest[2 * f] = lf[f]
                dest[2 * f + 1] = rf[f]
            }
            return
        }

        let oi = 0
        let inputIndex: Int = if inputBufferCount > outputBufferCount {
            inputBufferCount - outputBufferCount + oi
        } else {
            oi
        }

        guard inputIndex < inputBufferCount, let iPtr = inputBuffers[inputIndex].mData else {
            memset(dest, 0, byteStereo)
            return
        }

        let inCh = max(1, Int(inputBuffers[inputIndex].mNumberChannels))
        let inSamples = iPtr.assumingMemoryBound(to: Float.self)
        let inSampleCount = Int(inputBuffers[inputIndex].mDataByteSize) / MemoryLayout<Float>.size
        let inFrames = inSampleCount / inCh
        let useFrames = min(frameCount, inFrames)

        let safeL = min(max(left, 0), max(outChRef - 1, 0))
        let safeR = min(max(right, 0), max(outChRef - 1, 0))

        if inCh == outChRef {
            for f in 0..<useFrames {
                let inBase = f * inCh
                dest[2 * f] = inSamples[inBase + safeL]
                dest[2 * f + 1] = inSamples[inBase + safeR]
            }
        } else if inCh == 2, outChRef > 2 {
            for f in 0..<useFrames {
                let inBase = f * 2
                dest[2 * f] = inSamples[inBase]
                dest[2 * f + 1] = inSamples[inBase + 1]
            }
        } else if inCh == 1, outChRef > 1 {
            for f in 0..<useFrames {
                let s = inSamples[f]
                dest[2 * f] = s
                dest[2 * f + 1] = s
            }
        } else {
            let copied = min(inCh, outChRef)
            for f in 0..<useFrames {
                let inBase = f * inCh
                dest[2 * f] = safeL < copied ? inSamples[inBase + safeL] : 0
                dest[2 * f + 1] = safeR < copied ? inSamples[inBase + safeR] : 0
            }
        }
        if useFrames < frameCount {
            memset(dest.advanced(by: useFrames * 2), 0, (frameCount - useFrames) * 2 * MemoryLayout<Float>.size)
        }
    }

    /// Patch processed stereo onto **output buffer 0** at the preferred left/right speaker channels.
    nonisolated static func spreadStereoToFirstOutput(
        source: UnsafeMutablePointer<Float>,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        left: Int,
        right: Int
    ) {
        guard outputBuffers.count > 0, let oPtr = outputBuffers[0].mData else { return }
        let outCh = max(1, Int(outputBuffers[0].mNumberChannels))
        let outSamples = oPtr.assumingMemoryBound(to: Float.self)
        let safeL = min(max(left, 0), max(outCh - 1, 0))
        let safeR = min(max(right, 0), max(outCh - 1, 0))
        for f in 0..<frameCount {
            let outBase = f * outCh
            outSamples[outBase + safeL] = source[2 * f]
            outSamples[outBase + safeR] = source[2 * f + 1]
        }
    }

    /// Map tap buffers to output (float32); handles common stereo / tap layouts.
    private nonisolated static func copyBuffers(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        left: Int,
        right: Int
    ) {
        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count

        if inputBufferCount == 2,
           outputBufferCount == 1,
           inputBuffers[0].mNumberChannels == 1,
           inputBuffers[1].mNumberChannels == 1,
           outputBuffers[0].mNumberChannels == 2,
           let l = inputBuffers[0].mData,
           let r = inputBuffers[1].mData,
           let o = outputBuffers[0].mData
        {
            let lf = l.assumingMemoryBound(to: Float.self)
            let rf = r.assumingMemoryBound(to: Float.self)
            let of = o.assumingMemoryBound(to: Float.self)
            for f in 0..<frameCount {
                of[2 * f] = lf[f]
                of[2 * f + 1] = rf[f]
            }
            return
        }

        for oi in 0..<outputBufferCount {
            guard let oPtr = outputBuffers[oi].mData else { continue }
            let outCh = max(1, Int(outputBuffers[oi].mNumberChannels))
            let outSamples = oPtr.assumingMemoryBound(to: Float.self)
            let outSampleCount = Int(outputBuffers[oi].mDataByteSize) / MemoryLayout<Float>.size

            let inputIndex: Int = if inputBufferCount > outputBufferCount {
                inputBufferCount - outputBufferCount + oi
            } else {
                oi
            }

            guard inputIndex < inputBufferCount, let iPtr = inputBuffers[inputIndex].mData else {
                memset(oPtr, 0, Int(outputBuffers[oi].mDataByteSize))
                continue
            }

            let inCh = max(1, Int(inputBuffers[inputIndex].mNumberChannels))
            let inSamples = iPtr.assumingMemoryBound(to: Float.self)
            let inSampleCount = Int(inputBuffers[inputIndex].mDataByteSize) / MemoryLayout<Float>.size
            let inFrames = inSampleCount / inCh

            let useFrames = min(frameCount, inFrames)
            let safeL = min(max(left, 0), max(outCh - 1, 0))
            let safeR = min(max(right, 0), max(outCh - 1, 0))

            if inCh == outCh {
                let sampleCount = useFrames * inCh
                if sampleCount <= outSampleCount {
                    memcpy(oPtr, iPtr, sampleCount * MemoryLayout<Float>.size)
                }
                if sampleCount < outSampleCount {
                    memset(outSamples.advanced(by: sampleCount), 0, (outSampleCount - sampleCount) * MemoryLayout<Float>.size)
                }
            } else if inCh == 2, outCh > 2 {
                for f in 0..<useFrames {
                    let inBase = f * 2
                    let outBase = f * outCh
                    let l = inSamples[inBase]
                    let r = inSamples[inBase + 1]
                    for c in 0..<outCh { outSamples[outBase + c] = 0 }
                    outSamples[outBase + safeL] = l
                    outSamples[outBase + safeR] = r
                }
                let written = useFrames * outCh
                if written < outSampleCount {
                    memset(outSamples.advanced(by: written), 0, (outSampleCount - written) * MemoryLayout<Float>.size)
                }
            } else if inCh == 1, outCh > 1 {
                for f in 0..<useFrames {
                    let s = inSamples[f]
                    let outBase = f * outCh
                    for c in 0..<outCh { outSamples[outBase + c] = 0 }
                    outSamples[outBase + safeL] = s
                    outSamples[outBase + safeR] = s
                }
                let written = useFrames * outCh
                if written < outSampleCount {
                    memset(outSamples.advanced(by: written), 0, (outSampleCount - written) * MemoryLayout<Float>.size)
                }
            } else {
                for f in 0..<useFrames {
                    let inBase = f * inCh
                    let outBase = f * outCh
                    let copied = min(inCh, outCh)
                    for c in 0..<copied {
                        outSamples[outBase + c] = inSamples[inBase + c]
                    }
                    if copied < outCh {
                        for c in copied..<outCh {
                            outSamples[outBase + c] = 0
                        }
                    }
                }
                let written = useFrames * outCh
                if written < outSampleCount {
                    memset(outSamples.advanced(by: written), 0, (outSampleCount - written) * MemoryLayout<Float>.size)
                }
            }
        }
    }

    private nonisolated static func zeroOutput(_ out: UnsafeMutablePointer<AudioBufferList>?) {
        guard let out else { return }
        for buf in UnsafeMutableAudioBufferListPointer(out) {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
    }

    private func outputDeviceUIDToID(_ uid: String) throws -> AudioDeviceID {
        for id in try AudioObjectID.readDeviceList() {
            if (try? id.readDeviceUID()) == uid { return id }
        }
        throw NSError(domain: "tonepose", code: -5, userInfo: [NSLocalizedDescriptionKey: "Output device not found"])
    }

    private static func buildAggregateDescription(outputUIDs: [String], tapUUID: UUID) -> [String: Any] {
        precondition(!outputUIDs.isEmpty)
        var subDevices: [[String: Any]] = []
        for (index, uid) in outputUIDs.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceDriftCompensationKey: index > 0
            ])
        }
        let clock = outputUIDs[0]
        return [
            kAudioAggregateDeviceNameKey: "tonepose-\(tapUUID.uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceClockDeviceKey: clock,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }
}
