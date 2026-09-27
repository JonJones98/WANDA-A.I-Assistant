//
//  HeadGestures.swift
//  Wanda
//

import CoreMotion
import Foundation

/// Experimental: nod, shake or tilt your head while wearing AirPods to start (or stop)
/// talking to Wanda.
/// Uses the AirPods' head tracking (the motion sensors behind spatial audio), not the
/// mic, so music keeps playing at full quality until you actually talk.
///
/// Works with AirPods that support head tracking (AirPods Pro, AirPods 3rd generation
/// and later, AirPods Max) on macOS 14 or later.
@MainActor
final class HeadGestureListener: NSObject, ObservableObject {
    enum Status: Equatable {
        case off
        /// Needs macOS 14 or a Mac that supports headphone motion.
        case unsupported
        /// Motion access was turned off in System Settings.
        case denied
        /// On, but no head tracking AirPods are sending motion.
        case waitingForAirPods
        case ready
    }

    enum Gesture: String, CaseIterable, Identifiable {
        case nod, shake, tilt
        /// Any of the above. (Stored as "either" from when there were only two.)
        case any = "either"
        var id: Self { self }
    }

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    @Published var gesture: Gesture {
        didSet { defaults.set(gesture.rawValue, forKey: Self.gestureKey) }
    }
    @Published private(set) var status: Status = .off
    /// Called when the chosen gesture is made.
    var onGesture: (() -> Void)?

    private static let enabledKey = "WandaNodToTalk"
    private static let gestureKey = "WandaHeadGesture"
    private let defaults: UserDefaults
    /// A `CMHeadphoneMotionManager` (macOS 14+).
    private var manager: NSObject?
    private var nods = HeadGestureDetector.nod
    private var shakes = HeadGestureDetector.shake
    private var tilts = HeadGestureDetector.tilt
    /// Heading with the ±180° wrap removed, so turning past it isn't a jump.
    private var yaw: Double?
    private var lastRawYaw = 0.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        gesture = defaults.string(forKey: Self.gestureKey).flatMap(Gesture.init(rawValue:)) ?? .any
        super.init()
        if isEnabled { start() }
    }

    private func start() {
        guard #available(macOS 14.0, *) else {
            status = .unsupported
            return
        }
        let manager = (self.manager as? CMHeadphoneMotionManager) ?? CMHeadphoneMotionManager()
        self.manager = manager
        guard manager.isDeviceMotionAvailable else {
            status = .unsupported
            return
        }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = .denied
            return
        default:
            break
        }
        guard !manager.isDeviceMotionActive else { return }
        manager.delegate = self
        resetDetectors()
        status = .waitingForAirPods
        // Asks for Motion access the first time.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let motion {
                    self.handle(motion.attitude, at: motion.timestamp)
                } else if error != nil {
                    self.refreshAuthorization()
                }
            }
        }
    }

    private func stop() {
        if #available(macOS 14.0, *), let manager = manager as? CMHeadphoneMotionManager {
            manager.stopDeviceMotionUpdates()
        }
        status = .off
    }

    private func handle(_ attitude: CMAttitude, at time: TimeInterval) {
        guard isEnabled else { return }
        if status != .ready { status = .ready }
        let rawYaw = attitude.yaw
        let yaw = self.yaw.map { $0 + remainder(rawYaw - lastRawYaw, 2 * .pi) } ?? rawYaw
        self.yaw = yaw
        lastRawYaw = rawYaw
        // Feed both detectors so each keeps an up-to-date resting position.
        let nodded = nods.add(attitude.pitch, at: time)
        let shook = shakes.add(yaw, at: time)
        let tilted = tilts.add(attitude.roll, at: time)
        switch gesture {
        case .nod where nodded, .shake where shook, .tilt where tilted, .any where nodded || shook || tilted:
            // One gesture can wobble the other axis; don't let it count twice.
            resetDetectors(keepingRest: true)
            onGesture?()
        default:
            break
        }
    }

    private func resetDetectors(keepingRest: Bool = false) {
        if keepingRest {
            nods.cancelInProgress()
            shakes.cancelInProgress()
            tilts.cancelInProgress()
        } else {
            nods = .nod
            shakes = .shake
            tilts = .tilt
            yaw = nil
        }
    }

    private func refreshAuthorization() {
        guard #available(macOS 14.0, *) else { return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted: status = .denied
        default: break
        }
    }

    fileprivate func airPodsConnected(_ connected: Bool) {
        guard isEnabled, status != .denied, status != .unsupported else { return }
        resetDetectors()
        status = connected ? .ready : .waitingForAirPods
    }
}

