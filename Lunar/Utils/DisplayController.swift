//
//  DisplayController.swift
//  Lunar
//
//  Created by Alin on 02/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import Alamofire
import AXSwift
import Cocoa
import Combine
import CoreLocation
import Defaults
import Foundation
import Sentry
import Solar
import Surge
import SwiftDate
import SwiftyJSON

class DisplayController {
    let getDisplaysLock = NSRecursiveLock()
    @Atomic var lidClosed: Bool = IsLidClosed()
    var clamshellMode: Bool = false

    var appObserver: NSKeyValueObservation?
    @AtomicLock var runningAppExceptions: [AppException]!

    @AtomicLock var displays: [CGDirectDisplayID: Display] = [:] {
        didSet {
            activeDisplays = displays.filter { $1.active }
            activeDisplaysByReadableID = [String: Display](
                uniqueKeysWithValues: activeDisplays.map { _, display in
                    (display.readableID, display)
                }
            )
        }
    }

    var onActiveDisplaysChange: (() -> Void)?
    var _activeDisplaysLock = NSRecursiveLock()
    var _activeDisplays: [CGDirectDisplayID: Display] = [:]
    var activeDisplays: [CGDirectDisplayID: Display] {
        get { _activeDisplaysLock.around { _activeDisplays } }
        set {
            _activeDisplaysLock.around {
                _activeDisplays = newValue
                CachedDefaults[.hasActiveDisplays] = !_activeDisplays.isEmpty
                onActiveDisplaysChange?()
            }
        }
    }

    var activeDisplaysByReadableID: [String: Display] = [:]

    @AtomicLock var adaptiveMode: AdaptiveMode = DisplayController.getAdaptiveMode() {
        didSet {
            if adaptiveMode.key != .manual {
                lastNonManualAdaptiveMode = adaptiveMode
            }
            oldValue.stopWatching()
            _ = adaptiveMode.watch()
        }
    }

    var adaptiveModeKey: AdaptiveModeKey {
        adaptiveMode.key
    }

    var lastNonManualAdaptiveMode: AdaptiveMode = DisplayController.getAdaptiveMode()
    var lastModeWasAuto: Bool = !CachedDefaults[.overrideAdaptiveMode]

    func appBrightnessContrastOffset(for display: Display) -> (Int, Int) {
        guard let exceptions = runningAppExceptions, !exceptions.isEmpty, let screen = display.screen else { return (0, 0) }

        if let app = activeWindow(on: screen)?.appException {
            #if DEBUG
                log.debug("App offset: \(app.identifier) \(app.name) \(app.brightness) \(app.contrast)")
            #endif
            return (app.brightness.i, app.contrast.i)
        }

        let windows = exceptions.compactMap { (app: AppException) -> FlattenSequence<[[AXWindow]]>? in
            guard let runningApps = app.runningApps, !runningApps.isEmpty else { return nil }
            return runningApps.compactMap { (a: NSRunningApplication) -> [AXWindow]? in
                a.windows(appException: app)?.filter { window in
                    !window.minimized && window.size != .zero && window.screen != nil
                }
            }.joined()
        }.joined()

//        let windows = exceptions.compactMap { (app: AppException) -> FlattenSequence<[[Window]]>? in
//            guard let runningApps = app.runningApps, !runningApps.isEmpty else { return nil }
//            return runningApps.compactMap { (a: NSRunningApplication) -> [Window]? in
//                windowList(for: a, opaque: true, levels: [.normal], appException: app)
//            }.joined()
//        }.joined()

        let windowsOnScreen = windows.filter { w in w.screen?.displayID == screen.displayID }
        guard let focusedWindow = windowsOnScreen.first(where: { $0.focused }) ?? windowsOnScreen.first,
              let app = focusedWindow.appException
        else { return (0, 0) }

        #if DEBUG
            log.debug("App offset: \(app.identifier) \(app.name) \(app.brightness) \(app.contrast)")
        #endif

        return (app.brightness.i, app.contrast.i)
    }

    var firstDisplay: Display {
        if !displays.isEmpty {
            return displays.values.first(where: { d in d.active }) ?? displays.values.first!
        } else {
            #if DEBUG
                if TEST_MODE {
                    return TEST_DISPLAY
                }
            #endif
            return GENERIC_DISPLAY
        }
    }

