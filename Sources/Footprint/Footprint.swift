///
///  Footprint.swift
///  Footprint
///
///  Copyright (c) 2023 Alexander Cohen. All rights reserved.
///

import Foundation

/// The footprint manages snapshots of app memory limits and state,
/// and notifies your app when these change.
///
/// For the longest time, Apple platform engineers have been taught to be careful with memory,
/// and if there is an issue, a notification will tell you when to drop objects and you should be ok.
/// This works well for smaller apps, but as soon as your app grows you start finding that these
/// notifications come too late and with too many restrictions.
///
/// Later came `os_proc_available_memory` which gives us the amount of memory left
/// to our apps before they are terminated. Now we're getting somewhere, we can finally tell if
/// memory was the actual reason for being terminated. But again, we're still missing the upper
/// bound. Say we have 1GB of memory remaining, wouldn't it be useful to know how much
/// we've actually used, wouldn't it be useful to be able to **change the apps behavior based on
/// where our app stands within the bounds of the memory limit**?
///
/// This is where `Footprint` comes in. It gives you the opportunity to handle memory in
/// levels (Footprint.Memory.State) instead of all at once at the end. It expects you to change
/// your apps behavior as your users explore.
///
/// A simple use example is with caches. You could change the maximum cost
/// of said cache based on the `.State`. Say, `.normal` has a 100% multiplier,
///`.warning` is 80%, `.critical` is 50%  and so on. This leads to your
/// caches being purged based on the users behavior and the memory footprint
/// used by your app has a much lower upper bound and much smaller drops.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, visionOS 1.0, *)
final public class Footprint : @unchecked Sendable {

    /// A structure that represents the different values required for easier memory
    /// handling throughout your apps lifetime.
    public struct Memory {
        
        /// State describes how close to app termination your app is based on memory.
        public enum State: Int {
            /// Everything is good, no need to worry.
            case normal
            
            /// You're still doing ok, but start reducing memory usage.
            case warning
            
            /// Reduce your memory footprint now.
            case urgent
            
            /// Time is of the essence, memory usage is very high, reduce your footprint.
            case critical
            
            /// Termination is imminent. If you make it here, you haven't changed your
            /// memory usage behavior.
            /// Please revisit memory best practices and profile your app.
            case terminal
        }
        
        /// The amount of app used memory. Equivalent to `task_vm_info_data_t.phys_footprint`.
        public let used: Int
        
        /// The amount of memory remaining to the app. Equivalent to `task_vm_info_data_t.limit_bytes_remaining`
        /// or `os_proc_available_memory`.
        public let remaining: Int
        
        /// The high watermark of memory bytes your app can use before being terminated.
        public let limit: Int
        
        /// The state describing where your app sits within the scope of its memory limit.
        public let state: State
        
        /// The state of memory pressure (aka. how close the app is to being Jetsamed/Jetisoned).
        public let pressure: State
        
        /// The time at which this snapshot was taken in monotonic milliseconds of uptime.
        public let timestamp: UInt64
        
        init(memoryPressure: State = .normal) {
            var info = task_vm_info_data_t()
            var infoCount = TASK_VM_INFO_COUNT
            
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, thread_flavor_t(TASK_VM_INFO), $0, &infoCount)
                }
            }
            used = kerr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
            compressed = kerr == KERN_SUCCESS ? Int(info.compressed) : 0
#if targetEnvironment(simulator)
            // In the simulator `limit_bytes_remaining` returns -1
            // which means we can't calculate limits.
            // Due to this, we just set it to 4GB.
            limit = Int(4e+9)
            remaining = max(limit - used, 0)
#else
            remaining = kerr == KERN_SUCCESS ? Int(info.limit_bytes_remaining) : 0
            limit = used + remaining
