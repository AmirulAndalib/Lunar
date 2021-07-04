import Accelerate
import Alamofire
import Atomics
import AXSwift
import Cocoa
import Combine
import CryptorECC
import Foundation
import Surge
import SwiftDate
import UserNotifications

@inline(__always) func isGeneric(_ id: CGDirectDisplayID) -> Bool {
    #if DEBUG
        return id == GENERIC_DISPLAY_ID || id == TEST_DISPLAY_ID
    #else
        return id == GENERIC_DISPLAY_ID
    #endif
}

@inline(__always) func isGeneric(serial: String) -> Bool {
    #if DEBUG
        return serial == GENERIC_DISPLAY.serial || serial == TEST_DISPLAY.serial
    #else
        return serial == GENERIC_DISPLAY.serial
    #endif
}

@inline(__always) func isTestID(_ id: CGDirectDisplayID) -> Bool {
    #if DEBUG
        // return id == GENERIC_DISPLAY_ID
        return TEST_IDS.contains(id)
    #else
        return id == GENERIC_DISPLAY_ID
    #endif
}

class RequestTimeoutError: Error {}
struct ResponseError: Error {
    var statusCode: Int
}

class DispatchWorkItem {
    var name: String = ""
    var workItem: Foundation.DispatchWorkItem

    init(name: String, flags: DispatchWorkItemFlags = [], block: @escaping @convention(block) () -> Void) {
        workItem = Foundation.DispatchWorkItem(flags: flags, block: block)
        self.name = name
    }

    @discardableResult
    @inline(__always) func wait(for timeout: DateComponents?) -> DispatchTimeoutResult {
        guard let timeout = timeout else {
            return wait(for: 0)
        }
        return wait(for: timeout.timeInterval)
    }

    @inline(__always) func cancel() {
        workItem.cancel()
    }

    @inline(__always) var isCancelled: Bool {
        workItem.isCancelled
    }

    @discardableResult
    @inline(__always) func wait(for timeout: TimeInterval) -> DispatchTimeoutResult {
        #if DEBUG
            if timeout > 0 {
                log.verbose("Waiting for \(timeout) seconds on \(name)")
            } else {
                log.verbose("Waiting for \(name)")
            }
            defer { log.verbose("Done waiting for \(name)") }
        #endif

        if timeout > 0 {
            return workItem.wait(timeout: DispatchTime.now() + timeout)
        } else {
            workItem.wait()
            return .success
        }
    }
}

class DispatchSemaphore {
    var name: String = ""
    var sem: Foundation.DispatchSemaphore

    init(value: Int, name: String) {
        sem = Foundation.DispatchSemaphore(value: value)
        self.name = name
    }

    @discardableResult
    @inline(__always) func wait(for timeout: DateComponents?, context: Any? = nil) -> DispatchTimeoutResult {
        guard let timeout = timeout else {
            return wait(for: 0, context: context)
        }
        return wait(for: timeout.timeInterval, context: context)
    }

    @inline(__always) func signal() {
        sem.signal()
    }

    @discardableResult
    @inline(__always) func wait(for timeout: TimeInterval, context: Any? = nil) -> DispatchTimeoutResult {
        #if DEBUG
            if timeout > 0 {
                log.verbose("Waiting for \(timeout) seconds on \(name)", context: context)
            } else {
                log.verbose("Waiting for \(name)", context: context)
            }
            defer { log.verbose("Done waiting for \(name)", context: context) }
        #endif

        if timeout > 0 {
            return sem.wait(timeout: DispatchTime.now() + timeout)
        } else {
            sem.wait()
            return .success
        }
    }
}

func query(url: URL, timeout: TimeInterval = 0.seconds.timeInterval, wait: Bool = true) throws -> String {
    let semaphore = DispatchSemaphore(value: 0, name: "query \(url.absoluteString)")

    var result: String = ""
    var responseError: Error?

    let task = URLSession.shared.dataTask(with: url) { data, resp, error in
        guard let data = data else {
            responseError = error
            semaphore.signal()
            return
        }
        guard let response = resp as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            responseError = ResponseError(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 400)
            semaphore.signal()
            return
        }
        result = String(data: data, encoding: String.Encoding.utf8)!
        semaphore.signal()
    }

    task.resume()
    guard wait else { return "" }

    switch semaphore.wait(for: timeout) {
    case .timedOut:
        throw RequestTimeoutError()
    case .success:
        if let error = responseError {
            throw error
        }
        return result
    }
}

func waitForResponse(
    from url: URL,
    timeoutPerTry: DateComponents = 10.seconds,
    retries: UInt = 1,
    backoff: Double = 1,
    sleepBetweenTries: TimeInterval = 0,
    maxSleepBetweenTries: TimeInterval = 300
) -> String? {
    var sleepBetweenTries = sleepBetweenTries
    for tryNum in 0 ... retries {
        do {
            let resp = try query(url: url, timeout: timeoutPerTry.timeInterval)
            return resp
        } catch {
            log.debug("Could not reach URL '\(url)': \(error)", context: ["try": tryNum])
        }
        if sleepBetweenTries > 0 {
            Thread.sleep(forTimeInterval: sleepBetweenTries)
            sleepBetweenTries = min(sleepBetweenTries * backoff, maxSleepBetweenTries)
        }
    }

    return nil
}

func buildAlamofireSession(requestTimeout: DateComponents = 30.seconds, resourceTimeout: DateComponents = 60.seconds) -> Alamofire.Session {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = requestTimeout.timeInterval
    configuration.timeoutIntervalForResource = resourceTimeout.timeInterval
    return Alamofire.Session(configuration: configuration)
}