    var mainDisplay: Display? {
        guard let screen = NSScreen.withMouse,
              let id = screen.displayID
        else { return nil }

        return activeDisplays[id]
    }

    var currentAudioDisplay: Display? {
        guard let audioDevice = simplyCA.defaultOutputDevice, !audioDevice.canSetVirtualMasterVolume(scope: .output) else {
            return nil
        }
        return activeDisplays.values.map { $0 }.sorted(by: { d1, d2 in
            d1.name.levenshtein(audioDevice.name) < d2.name.levenshtein(audioDevice.name)
        }).first ?? currentDisplay
    }

    var currentDisplay: Display? {
        if let display = mainDisplay {
            return display
        }

        let displays = activeDisplays.values.map { $0 }
        if displays.count == 1 {
            return displays[0]
        } else {
            for display in displays {
                if CGDisplayIsMain(display.id) == 1 {
                    return display
                }
            }
        }
        return nil
    }

    var onAdapt: ((Any) -> Void)?

    var controlWatcherTask: CFRunLoopTimer?
    var modeWatcherTask: CFRunLoopTimer?

    func removeDisplay(id _: CGDirectDisplayID) {
        let nsDisplays = displays.values.map { $0 }
        CachedDefaults[.displays] = nsDisplays
    }

    static func getAdaptiveMode() -> AdaptiveMode {
        if CachedDefaults[.overrideAdaptiveMode] {
            return CachedDefaults[.adaptiveBrightnessMode].mode
        } else {
            let mode = autoMode()
            if mode.key != CachedDefaults[.adaptiveBrightnessMode] {
                CachedDefaults[.adaptiveBrightnessMode] = mode.key
            }
            return mode
        }
    }

    var pausedAdaptiveModeObserver: Bool = false
    var adaptiveModeObserver: Cancellable?

    func listenForAdaptiveModeChange() {
        adaptiveModeObserver = adaptiveBrightnessModePublisher.sink { [weak self] change in
            guard let self = self, !self.pausedAdaptiveModeObserver else {
                return
            }
            Defaults.withoutPropagation {
                mainThread {
                    self.pausedAdaptiveModeObserver = true
                    self.adaptiveMode = change.newValue.mode
                    self.pausedAdaptiveModeObserver = false
                }
            }
        }
    }

    static func autoMode() -> AdaptiveMode {
        if let mode = SensorMode.shared.ifAvailable() {
            return mode
        } else if let mode = SyncMode.shared.ifAvailable() {
            return mode
        } else if let mode = LocationMode.shared.ifAvailable() {
            return mode
        } else {
            return ManualMode.shared
        }
    }

    func toggle() {
        if adaptiveModeKey == .manual {
            enable()
        } else {
            disable()
        }
    }

    func disable() {
        if adaptiveModeKey != .manual {
            adaptiveMode = ManualMode.shared
        }
        if !CachedDefaults[.overrideAdaptiveMode] {
            lastModeWasAuto = true
            CachedDefaults[.overrideAdaptiveMode] = true
        }
        CachedDefaults[.adaptiveBrightnessMode] = AdaptiveModeKey.manual
    }

    func enable(mode: AdaptiveModeKey? = nil) {
        if let newMode = mode {
            adaptiveMode = newMode.mode
        } else if lastModeWasAuto {
            CachedDefaults[.overrideAdaptiveMode] = false
            adaptiveMode = DisplayController.getAdaptiveMode()
        } else if lastNonManualAdaptiveMode.available {
            adaptiveMode = lastNonManualAdaptiveMode
        } else {
            adaptiveMode = DisplayController.getAdaptiveMode()
        }
        CachedDefaults[.adaptiveBrightnessMode] = adaptiveMode.key
        adaptBrightness(force: true)
    }

    func resetDisplayList() {
        asyncNow {
            self.getDisplaysLock.around {
                DDC.reset()
                self.displays = DisplayController.getDisplays()
                SyncMode.builtinDisplay = SyncMode.getBuiltinDisplay()
                SyncMode.sourceDisplayID = SyncMode.getSourceDisplay()
                self.addSentryData()
            }

            mainThread {
                let appd = appDelegate()
                if appd.windowController?.window != nil {
                    appd.windowController?.close()
                    appd.windowController?.window = nil
                    appd.windowController = nil
                    appd.showWindow()
                }
            }
        }
    }

