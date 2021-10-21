//
//  DiagnosticsViewController.swift
//  Lunar
//
//  Created by Alin Panaitiu on 25.04.2021.
//  Copyright © 2021 Alin. All rights reserved.
//

import Carbon
import Cocoa
import Defaults
import Sentry
import SwiftyMarkdown

let FAQ_URL = "https://lunar.fyi/faq".asURL()!

// MARK: - DiagnosticsViewController

class DiagnosticsViewController: NSViewController, NSTextViewDelegate {
    // MARK: Lifecycle

    deinit {
        #if DEBUG
            log.verbose("START DEINIT")
            defer { log.verbose("END DEINIT") }
        #endif
        stopped = true
        continueTestCondition.signal()
        for display in displayController.activeDisplays.values {
            display.adaptivePaused = false
        }
    }

    // MARK: Internal

    @Atomic @objc dynamic var editable = false
    @Atomic @objc dynamic var stopped = false
    @objc dynamic var percentDone = 5
    @objc dynamic var info = NSAttributedString()

    @IBOutlet var outputScrollView: OutputScrollView!
    @IBOutlet var logo: NSTextField!

    @IBOutlet var sendButton: Button!
    @IBOutlet var stopButton: Button!

    @IBOutlet var backingTextView: NSTextView!
    @IBOutlet var textView: NSTextView!

    @Atomic var keyPressed: UInt16 = 0

    let continueTestCondition = NSCondition()
    @Atomic var waiting = false
    let markdown: SwiftyMarkdown = {
        let md = getMD()

        md.body.color = mauve
        md.h1.color = dullRed
        md.h2.color = dullRed
        md.h3.color = mauve.blended(withFraction: 0.3, of: red)!
        md.h4.color = darkMauve

        return md
    }()

    let SENT_TITLE = "Sent!"
    let SEND_DIAGNOSTICS_TITLE = "Send Diagnostics"

    @objc dynamic var sent = false {
        didSet {
            mainThread {
                self.waiting = false
                if sent {
                    setSendButtonEnabled(text: SENT_TITLE, color: blue)
                } else {
                    setSendButtonEnabled(text: SEND_DIAGNOSTICS_TITLE, color: green)
                }
            }
        }
    }

    @objc dynamic var name: String? = lunarProProduct?.activationID {
        didSet {
            mainThread { setSendButtonEnabled() }
        }
    }

    @objc dynamic var email: String? = lunarProProduct?.activationEmail {
        didSet {
            mainThread { setSendButtonEnabled() }
        }
    }

    func setSendButtonEnabled(text: String? = nil, color: NSColor? = nil, textColor: NSColor? = nil) {
        mainThread {
            sendButton.isEnabled = waiting || (!sent && !(name?.isEmpty ?? true) && !(email?.isEmpty ?? true) && stopped)

            if sendButton.isEnabled {
                sendButton.toolTip = nil
            } else if text != SENT_TITLE {
                sendButton.toolTip = "Make sure the diagnostics process has finished."
            }

            if let text = text {
                sendButton.attributedTitle = text.withAttribute(.textColor(textColor ?? white))
            }

            if let color = color {
                sendButton.bg = color
            }
        }
    }

    func renderSeparated(_ str: String) {
        render("----\n\n\(str)\n\n----\n\n")
    }

    func render(_ str: String) {
        guard !stopped else { return }
        mainThread {
            guard let textView = outputScrollView.documentView as? NSTextView else { return }

            self.info += markdown.attributedString(from: str)
            textView.scrollToEndOfDocument(nil)
        }
    }

