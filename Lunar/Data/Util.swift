import Accelerate
import Atomics
import AXSwift
import Cocoa
import Combine
import Defaults
import Foundation
import Path
import Surge
import SwiftDate
import SwiftyMarkdown
import UserNotifications

typealias FilePath = Path
func p(_ string: String) -> FilePath? {
    FilePath(string)
}

func displayIsInMirrorSet(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayIsInMirrorSet(id) != 0
}

func displayIsInHardwareMirrorSet(_ id: CGDirectDisplayID) -> Bool {
    guard let primary = Display.getPrimaryMirrorScreen(id) else { return displayIsInMirrorSet(id) }
    return !primary.isDummy
}

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
//        return id == GENERIC_DISPLAY_ID
        return TEST_IDS.contains(id)
    #else
        return id == GENERIC_DISPLAY_ID
    #endif
}

// MARK: - RequestTimeoutError

class RequestTimeoutError: Error {}

// MARK: - ResponseError

struct ResponseError: Error {
    var statusCode: Int
}

// MARK: - ProcessStatus

struct ProcessStatus {
    var output: Data?
    var error: Data?
    var success: Bool

    var o: String? {
        output?.s?.trimmed
    }

    var e: String? {
        error?.s?.trimmed
    }
}

func stdout(of process: Process) -> Data? {
    let stdout = process.standardOutput as! FileHandle
    try? stdout.close()

    guard let path = process.environment?["__swift_stdout"],
          let stdoutFile = FileHandle(forReadingAtPath: path) else { return nil }
    if #available(macOS 10.15.4, *) {
        return try! stdoutFile.readToEnd()
    } else {
        return stdoutFile.readDataToEndOfFile()
    }
}

func stderr(of process: Process) -> Data? {
    let stderr = process.standardOutput as! FileHandle
    try? stderr.close()

    guard let path = process.environment?["__swift_stderr"],
          let stderrFile = FileHandle(forReadingAtPath: path) else { return nil }
    if #available(macOS 10.15.4, *) {
        return try! stderrFile.readToEnd()
    } else {
        return stderrFile.readDataToEndOfFile()
    }
}

func shellProc(_ launchPath: String = "/bin/zsh", args: [String], env: [String: String]? = nil) -> Process? {
    let outputDir = try! fm.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: fm.homeDirectoryForCurrentUser,
        create: true
    )

    let stdoutFilePath = outputDir.appendingPathComponent("stdout").path
    fm.createFile(atPath: stdoutFilePath, contents: nil, attributes: nil)

    let stderrFilePath = outputDir.appendingPathComponent("stderr").path
    fm.createFile(atPath: stderrFilePath, contents: nil, attributes: nil)

    guard let stdoutFile = FileHandle(forWritingAtPath: stdoutFilePath),
          let stderrFile = FileHandle(forWritingAtPath: stderrFilePath)
    else {
        return nil
    }

    let task = Process()
    task.standardOutput = stdoutFile
    task.standardError = stderrFile
    task.launchPath = launchPath
    task.arguments = args

    var env = env ?? ProcessInfo.processInfo.environment
    env["__swift_stdout"] = stdoutFilePath
    env["__swift_stderr"] = stderrFilePath
    task.environment = env

    do {
        try task.run()
    } catch {
        log.error("Error running \(launchPath) \(args): \(error)")
        return nil
    }

    return task
}

func shell(
    _ launchPath: String = "/bin/zsh",
    command: String,
    timeout: DateComponents? = nil,
    env: [String: String]? = nil,
    wait: Bool = true
) -> ProcessStatus {
    shell(launchPath, args: ["-c", command], timeout: timeout, env: env, wait: wait)
}

func shell(
    _ launchPath: String = "/bin/zsh",
    args: [String],
    timeout: DateComponents? = nil,
    env: [String: String]? = nil,
    wait: Bool = true
) -> ProcessStatus {
    guard let task = shellProc(launchPath, args: args, env: env) else {
        return ProcessStatus(output: nil, error: nil, success: false)
    }

    guard wait else {
        return ProcessStatus(
            output: nil,
            error: nil,
            success: true
        )
    }

    guard let timeout = timeout else {
        task.waitUntilExit()
        return ProcessStatus(
            output: stdout(of: task),
            error: stderr(of: task),
            success: task.terminationStatus == 0
        )
    }

    let result = asyncNow(timeout: timeout) {
        task.waitUntilExit()
    }
    if result == .timedOut {
        task.terminate()
    }

    return ProcessStatus(
        output: stdout(of: task),
        error: stderr(of: task),
        success: task.terminationStatus == 0
    )
}

// MARK: - DispatchWorkItem

class DispatchWorkItem {
    // MARK: Lifecycle

    init(name: String, flags: DispatchWorkItemFlags = [], block: @escaping @convention(block) () -> Void) {
        workItem = Foundation.DispatchWorkItem(flags: flags, block: block)
        self.name = name
    }

    // MARK: Internal

    var name = ""
    var workItem: Foundation.DispatchWorkItem

    @inline(__always) var isCancelled: Bool {
        workItem.isCancelled
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
            let result = workItem.wait(timeout: DispatchTime.now() + timeout)
            if result == .timedOut {
                workItem.cancel()
                #if DEBUG
                    log.verbose("Timed out after \(timeout) seconds on \(name)")
                #endif
            }
            return result
        } else {
            workItem.wait()
            return .success
        }
    }
}

// MARK: - DispatchSemaphore

class DispatchSemaphore: CustomStringConvertible {
    // MARK: Lifecycle

    init(value: Int, name: String) {
        sem = Foundation.DispatchSemaphore(value: value)
        self.name = name
    }

    // MARK: Internal