    var fallbackPromptTime = [CGDirectDisplayID: Date]()

    func shouldPromptAboutFallback(_ display: Display) -> Bool {
        guard !display.neverFallbackControl else { return false }

        if !screensSleeping.load(ordering: .relaxed), let screen = display.screen, !screen.visibleFrame.isEmpty,
           !display.control.isResponsive()
        {
            if let promptTime = fallbackPromptTime[display.id] {
                return promptTime + 20.minutes < Date()
            }
            return true
        }

        return false
    }

    func watchControlAvailability() {
        guard controlWatcherTask == nil || !lowprioQueue.isValid(timer: controlWatcherTask!) else {
            return
        }

        controlWatcherTask = asyncEvery(15.seconds, queue: lowprioQueue) { [weak self] _ in
            guard !screensSleeping.load(ordering: .relaxed), let self = self else { return }
            for display in self.activeDisplays.values {
                display.control = display.getBestControl()
                if self.shouldPromptAboutFallback(display) {
                    log.warning("Non-responsive display", context: display.context)
                    self.fallbackPromptTime[display.id] = Date()
                    let semaphore = DispatchSemaphore(value: 0, name: "Non-responsive Control Watcher Prompt")
                    let completionHandler = { (fallbackToGamma: NSApplication.ModalResponse) in
                        if fallbackToGamma == .alertFirstButtonReturn {
                            display.control = GammaControl(display: display)
                            display.setGamma()
                        }
                        if fallbackToGamma == .alertThirdButtonReturn {
                            display.neverFallbackControl = true
                        }
                        semaphore.signal()
                    }

                    if display.alwaysFallbackControl {
                        completionHandler(.alertFirstButtonReturn)
                        return
                    }

                    let window = mainThread { appDelegate().windowController?.window }

                    let resp = ask(
                        message: "Non-responsive display \"\(display.name)\"",
                        info: """
                            This display is not responding to commands in
                            \(display.control!.str) mode.

                            Do you want to fallback to adjusting brightness in software?

                            Note: adjust the monitor to [BRIGHTNESS: 100%, CONTRAST: 70%] manually
                            using its physical buttons to allow for a full range in software.
                        """,
                        okButton: "Yes",
                        cancelButton: "Not now",
                        thirdButton: "No, never ask again",
                        screen: display.screen,
                        window: window,
                        suppressionText: "Always fallback to software controls for this display when needed",
                        onSuppression: { fallback in
                            display.alwaysFallbackControl = fallback
                            display.save()
                        },
                        onCompletion: completionHandler,
                        unique: true,
                        waitTimeout: 60.seconds,
                        wide: true
                    )
                    if window == nil {
                        completionHandler(resp)
                    } else {
                        semaphore.wait(for: nil)
                    }
                }
            }
        }
    }

    func autoAdaptMode() {
        guard !CachedDefaults[.overrideAdaptiveMode] else { return }

        let mode = DisplayController.autoMode()
        if mode.key != adaptiveMode.key {
            adaptiveMode = mode
            CachedDefaults[.adaptiveBrightnessMode] = mode.key
        }
    }

    var overrideAdaptiveModeObserver: Cancellable?
    var pausedOverrideAdaptiveModeObserver: Bool = false

    func watchModeAvailability() {
        guard modeWatcherTask == nil || !lowprioQueue.isValid(timer: modeWatcherTask!) else {
            return
        }

        let startOrStopWatcher = { (shouldStop: Bool) in
            guard !self.pausedOverrideAdaptiveModeObserver else { return }

            self.pausedOverrideAdaptiveModeObserver = true
            Defaults.withoutPropagation {
                if shouldStop {
                    if let task = self.modeWatcherTask {
                        lowprioQueue.cancel(timer: task)
                    }
                } else {
                    self.modeWatcherTask = asyncEvery(5.seconds, queue: lowprioQueue) { [weak self] _ in
                        guard !screensSleeping.load(ordering: .relaxed), let self = self,
                              !CachedDefaults[.overrideAdaptiveMode] else { return }
                        self.autoAdaptMode()
                    }
                }
            }
            self.pausedOverrideAdaptiveModeObserver = false
        }
        startOrStopWatcher(CachedDefaults[.overrideAdaptiveMode])
        overrideAdaptiveModeObserver = overrideAdaptiveModeObserver ?? overrideAdaptiveModePublisher
            .sink { startOrStopWatcher($0.newValue) }
    }