extension String {
    subscript(index: Int) -> Character {
        self[self.index(startIndex, offsetBy: index)]
    }
}

public extension String {
    func levenshtein(_ other: String) -> Int {
        let sCount = count
        let oCount = other.count

        guard sCount != 0 else {
            return oCount
        }

        guard oCount != 0 else {
            return sCount
        }

        let line: [Int] = Array(repeating: 0, count: oCount + 1)
        var mat: [[Int]] = Array(repeating: line, count: sCount + 1)

        for i in 0 ... sCount {
            mat[i][0] = i
        }

        for j in 0 ... oCount {
            mat[0][j] = j
        }

        for j in 1 ... oCount {
            for i in 1 ... sCount {
                if self[i - 1] == other[j - 1] {
                    mat[i][j] = mat[i - 1][j - 1] // no operation
                } else {
                    let del = mat[i - 1][j] + 1 // deletion
                    let ins = mat[i][j - 1] + 1 // insertion
                    let sub = mat[i - 1][j - 1] + 1 // substitution
                    mat[i][j] = min(min(del, ins), sub)
                }
            }
        }

        return mat[sCount][oCount]
    }
}

let publicKey =
    """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKGs3ARma5DHHnBb/vvTQmRV6sS3Y
    KtuJCVywyiA6TqoFEuQWDVmVwScqPbm5zmdRIUK31iZvxGjFjggMutstEA==
    -----END PUBLIC KEY-----
    """

func appDelegate() -> AppDelegate {
    NSApplication.shared.delegate as! AppDelegate
}

func refreshScreen(refocus: Bool = true) {
    mainThread {
        let focusedApp = NSWorkspace.shared.runningApplications.first(where: { app in app.isActive })
        if refocus {
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }

        if let w = appDelegate().windowController?.window?.contentViewController?.view {
            w.setNeedsDisplay(w.frame)
        }

        if refocus {
            focusedApp?.activate(options: .activateIgnoringOtherApps)
        }
    }
}

func createAndShowWindow(
    _ identifier: String,
    controller: inout ModernWindowController?,
    show: Bool = true,
    focus: Bool = true,
    screen: NSScreen? = nil
) {
    mainThread {
        guard let mainStoryboard = NSStoryboard.main else { return }

        if controller == nil {
            controller = mainStoryboard
                .instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(identifier)) as? ModernWindowController
        }

        if show, let wc = controller {
            wc.initPopovers()

            if let screen = screen, let w = wc.window, w.screen != screen {
                let size = w.frame.size
                w.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
            }

            wc.showWindow(nil)

            if let window = wc.window as? ModernWindow {
                log.debug("Showing window '\(window.title)'")
                window.orderFrontRegardless()
            }
            if focus {
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}

func encrypt(message: Data, key: String? = nil) -> Data? {
    do {
        let eccPublicKey = try ECPublicKey(key: key ?? publicKey)
        let encrypted = try message.encrypt(with: eccPublicKey)

        return encrypted
    } catch {
        log.error("Error when encrypting message: \(error)")
        return nil
    }
}

func sha256(data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: CC_SHA256_DIGEST_LENGTH.i)
    data.withUnsafeBytes {
        _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return Data(hash)
}

func sha512(data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: CC_SHA512_DIGEST_LENGTH.i)
    data.withUnsafeBytes {
        _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return Data(hash)
}

func shortHash(string: String, length: Int = 8) -> String {
    guard let data = string.data(using: .utf8, allowLossyConversion: true) else { return string }
    return String(sha256(data: data).str(hex: true, separator: "").prefix(length))
}

func getSerialNumberHash() -> String? {
    let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))

    guard platformExpert > 0 else {
        return nil
    }

    if let serialNumberProp = IORegistryEntryCreateCFProperty(
        platformExpert,
        kIOPlatformSerialNumberKey as CFString,
        kCFAllocatorDefault,
        0
    ) {
        guard let serialNumber = (serialNumberProp.takeRetainedValue() as? String)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        else {
            serialNumberProp.release()
            return nil
        }

        IOObjectRelease(platformExpert)
        guard let serialNumberData = serialNumber.data(using: .utf8, allowLossyConversion: true) else {
            return nil
        }
        let hash = sha256(data: serialNumberData).prefix(20).str(base64: true, separator: "").map { (c: Character) -> Character in
            switch c {
            case "/": return Character(".")
            case "+": return Character(".")
            default: return c
            }
        }.str()
        log.info(hash)
        return hash
    }
    return nil
}

func mainThreadSerial(_ action: () -> Void) {
    if Thread.isMainThread {
        action()
    } else {
        mainSerialQueue.sync {
            action()
        }
    }
}

func mainThreadSerial<T>(_ action: () -> T) -> T {
    if Thread.isMainThread {
        return action()
    } else {
        return mainSerialQueue.sync {
            return action()
        }
    }
}

func mainThread(_ action: () -> Void) {
    if Thread.isMainThread {
        action()
    } else if mainThreadLocked.load(ordering: .relaxed) {
        #if DEBUG
            log.error("DEADLOCK ON MAIN THREAD")
        #endif
        action()
    } else {
        DispatchQueue.main.sync {
            action()
        }
    }
}

@discardableResult
func mainThread<T>(_ action: () -> T) -> T {
    if Thread.isMainThread {
        return action()
    } else if mainThreadLocked.load(ordering: .relaxed) {
        #if DEBUG
            log.error("DEADLOCK ON MAIN THREAD")
        #endif
        return action()
    } else {
        return DispatchQueue.main.sync {
            return action()
        }
    }
}

