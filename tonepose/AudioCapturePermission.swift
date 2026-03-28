import AppKit
import Foundation
import os

enum AudioCapturePermissionStatus: Sendable {
    case unknown
    case authorized
    case denied
}

/// TCC audio-capture preflight using `kTCCServiceAudioCapture`.
@Observable
@MainActor
final class AudioCapturePermission {
    private let log = Logger(subsystem: "dev.tonepose", category: "Permission")

    private(set) var status: AudioCapturePermissionStatus = .unknown

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let r = Self.preflight()
        switch r {
        case 0: status = .authorized
        case 1: status = .denied
        default: status = .unknown
        }
        log.debug("Audio capture preflight: \(r) → \(String(describing: self.status))")
    }

    func request() {
        guard status != .authorized else { return }
        Self.requestAccess { [weak self] granted in
            Task { @MainActor in
                self?.status = granted ? .authorized : .denied
                self?.log.info("Audio capture request: \(granted)")
            }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - TCC (private SPI; same service as system “audio capture” for app audio)

    private static let tccService = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let tccHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightSPI: PreflightFunc? = {
        guard let h = tccHandle, let s = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(s, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let h = tccHandle, let s = dlsym(h, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(s, to: RequestFunc.self)
    }()

    /// 0 = authorized, 1 = denied, -1 = unavailable
    private static func preflight() -> Int {
        guard let spi = preflightSPI else { return -1 }
        return spi(tccService, nil)
    }

    private static func requestAccess(completion: @escaping (Bool) -> Void) {
        guard let spi = requestSPI else {
            completion(false)
            return
        }
        spi(tccService, nil, completion)
    }
}