    var observers: Set<AnyCancellable> = []

    func initObservers() {
        NotificationCenter.default.publisher(for: lunarProStateChanged, object: nil).sink { _ in
            self.autoAdaptMode()
        }.store(in: &observers)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.screensDidWakeNotification, object: nil
        ).sink { _ in
            self.watchControlAvailability()
            self.watchModeAvailability()
        }.store(in: &observers)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.screensDidSleepNotification, object: nil
        ).sink { _ in
            if let task = self.controlWatcherTask {
                lowprioQueue.cancel(timer: task)
            }
            if let task = self.modeWatcherTask {
                lowprioQueue.cancel(timer: task)
            }
        }.store(in: &observers)
    }

    init() {
        watchControlAvailability()
        watchModeAvailability()
        concurrentQueue.async {
            log.info("Sensor initial serial port: \(SensorMode.validSensorSerialPort?.path ?? "none")")
        }
        initObservers()
    }

    deinit {
        #if DEBUG
            log.verbose("START DEINIT")
            defer { log.verbose("END DEINIT") }
        #endif
        if let task = controlWatcherTask {
            lowprioQueue.cancel(timer: task)
        }

        if let task = modeWatcherTask {
            lowprioQueue.cancel(timer: task)
        }
    }

    func getMatchingDisplay(
        name: String,
        serial: Int,
        productID: Int,
        manufactureYear: Int,
        manufacturer: String? = nil,
        vendorID: Int? = nil
    ) -> Display? {
        let d = displays.values.first(where: { display in
            DisplayController.displayInfoDictFullMatch(
                display: display,
                name: name,
                serial: serial,
                productID: productID,
                manufactureYear: manufactureYear,
                manufacturer: manufacturer,
                vendorID: vendorID
            )
        })

        if let fullyMatchedDisplay = d {
            return fullyMatchedDisplay
        }

        let displayScores = displays.values.map { display -> (Display, Int) in
            let score = DisplayController.displayInfoDictPartialMatchScore(
                display: display,
                name: name,
                serial: serial,
                productID: productID,
                manufactureYear: manufactureYear,
                manufacturer: manufacturer,
                vendorID: vendorID
            )

            return (display, score)
        }

        return displayScores.max(count: 1, sortedBy: { first, second in first.1 <= second.1 }).first?.0
    }

    static func displayInfoDictPartialMatchScore(
        display: Display,
        name: String,
        serial: Int,
        productID: Int,
        manufactureYear: Int,
        manufacturer _: String? = nil,
        vendorID: Int? = nil
    ) -> Int {
        var score = (display.edidName == name).i

        let infoDict = display.infoDictionary

        if let displayYearManufacture = infoDict[kDisplayYearOfManufacture] as? Int64 {
            score += (displayYearManufacture == manufactureYear).i
        }
        if let displaySerialNumber = infoDict[kDisplaySerialNumber] as? Int64, abs(displaySerialNumber.i - serial) < 3 {
            score += 3 - abs(displaySerialNumber.i - serial)
        }
        if let displayProductID = infoDict[kDisplayProductID] as? Int64, abs(displayProductID.i - productID) < 3 {
            score += 3 - abs(displayProductID.i - serial)
        }
        if let vendorID = vendorID, let displayVendorID = infoDict[kDisplayVendorID] as? Int64,
           abs(displayVendorID.i - vendorID) < 3
        {
            score += 3 - abs(displayVendorID.i - vendorID)
        }

        return score
    }

    static func displayInfoDictFullMatch(
        display: Display,
        name: String,
        serial: Int,
        productID: Int,
        manufactureYear: Int,
        manufacturer _: String? = nil,
        vendorID: Int? = nil
    ) -> Bool {
        let infoDict = display.infoDictionary
        guard let displayYearManufacture = infoDict[kDisplayYearOfManufacture] as? Int64,
              let displaySerialNumber = infoDict[kDisplaySerialNumber] as? Int64,
              let displayProductID = infoDict[kDisplayProductID] as? Int64,
              let displayVendorID = infoDict[kDisplayVendorID] as? Int64
        else { return false }

        var matches = (
            display.edidName == name &&
                displayYearManufacture == manufactureYear &&
                displaySerialNumber == serial &&
                displayProductID == productID
        )

        if let vendorID = vendorID {
            matches = matches || displayVendorID == vendorID
        }

        return matches
    }

    static func allDisplayProperties() -> [[String: Any]] {
        var propList: [[String: Any]] = []
        var ioIterator = io_iterator_t()

        guard IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceNameMatching("AppleCLCD2"), &ioIterator) == KERN_SUCCESS
        else {
            return propList
        }

        defer {
            assert(IOObjectRelease(ioIterator) == KERN_SUCCESS)
        }
        while case let ioService = IOIteratorNext(ioIterator), ioService != 0 {
            var serviceProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(ioService, &serviceProperties, kCFAllocatorDefault, IOOptionBits()) == KERN_SUCCESS,
                  let cfProps = serviceProperties,
                  let props = cfProps.takeRetainedValue() as? [String: Any]
            else {
                continue
            }
            propList.append(props)
        }
        return propList
    }

    static func armDisplayProperties(display: Display) -> [String: Any]? {
        // "DisplayAttributes" = {"ProductAttributes"={"ManufacturerID"="GSM","YearOfManufacture"=2017,"SerialNumber"=314041,"ProductName"="LG Ultra HD","LegacyManufacturerID"=7789,"ProductID"=23305,"WeekOfManufacture"=8}

        let allProps = allDisplayProperties()
        let fullyMatchedProps = allProps.first(where: { props in
            guard let attrs = props["DisplayAttributes"] as? [String: Any],
                  let productAttrs = attrs["ProductAttributes"] as? [String: Any],
                  let manufactureYear = productAttrs["YearOfManufacture"] as? Int64,
                  let serial = productAttrs["SerialNumber"] as? Int64,
                  let name = productAttrs["ProductName"] as? String,
                  let vendorID = productAttrs["LegacyManufacturerID"] as? Int64,
                  let productID = productAttrs["ProductID"] as? Int64
            else { return false }
            return DisplayController.displayInfoDictFullMatch(
                display: display,
                name: name,
                serial: serial.i,
                productID: productID.i,
                manufactureYear: manufactureYear.i,
                vendorID: vendorID.i
            )
        })

        if let fullyMatchedProps = fullyMatchedProps {
            return fullyMatchedProps
        }

        let propScores = allProps.map { props -> ([String: Any], Int) in
            guard let attrs = props["DisplayAttributes"] as? [String: Any],
                  let productAttrs = attrs["ProductAttributes"] as? [String: Any],
                  let manufactureYear = productAttrs["YearOfManufacture"] as? Int64,
                  let serial = productAttrs["SerialNumber"] as? Int64,
                  let name = productAttrs["ProductName"] as? String,
                  let vendorID = productAttrs["LegacyManufacturerID"] as? Int64,
                  let productID = productAttrs["ProductID"] as? Int64
            else { return (props, 0) }

            let score = DisplayController.displayInfoDictPartialMatchScore(
                display: display,
                name: name,
                serial: serial.i,
                productID: productID.i,
                manufactureYear: manufactureYear.i,
                vendorID: vendorID.i
            )

            return (props, score)
        }

        return propScores.max(count: 1, sortedBy: { first, second in first.1 <= second.1 }).first?.0
    }

    static func getDisplays(includeVirtual: Bool = false) -> [CGDirectDisplayID: Display] {
        let ids = DDC.findExternalDisplays(includeVirtual: includeVirtual || TEST_MODE)
        var serials = ids.map { Display.uuid(id: $0) }

        // Make sure serials are unique
        if serials.count != Set(serials).count {
            serials = zip(serials, ids).map { serial, id in "\(serial)-\(id)" }
        }

        let idForSerial = Dictionary(zip(serials, ids), uniquingKeysWith: first(this:other:))
        let serialForID = Dictionary(zip(ids, serials), uniquingKeysWith: first(this:other:))

        guard let displayList = datastore.displays(serials: serials), !displayList.isEmpty else {
            let displays = ids.map { Display(id: $0, active: true) }

            #if DEBUG
                log.debug("STORING NEW DISPLAYS \(displays.map(\.serial))")
            #endif
            let storedDisplays = datastore.storeDisplays(displays)
            #if DEBUG
                log.debug("STORED NEW DISPLAYS \(storedDisplays.map(\.serial))")
            #endif

            return Dictionary(
                storedDisplays.map { d in (d.id, d) },
                uniquingKeysWith: first(this:other:)
            )
        }

        // Update IDs after reconnection
        for display in displayList {
            defer { display.active = true }
            guard let newID = idForSerial[display.serial] else {
                continue
            }

            display.id = newID
            display.edidName = Display.printableName(id: newID)
            if display.name.isEmpty {
                display.name = display.edidName
            }
        }

        var displays = Dictionary(
            displayList.map { ($0.id, $0) },
            uniquingKeysWith: first(this:other:)
        )

        // Initialize displays that were never seen before
        let newDisplayIDs = Set(ids).subtracting(Set(displays.keys))
        for id in newDisplayIDs {
            displays[id] = Display(id: id, serial: serialForID[id], active: true)
        }

        #if DEBUG
            log.debug("STORING UPDATED DISPLAYS \(displays.values.map(\.serial))")
        #endif
        let storedDisplays = datastore.storeDisplays(displays.values.map { $0 })
        #if DEBUG
            log.debug("STORED UPDATED DISPLAYS \(storedDisplays.map(\.serial))")
        #endif

        return Dictionary(storedDisplays.map { d in (d.id, d) }, uniquingKeysWith: first(this:other:))
    }

    func addSentryData() {
        SentrySDK.configureScope { [weak self] scope in
            log.info("Creating Sentry extra context")
            scope.setExtra(value: datastore.settingsDictionary(), key: "settings")
            if var armProps = SyncMode.getArmBuiltinDisplayProperties() {
                armProps.removeValue(forKey: "TimingElements")
                armProps.removeValue(forKey: "ColorElements")

                var computedProps = [String: String]()
                if let (b, c) = SyncMode.readBuiltinDisplayBrightnessContrast() {
                    computedProps["Brightness"] = b.str(decimals: 4)
                    computedProps["Contrast"] = c.str(decimals: 4)
                }

                var br: Float = cap(Float(armProps["IOMFBBrightnessLevel"] as! Int) / MAX_IOMFB_BRIGHTNESS.f, minVal: 0.0, maxVal: 1.0)
                computedProps["ComputedFromIOMFBBrightnessLevel"] = br.str(decimals: 4)
                if let id = SyncMode.builtinDisplay {
                    DisplayServicesGetLinearBrightness(id, &br)
                    computedProps["DisplayServicesGetLinearBrightness"] = br.str(decimals: 4)
                    computedProps["CoreDisplay_Display_GetUserBrightness"] = CoreDisplay_Display_GetUserBrightness(id).str(decimals: 4)
                }
                armProps["ComputedProps"] = computedProps

                if let encoded = try? encoder.encode(ForgivingEncodable(armProps)),
                   let compressed = encoded.gzip()?.base64EncodedString()
                {
                    scope.setExtra(value: compressed, key: "armBuiltinProps")
                }
            } else {
                scope.setExtra(value: SyncMode.readBuiltinDisplayBrightnessIOKit(), key: "builtinDisplayBrightnessIOKit")
            }
            scope.setExtra(value: self?.lidClosed ?? IsLidClosed(), key: "lidClosed")

            guard let self = self else { return }
            for display in self.displays.values {
                display.addSentryData()
                if display.isUltraFine() {
                    scope.setTag(value: "true", key: "ultrafine")
                    continue
                }
                if display.isThunderbolt() {
                    scope.setTag(value: "true", key: "thunderbolt")
                    continue
                }
                if display.isLEDCinema() {
                    scope.setTag(value: "true", key: "ledcinema")
                    continue
                }
                if display.isCinema() {
                    scope.setTag(value: "true", key: "cinema")
                    continue
                }
            }
        }
    }

    func adaptiveModeString(last: Bool = false) -> String {
        let mode: AdaptiveModeKey
        if last {
            mode = lastNonManualAdaptiveMode.key
        } else {
            mode = adaptiveModeKey
        }

        return mode.str
    }

    func activateClamshellMode() {
        if adaptiveModeKey == .sync {
            clamshellMode = true
            disable()
        }
    }

    func deactivateClamshellMode() {
        if adaptiveModeKey == .manual {
            clamshellMode = false
            enable()
        }
    }

    func manageClamshellMode() {
        lidClosed = IsLidClosed()
        SyncMode.builtinDisplay = SyncMode.getBuiltinDisplay()
        log.info("Lid closed: \(lidClosed)")
        SentrySDK.configureScope { [weak self] scope in
            guard let self = self else { return }
            scope.setTag(value: String(describing: self.lidClosed), key: "clamshellMode")
        }

        if CachedDefaults[.clamshellModeDetection] {
            if lidClosed {
                activateClamshellMode()
            } else if clamshellMode {
                deactivateClamshellMode()
            }
        }
    }

    func listenForRunningApps() {
        let appIdentifiers = NSWorkspace.shared.runningApplications.map { app in app.bundleIdentifier }.compactMap { $0 }
        runningAppExceptions = datastore.appExceptions(identifiers: appIdentifiers) ?? []
        adaptBrightness()

        appObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new], changeHandler: { [unowned self] _, change in
            let oldAppIdentifiers = change.oldValue?.map { app in app.bundleIdentifier }.compactMap { $0 }
            let newAppIdentifiers = change.newValue?.map { app in app.bundleIdentifier }.compactMap { $0 }

            if let identifiers = newAppIdentifiers, identifiers.contains(FLUX_IDENTIFIER),
               let app = change.newValue?.first(where: { app in app.bundleIdentifier == FLUX_IDENTIFIER }),
               let display = activeDisplays.values.first(where: { d in d.control is GammaControl })
            {
                (display.control as! GammaControl).fluxChecker(flux: app)
            }

            if let identifiers = newAppIdentifiers, let newApps = datastore.appExceptions(identifiers: identifiers) {
                self.runningAppExceptions.append(contentsOf: newApps)
            }
            if let identifiers = oldAppIdentifiers, let exceptions = datastore.appExceptions(identifiers: identifiers) {
                for exception in exceptions {
                    self.runningAppExceptions.removeAll(where: { $0.identifier == exception.identifier })
                }
            }
            self.adaptBrightness()
        })
    }

    func fetchValues(for displays: [Display]? = nil) {
        for display in displays ?? activeDisplays.values.map({ $0 }) {
            display.refreshBrightness()
            display.refreshContrast()
            display.refreshVolume()
            display.refreshInput()
        }
    }

    func adaptBrightness(for display: Display, force: Bool = false) {
        adaptiveMode.withForce(force || display.force) {
            self.adaptiveMode.adapt(display)
        }
    }

    func adaptBrightness(for displays: [Display]? = nil, force: Bool = false) {
        for display in displays ?? Array(activeDisplays.values) {
            adaptiveMode.withForce(force || display.force) {
                self.adaptiveMode.adapt(display)
            }
        }
    }

    func setBrightnessPercent(value: Int8, for displays: [Display]? = nil) {
        let manualMode = (adaptiveMode as? ManualMode) ?? ManualMode.specific
        if let displays = displays {
            displays.forEach { display in
                if !display.lockedBrightness {
                    display.brightness = manualMode.compute(
                        percent: value,
                        minVal: display.minBrightness.intValue,
                        maxVal: display.maxBrightness.intValue
                    )
                }
            }
        } else {
            activeDisplays.values
                .forEach { display in
                    if !display.lockedBrightness {
                        display.brightness = manualMode.compute(
                            percent: value,
                            minVal: display.minBrightness.intValue,
                            maxVal: display.maxBrightness.intValue
                        )
                    }
                }
        }
    }

    func setContrastPercent(value: Int8, for displays: [Display]? = nil) {
        let manualMode = (adaptiveMode as? ManualMode) ?? ManualMode.specific
        if let displays = displays {
            displays
                .forEach { display in
                    if !display.lockedContrast {
                        display.contrast = manualMode.compute(
                            percent: value,
                            minVal: display.minContrast.intValue,
                            maxVal: display.maxContrast.intValue
                        )
                    }
                }
        } else {
            activeDisplays.values
                .forEach { display in
                    if !display.lockedContrast {
                        display.contrast = manualMode.compute(
                            percent: value,
                            minVal: display.minContrast.intValue,
                            maxVal: display.maxContrast.intValue
                        )
                    }
                }
        }
    }

    func setBrightness(brightness: NSNumber, for displays: [Display]? = nil) {
        if let displays = displays {
            displays.forEach { display in display.brightness = brightness }
        } else {
            activeDisplays.values.forEach { display in display.brightness = brightness }
        }
    }

    func setContrast(contrast: NSNumber, for displays: [Display]? = nil) {
        if let displays = displays {
            displays.forEach { display in display.contrast = contrast }
        } else {
            activeDisplays.values.forEach { display in display.contrast = contrast }
        }
    }

    func toggleAudioMuted(for displays: [Display]? = nil, currentDisplay: Bool = false, currentAudioDisplay: Bool = true) {
        adjustValue(for: displays, currentDisplay: currentDisplay, currentAudioDisplay: currentAudioDisplay) { (display: Display) in
            display.audioMuted = !display.audioMuted
        }
    }

    func adjustVolume(by offset: Int, for displays: [Display]? = nil, currentDisplay: Bool = false, currentAudioDisplay: Bool = true) {
        adjustValue(for: displays, currentDisplay: currentDisplay, currentAudioDisplay: currentAudioDisplay) { (display: Display) in
            var value = getFilledChicletValue(display.volume.intValue, offset: offset)
            value = cap(value, minVal: MIN_VOLUME, maxVal: MAX_VOLUME)
            display.volume = value.ns
        }
    }

    func adjustBrightness(by offset: Int, for displays: [Display]? = nil, currentDisplay: Bool = false) {
        guard checkRemainingAdjustments() else { return }

        adjustValue(for: displays, currentDisplay: currentDisplay) { (display: Display) in
            var value = getFilledChicletValue(display.brightness.intValue, offset: offset)

            value = cap(
                value,
                minVal: display.minBrightness.intValue,
                maxVal: display.maxBrightness.intValue
            )
            display.brightness = value.ns

            if displayController.adaptiveModeKey != .manual {
                display.insertBrightnessUserDataPoint(SyncMode.lastBuiltinBrightness.intround, value, modeKey: adaptiveModeKey)
            }
        }
    }

    func adjustContrast(by offset: Int, for displays: [Display]? = nil, currentDisplay: Bool = false) {
        guard checkRemainingAdjustments() else { return }

        adjustValue(for: displays, currentDisplay: currentDisplay) { (display: Display) in
            var value = getFilledChicletValue(display.contrast.intValue, offset: offset)

            value = cap(
                value,
                minVal: display.minContrast.intValue,
                maxVal: display.maxContrast.intValue
            )
            display.contrast = value.ns

            if displayController.adaptiveModeKey != .manual {
                display.insertContrastUserDataPoint(SyncMode.lastBuiltinContrast.intround, value, modeKey: adaptiveModeKey)
            }
        }
    }

    func adjustValue(
        for displays: [Display]? = nil,
        currentDisplay: Bool = false,
        currentAudioDisplay: Bool = false,
        _ setValue: (Display) -> Void
    ) {
        if currentAudioDisplay {
            if let display = self.currentAudioDisplay {
                setValue(display)
            }
        } else if currentDisplay {
            if let display = self.currentDisplay {
                setValue(display)
            }
        } else if let displays = displays {
            displays.forEach { display in
                setValue(display)
            }
        } else {
            activeDisplays.values.forEach { display in
                setValue(display)
            }
        }
    }

    func getFilledChicletValue(_ value: Int, offset: Int) -> Int {
        let newValue = value + offset
        guard abs(offset) == 6 else { return newValue }
        let diffs = FILLED_CHICLETS_THRESHOLDS - newValue.f
        if let index = abs(diffs).enumerated().min(by: { $0.element <= $1.element })?.offset {
            let backupIndex = cap(index + (offset < 0 ? -1 : 1), minVal: 0, maxVal: FILLED_CHICLETS_THRESHOLDS.count - 1)
            let chicletValue = FILLED_CHICLETS_THRESHOLDS[index].i
            return chicletValue != value ? chicletValue : FILLED_CHICLETS_THRESHOLDS[backupIndex].i
        }
        return newValue
    }

    func gammaUnlock(for displays: [Display]? = nil) {
        (displays ?? self.displays.values.map { $0 }).forEach { $0.gammaUnlock() }
    }
}

let displayController = DisplayController()
let FILLED_CHICLETS_THRESHOLDS: [Float] = [0, 6, 12, 19, 25, 31, 37, 44, 50, 56, 62, 69, 75, 81, 87, 94, 100]