    var name = ""
    var sem: Foundation.DispatchSemaphore

    var description: String {
        "<DispatchSemaphore: \(name)>"
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

import SwiftyJSON

func queryJSON(url: URL, timeout: TimeInterval = 0, _ action: @escaping (JSON) -> Void) -> AnyCancellable {
    query(url: url, timeout: timeout)
        .map(\.data)
        .catch { error -> Just<Data> in
            log.error("Error requesting \(url.host ?? ""): \(error)")
            return Just(Data())
        }
        .sink { data in
            guard !data.isEmpty else { return }
            let json = JSON(data)
            guard json != JSON.null else { return }
            action(json)
        }
}

func session(timeout: TimeInterval = 0) -> URLSession {
    if timeout == 0 {
        return URLSession.shared
    }

    let key = "URLSession: timeout=\(timeout)"
    guard let session = Thread.current.threadDictionary[key] as? URLSession else {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        Thread.current.threadDictionary[key] = session
        return session
    }
    return session
}

typealias DataTaskOutput = URLSession.DataTaskPublisher.Output
typealias DataTaskResult = Result<DataTaskOutput, Error>

func query(url: URL, timeout: TimeInterval = 0) -> Publishers.TryMap<URLSession.DataTaskPublisher, DataTaskOutput> {
    let session = session(timeout: timeout)

    return session.dataTaskPublisher(for: url)
        .tryMap { (dataTaskOutput: DataTaskOutput) -> DataTaskOutput in
            guard let response = dataTaskOutput.response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                throw ResponseError(statusCode: (dataTaskOutput.response as? HTTPURLResponse)?.statusCode ?? 400)
            }
            return dataTaskOutput
        }
}

func request(
    from url: URL,
    method: String = "GET",
    body: Data? = nil,
    headers: [String: String]? = nil,
    timeoutPerTry: TimeInterval = 10,
    retries: UInt = 1,
    backoff: Double = 1,
    sleepBetweenTries: TimeInterval = 0,
    maxSleepBetweenTries: TimeInterval = 300,
    _ onResponse: ((String?) -> Void)? = nil
) -> AnyCancellable {
    var sleepBetweenTries = sleepBetweenTries
    let session = session(timeout: timeoutPerTry)

    var urlRequest = URLRequest(url: url, timeoutInterval: timeoutPerTry)
    urlRequest.httpMethod = method
    urlRequest.httpBody = body
    urlRequest.allHTTPHeaderFields = headers

    let request = session.dataTaskPublisher(for: urlRequest)
        .tryMap { (dataTaskOutput: DataTaskOutput) -> DataTaskResult in
            guard let response = dataTaskOutput.response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                throw ResponseError(statusCode: (dataTaskOutput.response as? HTTPURLResponse)?.statusCode ?? 400)
            }
            return .success(dataTaskOutput)
        }
        .catch { (error: Error) -> AnyPublisher<DataTaskResult, Error> in
            defer {
                if sleepBetweenTries > 0 {
                    sleepBetweenTries = min(sleepBetweenTries * backoff, maxSleepBetweenTries)
                }
            }
            return Fail(error: error)
                .delay(for: RunLoop.SchedulerTimeType.Stride(sleepBetweenTries), scheduler: RunLoop.current)
                .eraseToAnyPublisher()
        }
        .retry(retries.i)
        .map { (result: DataTaskResult) -> String? in
            guard let data = (try? result.get())?.data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        .replaceError(with: nil)
        .sink { resp in onResponse?(resp) }

    return request
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
    let semaphore = DispatchSemaphore(value: 0, name: "waitForResponse \(url.absoluteString)")

    let session = session(timeout: timeoutPerTry.timeInterval)
    var responseString: String?
    let lock = NSRecursiveLock()

    let request = session.dataTaskPublisher(for: url)
        .tryMap { (dataTaskOutput: DataTaskOutput) -> DataTaskResult in
            guard let response = dataTaskOutput.response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                throw ResponseError(statusCode: (dataTaskOutput.response as? HTTPURLResponse)?.statusCode ?? 400)
            }
            return .success(dataTaskOutput)
        }
        .catch { (error: Error) -> AnyPublisher<DataTaskResult, Error> in
            defer {
                if sleepBetweenTries > 0 {
                    sleepBetweenTries = min(sleepBetweenTries * backoff, maxSleepBetweenTries)
                }
            }
            return Fail(error: error)
                .delay(for: RunLoop.SchedulerTimeType.Stride(sleepBetweenTries), scheduler: RunLoop.current)
                .eraseToAnyPublisher()
        }
        .retry(retries.i)
        .map { (result: DataTaskResult) -> String? in
            guard let data = (try? result.get())?.data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        .replaceError(with: nil)
        .sink { resp in
            lock.around { responseString = resp }
            semaphore.signal()
        }

    log.verbose("Request: \(request)")
    log.debug("Waiting for request on \(url.absoluteString)")
    semaphore.wait(for: timeoutPerTry.timeInterval * retries.d)
    let result = lock.around { responseString }
    return result
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

var appDelegate: AppDelegate? =
    NSApplication.shared.delegate as? AppDelegate

func refreshScreen(refocus: Bool = true) {
    mainAsync {
        let focusedApp = NSWorkspace.shared.runningApplications.first(where: { app in app.isActive })
        if refocus {
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }

        if let w = appDelegate!.windowController?.window?.contentViewController?.view {
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
    screen: NSScreen? = nil,
    position: NSPoint? = nil
) {
    mainThread {
        guard let mainStoryboard = NSStoryboard.main else { return }

        if identifier == "windowController" {
            appDelegate!.initPopovers()
        }
        if controller == nil {
            controller = mainStoryboard
                .instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(identifier)) as? ModernWindowController
        }

        if show, let wc = controller {
            if let screen = screen, let w = wc.window, w.screen != screen {
                let size = w.frame.size
                w.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
            } else if let position = position, let w = wc.window {
                w.setFrameOrigin(position)
            }

            wc.showWindow(nil)

            if focus {
                if let window = wc.window as? ModernWindow {
                    log.debug("Focusing window '\(window.title)'")
                    window.orderFrontRegardless()
                }

                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            }
        }
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

func generateAPIKey() -> String {
    var r = SystemRandomNumberGenerator()
    let serialNumberData = Data(r.next().toUInt8Array() + r.next().toUInt8Array() + r.next().toUInt8Array() + r.next().toUInt8Array())
    let hash = sha256(data: serialNumberData).prefix(20).str(base64: true, separator: "").map { (c: Character) -> Character in
        switch c {
        case "/": return Character(".")
        case "+": return Character(".")
        default: return c
        }
    }.str()
    log.info("APIKey: \(hash)")
    return hash
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
        log.info("SerialNumberHash: \(hash)")
        return hash
    }
    return nil
}

let SERIAL_NUMBER_HASH = getSerialNumberHash() ?? generateAPIKey()

@discardableResult
@inline(__always) func mainThreadThrows<T>(_ action: () throws -> T) throws -> T {
    guard !Thread.isMainThread else {
        return try action()
    }
    return try DispatchQueue.main.sync { return try action() }
}

@discardableResult
@inline(__always) func mainThread<T>(_ action: () -> T) -> T {
    guard !Thread.isMainThread else {
        return action()
    }
    return DispatchQueue.main.sync { return action() }
}

@inline(__always) func mainAsync(_ action: @escaping () -> Void) {
    guard !Thread.isMainThread else {
        action()
        return
    }
    DispatchQueue.main.async { action() }
}

func stringRepresentation(forAddress address: Data) -> String? {
    address.withUnsafeBytes { pointer in
        var hostStr = [Int8](repeating: 0, count: Int(NI_MAXHOST))

        let result = getnameinfo(
            pointer.baseAddress?.assumingMemoryBound(to: sockaddr.self),
            socklen_t(address.count),
            &hostStr,
            socklen_t(hostStr.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: hostStr)
    }
}

func resolve(hostname: String) -> String? {
    let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
    CFHostStartInfoResolution(host, .addresses, nil)
    var success: DarwinBoolean = false
    guard let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as NSArray?,
          let theAddress = addresses.firstObject as? NSData
    else { return nil }

    return stringRepresentation(forAddress: theAddress as Data)
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
//        let queue = mainThread ? mainQueue : timerQueue
//        taskQueueLock.around { taskQueue[key] = queue }
        task = DispatchWorkItem(name: "Unique Task \(key) asyncAfter(\(ms) ms)") {
            guard !isCancelled(key) else {
                taskManager(key, nil)
                return
            }
            action()
            taskManager(key, nil)
        }

        taskManagerQueue.async {
            (Thread.current.threadDictionary[key] as? DispatchWorkItem)?.cancel()
            Thread.current.threadDictionary["\(key)-cancelled"] = false
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

func taskIsRunning(_ key: String) -> Bool {
    if let timer = taskManager(key) as? DispatchSourceTimer { return !timer.isCancelled }
    if let timer = taskManager(key) as? DispatchWorkItem { return !timer.isCancelled }
    if let timer = taskManager(key) as? Timer { return timer.isValid }
    return false
}

func asyncEvery(
    _ interval: DateComponents,
    leeway: DateComponents = 0.seconds,
    uniqueTaskKey: String? = nil,
    runs: Int? = nil,
    skipIfExists: Bool = false,
    eager: Bool = false,
    queue: DispatchQueue? = nil,
    onSuccess: (() -> Void)? = nil,
    onCancelled: (() -> Void)? = nil,
    _ action: @escaping () -> Void
) {
    let queue = queue ?? concurrentQueue
    taskManagerQueue.async {
        if skipIfExists, let key = uniqueTaskKey, let timer = taskManager(key) as? DispatchSourceTimer, !timer.isCancelled {
            return
        }

        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        timer.schedule(
            deadline: DispatchTime.now() + (eager ? 0 : interval.timeInterval),
            repeating: interval.timeInterval,
            leeway: .milliseconds((leeway.timeInterval * 1000).intround)
        )
        timer.setEventHandler {
            action()
            taskManagerQueue.async {
                guard let key = uniqueTaskKey,
                      let runs = taskManager("\(key)-runs") as? Int,
                      let maxRuns = taskManager("\(key)-maxRuns") as? Int
                else {
                    return
                }

                if runs >= maxRuns || isCancelled(key) {
                    cancelTask(key)
                } else {
                    taskManager("\(key)-runs", runs + 1)
                }
            }
        }
        timer.setCancelHandler {
            taskManagerQueue.async {
                guard let key = uniqueTaskKey,
                      let runs = taskManager("\(key)-runs") as? Int,
                      let maxRuns = taskManager("\(key)-maxRuns") as? Int
                else {
                    return
                }

                if runs >= maxRuns {
                    queue.async { onSuccess?() }
                } else {
                    queue.async { onCancelled?() }
                }
            }
        }

        if let key = uniqueTaskKey {
            taskManagerQueue.async {
                (taskManager(key) as? DispatchSourceTimer)?.cancel()
                taskManager(key, timer)

                if let runs = runs {
                    taskManager("\(key)-maxRuns", runs)
                    taskManager("\(key)-runs", 0)
                }
            }
        }
        timer.activate()
    }
}

func asyncEvery(
    _ interval: DateComponents,
    uniqueTaskKey: String? = nil,
    runs: Int? = nil,
    skipIfExists: Bool = false,
    eager: Bool = false,
    queue: RunloopQueue? = nil,
    onSuccess: (() -> Void)? = nil,
    onCancelled: (() -> Void)? = nil,
    _ action: @escaping (Timer) -> Void
) {
    let queue = queue ?? timerQueue
    queue.async {
        if skipIfExists, let key = uniqueTaskKey, let timer = taskManager(key) as? Timer, timer.isValid {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval.timeInterval, repeats: true) { timer in
            action(timer)
            guard let key = uniqueTaskKey,
                  let runs = taskManager("\(key)-runs") as? Int,
                  let maxRuns = taskManager("\(key)-maxRuns") as? Int
            else {
                return
            }

            if runs >= maxRuns || isCancelled(key) {
                timer.invalidate()
                taskManager(key, nil)
                if runs >= maxRuns { onSuccess?() } else { onCancelled?() }
            } else {
                taskManager("\(key)-runs", runs + 1)
            }
        }

        if eager { action(timer) }

        if let key = uniqueTaskKey {
//            taskQueueLock.around { taskQueue[key] = queue }
            (taskManager(key) as? Timer)?.invalidate()
            taskManager(key, timer)

            if let runs = runs {
                taskManager("\(key)-maxRuns", runs)
                taskManager("\(key)-runs", 0)
            }
        }
    }
}

func cancelScreenWakeAdapterTask() {
    appDelegate!.screenWakeAdapterTask = nil
}

func cancelTask(_ key: String, subscriberKey: String? = nil) {
    guard let task = taskManager(key) else { return }

    taskManager("\(key)-cancelled", true)
    if let task = task as? DispatchWorkItem {
        task.cancel()
    } else if let task = task as? DispatchSourceTimer {
        task.cancel()
    } else if let task = task as? Timer {
        task.invalidate()
    }

    globalObservers.removeValue(forKey: subscriberKey ?? key)
    taskManagerQueue.async {
        Thread.current.threadDictionary.removeObject(forKey: key)
    }
}

@discardableResult func asyncNow(
    timeout: DateComponents? = nil,
    queue: DispatchQueue? = nil,
    runLoopQueue: RunloopQueue? = nil,
    threaded: Bool = false,
    barrier: Bool = false,
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
        if barrier {
            queue.asyncAfter(deadline: DispatchTime.now(), flags: .barrier) { action() }
        } else {
            queue.async { action() }
        }
        return .success
    }

    let task = DispatchWorkItem(name: "async(\(queue.label))") {
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
// var taskQueue: [String: RunloopQueue] = Dictionary(minimumCapacity: 100)
// let taskQueueLock = NSRecursiveLock()

func sync<T>(queue: RunloopQueue, _ action: @escaping () -> T) -> T {
    if let q = DispatchQueue.current, queue == q {
        return action()
    } else {
        return queue.sync { action() }
    }
}

func isCancelled(_ key: String) -> Bool {
    sync(queue: taskManagerQueue) {
        Thread.current.threadDictionary[key] == nil || (Thread.current.threadDictionary["\(key)-cancelled"] as? Bool) ?? false
    }
}

func taskManager(_ key: String, _ value: Any?) {
    taskManagerQueue.async { Thread.current.threadDictionary[key] = value }
}

func taskManager(_ key: String) -> Any? {
    sync(queue: taskManagerQueue) {
        Thread.current.threadDictionary[key]
    }
}

@discardableResult
func asyncAfter(ms: Int, name: String = "asyncAfter", _ action: @escaping () -> Void) -> DispatchWorkItem {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    let workItem = DispatchWorkItem(name: name) {
        action()
    }
    concurrentQueue.asyncAfter(deadline: deadline, execute: workItem.workItem)

    return workItem
}

func asyncAfter(ms: Int, _ action: DispatchWorkItem) {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    concurrentQueue.asyncAfter(deadline: deadline, execute: action.workItem)
}

@discardableResult
func mainAsyncAfter(ms: Int, name: String = "mainAsyncAfter", _ action: @escaping () -> Void) -> DispatchWorkItem {
    let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))

    let workItem = DispatchWorkItem(name: name) {
        action()
    }
    DispatchQueue.main.asyncAfter(deadline: deadline, execute: workItem.workItem)

    return workItem
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

// MARK: - Zip3Sequence

struct Zip3Sequence<E1, E2, E3>: Sequence, IteratorProtocol {
    // MARK: Lifecycle

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

    // MARK: Internal

    mutating func next() -> (E1, E2, E3)? {
        _next()
    }

    // MARK: Private

    private let _next: () -> (E1, E2, E3)?
}

func zip3<S1: Sequence, S2: Sequence, S3: Sequence>(_ s1: S1, _ s2: S2, _ s3: S3) -> Zip3Sequence<S1.Element, S2.Element, S3.Element> {
    Zip3Sequence(s1, s2, s3)
}

// MARK: - Zip4Sequence

struct Zip4Sequence<E1, E2, E3, E4>: Sequence, IteratorProtocol {
    // MARK: Lifecycle

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

    // MARK: Internal

    mutating func next() -> (E1, E2, E3, E4)? {
        _next()
    }

    // MARK: Private

    private let _next: () -> (E1, E2, E3, E4)?
}

func zip4<S1: Sequence, S2: Sequence, S3: Sequence, S4: Sequence>(
    _ s1: S1,
    _ s2: S2,
    _ s3: S3,
    _ s4: S4
) -> Zip4Sequence<S1.Element, S2.Element, S3.Element, S4.Element> {
    Zip4Sequence(s1, s2, s3, s4)
}

func createWindow(
    _ identifier: String,
    controller: inout NSWindowController?,
    screen: NSScreen? = nil,
    show: Bool = true,
    backgroundColor: NSColor? = .clear,
    level: NSWindow.Level = .normal,
    fillScreen: Bool = false,
    stationary: Bool = false
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
                if stationary {
                    window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenDisallowsTiling]
                    window.sharingType = .none
                    window.ignoresMouseEvents = true
                    window.setAccessibilityRole(.popover)
                    window.setAccessibilitySubrole(.unknown)
                }
                if show {
                    log.debug("Showing window '\(window.title)'")
                    wc.showWindow(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }
}

// MARK: Dialogs

var alertsByMessageSemaphore = DispatchSemaphore(value: 1, name: "alertsByMessageSemaphore")
var alertsByMessage = [String: Bool]()
import Regex
let WHITESPACE_REGEX = "\\s+".r!

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
    ultrawide: Bool = false,
    markdown: Bool = false
) -> NSAlert {
    mainThread {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning

        if ultrawide {
            alert.accessoryView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 650, height: 0)))
        } else if wide {
            alert.accessoryView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 500, height: 0)))
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

        if let screen = screen, !screen.isVirtual {
            let w = window ?? alert.window

            let alertSize = w.frame.size
            w.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - alertSize.width / 2, y: screen.visibleFrame.midY - alertSize.height / 2))
            w.makeKeyAndOrderFront(nil)
            if window != nil {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            if w.occlusionState != .visible, let screen = NSScreen.main {
                w
                    .setFrameOrigin(CGPoint(
                        x: screen.visibleFrame.midX - alertSize.width / 2,
                        y: screen.visibleFrame.midY - alertSize.height / 2
                    ))
                w.makeKeyAndOrderFront(nil)
            }
        }

        if markdown, let infoTextField = textField(alert: alert, containing: info) {
            infoTextField.attributedStringValue = MARKDOWN.attributedString(from: info)
        }
        return alert
    }
}