#endif
            
            usedRatio = Double(used)/Double(limit)
            state = usedRatio < 0.25 ? .normal :
            usedRatio < 0.50 ? .warning :
            usedRatio < 0.75 ? .urgent :
            usedRatio < 0.90 ? .critical : .terminal
            pressure = memoryPressure
            timestamp = {
                let time = mach_absolute_time()
                var timebaseInfo = mach_timebase_info_data_t()
                guard mach_timebase_info(&timebaseInfo) == KERN_SUCCESS else {
                    return 0
                }
                let timeInNanoseconds = time * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
                return timeInNanoseconds / 1_000_000
            }()
        }
        
        private let compressed: Int
        private let usedRatio: Double
        private let TASK_BASIC_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size /  MemoryLayout<UInt32>.size)
        private let TASK_VM_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<UInt32>.size)
    }
    
    /// The footprint instance that is used throughout the lifetime of your app.
    ///
    /// Although the first call to this method can be made an any point,
    /// it is best to call this API as soon as possible at startup.
    public static let shared = Footprint()
    
    /// Notification name sent when the Footprint.Memory.state and/or
    /// Footprint.Memory.pressure changes.
    ///
    /// The notification userInfo dict will contain they `.oldMemoryKey`,
    /// .newMemoryKey` and `.changesKey` keys.
    public static let memoryDidChangeNotification: NSNotification.Name = NSNotification.Name("FootprintMemoryDidChangeNotification")
    
    /// Key for the previous value of the memory state in the the
    /// `.stateDidChangeNotification` userInfo object.
    /// Type is `Footprint.Memory`.
    public static let oldMemoryKey: String = "oldMemory"
    
    /// Key for the new value of the memory statein the the `.stateDidChangeNotification`
    /// userInfo object. Type is `Footprint.Memory`.
    public static let newMemoryKey: String = "newMemory"
    
    /// Key for the changes of the memory in the the `.stateDidChangeNotification`
    /// userInfo object. Type is `Set<ChangeType>`
    public static let changesKey: String = "changes"
    
    /// Types of changes possible
    public enum ChangeType: Comparable {
        case state
        case pressure
    }
    
    /// Returns a copy of the current memory structure.
    public var memory: Memory {
        _memoryLock.lock()
        defer { _memoryLock.unlock() }
        return _memory
    }
    
    /// Based on the current memory footprint, tells you if you should be able to allocate
    /// a certain amount of memory.
    ///
    /// - Parameter bytes: The number of bytes you are interested in allocating.
    ///
    /// - returns: A `Bool` indicating if allocating `bytes` will likely work.
    public func canAllocate(bytes: UInt) -> Bool {
        return bytes < Footprint.Memory().remaining
    }

    /// The currently tracked memory state.
    public var state: Memory.State {
        _memoryLock.lock()
        defer { _memoryLock.unlock() }
        return _memory.state
    }
    
    /// The currently tracked memory pressure.
    public var pressure: Memory.State {
        _memoryLock.lock()
        defer { _memoryLock.unlock() }
        return _memory.pressure
    }
    
    private init() {
        _memory = Memory()
        
        let timerSource = DispatchSource.makeTimerSource(queue: _queue)
        timerSource.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(500))
        timerSource.setEventHandler { [weak self] in
            self?.heartbeat()
        }
        timerSource.activate()
        _timerSource = timerSource
        
        let memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.all], queue: _queue)
        memorySource.setEventHandler { [weak self] in
            self?.heartbeat()
        }
        memorySource.activate()
        _memoryPressureSource = memorySource
    }
    
    deinit {
        _timerSource?.suspend()
        _timerSource?.cancel()
        _timerSource = nil
        
        _memoryPressureSource?.suspend()
        _memoryPressureSource?.cancel()
        _memoryPressureSource = nil
    }
    
    private func heartbeat() {
        let memory = Memory(memoryPressure: currentPressureFromSource())
        storeAndSendObservers(for: memory)
#if targetEnvironment(simulator)
        // In the simulator there are no memory terminations,
        // so we fake one.
        if memory.state == .terminal {
            print("Footprint: exiting due to the memory limit")
            _exit(EXIT_FAILURE)
        }
#endif
    }
    
    private func currentPressureFromSource() -> Memory.State {
        guard let source = _memoryPressureSource else {
            return .normal
        }
        if source.data.contains(.critical) {
            return .critical
        }
        if source.data.contains(.warning) {
            return .warning
        }
        return .normal
    }
    
    private func update(with memory: Memory) -> (Memory, Set<ChangeType>)? {
        
        _memoryLock.lock()
        defer { _memoryLock.unlock() }
        
        // Verify that state changed...
        var changeSet: Set<ChangeType> = []
        
        if _memory.state != memory.state {
            changeSet.insert(.state)
        }
        if _memory.pressure != memory.pressure {
            changeSet.insert(.pressure)
        }
        guard !changeSet.isEmpty else {
            return nil
        }
        
        // ... and enough time has passed to send out
        // notifications again. Approximately the heartbeat interval.
        guard memory.timestamp - _memory.timestamp >= _heartbeatInterval else {
            print("Footprint.state changed but not enough time (\(memory.timestamp - _memory.timestamp)) has changed to deploy it.")
            return nil
        }
        
        print("Footprint changed after \(memory.timestamp - _memory.timestamp)")
        let oldMemory = _memory
        _memory = memory
        
        return (oldMemory, changeSet)
    }
    
    private func storeAndSendObservers(for memory: Memory) {
        
        guard let (oldMemory, changeSet) = update(with: memory) else {
            return
        }
        
        // send all observers outside of the lock on the main queue.
        // main queue is important since most of us will want to
        // make changes that might touch the UI.
        print("Footprint changes \(changeSet)")
        print("Footprint.state \(memory.state)")
        print("Footprint.pressure \(memory.pressure)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Footprint.memoryDidChangeNotification, object: nil, userInfo: [
                Footprint.newMemoryKey: memory,
                Footprint.oldMemoryKey: oldMemory,
                Footprint.changesKey: changeSet
            ])
        }
    }
    
    private let _queue = DispatchQueue(label: "com.bedroomcode.footprint.heartbeat.queue", qos: .utility, target: DispatchQueue.global(qos: .utility))
    private var _timerSource: DispatchSourceTimer? = nil
    private let _heartbeatInterval = 500 // milliseconds
    private var _memoryLock: NSLock = NSLock()
    private var _memory: Memory = Memory()
    private var _memoryPressureSource: DispatchSourceMemoryPressure? = nil
}