@available(macOS 14.0, *)
extension HeadGestureListener: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.airPodsConnected(true) }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.airPodsConnected(false) }
    }
}

/// How Wanda is woken up to listen: one at a time, so gestures never leave the mic on
/// for "Hey Wanda" (which keeps AirPods in call mode).
enum WakeMode: String, CaseIterable, Identifiable {
    case voice, nod, shake, tilt, anyGesture, off

    var id: Self { self }

    var label: String {
        switch self {
        case .voice: return "Saying “Hey Wanda”"
        case .nod: return "Nodding twice (AirPods)"
        case .shake: return "Shaking head (AirPods)"
        case .tilt: return "Tilting head twice (AirPods)"
        case .anyGesture: return "Any head gesture (AirPods)"
        case .off: return "Mic button only"
        }
    }

    /// The head gesture this mode listens for, if any.
    var gesture: HeadGestureListener.Gesture? {
        switch self {
        case .nod: return .nod
        case .shake: return .shake
        case .tilt: return .tilt
        case .anyGesture: return .any
        case .voice, .off: return nil
        }
    }

    init(wakeWordEnabled: Bool, gesturesEnabled: Bool, gesture: HeadGestureListener.Gesture) {
        if gesturesEnabled {
            switch gesture {
            case .nod: self = .nod
            case .shake: self = .shake
            case .tilt: self = .tilt
            case .any: self = .anyGesture
            }
        } else {
            self = wakeWordEnabled ? .voice : .off
        }
    }
}

/// Spots a quick "yes yes", "no no" or double tilt in a stream of head angles (radians):
/// pitch for nods, heading for shakes, roll for tilts.
///
/// A swing is the head moving more than `threshold` away from where it rests and coming
/// back within `maxSwingDuration`. Two swings within `pairWindow` count, so a nod is down
/// and up twice, and a shake is left then right (or right then left). Turning or looking
/// down and staying there (at another screen, at the keyboard) isn't a swing: it becomes
/// the new resting position.
struct HeadGestureDetector {
    var threshold: Double
    var settle: Double
    var maxSwingDuration: TimeInterval
    var pairWindow: TimeInterval = 1.4
    var cooldown: TimeInterval = 2

    /// Tip down about 11° and back, twice.
    static let nod = HeadGestureDetector(threshold: 0.2, settle: 0.08, maxSwingDuration: 0.7)
    /// Turn about 14° to one side and back, then to either side and back.
    static let shake = HeadGestureDetector(threshold: 0.25, settle: 0.1, maxSwingDuration: 0.6)
    /// Lean an ear about 14° toward a shoulder and back, twice (either side).
    static let tilt = HeadGestureDetector(threshold: 0.25, settle: 0.1, maxSwingDuration: 0.8)

    private var rest: Double?
    private var swingStart: TimeInterval?
    private var lastSwing: TimeInterval?
    private var lastTrigger = -Double.infinity

    init(threshold: Double, settle: Double, maxSwingDuration: TimeInterval) {
        self.threshold = threshold
        self.settle = settle
        self.maxSwingDuration = maxSwingDuration
    }

    /// Forgets half-finished gestures but keeps the resting position.
    mutating func cancelInProgress() {
        swingStart = nil
        lastSwing = nil
    }

    /// Returns true when this reading completes the gesture.
    mutating func add(_ angle: Double, at time: TimeInterval) -> Bool {
        guard let rest else {
            self.rest = angle
            return false
        }
        let offset = angle - rest
        if let start = swingStart {
            if abs(offset) < settle {
                swingStart = nil
                guard time - start <= maxSwingDuration else { return false }
                if let lastSwing, time - lastSwing <= pairWindow, time - lastTrigger > cooldown {
                    self.lastSwing = nil
                    lastTrigger = time
                    return true
                }
                lastSwing = time
            } else if time - start > maxSwingDuration {
                // Held there: that's the new resting position, not a swing.
                swingStart = nil
                lastSwing = nil
                self.rest = angle
            }
        } else if abs(offset) > threshold {
            swingStart = time
        } else if abs(offset) < settle {
            // Follow slow changes in posture (and heading drift), but only while the head
            // is near still, so the start of a gesture doesn't drag the resting position.
            self.rest = rest + offset * 0.02
        }
        return false
    }
}