func textField(alert: NSAlert, containing text: String) -> NSTextField? {
    alert.window.contentView?.subviews.first { view in
        guard let s = (view as? NSTextField)?.stringValue else { return false }
        return WHITESPACE_REGEX.replaceAll(in: s, with: "") == WHITESPACE_REGEX.replaceAll(in: text, with: "")
    } as? NSTextField
}

func ask(
    message: String,
    info: String,
    window: NSWindow,
    okButton: String = "OK",
    cancelButton: String = "Cancel",
    timeout: DateComponents = 15.seconds,
    onCompletion: @escaping (Bool) -> Void
) {
    mainAsync {
        let alert = dialog(
            message: message,
            info: info,
            okButton: okButton,
            cancelButton: cancelButton,
            window: window
        )

        let semaphore = DispatchSemaphore(value: 0, name: "Panel alert dismissed")

        if let wc = window.windowController {
            log.debug("Showing window '\(window.title)'")
            wc.showWindow(nil)
            window.orderFrontRegardless()
        }

        alert.beginSheetModal(for: window, completionHandler: { resp in
            onCompletion(resp == .alertFirstButtonReturn)
            semaphore.signal()
        })
        asyncNow {
            if semaphore.wait(for: timeout) == .timedOut {
                mainThread {
                    if alert.window.isVisible {
                        alert.window.close()
                    }
                }
                onCompletion(false)
            }
        }
    }
}