func serialAsyncAfter(ms: Int, _ action: @escaping () -> Void) {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    serialQueue.asyncAfter(deadline: deadline) {
        action()
    }
}

func serialAsyncAfter(ms: Int, _ action: DispatchWorkItem) {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    serialQueue.asyncAfter(deadline: deadline, execute: action.workItem)
}

@discardableResult func asyncAfter(
    ms: Int,
    uniqueTaskKey: String? = nil,
    mainThread: Bool = false,
    _ action: @escaping () -> Void
) -> DispatchWorkItem {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    let task: DispatchWorkItem
    if let key = uniqueTaskKey {
        taskQueueLock.around { taskQueue[key] = mainThread ? mainQueue : timerQueue }
        task = DispatchWorkItem(name: "Unique Task \(key) asyncAfter(\(ms) ms)") {
            guard !isCancelled(key) else {
                timerQueue.async { Thread.current.threadDictionary[key] = nil }
                return
            }
            action()

            timerQueue.async { Thread.current.threadDictionary[key] = nil }
        }

        timerQueue.async {
            (Thread.current.threadDictionary[key] as? DispatchWorkItem)?.cancel()
            Thread.current.threadDictionary[key] = task
        }
    } else {
        task = DispatchWorkItem(name: "asyncAfter(\(ms) ms)") {
            action()
        }
    }

    if mainThread {
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: task.workItem)
    } else {
        concurrentQueue.asyncAfter(deadline: deadline, execute: task.workItem)
    }

    return task
}

func asyncEvery(
    _ interval: DateComponents,
    uniqueTaskKey: String? = nil,
    runs: Int? = nil,
    skipIfExists: Bool = false,
    _ action: @escaping () -> Void
) {
    timerQueue.async {
        if skipIfExists, let key = uniqueTaskKey, let timer = Thread.current.threadDictionary[key] as? Timer, timer.isValid {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval.timeInterval, repeats: true) { timer in
            action()
            guard let key = uniqueTaskKey,
                  let runs = Thread.current.threadDictionary["\(key)-runs"] as? Int,
                  let maxRuns = Thread.current.threadDictionary["\(key)-maxRuns"] as? Int
            else {
                return
            }

            if runs >= maxRuns || isCancelled(key) {
                timer.invalidate()
                Thread.current.threadDictionary[key] = nil
            } else {
                Thread.current.threadDictionary["\(key)-runs"] = runs + 1
            }
        }

        if let key = uniqueTaskKey {
            taskQueueLock.around { taskQueue[key] = timerQueue }
            (Thread.current.threadDictionary[key] as? Timer)?.invalidate()
            Thread.current.threadDictionary[key] = timer

            if let runs = runs {
                Thread.current.threadDictionary["\(key)-maxRuns"] = runs
                Thread.current.threadDictionary["\(key)-runs"] = 0
            }
        }
    }
}

func cancelTask(_ key: String, subscriberKey: String? = nil) {
    guard let queue = taskQueueLock.around({ taskQueue[key] }) else { return }

    queue.async {
        guard let task = Thread.current.threadDictionary[key] else { return }

        Thread.current.threadDictionary["\(key)-cancelled"] = true
        if let task = task as? DispatchWorkItem {
            task.cancel()
        } else if let task = task as? Timer {
            task.invalidate()
        }

        if let subscriberKey = subscriberKey {
            globalObservers.removeValue(forKey: subscriberKey)
        }

        Thread.current.threadDictionary.removeObject(forKey: key)
    }
}

@discardableResult func asyncNow(
    timeout: DateComponents? = nil,
    queue: DispatchQueue? = nil,
    runLoopQueue: RunloopQueue? = nil,
    threaded: Bool = false,
    _ action: @escaping () -> Void
) -> DispatchTimeoutResult {
    if threaded {
        guard let timeout = timeout else {
            let thread = Thread { action() }
            thread.start()
            return .success
        }

        let semaphore = DispatchSemaphore(value: 0, name: "Async Thread Timeout")

        let thread = Thread {
            action()
            semaphore.signal()
        }
        thread.start()

        let result = semaphore.wait(for: timeout)
        if result == .timedOut {
            thread.cancel()
        }

        return result
    }

    if let queue = runLoopQueue {
        guard let timeout = timeout else {
            queue.async { action() }
            return .success
        }

        let semaphore = DispatchSemaphore(value: 0, name: "Async RunLoopQueue Timeout")

        queue.async {
            action()
            semaphore.signal()
        }

        let result = semaphore.wait(for: timeout)

        return result
    }

    let queue = queue ?? concurrentQueue
    guard let timeout = timeout else {
        queue.async { action() }
        return .success
    }

    let task = DispatchWorkItem(name: "async(\(queue.label)") {
        action()
    }
    queue.async(execute: task.workItem)

    let result = task.wait(for: timeout)
    if result == .timedOut {
        task.cancel()
    }

    return result
}

func asyncEvery(_ interval: DateComponents, queue: RunloopQueue, _ action: @escaping (CFRunLoopTimer?) -> Void) -> CFRunLoopTimer? {
    queue.async(every: interval, action)
}

func asyncEvery(_ interval: DateComponents, qos: QualityOfService? = nil, _ action: @escaping (inout TimeInterval) -> Void) -> Thread {
    let thread = Thread {
        var pollingInterval = interval.timeInterval
        while true {
            action(&pollingInterval)
            if Thread.current.isCancelled { return }
            Thread.sleep(forTimeInterval: pollingInterval)
            if Thread.current.isCancelled { return }
        }
    }

    if let qos = qos {
        thread.qualityOfService = qos
    }

    thread.start()
    return thread
}

