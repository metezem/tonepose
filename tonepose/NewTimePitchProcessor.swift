import AudioToolbox
import Darwin
import Foundation

/// Apple `nutp` (New Time Pitch). `-10868` (`FormatNotSupported`) is handled by trying several
/// `AudioStreamBasicDescription` candidates and both input/output property orders.
final class NewTimePitchProcessor {
    private enum IOLayout {
        /// Output of `AudioUnitRender` is one interleaved stereo buffer.
        case interleavedRender
        /// Output is two mono float buffers (matches `kAudioFormatFlagIsNonInterleaved` on the unit).
        case splitRender
    }

    private var audioUnit: AudioComponentInstance?
    private var ioLayout: IOLayout = .interleavedRender
    private let maxFrames: UInt32 = 8192
    /// Monotonic sample time for `AudioUnitRender` (some units output silence with an all-zero timestamp).
    private nonisolated(unsafe) var hostSampleTime: Float64 = 0
    private var interleavedIn = [Float](repeating: 0, count: 8192 * 2)
    private var interleavedOut = [Float](repeating: 0, count: 8192 * 2)
    private var splitLeft = [Float](repeating: 0, count: 8192)
    private var splitRight = [Float](repeating: 0, count: 8192)
    /// Holds `AudioBufferList` + second `AudioBuffer` for `AudioUnitRender` when `ioLayout == .splitRender`.
    private var splitRenderABLStorage: UnsafeMutableRawPointer?

    init() {}