func askAndHandle(
    message: String,
    info: String,
    okButton: String = "OK",
    cancelButton: String = "Cancel",
    thirdButton: String? = nil,
    screen: NSScreen? = nil,
    window: NSWindow? = nil,
    suppressionText: String? = nil,
    onSuppression: ((Bool) -> Void)? = nil,
    unique: Bool = false,
    waitTimeout: DateComponents = 5.seconds,
    wide: Bool = false,
    ultrawide: Bool = false,
    markdown: Bool = false,
    onCompletion: ((Bool) -> Void)? = nil
) {
    let resp = ask(
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
        ultrawide: ultrawide,
        markdown: markdown
    ) == .alertFirstButtonReturn

    if window == nil {
        onCompletion?(resp)
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
    ultrawide: Bool = false,
    markdown: Bool = false
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
        ultrawide: ultrawide,
        markdown: markdown
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
    ultrawide: Bool = false,
    markdown: Bool = false
) -> NSApplication.ModalResponse {
    if unique {
        defer { alertsByMessageSemaphore.signal() }
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
            ultrawide: ultrawide,
            markdown: markdown
        )

        if let window = window {
            if let wc = window.windowController {
                log.debug("Showing window '\(window.title)'")
                wc.showWindow(nil)
                window.orderFrontRegardless()
            }

            alert.beginSheetModal(for: window, completionHandler: { resp in
                onCompletion?(resp)
                onSuppression?((alert.suppressionButton?.state ?? .off) == .on)

                if unique {
                    defer { alertsByMessageSemaphore.signal() }
                    switch alertsByMessageSemaphore.wait(for: 5) {
                    case .success:
                        alertsByMessage.removeValue(forKey: message)
                    case .timedOut:
                        log.warning("Timeout in waiting for alertsForMessage")
                    }
                }
            })
            return .cancel
        }

        let resp = alert.runModal()

        if let onSuppression = onSuppression {
            onSuppression((alert.suppressionButton?.state ?? .off) == .on)
        }

        if unique {
            defer { alertsByMessageSemaphore.signal() }
            switch alertsByMessageSemaphore.wait(for: 5) {
            case .success:
                alertsByMessage.removeValue(forKey: message)
            case .timedOut:
                log.warning("Timeout in waiting for alertsForMessage")
            }
        }
        return resp
    }
    return response
}