var globalObservers: [String: AnyCancellable] = Dictionary(minimumCapacity: 100)
var taskQueue: [String: RunloopQueue] = Dictionary(minimumCapacity: 100)
let taskQueueLock = NSRecursiveLock()

func isCancelled(_ key: String) -> Bool {
    Thread.current.threadDictionary[key] == nil || (Thread.current.threadDictionary["\(key)-cancelled"] as? Bool) ?? false
}

func debounce(
    ms: Int,
    uniqueTaskKey: String,
    queue: RunloopQueue = debounceQueue,
    mainThread: Bool = false,
    replace: Bool = false,
    subscriberKey: String? = nil,
    _ action: @escaping () -> Void
) {
    debounce(
        ms: ms,
        uniqueTaskKey: uniqueTaskKey,
        queue: queue,
        mainThread: mainThread,
        value: nil,
        replace: replace,
        subscriberKey: subscriberKey
    ) { (_: Bool?) in action() }
}

func debounce<T: Equatable>(
    ms: Int,
    uniqueTaskKey: String,
    queue: RunloopQueue = debounceQueue,
    mainThread: Bool = false,
    value: T,
    replace: Bool = false,
    subscriberKey: String? = nil,
    _ action: @escaping (T) -> Void
) {
    taskQueueLock.around { taskQueue[uniqueTaskKey] = mainThread ? mainQueue : queue }
    queue.async {
        Thread.current.threadDictionary["\(uniqueTaskKey)-cancelled"] = false
        if Thread.current.threadDictionary[uniqueTaskKey] == nil || replace {
            #if DEBUG
                if replace {
                    log.verbose("Replacing subscriber for '\(uniqueTaskKey)'. Current subscriber count: \(globalObservers.count)")
                } else {
                    log.verbose("Creating subscriber for '\(uniqueTaskKey)'. Current subscriber count: \(globalObservers.count)")
                }
            #endif

            let pub = (Thread.current.threadDictionary[uniqueTaskKey] as? PassthroughSubject<T, Never>) ?? PassthroughSubject<T, Never>()
            pub
                .debounce(for: .milliseconds(ms), scheduler: mainThread ? RunLoop.main : RunLoop.current)
                .sink(receiveValue: action)
                .store(in: &globalObservers, for: subscriberKey ?? uniqueTaskKey)
            Thread.current.threadDictionary[uniqueTaskKey] = pub

            #if DEBUG
                if replace {
                    log.verbose("Replaced subscriber for '\(uniqueTaskKey)'. New subscriber count: \(globalObservers.count)")
                } else {
                    log.verbose("Created subscriber for '\(uniqueTaskKey)'. New subscriber count: \(globalObservers.count)")
                }
            #endif
        }

        guard let pub = Thread.current.threadDictionary[uniqueTaskKey] as? PassthroughSubject<T, Never> else { return }
        pub.send(value)
    }
}

func asyncAfter(ms: Int, _ action: DispatchWorkItem) {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    concurrentQueue.asyncAfter(deadline: deadline, execute: action.workItem)
}

func mainAsyncAfter(ms: Int, _ action: @escaping () -> Void) {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    DispatchQueue.main.asyncAfter(deadline: deadline) {
        action()
    }
}

func mainAsyncAfter(ms: Int, _ action: DispatchWorkItem) {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    DispatchQueue.main.asyncAfter(deadline: deadline, execute: action.workItem)
}

func mapNumber<T: Numeric & Comparable & FloatingPoint>(_ number: T, fromLow: T, fromHigh: T, toLow: T, toHigh: T) -> T {
    if fromLow == fromHigh {
        log.warning("fromLow and fromHigh are both equal to \(fromLow)")
        return number
    }

    if number >= fromHigh {
        return toHigh
    } else if number <= fromLow {
        return toLow
    } else if toLow < toHigh {
        let diff = toHigh - toLow
        let fromDiff = fromHigh - fromLow
        return (number - fromLow) * diff / fromDiff + toLow
    } else {
        let diff = toHigh - toLow
        let fromDiff = fromHigh - fromLow
        return (number - fromLow) * diff / fromDiff + toLow
    }
}

func mapNumberSIMD(_ number: [Double], fromLow: Double, fromHigh: Double, toLow: Double, toHigh: Double) -> [Double] {
    if fromLow == fromHigh {
        log.warning("fromLow and fromHigh are both equal to \(fromLow)")
        return number
    }

    let resultLow = number.firstIndex(where: { $0 > fromLow }) ?? 0
    let resultHigh = number.lastIndex(where: { $0 < fromHigh }) ?? (number.count - 1)

    if resultLow >= resultHigh {
        var result = [Double](repeating: toLow, count: number.count)
        if resultHigh != (number.count - 1) {
            result.replaceSubrange((resultHigh + 1) ..< number.count, with: repeatElement(toHigh, count: number.count - resultHigh))
        }
        return result
    }

    let numbers = Array(number[resultLow ... resultHigh])

    var value: [Double]
    if toLow == 0.0, fromLow == 0.0, toHigh == 1.0 {
        value = numbers / fromHigh
    } else {
        let diff = toHigh - toLow
        let fromDiff = fromHigh - fromLow
        value = numbers - fromLow
        value = value * diff
        value = value / fromDiff
        value = value + toLow
    }

    var result = [Double](repeating: toLow, count: number.count)
    result.replaceSubrange(resultLow ... resultHigh, with: value)
    if resultHigh != (number.count - 1) {
        result.replaceSubrange((resultHigh + 1) ..< number.count, with: repeatElement(toHigh, count: number.count - (resultHigh + 1)))
    }
    return result
}