    func prepare(tapASBD: AudioStreamBasicDescription) throws {
        teardown()

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))
        }

        let candidates = Self.buildFormatCandidates(fromTap: tapASBD)
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var lastErr: OSStatus = kAudioUnitErr_FormatNotSupported

        for asbd in candidates {
            let layout: IOLayout = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
                ? .splitRender
                : .interleavedRender

            for outputFirst in [true, false] {
                for inputBus: AudioUnitElement in [0, 1] {
                    var au: AudioComponentInstance?
                    var err = AudioComponentInstanceNew(comp, &au)
                    guard err == noErr, let instance = au else {
                        lastErr = err
                        continue
                    }

                    var mf = maxFrames
                    err = AudioUnitSetProperty(
                        instance,
                        kAudioUnitProperty_MaximumFramesPerSlice,
                        kAudioUnitScope_Global,
                        0,
                        &mf,
                        UInt32(MemoryLayout<UInt32>.size)
                    )
                    guard err == noErr else {
                        AudioComponentInstanceDispose(instance)
                        lastErr = err
                        continue
                    }

                    var fmt = asbd
                    if outputFirst {
                        err = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, asbdSize)
                        guard err == noErr else {
                            AudioComponentInstanceDispose(instance)
                            lastErr = err
                            continue
                        }
                        fmt = asbd
                        err = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &fmt, asbdSize)
                    } else {
                        err = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &fmt, asbdSize)
                        guard err == noErr else {
                            AudioComponentInstanceDispose(instance)
                            lastErr = err
                            continue
                        }
                        fmt = asbd
                        err = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, asbdSize)
                    }
                    guard err == noErr else {
                        AudioComponentInstanceDispose(instance)
                        lastErr = err
                        continue
                    }

                    var cb = AURenderCallbackStruct(
                        inputProc: { refCon, _, _, _, inNumberFrames, ioData -> OSStatus in
                            let proc = Unmanaged<NewTimePitchProcessor>.fromOpaque(refCon).takeUnretainedValue()
                            return proc.supplyInput(ioData: ioData, frames: inNumberFrames)
                        },
                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
                    )
                    err = AudioUnitSetProperty(
                        instance,
                        kAudioUnitProperty_SetRenderCallback,
                        kAudioUnitScope_Input,
                        inputBus,
                        &cb,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                    )
                    guard err == noErr else {
                        AudioComponentInstanceDispose(instance)
                        lastErr = err
                        continue
                    }

                    err = AudioUnitInitialize(instance)
                    guard err == noErr else {
                        AudioUnitUninitialize(instance)
                        AudioComponentInstanceDispose(instance)
                        lastErr = err
                        continue
                    }

                    audioUnit = instance
                    ioLayout = layout
                    hostSampleTime = 0
                    ensureSplitABLStorageIfNeeded()
                    applyPitch(instance: instance, semitones: 0)
                    return
                }
            }
        }

        throw NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(lastErr),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "NewTimePitch could not accept any stream format (last OSStatus \(lastErr)). "
                    + "Tap: \(tapASBD.mSampleRate) Hz, \(tapASBD.mChannelsPerFrame) ch, flags \(tapASBD.mFormatFlags)."
            ]
        )
    }

    /// Formats to try, in order. New Time Pitch often wants the tap’s native layout or stereo float (interleaved or split).
    private static func buildFormatCandidates(fromTap tap: AudioStreamBasicDescription) -> [AudioStreamBasicDescription] {
        let rate = tap.mSampleRate > 0 ? tap.mSampleRate : 48_000
        var list: [AudioStreamBasicDescription] = []

        if let exact = exactFloatStereoTapFormat(tap) {
            list.append(exact)
        }

        list.append(
            AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
        )

        list.append(
            AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
        )

        return list
    }

    /// Use only if the tap is already float 32 stereo (typical process tap); otherwise nutp usually rejects it.
    private static func exactFloatStereoTapFormat(_ tap: AudioStreamBasicDescription) -> AudioStreamBasicDescription? {
        guard tap.mFormatID == kAudioFormatLinearPCM else { return nil }
        guard (tap.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else { return nil }
        guard tap.mChannelsPerFrame == 2 else { return nil }
        var t = tap
        t.mReserved = 0
        return t
    }

    func setSemitones(_ semitones: Float) {
        guard let instance = audioUnit else { return }
        applyPitch(instance: instance, semitones: semitones)
    }

    private func applyPitch(instance: AudioComponentInstance, semitones: Float) {
        let cents = max(-2400, min(2400, semitones * 100.0))
        // `nutp` is kAudioUnitSubType_NewTimePitch; use kNewTimePitchParam_* (same IDs as kTimePitchParam_* but correct symbol).
        AudioUnitSetParameter(instance, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, cents, 0)
        AudioUnitSetParameter(instance, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, 1.0, 0)
    }

    func teardown() {
        if let instance = audioUnit {
            AudioUnitUninitialize(instance)
            AudioComponentInstanceDispose(instance)
            audioUnit = nil
        }
        freeSplitABLStorage()
        ioLayout = .interleavedRender
    }

    private func ensureSplitABLStorageIfNeeded() {
        guard ioLayout == .splitRender, splitRenderABLStorage == nil else { return }
        let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        splitRenderABLStorage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    }

    private func freeSplitABLStorage() {
        splitRenderABLStorage?.deallocate()
        splitRenderABLStorage = nil
    }

    func process(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        left: Int,
        right: Int
    ) -> OSStatus {
        guard let instance = audioUnit else { return kAudioUnitErr_Uninitialized }
        guard frameCount > 0, frameCount <= Int(maxFrames) else { return kAudio_ParamError }

        interleavedIn.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            TransposeTapEngine.extractStereoForFirstOutput(
                inputBuffers: input,
                referenceOutputBuffers: output,
                dest: base,
                frameCount: frameCount,
                left: left,
                right: right
            )
        }

        var renderStatus: OSStatus = kAudioUnitErr_Uninitialized
        switch ioLayout {
        case .interleavedRender:
            interleavedOut.withUnsafeMutableBufferPointer { outBuf in
                var abl = AudioBufferList()
                abl.mNumberBuffers = 1
                abl.mBuffers.mNumberChannels = 2
                abl.mBuffers.mDataByteSize = UInt32(frameCount * 2 * MemoryLayout<Float>.size)
                abl.mBuffers.mData = UnsafeMutableRawPointer(outBuf.baseAddress)
                if let base = outBuf.baseAddress {
                    memset(base, 0, Int(abl.mBuffers.mDataByteSize))
                }
                renderStatus = Self.renderPull(instance: instance, frameCount: UInt32(frameCount), ioData: &abl, hostTime: &hostSampleTime)
            }
        case .splitRender:
            guard let ablPtr = splitRenderABLStorage else { return kAudioUnitErr_Uninitialized }
            splitLeft.withUnsafeMutableBufferPointer { lp in
                splitRight.withUnsafeMutableBufferPointer { rp in
                    guard let lb = lp.baseAddress, let rb = rp.baseAddress else { return }
                    let byteCount = frameCount * MemoryLayout<Float>.size
                    memset(lb, 0, byteCount)
                    memset(rb, 0, byteCount)

                    let full = ablPtr.assumingMemoryBound(to: AudioBufferList.self)
                    full.pointee.mNumberBuffers = 2
                    let bp = UnsafeMutableAudioBufferListPointer(full)
                    bp[0].mNumberChannels = 1
                    bp[0].mDataByteSize = UInt32(byteCount)
                    bp[0].mData = UnsafeMutableRawPointer(lb)
                    bp[1].mNumberChannels = 1
                    bp[1].mDataByteSize = UInt32(byteCount)
                    bp[1].mData = UnsafeMutableRawPointer(rb)

                    renderStatus = Self.renderPull(instance: instance, frameCount: UInt32(frameCount), ioData: full, hostTime: &hostSampleTime)
                }
            }
            if renderStatus == noErr {
                for i in 0..<frameCount {
                    interleavedOut[2 * i] = splitLeft[i]
                    interleavedOut[2 * i + 1] = splitRight[i]
                }
            }
        }

        guard renderStatus == noErr else { return renderStatus }

        let peak = Self.peakMagnitude(interleavedOut, sampleCount: frameCount * 2)
        if peak < 1e-10 {
            return kAudioUnitErr_Uninitialized
        }

        interleavedOut.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            TransposeTapEngine.spreadStereoToFirstOutput(
                source: base,
                outputBuffers: output,
                frameCount: frameCount,
                left: left,
                right: right
            )
        }
        return noErr
    }

    /// Pull-mode render with a valid sample timeline; tries output bus `1` if bus `0` is silent (some builds behave differently).
    private nonisolated static func renderPull(
        instance: AudioComponentInstance,
        frameCount: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        hostTime: inout Float64
    ) -> OSStatus {
        var ts = AudioTimeStamp()
        ts.mSampleTime = hostTime
        ts.mFlags = AudioTimeStampFlags.sampleTimeValid
        hostTime += Double(frameCount)

        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var st = AudioUnitRender(instance, &flags, &ts, 0, frameCount, ioData)
        if st == noErr, peakInABL(ioData) < 1e-10 {
            var ts2 = AudioTimeStamp()
            ts2.mSampleTime = ts.mSampleTime
            ts2.mFlags = AudioTimeStampFlags.sampleTimeValid
            flags = AudioUnitRenderActionFlags(rawValue: 0)
            let st1 = AudioUnitRender(instance, &flags, &ts2, 1, frameCount, ioData)
            if st1 == noErr, peakInABL(ioData) > 1e-10 {
                st = st1
            }
        }
        return st
    }

    private nonisolated static func peakInABL(_ abl: UnsafeMutablePointer<AudioBufferList>) -> Float {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        var peak: Float = 0
        for i in 0..<list.count {
            guard let p = list[i].mData else { continue }
            let n = Int(list[i].mDataByteSize) / MemoryLayout<Float>.size
            let samples = p.assumingMemoryBound(to: Float.self)
            for j in 0..<n {
                peak = max(peak, abs(samples[j]))
            }
        }
        return peak
    }

    private nonisolated static func peakMagnitude(_ buf: [Float], sampleCount: Int) -> Float {
        var p: Float = 0
        let n = min(sampleCount, buf.count)
        for i in 0..<n {
            p = max(p, abs(buf[i]))
        }
        return p
    }

    /// `nutp` may ask for one interleaved buffer or two mono buffers depending on processing state; accept both.
    private func supplyInput(ioData: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) -> OSStatus {
        guard let raw = ioData else { return kAudio_ParamError }
        let list = UnsafeMutableAudioBufferListPointer(raw)
        let n = Int(frames)
        let byteCount = n * 2 * MemoryLayout<Float>.size

        if list.count == 1,
           list[0].mNumberChannels == 2,
           let dst = list[0].mData
        {
            _ = interleavedIn.withUnsafeBufferPointer { src -> () in
                memcpy(dst, src.baseAddress!, byteCount)
            }
            return noErr
        }

        if list.count >= 2,
           list[0].mNumberChannels == 1,
           list[1].mNumberChannels == 1,
           let d0 = list[0].mData,
           let d1 = list[1].mData
        {
            let L = d0.assumingMemoryBound(to: Float.self)
            let R = d1.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                L[i] = interleavedIn[2 * i]
                R[i] = interleavedIn[2 * i + 1]
            }
            return noErr
        }

        return kAudioUnitErr_FormatNotSupported
    }
}