// MARK: - UnfairLock

/// An `os_unfair_lock` wrapper.
final class UnfairLock {
    // MARK: Lifecycle

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

    // MARK: Internal

    @Atomic var lockedInThread: Int32 = 0

    func locked() -> Bool { !os_unfair_lock_trylock(unfairLock) }

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

    // MARK: Private

    private let unfairLock: os_unfair_lock_t

    @discardableResult
    private func trylock() -> Bool {
        os_unfair_lock_trylock(unfairLock)
    }

    private func lock() -> Bool {
        var id: Int32?

        if #available(macOS 12, *) {
            let exc = tryBlock {
                id = Thread.current.value(forKeyPath: "seqNum") as? Int32
            }
            if exc != nil {
                tryBlock {
                    id = Thread.current.value(forKeyPath: "private.seqNum") as? Int32
                }
            }
        } else {
            let exc = tryBlock {
                id = Thread.current.value(forKeyPath: "private.seqNum") as? Int32
            }
            if exc != nil {
                tryBlock {
                    id = Thread.current.value(forKeyPath: "seqNum") as? Int32
                }
            }
        }

        guard let threadID = id, lockedInThread != threadID else {
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
        }

        let locked = lock(before: Date().addingTimeInterval(timeout))
        defer { if locked { unlock() } }