func ramp(targetValue: Float, lastTargetValue: inout Float, samples: Int, step _: Float = 1.0) -> [Float] {
    var control = [Float](repeating: 0, count: samples)

    var from = lastTargetValue
    var to = targetValue

    var reversed = false
    if from > to {
        swap(&from, &to)
        reversed = true
    }

    if from == to {
        return [Float](repeating: from, count: samples)
    }

    control = vDSP.ramp(in: from ... to, count: samples)

    return reversed ? control.reversed() : control
}

struct Zip3Sequence<E1, E2, E3>: Sequence, IteratorProtocol {
    private let _next: () -> (E1, E2, E3)?

    init<S1: Sequence, S2: Sequence, S3: Sequence>(_ s1: S1, _ s2: S2, _ s3: S3) where S1.Element == E1, S2.Element == E2,
        S3.Element == E3
    {
        var it1 = s1.makeIterator()
        var it2 = s2.makeIterator()
        var it3 = s3.makeIterator()
        _next = {
            guard let e1 = it1.next(), let e2 = it2.next(), let e3 = it3.next() else { return nil }
            return (e1, e2, e3)
        }
    }

    mutating func next() -> (E1, E2, E3)? {
        _next()
    }
}

func zip3<S1: Sequence, S2: Sequence, S3: Sequence>(_ s1: S1, _ s2: S2, _ s3: S3) -> Zip3Sequence<S1.Element, S2.Element, S3.Element> {
    Zip3Sequence(s1, s2, s3)
}

struct Zip4Sequence<E1, E2, E3, E4>: Sequence, IteratorProtocol {
    private let _next: () -> (E1, E2, E3, E4)?

    init<S1: Sequence, S2: Sequence, S3: Sequence, S4: Sequence>(_ s1: S1, _ s2: S2, _ s3: S3, _ s4: S4) where S1.Element == E1,
        S2.Element == E2, S3.Element == E3, S4.Element == E4
    {
        var it1 = s1.makeIterator()
        var it2 = s2.makeIterator()
        var it3 = s3.makeIterator()
        var it4 = s4.makeIterator()
        _next = {
            guard let e1 = it1.next(), let e2 = it2.next(), let e3 = it3.next(), let e4 = it4.next() else { return nil }
            return (e1, e2, e3, e4)
        }
    }

    mutating func next() -> (E1, E2, E3, E4)? {
        _next()
    }
}

func zip4<S1: Sequence, S2: Sequence, S3: Sequence, S4: Sequence>(
    _ s1: S1,
    _ s2: S2,
    _ s3: S3,
    _ s4: S4
) -> Zip4Sequence<S1.Element, S2.Element, S3.Element, S4.Element> {
    Zip4Sequence(s1, s2, s3, s4)
}

var gammaWindowController: NSWindowController?
var faceLightWindowController: NSWindowController?

func createWindow(
    _ identifier: String,
    controller: inout NSWindowController?,
    screen: NSScreen? = nil,
    show: Bool = true,
    backgroundColor: NSColor? = .clear,
    level: NSWindow.Level = .normal,
    fillScreen: Bool = false
) {
    mainThread {
        guard let mainStoryboard = NSStoryboard.main else { return }

        if controller == nil {
            controller = mainStoryboard
                .instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(identifier)) as? NSWindowController
        }

        if let wc = controller {
            if let screen = screen, let w = wc.window {
                w.setFrameOrigin(CGPoint(x: screen.frame.minX, y: screen.frame.minY))
                if fillScreen {
                    w.setFrame(screen.frame, display: false)
                }
            }

            if let window = wc.window {
                window.level = level
                window.isOpaque = false
                window.backgroundColor = backgroundColor
                if show {
                    log.debug("Showing window '\(window.title)'")
                    wc.showWindow(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }
}

struct OperationHighlightData: Equatable {
    let shouldHighlight: Bool
    let screen: NSScreen?
}

let operationHighlightPublisher = PassthroughSubject<OperationHighlightData, Never>()

func showOperationInProgress(screen: NSScreen? = nil) {
    guard !CachedDefaults[.hideYellowDot] else { return }
    operationHighlightPublisher.send(OperationHighlightData(shouldHighlight: true, screen: screen))
    debounce(ms: 3000, uniqueTaskKey: "operationHighlightHandler") {
        operationHighlightPublisher.send(OperationHighlightData(shouldHighlight: false, screen: nil))
    }
}

func hideOperationInProgress() {
    operationHighlightPublisher.send(OperationHighlightData(shouldHighlight: false, screen: nil))
}

// MARK: Dialogs

var alertsByMessageSemaphore = DispatchSemaphore(value: 1, name: "alertsByMessageSemaphore")
var alertsByMessage = [String: Bool]()

func dialog(
    message: String,
    info: String,
    okButton: String? = "OK",
    cancelButton: String? = "Cancel",
    thirdButton: String? = nil,
    screen: NSScreen? = nil,
    window: NSWindow? = nil,
    suppressionText: String? = nil,
    wide: Bool = false,
    ultrawide: Bool = false
) -> NSAlert {
    mainThread {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning

        if ultrawide {
            alert.accessoryView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 500, height: 0)))
        } else if wide {
            alert.accessoryView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 650, height: 0)))
        }

        if let okButton = okButton {
            alert.addButton(withTitle: okButton)
        }
        if let cancelButton = cancelButton {
            alert.addButton(withTitle: cancelButton)
        }
        if let thirdButton = thirdButton {
            alert.addButton(withTitle: thirdButton)
        }

        if let suppressionText = suppressionText {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = suppressionText
        }

        if let screen = screen {
            let w = window ?? alert.window

            let alertSize = w.frame.size
            w.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - alertSize.width / 2, y: screen.visibleFrame.midY - alertSize.height / 2))
            w.makeKeyAndOrderFront(nil)
            if window != nil {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        return alert
    }
}

