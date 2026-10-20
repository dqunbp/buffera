import Foundation
import IOKit.ps
import BufferaSearch

struct BackgroundPreparationEnvironment: Equatable {
    enum PowerSource: Equatable { case external, battery, unknown }
    let powerSource: PowerSource
    let lowPowerMode: Bool
    let thermalState: ProcessInfo.ThermalState
}

/// Pure policy: the persisted preference is supplied by the application; overrides are session-only.
struct BackgroundPreparationPolicy {
    static let preferenceKey = "semanticPreparationOnlyOnExternalPower"
    var onlyOnExternalPower: Bool
    private(set) var environment: BackgroundPreparationEnvironment
    private(set) var continuesOnBattery = false

    init(onlyOnExternalPower: Bool = true, environment: BackgroundPreparationEnvironment) {
        self.onlyOnExternalPower = onlyOnExternalPower
        self.environment = environment
    }

    mutating func updateEnvironment(_ value: BackgroundPreparationEnvironment) {
        environment = value
        if value.powerSource == .external { continuesOnBattery = false }
    }

    mutating func continueOnBattery() {
        guard pauseReason == .battery else { return }
        continuesOnBattery = true
    }

    var pauseReason: EmbeddingIndexPauseReason? {
        if environment.thermalState == .serious || environment.thermalState == .critical { return .thermalPressure }
        if environment.lowPowerMode { return .lowPowerMode }
        guard onlyOnExternalPower else { return nil }
        switch environment.powerSource {
        case .external: return nil
        case .battery: return continuesOnBattery ? nil : .battery
        case .unknown: return .powerSourceUnknown
        }
    }
}

/// Native power notifications are delivered through the main run loop; Foundation observers
/// explicitly hop to the main queue because their notifications originate on a global queue.
final class BackgroundPreparationMonitor {
    private(set) var environment: BackgroundPreparationEnvironment
    var onChange: ((BackgroundPreparationEnvironment) -> Void)?
    private var powerSource: CFRunLoopSource?
    private var fallbackTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init() {
        precondition(Thread.isMainThread)
        // Reading thermalState before subscribing is required by NSProcessInfo's contract.
        environment = Self.readEnvironment()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BackgroundPreparationMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        } else {
            // A failed IOKit subscription must not leave a stale "AC power" decision indefinitely.
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() })
        }
    }

    deinit { stop() }

    func stop() {
        stopped = true
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func refresh() {
        guard !stopped else { return }
        let updated = Self.readEnvironment()
        guard updated != environment else { return }
        environment = updated
        onChange?(updated)
    }

    private static func readEnvironment() -> BackgroundPreparationEnvironment {
        let power: BackgroundPreparationEnvironment.PowerSource
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            switch source as String {
            case kIOPMACPowerKey: power = .external
            case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: power = .battery
            default: power = .unknown
            }
        } else { power = .unknown }
        return BackgroundPreparationEnvironment(powerSource: power,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
    }
}