        return try closure()
    }

    @inline(__always) func around<T>(timeout: TimeInterval = 10, ignoreMainThread: Bool = false, _ closure: () -> T) -> T {
        if ignoreMainThread, Thread.isMainThread {
            return closure()
        }

        let locked = lock(before: Date().addingTimeInterval(timeout))
        defer { if locked { unlock() } }

        return closure()
    }

    @inline(__always) func around(timeout: TimeInterval = 10, ignoreMainThread: Bool = false, _ closure: () -> Void) {
        if ignoreMainThread, Thread.isMainThread {
            return closure()
        }

        let locked = lock(before: Date().addingTimeInterval(timeout))
        defer { if locked { unlock() } }

        closure()
    }
}

// MARK: - AtomicLock

@propertyWrapper
public struct AtomicLock<Value> {
    // MARK: Lifecycle

    public init(wrappedValue: Value) {
        value = wrappedValue
    }

    // MARK: Public

    public var wrappedValue: Value {
        get {
            lock.around { value }
        }
        set {
            lock.around { value = newValue }
        }
    }

    // MARK: Internal

    var value: Value
    var lock = NSRecursiveLock()
}

// MARK: - Atomic

@propertyWrapper
public struct Atomic<Value: AtomicValue> {
    // MARK: Lifecycle

    public init(wrappedValue: Value) {
        value = ManagedAtomic<Value>(wrappedValue)
    }

    // MARK: Public

    public var wrappedValue: Value {
        get {
            value.load(ordering: .relaxed)
        }
        set {
            value.store(newValue, ordering: .sequentiallyConsistent)
        }
    }

    // MARK: Internal

    var value: ManagedAtomic<Value>
}

// MARK: - AtomicOptional

@propertyWrapper
public struct AtomicOptional<Value: AtomicValue & Equatable> {
    // MARK: Lifecycle

    public init(wrappedValue: Value?, nilValue: Value) {
        self.nilValue = nilValue
        value = ManagedAtomic<Value>(wrappedValue ?? nilValue)
    }

    // MARK: Public

    public var wrappedValue: Value? {
        get {
            let v = value.load(ordering: .relaxed)
            return v == nilValue ? nil : v
        }
        set {
            value.store(newValue ?? nilValue, ordering: .sequentiallyConsistent)
        }
    }

    // MARK: Internal

    var nilValue: Value
    var value: ManagedAtomic<Value>
}

// MARK: - LazyAtomic

@propertyWrapper
public struct LazyAtomic<Value> {
    // MARK: Lifecycle

    public init(wrappedValue constructor: @autoclosure @escaping () -> Value) {
        self.constructor = constructor
    }

    // MARK: Public

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

    // MARK: Internal

    var storage: Value?
    let constructor: () -> Value
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

// MARK: - PlainTextPasteView

class PlainTextPasteView: NSTextView, NSTextViewDelegate {
    override func paste(_ sender: Any?) {
        super.pasteAsPlainText(sender)
    }
}

// MARK: - PlainTextFieldCell

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

import Defaults

func notify(identifier: String, title: String, body: String) {
    let sendNotification = { (nc: UNUserNotificationCenter) in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        nc.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }

    let nc = UNUserNotificationCenter.current()
    nc.getNotificationSettings { settings in
        mainAsync {
            let enabled = settings.alertSetting == .enabled
            Defaults[.notificationsPermissionsGranted] = enabled
            guard enabled else {
                nc.requestAuthorization(options: [], completionHandler: { granted, _ in
                    guard granted else { return }
                    sendNotification(nc)
                })
                return
            }
            sendNotification(nc)
        }
    }
}

func removeNotifications(withIdentifiers ids: [String]) {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
}

// MARK: - Window

struct Window {
    // MARK: Lifecycle

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

    // MARK: Internal

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
}

extension NSRect {
    func intersectedArea(_ other: NSRect) -> CGFloat {
        let i = intersection(other)
        return i.height * i.width
    }
}

// MARK: - AXWindow

struct AXWindow {
    // MARK: Lifecycle

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
        #if DEBUG
            log.debug("\(appException?.description ?? "") \(title) frame: \(frame)")
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                log.debug("Screen \(id) frame: \(screen.frame)")
                log.debug("Screen \(id) bounds: \(CGDisplayBounds(id))")
            }
        #endif
        screen = NSScreen.screens.filter {
            guard let bounds = $0.bounds else { return false }
            return bounds.intersects(frame)
        }.max(by: { s1, s2 in
            guard let bounds1 = s1.bounds, let bounds2 = s2.bounds else { return false }
            return bounds1.intersectedArea(frame) < bounds2.intersectedArea(frame)
        })
    }

    // MARK: Internal

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
}