func ask(
    message: String,
    info: String,
    okButton: String = "OK",
    cancelButton: String = "Cancel",
    thirdButton: String? = nil,
    screen: NSScreen? = nil,
    window: NSWindow? = nil,
    suppressionText: String? = nil,
    onSuppression: ((Bool) -> Void)? = nil,
    onCompletion: ((Bool) -> Void)? = nil,
    unique: Bool = false,
    waitTimeout: DateComponents = 5.seconds,
    wide: Bool = false,
    ultrawide: Bool = false
) -> Bool {
    ask(
        message: message,
        info: info,
        okButton: okButton,
        cancelButton: cancelButton,
        thirdButton: thirdButton,
        screen: screen,
        window: window,
        suppressionText: suppressionText,
        onSuppression: onSuppression,
        onCompletion: { resp in onCompletion?(resp == .alertFirstButtonReturn) },
        unique: unique,
        waitTimeout: waitTimeout,
        wide: wide,
        ultrawide: ultrawide
    ) == .alertFirstButtonReturn
}

func ask(
    message: String,
    info: String,
    okButton: String = "OK",
    cancelButton: String = "Cancel",
    thirdButton: String? = nil,
    screen: NSScreen? = nil,
    window: NSWindow? = nil,
    suppressionText: String? = nil,
    onSuppression: ((Bool) -> Void)? = nil,
    onCompletion: ((NSApplication.ModalResponse) -> Void)? = nil,
    unique: Bool = false,
    waitTimeout: DateComponents = 5.seconds,
    wide: Bool = false,
    ultrawide: Bool = false
) -> NSApplication.ModalResponse {
    if unique {
        switch alertsByMessageSemaphore.wait(for: waitTimeout) {
        case .success:
            if alertsByMessage[message] != nil {
                return .cancel
            }
            alertsByMessage[message] = true
        case .timedOut:
            log.warning("Timeout in waiting for alertsForMessage")
            return .cancel
        }
        alertsByMessageSemaphore.signal()
    }

    let response: NSApplication.ModalResponse = mainThread {
        let alert = dialog(
            message: message,
            info: info,
            okButton: okButton,
            cancelButton: cancelButton,
            thirdButton: thirdButton,
            screen: screen,
            window: window,
            suppressionText: suppressionText,
            wide: wide,
            ultrawide: ultrawide
        )

        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: { resp in
                onCompletion?(resp)
                onSuppression?((alert.suppressionButton?.state ?? .off) == .on)

                if unique {
                    switch alertsByMessageSemaphore.wait(for: 5) {
                    case .success:
                        alertsByMessage.removeValue(forKey: message)
                    case .timedOut:
                        log.warning("Timeout in waiting for alertsForMessage")
                    }
                    alertsByMessageSemaphore.signal()
                }
            })
            return .cancel
        }

        let resp = alert.runModal()

        if let onSuppression = onSuppression {
            onSuppression((alert.suppressionButton?.state ?? .off) == .on)
        }

        if unique {
            switch alertsByMessageSemaphore.wait(for: 5) {
            case .success:
                alertsByMessage.removeValue(forKey: message)
            case .timedOut:
                log.warning("Timeout in waiting for alertsForMessage")
            }
            alertsByMessageSemaphore.signal()
        }
        return resp
    }
    return response
}

// MARK: Property Wrappers

/// An `os_unfair_lock` wrapper.
final class UnfairLock {
    private let unfairLock: os_unfair_lock_t

    init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        #if DEBUG
            log.verbose("START DEINIT")
            defer { log.verbose("END DEINIT") }
        #endif
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @Atomic var lockedInThread: Int32 = 0

    func locked() -> Bool { !os_unfair_lock_trylock(unfairLock) }

    @discardableResult
    private func trylock() -> Bool {
        os_unfair_lock_trylock(unfairLock)
    }

    private func lock() -> Bool {
        guard let threadID = Thread.current.value(forKeyPath: "private.seqNum") as? Int32, lockedInThread != threadID else {
            return trylock()
        }
        os_unfair_lock_lock(unfairLock)
        lockedInThread = threadID
        return true
    }

    private func unlock() {
        os_unfair_lock_unlock(unfairLock)
        lockedInThread = 0
    }

    /// Executes a closure returning a value while acquiring the lock.
    ///
    /// - Parameter closure: The closure to run.
    ///
    /// - Returns:           The value the closure generated.
    @inline(__always) func around<T>(_ closure: () -> T) -> T {
        let locked = lock(); defer { if locked { unlock() } }
        return closure()
    }

    /// Execute a closure while acquiring the lock.
    ///
    /// - Parameter closure: The closure to run.
    @inline(__always) func around(_ closure: () -> Void) {
        let locked = lock(); defer { if locked { unlock() } }
        return closure()
    }
}

var mainThreadLocked = ManagedAtomic<Bool>(false)

extension NSRecursiveLock {
    @inline(__always) func aroundThrows<T>(
        timeout: TimeInterval = 10,
        ignoreMainThread: Bool = false,
        _ closure: () throws -> T
    ) throws -> T {
        if ignoreMainThread, Thread.isMainThread {
            return try closure()
//            mainThreadLocked.store(true, ordering: .sequentiallyConsistent)
        }
        let locked = lock(before: Date().addingTimeInterval(timeout))

        defer {
            if locked {
                unlock()
//                if Thread.isMainThread {
//                    mainThreadLocked.store(false, ordering: .sequentiallyConsistent)
//                }
            }
        }

        return try closure()
    }