#if canImport(SwiftUI)
import SwiftUI

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
extension View {
    
    /// A SwiftUI extension providing a convenient way to observe changes in the memory
    /// state of the app through the `onFootprintMemoryDidChange` modifier.
    ///
    /// ## Overview
    ///
    /// The `onFootprintMemoryDidChange` extension allows you to respond
    /// to changes in the app's memory state and pressure by providing a closure that is executed
    /// whenever the memory state transitions. You can also use specific modifiers for 
    /// state (`onFootprintMemoryStateDidChange`) or
    /// pressure (`onFootprintMemoryPressureDidChange`).
    ///
    /// ### Example Usage
    ///
    /// ```swift
    /// Text("Hello, World!")
    ///     .onFootprintMemoryDidChange { newMemory, oldMemory, changeSet in
    ///         print("Memory state changed from \(oldState) to \(newState)")
    ///         // Perform actions based on the memory change
    ///     }
    @inlinable public func onFootprintMemoryDidChange(perform action: @escaping (_ state: Footprint.Memory, _ previousState: Footprint.Memory, _ changes: Set<Footprint.ChangeType>) -> Void) -> some View {
        _ = Footprint.shared // make sure it's running
        return onReceive(NotificationCenter.default.publisher(for: Footprint.memoryDidChangeNotification)) { note in
            if let changes = note.userInfo?[Footprint.changesKey] as? Set<Footprint.ChangeType>,
               let memory = note.userInfo?[Footprint.newMemoryKey] as? Footprint.Memory,
               let prevMemory = note.userInfo?[Footprint.oldMemoryKey] as? Footprint.Memory {
                action(memory, prevMemory, changes)
            }
        }
    }
    
    @inlinable public func onFootprintMemoryStateDidChange(perform action: @escaping (_ state: Footprint.Memory.State, _ previousState: Footprint.Memory.State) -> Void) -> some View {
        _ = Footprint.shared // make sure it's running
        return onReceive(NotificationCenter.default.publisher(for: Footprint.memoryDidChangeNotification)) { note in
            if let changes = note.userInfo?[Footprint.changesKey] as? Set<Footprint.ChangeType>,
               changes.contains(.state),
               let memory = note.userInfo?[Footprint.newMemoryKey] as? Footprint.Memory,
               let prevMemory = note.userInfo?[Footprint.oldMemoryKey] as? Footprint.Memory {
                action(memory.state, prevMemory.state)
            }
        }
    }
    
    @inlinable public func onFootprintMemoryPressureDidChange(perform action: @escaping (_ pressure: Footprint.Memory.State, _ previousPressure: Footprint.Memory.State) -> Void) -> some View {
        _ = Footprint.shared // make sure it's running
        return onReceive(NotificationCenter.default.publisher(for: Footprint.memoryDidChangeNotification)) { note in
            if let changes = note.userInfo?[Footprint.changesKey] as? Set<Footprint.ChangeType>,
               changes.contains(.pressure),
               let memory = note.userInfo?[Footprint.newMemoryKey] as? Footprint.Memory,
               let prevMemory = note.userInfo?[Footprint.oldMemoryKey] as? Footprint.Memory {
                action(memory.pressure, prevMemory.pressure)
            }
        }
    }
    
}

#endif