extension NSRunningApplication {
    func windows(appException: AppException? = nil) -> [AXWindow]? {
        guard let app = Application(self) else { return nil }
        do {
            let wins = try app.windows()
            return wins?.compactMap { AXWindow(from: $0, runningApp: self, appException: appException) }
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

// MARK: - LineReader

class LineReader {
    // MARK: Lifecycle

    init?(path: String) {
        self.path = path
        guard let file = fopen(path, "r") else {
            return nil
        }
        self.file = file
    }

    deinit {
        fclose(file)
    }

    // MARK: Internal

    let path: String

    var nextLine: String? {
        var line: UnsafeMutablePointer<CChar>?
        var linecap = 0
        defer {
            if let line = line {
                free(line)
            }
        }
        let status = getline(&line, &linecap, file)
        guard status > 0, let unwrappedLine = line else {
            return nil
        }
        return String(cString: unwrappedLine)
    }

    // MARK: Private

    private let file: UnsafeMutablePointer<FILE>
}

// MARK: Sequence

extension LineReader: Sequence {
    func makeIterator() -> AnyIterator<String> {
        AnyIterator<String> {
            self.nextLine
        }
    }
}

func getModeDetails(_ mode: MPDisplayMode?, prefix: String = "\t") -> String {
    guard let mode = mode else { return "nil" }
    return """
        \(prefix)refreshString: \(mode.refreshStringSafe ?? "Unknown")
        \(prefix)resolutionString: \(mode.resolutionStringSafe ?? "Unknown")
        \(prefix)isSafeMode: \(mode.isSafeMode)
        \(prefix)tvModeEquiv: \(mode.tvModeEquiv)
        \(prefix)tvMode: \(mode.tvMode)
        \(prefix)isTVMode: \(mode.isTVMode)
        \(prefix)isSimulscan: \(mode.isSimulscan)
        \(prefix)isInterlaced: \(mode.isInterlaced)
        \(prefix)isNativeMode: \(mode.isNativeMode)
        \(prefix)isDefaultMode: \(mode.isDefaultMode)
        \(prefix)isStretched: \(mode.isStretched)
        \(prefix)isUserVisible: \(mode.isUserVisible)
        \(prefix)isHiDPI: \(mode.isHiDPI)
        \(prefix)isRetina: \(mode.isRetina)
        \(prefix)scanRate: \(mode.scanRate ?? 0)
        \(prefix)roundedScanRate: \(mode.roundedScanRate)
        \(prefix)scale: \(mode.scale)
        \(prefix)aspectRatio: \(mode.aspectRatio)
        \(prefix)fixPtRefreshRate: \(mode.fixPtRefreshRate)
        \(prefix)refreshRate: \(mode.refreshRate)
        \(prefix)dotsPerInch: \(mode.dotsPerInch)
        \(prefix)vertDPI: \(mode.vertDPI)
        \(prefix)horizDPI: \(mode.horizDPI)
        \(prefix)pixelsHigh: \(mode.pixelsHigh)
        \(prefix)pixelsWide: \(mode.pixelsWide)
        \(prefix)height: \(mode.height)
        \(prefix)width: \(mode.width)
        \(prefix)modeNumber: \(mode.modeNumber)
    """
}

import AnyCodable

func getModeDetailsJSON(_ mode: MPDisplayMode?) -> [String: Any]? {
    guard let mode = mode else { return nil }
    return [
        "refreshString": mode.refreshStringSafe ?? "Unknown",
        "resolutionString": mode.resolutionStringSafe ?? "Unknown",
        "isSafeMode": mode.isSafeMode,
        "tvModeEquiv": mode.tvModeEquiv,
        "tvMode": mode.tvMode,
        "isTVMode": mode.isTVMode,
        "isSimulscan": mode.isSimulscan,
        "isInterlaced": mode.isInterlaced,
        "isNativeMode": mode.isNativeMode,
        "isDefaultMode": mode.isDefaultMode,
        "isStretched": mode.isStretched,
        "isUserVisible": mode.isUserVisible,
        "isHiDPI": mode.isHiDPI,
        "isRetina": mode.isRetina,
        "scanRate": mode.scanRate ?? 0,
        "roundedScanRate": mode.roundedScanRate,
        "scale": mode.scale,
        "aspectRatio": mode.aspectRatio,
        "fixPtRefreshRate": mode.fixPtRefreshRate,
        "refreshRate": mode.refreshRate,
        "dotsPerInch": mode.dotsPerInch,
        "vertDPI": mode.vertDPI,
        "horizDPI": mode.horizDPI,
        "pixelsHigh": mode.pixelsHigh,
        "pixelsWide": mode.pixelsWide,
        "height": mode.height,
        "width": mode.width,
        "modeNumber": mode.modeNumber,
    ]
}

func getMonitorPanelDataJSON(
    _ display: MPDisplay,
    includeModes: Bool = false,
    modeFilter: ((MPDisplayMode) -> Bool)? = nil
) -> [String: Any] {
    [
        "id": display.displayID,
        "aliasID": display.aliasID,
        "canChangeOrientation": display.canChangeOrientation(),
        "hasRotationSensor": display.hasRotationSensor,
        "hasZeroRate": display.hasZeroRate,
        "hasMultipleRates": display.hasMultipleRates,
        "isSidecarDisplay": display.isSidecarDisplay,
        "isAirPlayDisplay": display.isAirPlayDisplay,
        "isProjector": display.isProjector,
        "is4K": display.is4K,
        "isTV": display.isTV,
        "isMirrorMaster": display.isMirrorMaster,
        "isMirrored": display.isMirrored,
        "isBuiltIn": display.isBuiltIn,
        "isHiDPI": display.isHiDPI,
        "hasTVModes": display.hasTVModes,
        "hasSimulscan": display.hasSimulscan,
        "hasSafeMode": display.hasSafeMode,
        "isSmartDisplay": display.isSmartDisplay,
        "isAppleProDisplay": display.isAppleProDisplay,
        "uuid": (display.uuid?.uuidString ?? "") as Any,
        "isForcedToMirror": display.isForcedToMirror,
        "hasMenuBar": display.hasMenuBar,
        "isBuiltInRetina": display.isBuiltInRetina,
        "titleName": (display.titleName ?? "") as Any,
        "name": (display.displayName ?? "") as Any,
        "orientation": display.orientation,
        "modes": [String: Any](
            (includeModes ? ((display.allModes() as? [MPDisplayMode]) ?? []) : [])
                .filter(modeFilter ?? { _ in true })
                .compactMap { mode in
                    guard let modeJSON = getModeDetailsJSON(mode) else { return nil }
                    return (mode.description.replacingOccurrences(of: "\n", with: ", "), modeJSON)
                } + [
                    ("default", getModeDetailsJSON(display.defaultMode) as Any),
                    ("native", getModeDetailsJSON(display.nativeMode) as Any),
                    ("current", getModeDetailsJSON(display.currentMode) as Any),
                ],
            uniquingKeysWith: first(this:other:)
        ),
    ]
}

func getMonitorPanelData(_ display: MPDisplay) -> String {
    """
        ID: \(display.displayID)
        Alias ID: \(display.aliasID)
        canChangeOrientation: \(display.canChangeOrientation())
        hasRotationSensor: \(display.hasRotationSensor)
        hasZeroRate: \(display.hasZeroRate)
        hasMultipleRates: \(display.hasMultipleRates)
        isSidecarDisplay: \(display.isSidecarDisplay)
        isAirPlayDisplay: \(display.isAirPlayDisplay)
        isProjector: \(display.isProjector)
        is4K: \(display.is4K)
        isTV: \(display.isTV)
        isMirrorMaster: \(display.isMirrorMaster)
        isMirrored: \(display.isMirrored)
        isBuiltIn: \(display.isBuiltIn)
        isHiDPI: \(display.isHiDPI)
        hasTVModes: \(display.hasTVModes)
        hasSimulscan: \(display.hasSimulscan)
        hasSafeMode: \(display.hasSafeMode)
        isSmartDisplay: \(display.isSmartDisplay)
        orientation: \(display.orientation)

        Default mode:
        \(getModeDetails(display.defaultMode, prefix: "\t"))

        Native mode:
        \(getModeDetails(display.nativeMode, prefix: "\t"))

        Current mode:
        \(getModeDetails(display.currentMode, prefix: "\t"))

        All modes:
        \((display.allModes() as? [MPDisplayMode])?
        .map { "\t\($0.description.replacingOccurrences(of: "\n", with: ", ")):\n\(getModeDetails($0, prefix: "\t\t"))" }
        .joined(separator: "\n\n") ?? "nil")
    """
}

func contactURL() -> URL {
    guard var urlBuilder = URLComponents(url: CONTACT_URL, resolvingAgainstBaseURL: false) else {
        return CONTACT_URL
    }
    urlBuilder.queryItems = [URLQueryItem(name: "userid", value: SERIAL_NUMBER_HASH)]

    if let licenseCode = lunarProProduct?.licenseCode {
        urlBuilder.queryItems?.append(URLQueryItem(name: "code", value: licenseCode))
    }

    if let email = lunarProProduct?.activationEmail {
        urlBuilder.queryItems?.append(URLQueryItem(name: "email", value: email))
    }

    return urlBuilder.url ?? CONTACT_URL
}

extension NSView {
    class func loadFromNib<T>(withName nibName: String, for owner: Any) -> T? {
        var nibObjects: NSArray?
        let bundle = Bundle(identifier: "fyi.lunar.Lunar")
        guard let nib = NSNib(nibNamed: nibName, bundle: bundle),
              nib.instantiate(withOwner: owner, topLevelObjects: &nibObjects),
              let view = nibObjects?.compactMap({ $0 as? T }).first
        else { return nil }

        return view
    }
}

func memoryFootprint() -> Double? {
    // The `TASK_VM_INFO_COUNT` and `TASK_VM_INFO_REV1_COUNT` macros are too
    // complex for the Swift C importer, so we have to define them ourselves.
    let TASK_VM_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let TASK_VM_INFO_REV1_COUNT = mach_msg_type_number_t(
        MemoryLayout
            .offset(of: \task_vm_info_data_t.min_address)! / MemoryLayout<integer_t>.size
    )
    var info = task_vm_info_data_t()
    var count = TASK_VM_INFO_COUNT
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS,
          count >= TASK_VM_INFO_REV1_COUNT
    else { return nil }

    let usedBytes = Double(info.phys_footprint)
    return usedBytes
}

func memoryFootprintMB() -> Double? {
    guard let usedBytes = memoryFootprint() else { return nil }
    let usedMB = usedBytes / 1024 / 1024
    return usedMB
}

func formattedMemoryFootprint() -> String {
    let usedMBAsString = "Memory Used by App: \((memoryFootprintMB() ?? 0).str(decimals: 2)) MB"
    return usedMBAsString
}