    /// Executes a closure returning a value while acquiring the lock.
    ///
    /// - Parameter closure: The closure to run.
    ///
    /// - Returns:           The value the closure generated.
    @inline(__always) func around<T>(timeout: TimeInterval = 10, ignoreMainThread: Bool = false, _ closure: () -> T) -> T {
        if ignoreMainThread, Thread.isMainThread {
            return closure()
//            mainThreadLocked.store(true, ordering: .sequentiallyConsistent)
        }
        let locked = lock(before: Date().addingTimeInterval(timeout))
        defer {
            if locked {
                unlock()
//                if Thread.isMainThread {
//                    mainThreadLocked.store(false, ordering: .sequentiallyConsistent)
//                }
            }
        }

        return closure()
    }

    /// Execute a closure while acquiring the lock.
    ///
    /// - Parameter closure: The closure to run.
    @inline(__always) func around(timeout: TimeInterval = 10, ignoreMainThread: Bool = false, _ closure: () -> Void) {
        if ignoreMainThread, Thread.isMainThread {
            return closure()
//            mainThreadLocked.store(true, ordering: .sequentiallyConsistent)
        }
        let locked = lock(before: Date().addingTimeInterval(timeout))

        defer {
            if locked {
                unlock()
//                if Thread.isMainThread {
//                    mainThreadLocked.store(false, ordering: .sequentiallyConsistent)
//                }
            }
        }

        closure()
    }
}

@propertyWrapper
public struct AtomicLock<Value> {
    var value: Value
    var lock = NSRecursiveLock()

    public init(wrappedValue: Value) {
        value = wrappedValue
    }

    public var wrappedValue: Value {
        get {
            lock.around { value }
        }
        set {
            lock.around { value = newValue }
        }
    }
}

@propertyWrapper
public struct Atomic<Value: AtomicValue> {
    var value: ManagedAtomic<Value>

    public init(wrappedValue: Value) {
        value = ManagedAtomic<Value>(wrappedValue)
    }

    public var wrappedValue: Value {
        get {
            value.load(ordering: .relaxed)
        }
        set {
            value.store(newValue, ordering: .sequentiallyConsistent)
        }
    }
}

@propertyWrapper
public struct AtomicOptional<Value: AtomicValue & Equatable> {
    var nilValue: Value
    var value: ManagedAtomic<Value>

    public init(wrappedValue: Value?, nilValue: Value) {
        self.nilValue = nilValue
        value = ManagedAtomic<Value>(wrappedValue ?? nilValue)
    }

    public var wrappedValue: Value? {
        get {
            let v = value.load(ordering: .relaxed)
            return v == nilValue ? nil : v
        }
        set {
            value.store(newValue ?? nilValue, ordering: .sequentiallyConsistent)
        }
    }
}

@propertyWrapper
public struct LazyAtomic<Value> {
    var storage: Value?
    let constructor: () -> Value

    public init(wrappedValue constructor: @autoclosure @escaping () -> Value) {
        self.constructor = constructor
    }

    public var wrappedValue: Value {
        mutating get {
            if storage == nil {
                self.storage = constructor()
            }
            return storage!
        }
        set {
            storage = newValue
        }
    }
}

func localNow() -> DateInRegion {
    Region.local.nowInThisRegion()
}

func monospace(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

func displayInfoDictionary(_ id: CGDirectDisplayID) -> NSDictionary? {
    let unmanagedDict = CoreDisplay_DisplayCreateInfoDictionary(id)
    let retainedDict = unmanagedDict?.takeRetainedValue()
    guard let dict = retainedDict as NSDictionary? else {
        return nil
    }

    return dict
}

class PlainTextPasteView: NSTextView, NSTextViewDelegate {
    override func paste(_ sender: Any?) {
        super.pasteAsPlainText(sender)
    }
}

class PlainTextFieldCell: NSTextFieldCell {
    static var plainTextView: PlainTextPasteView?

    override func fieldEditor(for _: NSView) -> NSTextView? {
        if Self.plainTextView == nil {
            Self.plainTextView = PlainTextPasteView()
        }
        return Self.plainTextView
    }
}

func cap<T: Comparable>(_ number: T, minVal: T, maxVal: T) -> T {
    max(min(number, maxVal), minVal)
}

func notify(identifier: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = UNNotificationSound.default
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
        withCompletionHandler: nil
    )
}

func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    guard !isTestID(displayID) else { return nil }
    return NSScreen.screens.first(where: { screen in screen.hasDisplayID(displayID) })
}

struct Window {
    let storeType: Int
    let isOnScreen: Bool
    let layer: NSWindow.Level
    let title: String
    let ownerName: String
    let alpha: Float
    let bounds: NSRect
    let id: Int
    let ownerPID: Int
    let sharingState: Int
    let memoryUsage: Int
    let screen: NSScreen?
    let appException: AppException?
    let runningApp: NSRunningApplication?