    func startDiagnostics() {
        asyncNow(threaded: true) { [weak self] in
            guard let self = self else { return }

            let steps = displayController.activeDisplays.values.count
            let stepPercent = 90.0 / steps.d

            self.render("""
            *Note: Don't copy/paste this output in an email as that is not enough.*
            *Clicking the `Send Diagnostics` button will send more useful technical data.*
            *If you want to aid the developer in debugging your problem, make sure to complete the full diagnostics by clicking the necessary buttons when prompted.*
            """)

            for (i, display) in displayController.activeDisplays.values.enumerated() {
                let setPercent = { (percent: Double) in
                    guard !self.stopped else { return }
                    mainThread {
                        self.percentDone = (stepPercent * i.d).intround + (stepPercent * (percent / 100)).intround
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }

                self.render("\n\n### Diagnosing display \(display.name) *[\(display.serial)]*")
                setPercent(10)
                guard !self.stopped else { return }

                #if arch(arm64)
                    let avService = DDC.AVService(displayID: display.id, display: display, ignoreCache: true)
                #else
                    let i2c = DDC.I2CController(displayID: display.id, ignoreCache: true)
                #endif

                setPercent(20)
                guard !self.stopped else { return }

                let networkController = NetworkControl.controllersForDisplay[display.serial]
                let network = networkController?.url?.absoluteString
                setPercent(30)
                guard !self.stopped else { return }

                let appleNative = AppleNativeControl(display: display).isAvailable()
                let appleDisplay = display.isAppleDisplay()
                setPercent(40)
                guard !self.stopped else { return }

                var br: Float = 0.0

                #if arch(arm64)
                    let i2cMessage = """
                    * AV Service: `\(
                        avService == nil ? "NONE" : CFCopyDescription(avService!) as String)`
                    	* _This monitor \(
                    	    avService == nil ? "can't receive DDC control messages through a cable connection" :
                    	        "should be controllable through DDC")_
                    """
                #else
                    let i2cMessage = """
                    * I2C Controller: `\(
                        i2c == nil ? "NONE" : i2c!.s)`
                    	* _This monitor \(
                    	    i2c == nil ? "can't receive DDC control messages through a cable connection" :
                    	        "should be controllable through DDC")_
                    """
                #endif
                self.render("""

                * ID: `\(display.id)`
                * EDID Name: `\(display.edidName)`
                \(i2cMessage)
                * Network Controller: `\(network == nil ? "NONE" : network!)`
                	* _This monitor \(network == nil ?
                    "can't be controlled through the network" : "supports DDC through a network controller")_
                * DDC Status: `\(display.responsiveDDC ? "responsive" : "unresponsive")`
                * Apple vendored: `\((appleDisplay || display.isSmartDisplay) ? "YES" : "NO")`
                	* **DisplayServicesCanChangeBrightness: \(DisplayServicesCanChangeBrightness(display.id))**
                	* **DisplayServicesHasAmbientLightCompensation: \(DisplayServicesHasAmbientLightCompensation(display.id))**
                	* **DisplayServicesIsSmartDisplay: \(DisplayServicesIsSmartDisplay(display.id))**
                	* **DisplayServicesGetBrightness: \(DisplayServicesGetBrightness(display.id, &br) == KERN_SUCCESS ? br
                    .str(decimals: 2) : "\(br.str(decimals: 2)) [error]")**
                	* **DisplayServicesGetLinearBrightness: \(DisplayServicesGetLinearBrightness(display.id, &br) == KERN_SUCCESS ? br
                    .str(decimals: 2) : "\(br.str(decimals: 2)) [error]")**
                	* _\(
                	    (appleDisplay || display.isSmartDisplay)
                	        ?
                	        (
                	            appleNative ?
                	                "Should support native control through DisplayServices" :
                	                "Should support DisplayServices but doesn't"
                	        )
                	        : "Doesn't support DisplayServices")_
                * Vendor ID: `\(CGDisplayVendorNumber(display.id))` \(display.isAppleVendorID() ? "_(seems to be an Apple vendor ID)_" : "")
                """)
                setPercent(50)
                guard !self.stopped else { return }

                Thread.sleep(forTimeInterval: 1.5)
                guard !self.stopped else { return }

                var ddcWorked = false
                var ddcctlWorked = false
                var appleNativeWorked = false
                var networkWorked = false

                var ddcReadWorked = false
                var ddcctlReadWorked = false
                var appleNativeReadWorked = false
                var networkReadWorked = false

                let tryBrightness = { (control: Control) in
                    guard !self.stopped else { return }

                    self.waiting = true
                    self.continueTestCondition.wait()
                    guard !self.stopped else { return }

                    if control is DDCCTLControl, ddcWorked {
                        return
                    }

                    self.render("-----------------------------")
                    self
                        .render(
                            "#### Testing \(control.str):\(control is DDCCTLControl ? "  [https://github.com/kfix/ddcctl](https://github.com/kfix/ddcctl)" : "")"
                        )

                    let brightnessBeforeTest = display.brightness.uint8Value
                    switch control {
                    case is AppleNativeControl:
                        self.render("\n##### Reading brightness...")
                        Thread.sleep(forTimeInterval: 0.5)

                        if let br = control.getBrightness() {
                            self.renderSeparated("Received brightness value: `\(br)` *(\(br.asPercentage(of: 100)))*")
                            appleNativeReadWorked = true
                        } else {
                            self.renderSeparated("`Could not read brightness value!`")
                        }
                        Thread.sleep(forTimeInterval: 0.5)

                    case is DDCControl, is DDCCTLControl, is NetworkControl:
                        self.render("\nDo you want to test reading brightness?")
                        self.renderSeparated(
                            """
                            `Caution!! This can cause a kernel panic and you'll have to restart your \(
                                control is NetworkControl
                                    ? "Network Controller *(Raspberry Pi)*"
                                    : Sysctl.device
                            ) if it happens!`
                            """
                        )
                        self.renderSeparated(
                            "Click the `Test Read` button below to test reading.\n_Press `any other key` to `skip reading test` and continue diagnostics..._"
                        )
                        self.waiting = true
                        self.setSendButtonEnabled(text: "Test Read", color: lunarYellow, textColor: darkMauve)
                        self.continueTestCondition.wait()

                        if self.keyPressed == kVK_Return {
                            self.render("##### Reading brightness...")
                            Thread.sleep(forTimeInterval: 0.5)

                            if let br = control.getBrightness() {
                                self
                                    .renderSeparated(
                                        "Received brightness value: `\(br)` *(\(br.asPercentage(of: display.maxDDCBrightness.uint8Value)))*"
                                    )
                                switch control {
                                case is DDCControl:
                                    ddcReadWorked = true
                                case is DDCCTLControl:
                                    ddcctlReadWorked = true
                                    log.debug("ddcctlReadWorked: \(ddcctlReadWorked)")
                                case is NetworkControl:
                                    networkReadWorked = true
                                default:
                                    break
                                }
                            } else {
                                self.renderSeparated("`Could not read brightness value!`")
                            }
                        } else {
                            self.render("_Skipped reading brightness..._")
                        }
                        Thread.sleep(forTimeInterval: 0.3)

                    default:
                        break
                    }

                    if control is NetworkControl {
                        if let networkController = NetworkControl.controllersForDisplay[display.serial],
                           let url = networkController.url
                        {
                            self.render("\n##### Detecting connected displays...")
                            if let resp = waitForResponse(
                                from: url.deletingLastPathComponent().appendingPathComponent("displays"),
                                timeoutPerTry: 2.seconds,
                                retries: 3
                            ) {
                                self.renderSeparated("""
                                ```
                                \(resp)
                                ```
                                """)
                            } else {
                                self.renderSeparated("`The server did not respond successfully!`")
                            }
                        } else {
                            self.renderSeparated("`Could not find any responding URL for this controller!`")
                        }
                    }

                    self.render("\n* _Setting brightness to `1`_")
                    let try1 = control.setBrightness(10, oldValue: nil, onChange: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("\n* _Setting brightness to `100`_")
                    let try2 = control.setBrightness(100, oldValue: nil, onChange: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("\n* _Setting brightness to `25`_")
                    let try3 = control.setBrightness(10, oldValue: nil, onChange: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("\n* _Setting brightness to `50`_")
                    let try4 = control.setBrightness(50, oldValue: nil, onChange: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("\n* _Setting brightness back to `\(brightnessBeforeTest)`_")
                    let try5 = control.setBrightness(brightnessBeforeTest, oldValue: nil, onChange: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    let tries = [try1, try2, try3, try4, try5]
                    self.render("\n`\(tries.trueCount)` out of `\(tries.count)` tries seemed to reach the monitor")

                    Thread.sleep(forTimeInterval: 1.5)
                    guard !self.stopped else { return }
                    _ = ask(
                        message: "\(control.str) Test",
                        info: "Was there any noticeable change in brightness?",
                        okButton: "Yes",
                        cancelButton: "No",
                        window: mainThread { self.view.window },
                        onCompletion: { (changed: Bool) in
                            self.render("\n\n**Was there any noticeable change in brightness? : `\(changed ? "YES" : "NO")`**")

                            switch control {
                            case is DDCCTLControl:
                                ddcctlWorked = changed
                                if !ddcWorked {
                                    if !ddcctlWorked {
                                        self.renderSeparated("""
                                        #### `ddcctl` wasn't able to control the monitor.

                                        --------

                                        This means that your hardware setup doesn't support DDC and **Lunar can't fix this in software**.
                                        Go through the checklist above if you think this should work.
                                        Most of the time, using a different cable/connector/hub can fix this.

                                        """)
                                    } else {
                                        self.renderSeparated("""
                                        #### Looks like `ddcctl` was able to control the monitor, while Lunar failed.

                                        --------

                                        This can mean that Lunar has a bug.
                                        Please click the button below to send the diagnostics to the developer.
                                        """)
                                    }
                                }
                            case is AppleNativeControl:
                                appleNativeWorked = changed
                                if !appleNativeWorked {
                                    self.renderSeparated("""
                                    #### This monitor could not be controlled through Apple's native DisplayServices framework.

                                    --------

                                    If this really is an Apple vendored display _(Pro Display XDR, LG Ultrafine, Thunderbolt, LED Cinema)_ then check the following:
                                    * If it is a LED Cinema, make sure to also connect the monitor through USB
                                    * Make sure the monitor isn't being controlled by another adaptive setting in your system
                                    """)
                                    if ddcWorked {
                                        self.renderSeparated("""
                                            Since DDC worked, you can also disable DisplayServices and use DDC for this monitor:
                                            * Click on the `Display Settings` button near the `RESET` button on the Display page of the Lunar UI
                                            * Uncheck DisplayServices
                                        """)
                                    }
                                }
                            case is NetworkControl:
                                networkWorked = changed
                                if !networkWorked {
                                    self.renderSeparated("""
                                    #### The assigned network controller wasn't able to control this monitor
                                    """)
                                    if let networkController = NetworkControl.controllersForDisplay[display.serial],
                                       let url = networkController.url
                                    {
                                        self.render("""
                                        ##### If you have technical knowledge about `SSH` and `curl`, you can check the following:
                                        * See if the controller is reachable using this curl command: `curl \(url
                                            .deletingLastPathComponent().appendingPathComponent("displays"))`
                                        	* You should get a response similar to the one below:
                                        	* ```
                                            Display 1
                                              I2C bus:  /dev/i2c-2
                                              EDID synopsis:
                                                 Mfg id:               GSM
                                                 Model:                LG Ultra HD
                                                 Product code:         23304
                                                 Serial number:
                                                 Binary serial number: 314041 (0x0004cab9)
                                                 Manufacture year:     2017
                                                 EDID version:         1.3
                                              VCP version:         2.1
                                            ```
                                        	* If you get `Invalid Display` try turning your monitor off then turn it on after a few seconds
                                        	* If you get `Display not found`, make sure your Pi is running an OS with a desktop environment, and the desktop is visible when the Pi HDMI input is active
                                        * Check that the server is running
                                        	* SSH into your Pi
                                        	* Run `sudo systemctl status ddcutil-server`
                                        * Check if `ddcutil` can correctly identify and control your monitor
                                        	* SSH into your Pi
                                        	* Run `ddcutil detect` _(you should get the same response as for the `curl` command)_
                                        	* Cycle through a few brightness values to see if there's any change:
                                          		* `ddcutil setvcp 0x10 25`
                                          		* `ddcutil setvcp 0x10 100`
                                          		* `ddcutil setvcp 0x10 50`
                                        """)
                                    }
                                }
                            case is DDCControl:
                                ddcWorked = changed
                                if !ddcWorked {
                                    self.renderSeparated("""
                                    #### Looks like your setup doesn't support DDC
                                    ##### This means Lunar won't be able to control the hardware values of your monitor through the connected cable

                                    --------

                                    ##### The following features won't be supported:
                                    * Changing the hardware brightness _(hardware, as in, the same brightness you can change using the monitor's physical buttons)_
                                    * Changing the hardware contrast
                                    * Changing the monitor volume
                                    * Switching to another monitor input
                                    * Powering off the monitor

                                    --------

                                    Lunar will still be able to decrease **(but not increase)** brightness using gamma tables, a software control method.
                                    If you see the red `Software Control` tag under the monitor name, you should manually set the monitor brightness and contrast to the highest possible values using the monitor physical buttons.

                                    --------

                                    ##### If you think DDC should work, check the following:
                                    * Is this a TV? **(TVs don't support DDC)**
                                    * Are you using a hub/dock/adapter between this monitor and your Mac?
                                    	* Some of these devices can block DDC from reaching the monitor
                                    	* If possible, try connecting the monitor without the hub or using a different cable/connector
                                    * Are you using DisplayLink? **(DisplayLink doesn't provide support for DDC on macOS)**
                                    * Is DDC/CI enabled in your monitor settings?
                                    * Is this monitor connected to the HDMI output of a Mac Mini?
                                    	* This is a known hardware issue: [https://github.com/alin23/Lunar/issues/125](https://github.com/alin23/Lunar/issues/125)
                                    """)
                                }
                            default:
                                break
                            }
                            self.renderSeparated(
                                "Click the `Continue` button below to continue diagnostics..."
                            )
                            self.waiting = true
                            self.setSendButtonEnabled(text: "Continue", color: lunarYellow, textColor: darkMauve)
                        }
                    )
                }

                let networkControl = NetworkControl(display: display)
                let appleNativeControl = AppleNativeControl(display: display)
                let ddcControl = DDCControl(display: display)

                #if arch(arm64)
                    let ddcAvailable = !display
                        .isSmartBuiltin && (ddcControl.isAvailable() || DDC.hasAVService(displayID: display.id, ignoreCache: true))
                #else
                    let ddcAvailable = !display
                        .isSmartBuiltin && (ddcControl.isAvailable() || DDC.hasI2CController(displayID: display.id, ignoreCache: true))
                #endif
                let appleNativeAvailable = appleNativeControl.isAvailable() || display.isAppleDisplay() || display.isSmartBuiltin
                let networkAvailable = !display.isSmartBuiltin && networkControl.isAvailable()
                let shouldStartTests = ddcAvailable || appleNativeAvailable || networkAvailable

                if shouldStartTests {
                    display.adaptivePaused = true
                    defer {
                        display.adaptivePaused = false
                        display.readapt(newValue: false, oldValue: true)
                    }
                    self.renderSeparated(
                        "Click the `Start Testing` button below to start tests for this display..."
                    )
                    self.waiting = true
                    self.setSendButtonEnabled(text: "Start Testing", color: lunarYellow, textColor: darkMauve)

                    if ddcAvailable {
                        tryBrightness(ddcControl)
                        setPercent(60)
                        guard !self.stopped else { return }

                        #if !arch(arm64)
                            tryBrightness(DDCCTLControl(display: display))
                            setPercent(70)
                            guard !self.stopped else { return }
                        #endif
                    }
                    if appleNativeAvailable {
                        tryBrightness(appleNativeControl)
                        setPercent(80)
                        guard !self.stopped else { return }
                    }
                    if networkAvailable {
                        tryBrightness(networkControl)
                        setPercent(90)
                        guard !self.stopped else { return }
                    }
                    self.continueTestCondition.wait()
                } else {
                    self.renderSeparated("**This display doesn't support hardware controls.**")
                }

                if SyncMode.specific.available, !display.isBuiltin, !display.isSource {
                    self.renderSeparated("### Sync Mode")
                    self.render("Do you want to test Sync Mode?")

                    self.renderSeparated(
                        "Click the `Test Sync Mode` button to test Sync Mode.\n_Press `any other key` to `skip the Sync Mode test` and continue diagnostics..._"
                    )
                    self.waiting = true
                    self.setSendButtonEnabled(text: "Test Sync Mode", color: lunarYellow, textColor: darkMauve)
                    self.continueTestCondition.wait()
                    guard !self.stopped else { return }

                    if self.keyPressed != kVK_Return {
                        self.render("_Skipped Sync Mode test..._")
                    } else {
                        // self.renderSeparated("""
                        // **Lunar will launch System Preferences for Displays now**
                        // **Please disable `\"Automatically adjust brightness\"` on the source display (\(SyncMode.sourceDisplay?
                        //     .name ?? "Built-in")) until this test is done**

                        // Click the `Continue` button below to continue diagnostics _after disabling the setting_...
                        // """)
                        // self.waiting = true
                        // self.setSendButtonEnabled(text: "Continue", color: lunarYellow, textColor: darkMauve)
                        // Thread.sleep(forTimeInterval: 1)
                        // NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Displays.prefPane"))
                        // self.continueTestCondition.wait()
                        // guard !self.stopped else { return }

                        let lastMode = displayController.adaptiveMode
                        let lastPollingInterval = SyncMode.pollingSeconds
                        let oldBrightnessTransition = CachedDefaults[.brightnessTransition]
                        let oldAmbientLightAdaptiveBrightnessEnabled = display.ambientLightAdaptiveBrightnessEnabled
                        defer {
                            if lastMode.key != .sync {
                                self.render("\nGoing back from Sync to \(lastMode.str) Mode")
                                displayController.adaptiveMode = lastMode
                            }
                            if lastPollingInterval != 1 {
                                self.render("\nSetting polling interval back to \(lastPollingInterval) seconds")
                                SyncMode.pollingSeconds = lastPollingInterval
                            }
                            if oldBrightnessTransition != .instant {
                                self.render("\nRe-enabling smooth transition")
                                brightnessTransition = oldBrightnessTransition
                            }
                            if oldAmbientLightAdaptiveBrightnessEnabled {
                                display.ambientLightAdaptiveBrightnessEnabled = true
                            }
                        }
                        if oldAmbientLightAdaptiveBrightnessEnabled {
                            display.ambientLightAdaptiveBrightnessEnabled = false
                        }
                        if lastMode.key != .sync {
                            self.render("\nChanging from \(lastMode.str) to Sync Mode")
                            displayController.adaptiveMode = SyncMode.shared
                        }
                        if lastPollingInterval != 1 {
                            self.render("\nSetting polling interval to 1 second")
                            SyncMode.pollingSeconds = 1
                            SyncMode.specific.stopWatching()
                            Thread.sleep(forTimeInterval: 1)
                            if SyncMode.specific.available {
                                SyncMode.specific.watch()
                            }
                        }
                        if brightnessTransition != .instant {
                            self.render("\nDisabling smooth transition")
                            brightnessTransition = .instant
                        }

                        let sourceBrightness = SyncMode.getSourceBrightnessContrast()?.0

                        let printBrightness = {
                            guard !self.stopped else { return }
                            let sourceBrightness = SyncMode.getSourceBrightnessContrast()?.0.str(decimals: 2) ?? "nil"

                            self.renderSeparated("""
                            **Built-in brightness: `\(sourceBrightness)`**
                            """)

                            var monitorBrightness = "nil"

                            if appleNativeReadWorked {
                                monitorBrightness = appleNativeControl.getBrightness()?.s ?? "nil"
                                self.render("**\(display.name) monitor brightness (as reported by AppleNative): `\(monitorBrightness)`**")
                            }
                            if networkReadWorked {
                                monitorBrightness = networkControl.getBrightness()?.s ?? "nil"
                                self
                                    .render(
                                        "**\(display.name) monitor brightness (as reported by NetworkControl): `\(monitorBrightness)`**"
                                    )
                            }
                            if ddcReadWorked {
                                monitorBrightness = ddcControl.getBrightness()?.s ?? "nil"
                                self.render("**\(display.name) monitor brightness (as reported by DDC): `\(monitorBrightness)`**")
                            }
                        }
                        printBrightness()
                        Thread.sleep(forTimeInterval: 0.5)

                        let trySync = { (brightness: UInt8, method: AppleNativeMethod) in
                            guard !self.stopped else { return }
                            self.render("\n\n##### Setting source brightness to `\(brightness)`")
                            display.brightness = brightness.ns
                            Thread.sleep(forTimeInterval: 3)
                            guard !self.stopped else { return }
                            printBrightness()
                            Thread.sleep(forTimeInterval: 1)
                        }

                        trySync(100, .displayServices)
                        trySync(10, .displayServices)
                        trySync(1, .displayServices)
                        if let oldBrightness = sourceBrightness {
                            trySync(oldBrightness.u8, .displayServices)
                        }
                    }
                }

                self.renderSeparated("**Diagnostics done for display \(display.name) [\(display.serial)]**")
            }

            self.renderSeparated("""
            **If you want to send diagnostics, make sure to fill in the Name and Email fields.**
            **Don't copy/paste this output in an email as that is not enough, clicking the button will send more useful technical data.**

            `You can also add additional comments below this line.`
            """)

            mainThread {
                self.percentDone = 100
                self.stopDiagnostics(self)
                self.textView.isSelectable = true
                self.textView.isEditable = true
                self.waiting = false
                self.setSendButtonEnabled(text: self.SEND_DIAGNOSTICS_TITLE, color: green)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        keyPressed = event.keyCode
        waiting = false
        continueTestCondition.signal()
        if stopped {
            super.keyDown(with: event)
        }
    }

    @IBAction func restartDiagnostics(_: Any) {
        waiting = false
        continueTestCondition.broadcast()
        stopped = false
        sent = false
        percentDone = 5

        mainThread {
            info = NSAttributedString()
            stopButton.bg = red
            stopButton.attributedTitle = "Stop".withAttribute(.textColor(white))
            stopButton.action = #selector(stopDiagnostics(_:))
        }

        startDiagnostics()
    }

    @IBAction func stopDiagnostics(_: Any) {
        stopped = true
        mainThread {
            stopButton.bg = blue
            stopButton.attributedTitle = "Restart".withAttribute(.textColor(white))
            stopButton.action = #selector(restartDiagnostics(_:))
        }
        waiting = false
        continueTestCondition.broadcast()
    }

    @IBAction func sendDiagnostics(_: Any) {
        guard sendButton.attributedTitle.string == SEND_DIAGNOSTICS_TITLE else {
            keyPressed = kVK_Return.u16
            waiting = false
            continueTestCondition.signal()
            return
        }

        mainThread {
            sendButton.refusesFirstResponder = false
            view.window?.makeFirstResponder(sendButton)
        }

        stopDiagnostics(self)
        sent = true
        let eventId = SentrySDK.capture(message: "Diagnostics")

        let userFeedback = UserFeedback(eventId: eventId)
        userFeedback.comments = textView.string
        userFeedback.email = email ?? "No email"
        userFeedback.name = name ?? "No name"
        SentrySDK.capture(userFeedback: userFeedback)
    }

    @IBAction func faq(_: Any) {
        NSWorkspace.shared.open(FAQ_URL)
    }

    override func mouseDown(with _: NSEvent) {
        view.window?.makeFirstResponder(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.radius = 12.0.ns
        view.bg = white
        logo?.textColor = logoColor

        outputScrollView.scrollsDynamically = true
        outputScrollView.wantsLayer = true
        outputScrollView.appearance = NSAppearance(named: .vibrantLight)
        outputScrollView.radius = 14.0.ns
        outputScrollView.onKeyDown = { [weak self] _ in
            self?.waiting = false
            self?.continueTestCondition.signal()
        }

        textView?.isEditable = false
        textView?.isSelectable = false
        textView.delegate = self
        backingTextView.isEditable = false
        backingTextView.isSelectable = false

        setSendButtonEnabled()
        sendButton.bg = green
        sendButton.attributedTitle = sendButton.title.withAttribute(.textColor(white))
        sendButton.radius = 10.ns
        sendButton.frame = NSRect(origin: sendButton.frame.origin, size: CGSize(width: sendButton.frame.width, height: 30))

        stopButton.bg = red
        stopButton.attributedTitle = stopButton.title.withAttribute(.textColor(white))

        startDiagnostics()
    }
}