    init(from dict: [String: AnyObject], appException: AppException? = nil, runningApp: NSRunningApplication? = nil) {
        storeType = (dict[kCGWindowStoreType as String] as? Int) ?? 0
        isOnScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
        layer = NSWindow.Level(rawValue: (dict[kCGWindowLayer as String] as? Int) ?? NSWindow.Level.normal.rawValue)
        title = (dict[kCGWindowName as String] as? String) ?? ""
        ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
        alpha = (dict[kCGWindowAlpha as String] as? Float) ?? 1

        if let rectDict = dict[kCGWindowBounds as String], let rect = CGRect(dictionaryRepresentation: rectDict as! CFDictionary) {
            bounds = rect as NSRect
            screen = NSScreen.screens.first { NSRect(
                x: $0.frame.origin.x,
                y: $0.frame.origin.y - $0.frame.height,
                width: $0.frame.width,
                height: $0.frame.height
            ).intersects(rect as NSRect) }
        } else {
            bounds = NSRect()
            screen = nil
        }

        id = (dict[kCGWindowNumber as String] as? Int) ?? 0
        ownerPID = (dict[kCGWindowOwnerPID as String] as? Int) ?? 0
        sharingState = (dict[kCGWindowSharingState as String] as? Int) ?? 0
        memoryUsage = (dict[kCGWindowMemoryUsage as String] as? Int) ?? 0
        self.appException = appException
        self.runningApp = runningApp
    }
}

extension NSRect {
    func intersectedArea(_ other: NSRect) -> CGFloat {
        let i = intersection(other)
        return i.height * i.width
    }
}

struct AXWindow {
    let frame: NSRect
    let fullScreen: Bool
    let title: String
    let position: NSPoint
    let main: Bool
    let minimized: Bool
    let focused: Bool
    let size: NSSize
    let identifier: String
    let subrole: String
    let role: String
    let runningApp: NSRunningApplication?
    let appException: AppException?
    let screen: NSScreen?

    init?(from window: UIElement, runningApp: NSRunningApplication? = nil, appException: AppException? = nil) {
        guard let attrs = try? window.getMultipleAttributes(
            .frame,
            .fullScreen,
            .title,
            .position,
            .main,
            .minimized,
            .size,
            .identifier,
            .subrole,
            .role,
            .focused
        )
        else {
            return nil
        }

        let frame = attrs[.frame] as? NSRect ?? NSRect()

        self.frame = frame
        fullScreen = attrs[.fullScreen] as? Bool ?? false
        title = attrs[.title] as? String ?? ""
        position = attrs[.position] as? NSPoint ?? NSPoint()
        main = attrs[.main] as? Bool ?? false
        minimized = attrs[.minimized] as? Bool ?? false
        focused = attrs[.focused] as? Bool ?? false
        size = attrs[.size] as? NSSize ?? NSSize()
        identifier = attrs[.identifier] as? String ?? ""
        subrole = attrs[.subrole] as? String ?? ""
        role = attrs[.role] as? String ?? ""

        self.runningApp = runningApp
        self.appException = appException
        screen = NSScreen.screens.filter { !$0.isBuiltin && $0.frame.intersects(frame) }.max(by: { s1, s2 in
            s1.frame.intersectedArea(frame) < s2.frame.intersectedArea(frame)
        })
    }
}

extension NSRunningApplication {
    func windows(appException: AppException? = nil) -> [AXWindow]? {
        guard let app = Application(self) else { return nil }
        do {
            return try app.windows()?.compactMap { AXWindow(from: $0, runningApp: self, appException: appException) }
        } catch {
            log.error("Can't get windows for app \(self): \(error)")
            return nil
        }
    }
}

func windowList(
    for app: NSRunningApplication,
    onscreen: Bool? = nil,
    opaque: Bool? = nil,
    withTitle: Bool? = nil,
    levels: Set<NSWindow.Level>? = nil,
    appException: AppException? = nil
) -> [Window]? {
    windowList(
        for: app.processIdentifier.i,
        onscreen: onscreen,
        opaque: opaque,
        withTitle: withTitle,
        levels: levels,
        appException: appException,
        runningApp: app
    )
}

func windowList(
    for pid: Int,
    onscreen: Bool? = nil,
    opaque: Bool? = nil,
    withTitle: Bool? = nil,
    levels: Set<NSWindow.Level>? = nil,
    appException: AppException? = nil,
    runningApp: NSRunningApplication? = nil
) -> [Window]? {
    let options: CGWindowListOption = (onscreen == true) ? [.excludeDesktopElements, .optionOnScreenOnly] : [.excludeDesktopElements]
    guard let cgWindowListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as NSArray? as? [[String: AnyObject]] else {
        return nil
    }

    let windows = cgWindowListInfo.filter { windowDict in
        guard let ownerProcessID = windowDict[kCGWindowOwnerPID as String] as? Int else { return false }
        if let opaque = opaque, (((windowDict[kCGWindowAlpha as String] as? Float) ?? 0) > 0) != opaque { return false }
        if let withTitle = withTitle, ((windowDict[kCGWindowName as String] as? String) ?? "").isEmpty != withTitle { return false }
        if let levels = levels, !levels.contains(
            NSWindow.Level(rawValue: (windowDict[kCGWindowLayer as String] as? Int) ?? NSWindow.Level.normal.rawValue)
        ) {
            return false
        }

        return pid == ownerProcessID
    }.map {
        Window(from: $0, appException: appException, runningApp: runningApp)
    }

    return windows
}

func activeWindow(on screen: NSScreen? = nil) -> AXWindow? {
    guard let frontMostApp = NSWorkspace.shared.frontmostApplication else {
        return nil
    }

    let appException = displayController.runningAppExceptions.first { $0.identifier == frontMostApp.bundleIdentifier }

    return frontMostApp.windows(appException: appException)?.first(where: { $0.screen?.displayID == screen?.displayID })

//    return windowList(for: frontMostApp, opaque: true, levels: [.normal, .modalPanel, .popUpMenu, .floating], appException: appException)?
//        .filter { screen == nil || $0.screen?.displayID == screen!.displayID }
//        .min { $0.layer < $1.layer && $0.isOnScreen.i >= $1.isOnScreen.i }
}
