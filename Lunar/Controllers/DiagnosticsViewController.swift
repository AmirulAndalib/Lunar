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
import Down
import Sentry

let FAQ_URL = try! "https://lunar.fyi/faq".asURL()

class DiagnosticsViewController: NSViewController, NSTextViewDelegate {
    @objc dynamic var editable = false
    @objc dynamic var stopped = false
    @objc dynamic var sent = false {
        didSet {
            mainThread {
                if sent {
                    sendButton.isEnabled = false
                    sendButton.bg = blue
                    sendButton.attributedTitle = "Sent!".withAttribute(.textColor(white))
                } else {
                    setSendButtonEnabled()
                    sendButton.bg = green
                    sendButton.attributedTitle = "Send Diagnostics".withAttribute(.textColor(white))
                }
            }
        }
    }

    @objc dynamic var percentDone = 5
    @objc dynamic var info = NSAttributedString()

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

    @IBOutlet var outputScrollView: OutputScrollView!
    @IBOutlet var logo: NSTextField!

    @IBOutlet var sendButton: Button!
    @IBOutlet var stopButton: Button!

    @IBOutlet var backingTextView: NSTextView!
    @IBOutlet var textView: NSTextView!

    var keyPressed: UInt16 = 0

    func setSendButtonEnabled() {
        sendButton.isEnabled = !sent && !(name?.isEmpty ?? true) && !(email?.isEmpty ?? true)
    }

    let continueTestCondition = NSCondition()
    let style = """
    \(STYLESHEET)

    p, ul, ol, li, a {
        margin: 0;
        padding: 0;
        font-size: 14px;
    }
    p, li {
        color: #49435A;
    }

    h1, h2 {
        color: #D55D5C;
    }
    h2 {
        color: #D55D5C;
        font-size: 18px;
    }
    h3 {
        color: #6C4159;
        font-size: 17px;
    }
    h4 {
        color: #3D3A47;
        font-size: 15px;
    }

    ul, ol, li:last-child {
        margin-bottom: 3px;
    }

    hr {
        border-top: 1px solid #6C4159;
    }

    """

    func renderSeparated(_ str: String) {
        render("----\n\n\(str)\n\n----\n\n")
    }

    func render(_ str: String) {
        guard !stopped else { return }
        let down = Down(markdownString: str)
        mainThread {
            guard let textView = outputScrollView.documentView as? NSTextView else { return }

            self.info += ((try? down.toAttributedString(.hardBreaks, stylesheet: style)) ?? str.attributedString)
            textView.scrollToEndOfDocument(nil)
        }
    }

    func startDiagnostics() {
        async(threaded: true) { [weak self] in
            guard let self = self else { return }

            let steps = displayController.activeDisplays.values.count
            let stepPercent = 90.0 / steps.d

            self.renderSeparated("""
            **Note: Don't copy/paste this output in an email as that is not enough.**
            **Clicking the `Send Diagnostics` button will send more useful technical data.**
            **If you want to aid the developer in debugging your problem, make sure to complete the full diagnostics by:**

            * Pressing the necessary keys when prompted
            * Not clicking inside this text container as it steals the focus and keys will not be registered by the diagnostics window
                * Click outside this text container if pressing keys doesn't continue the diagnostics
            """)

            for (i, display) in displayController.activeDisplays.values.enumerated() {
                let setPercent = { (percent: Double) in
                    guard !self.stopped else { return }
                    mainThread {
                        self.percentDone = (stepPercent * i.d).intround + (stepPercent * (percent / 100)).intround
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }

                self.render("## Diagnosing display \(display.name) [\(display.serial)]")
                setPercent(10)
                guard !self.stopped else { return }

                let i2c = DDC.I2CController(displayID: display.id)
                setPercent(20)
                guard !self.stopped else { return }

                let networkController = NetworkControl.controllersForDisplay[display.id]
                let network = networkController?.url?.absoluteString
                setPercent(30)
                guard !self.stopped else { return }

                let coreDisplay = CoreDisplayControl(display: display).isAvailable()
                let appleDisplay = display.isAppleDisplay()
                setPercent(40)
                guard !self.stopped else { return }

                self.render("""
                * ID: `\(display.id)`
                * EDID Name: `\(display.edidName)`
                * I2C Controller: `\(
                    i2c == 0 ? "NONE" : i2c.s)`
                  * _This monitor \(
                      i2c == 0 ? "can't receive DDC control messages through a cable connection" : "should be controllable through DDC")_
                * Network Controller: `\(network == nil ? "NONE" : network!)`
                  * _This monitor \(network == nil ?
                    "can't be controlled through the network" : "supports DDC through a network controller")_
                * DDC Status: `\(display.responsiveDDC ? "responsive" : "unresponsive")`
                * Apple vendored: `\(appleDisplay ? "YES" : "NO")`
                  * _\(
                      appleDisplay
                          ?
                          (
                              coreDisplay ?
                                  "Should support native control through CoreDisplay" :
                                  "Should support CoreDisplay but doesn't"
                          )
                          : "Doesn't support CoreDisplay")_
                * Vendor ID: `\(CGDisplayVendorNumber(display.id))` \(display.isAppleVendorID() ? "_(seems to be an Apple vendor ID)_" : "")
                """)
                setPercent(50)
                guard !self.stopped else { return }

                Thread.sleep(forTimeInterval: 1.5)
                guard !self.stopped else { return }

                var ddcWorked = false
                var ddcctlWorked = false
                var coreDisplayWorked = false
                var networkWorked = false

                var ddcReadWorked = false
                var ddcctlReadWorked = false
                var coreDisplayReadWorked = false
                var networkReadWorked = false

                let tryBrightness = { (control: Control) in
                    guard !self.stopped else { return }

                    self.continueTestCondition.wait()
                    guard !self.stopped else { return }

                    if control is DDCCTLControl, ddcWorked {
                        return
                    }

                    self.render("-----------------------------")
                    self
                        .render(
                            "### Testing \(control.str):\(control is DDCCTLControl ? "  [https://github.com/kfix/ddcctl](https://github.com/kfix/ddcctl)" : "")"
                        )

                    switch control {
                    case is CoreDisplayControl:
                        self.render("#### Reading brightness...")
                        Thread.sleep(forTimeInterval: 0.5)

                        if let br = control.getBrightness() {
                            self.renderSeparated("Received brightness value: `\(br)` *(\(br.asPercentage(of: 100)))*")
                            coreDisplayReadWorked = true
                        } else {
                            self.renderSeparated("`Could not read brightness value!`")
                        }
                        Thread.sleep(forTimeInterval: 0.5)

                    case is DDCControl, is DDCCTLControl, is NetworkControl:
                        self.render("**Do you want to test reading brightness?**")
                        self.renderSeparated(
                            """
                            ## Caution!! This can cause a kernel panic and you'll have to restart your \(
                                control is NetworkControl
                                    ? "Network Controller *(Raspberry Pi)*"
                                    : Sysctl.device
                            ) if it happens!
                            """
                        )
                        self.renderSeparated(
                            "_Press the `Enter` key to test reading.\nPress `any other key` to `skip reading test` and continue diagnostics... (click outside this container if keys don't work)_"
                        )
                        self.continueTestCondition.wait()

                        if self.keyPressed == kVK_Return {
                            self.render("#### Reading brightness...")
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
                        if let networkController = NetworkControl.controllersForDisplay[display.id],
                           let url = networkController.url
                        {
                            self.render("#### Detecting connected displays...")
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

                    self.render("* _Setting brightness to `1`_")
                    let try1 = control.setBrightness(10, oldValue: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("* _Setting brightness to `100`_")
                    let try2 = control.setBrightness(100, oldValue: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("* _Setting brightness to `25`_")
                    let try3 = control.setBrightness(10, oldValue: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    self.render("* _Setting brightness to `50`_")
                    let try4 = control.setBrightness(50, oldValue: nil)
                    Thread.sleep(forTimeInterval: 0.5)
                    guard !self.stopped else { return }

                    let tries = [try1, try2, try3, try4]
                    self.render("`\(tries.trueCount)` out of `4` tries seemed to reach the monitor")

                    Thread.sleep(forTimeInterval: 1.5)
                    guard !self.stopped else { return }
                    _ = ask(
                        message: "\(control.str) Test",
                        info: "Was there any noticeable change in brightness?",
                        okButton: "Yes",
                        cancelButton: "No",
                        window: self.view.window,
                        onCompletion: { (changed: Bool) in
                            self.render("**Was there any noticeable change in brightness? : `\(changed ? "YES" : "NO")`**")

                            switch control {
                            case is DDCCTLControl:
                                ddcctlWorked = changed
                                if !ddcWorked {
                                    if !ddcctlWorked {
                                        self.renderSeparated("""
                                        ### `ddcctl` wasn't able to control the monitor.

                                        --------

                                        This means that your hardware setup doesn't support DDC and **Lunar can't fix this in software**.
                                        Go through the checklist above if you think this should work.
                                        Most of the time, using a different cable/connector/hub can fix this.

                                        """)
                                    } else {
                                        self.renderSeparated("""
                                        ### Looks like `ddcctl` was able to control the monitor, while Lunar failed.

                                        --------

                                        This can mean that Lunar has a bug.
                                        Please click the button below to send the diagnostics to the developer.
                                        """)
                                    }
                                }
                            case is CoreDisplayControl:
                                coreDisplayWorked = changed
                                if !coreDisplayWorked {
                                    self.renderSeparated("""
                                    ### This monitor could not be controlled through Apple's native CoreDisplay framework.

                                    --------

                                    If this really is an Apple vendored display _(Pro Display XDR, LG Ultrafine, Thunderbolt, LED Cinema)_ then check the following:
                                    * If it is a LED Cinema, make sure to also connect the monitor through USB
                                    * Make sure the monitor isn't being controlled by another adaptive setting in your system
                                    """)
                                    if ddcWorked {
                                        self.renderSeparated("""
                                            Since DDC worked, you can also disable CoreDisplay and use DDC for this monitor:
                                            * Click on the ⚙️ (gear) icon near the `RESET` button on the Display page of the Lunar UI
                                            * Uncheck CoreDisplay
                                        """)
                                    }
                                }
                            case is NetworkControl:
                                networkWorked = changed
                                if !networkWorked {
                                    self.renderSeparated("""
                                    ### The assigned network controller wasn't able to control this monitor
                                    """)
                                    if let networkController = NetworkControl.controllersForDisplay[display.id],
                                       let url = networkController.url
                                    {
                                        self.render("""
                                        #### If you have technical knowledge about `SSH` and `curl`, you can check the following:
                                        * See if the controller is reachable using this curl command: `curl \(url)`
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
                                          * If you get `Display not found`, make sure your Pi is running an OS with a desktop environment
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
                                    ### Looks like your setup doesn't support DDC
                                    #### This means Lunar won't be able to control the hardware values of your monitor through the connected cable

                                    --------

                                    #### The following features won't be supported:
                                    * Changing the hardware brightness _(hardware, as in, the same brightness you can change using the monitor's physical buttons)_
                                    * Changing the hardware contrast
                                    * Changing the monitor volume
                                    * Switching to another monitor input
                                    * Powering off the monitor

                                    --------

                                    Lunar will still be able to decrease **(but not increase)** brightness using gamma tables, a software control method.
                                    If you see the red `Software Control` tag under the monitor name, you should manually set the monitor brightness and contrast to the highest possible values using the monitor physical buttons.

                                    --------

                                    #### If you think DDC should work, check the following:
                                    * Is this an M1 Mac? **(M1 doesn't yet provide support for DDC)**
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
                                "_Press any key to continue diagnostics... (click outside this container if keys don't work)_"
                            )
                        }
                    )
                }

                let networkControl = NetworkControl(display: display)
                let coreDisplayControl = CoreDisplayControl(display: display)
                let ddcControl = DDCControl(display: display)

                let shouldStartTests = ddcControl.isAvailable() || DDC.hasI2CController(displayID: display.id) || coreDisplayControl
                    .isAvailable() || display.isAppleDisplay() || networkControl.isAvailable()

                if shouldStartTests {
                    self.renderSeparated(
                        "_Press any key to start tests for this display... (click outside this container if keys don't work)_"
                    )
                    display.adaptivePaused = true
                    defer {
                        display.adaptivePaused = false
                        display.readapt(newValue: false, oldValue: true)
                    }
                    if ddcControl.isAvailable() || DDC.hasI2CController(displayID: display.id) {
                        tryBrightness(ddcControl)
                        setPercent(60)
                        guard !self.stopped else { return }

                        tryBrightness(DDCCTLControl(display: display))
                        setPercent(70)
                        guard !self.stopped else { return }
                    }
                    if coreDisplayControl.isAvailable() || display.isAppleDisplay() {
                        tryBrightness(coreDisplayControl)
                        setPercent(80)
                        guard !self.stopped else { return }
                    }
                    if networkControl.isAvailable() {
                        tryBrightness(networkControl)
                        setPercent(90)
                        guard !self.stopped else { return }
                    }
                    self.continueTestCondition.wait()
                } else {
                    self.renderSeparated("**This display doesn't support hardware controls.**")
                }

                if SyncMode.specific.available {
                    self.renderSeparated("### Sync Mode")
                    self.render("**Do you want to test Sync Mode?**")

                    self.renderSeparated(
                        "_Press the `Enter` key to test Sync Mode.\nPress `any other key` to `skip the Sync Mode test` and continue diagnostics... (click outside this container if keys don't work)_"
                    )
                    self.continueTestCondition.wait()
                    guard !self.stopped else { return }

                    if self.keyPressed != kVK_Return {
                        self.render("_Skipped Sync Mode test..._")
                    } else {
                        self.renderSeparated("""
                        **Lunar will launch System Preferences for Displays now**
                        **Please disable `\"Automatically adjust brightness\"` until this test is done**

                        Press any key to continue diagnostics _after disabling the setting_... (click outside this container if keys don't work)_"
                        """)
                        Thread.sleep(forTimeInterval: 1)
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Displays.prefPane"))
                        self.continueTestCondition.wait()
                        guard !self.stopped else { return }

                        let lastMode = displayController.adaptiveMode
                        let lastPollingInterval = SyncMode.pollingSeconds
                        let smoothTransitionActive = Defaults[.smoothTransition]
                        defer {
                            if lastMode.key != .sync {
                                self.render("Going back from Sync to \(lastMode.str) Mode")
                                displayController.adaptiveMode = lastMode
                            }
                            if lastPollingInterval != 1 {
                                self.render("Setting polling interval back to \(lastPollingInterval) seconds")
                                SyncMode.pollingSeconds = lastPollingInterval
                            }
                            if smoothTransitionActive {
                                self.render("Re-enabling smooth transition")
                                Defaults[.smoothTransition] = true
                            }
                        }
                        if lastMode.key != .sync {
                            self.render("Changing from \(lastMode.str) to Sync Mode")
                            displayController.adaptiveMode = SyncMode.shared
                        }
                        if lastPollingInterval != 1 {
                            self.render("Setting polling interval to 1 second")
                            SyncMode.pollingSeconds = 1
                            SyncMode.specific.stopWatching()
                            Thread.sleep(forTimeInterval: 1)
                            _ = SyncMode.specific.watch()
                        }
                        if smoothTransitionActive {
                            self.render("Disabling smooth transition")
                            Defaults[.smoothTransition] = false
                        }

                        let builtinBrightness = SyncMode.getBuiltinDisplayBrightnessContrast()?.0
                        var iokitBrightness = SyncMode.readBuiltinDisplayBrightnessIOKit()
                        var armBrightness = SyncMode.readBuiltinDisplayBrightnessARM()
                        var coreDisplayBrightness = SyncMode.readBuiltinDisplayBrightnessCoreDisplay()
                        var displayServicesBrightness = SyncMode.readBuiltinDisplayBrightnessDisplayServices()

                        let printBrightness = {
                            guard !self.stopped else { return }
                            iokitBrightness = SyncMode.readBuiltinDisplayBrightnessIOKit()
                            armBrightness = SyncMode.readBuiltinDisplayBrightnessARM()
                            coreDisplayBrightness = SyncMode.readBuiltinDisplayBrightnessCoreDisplay()
                            displayServicesBrightness = SyncMode.readBuiltinDisplayBrightnessDisplayServices()
                            let builtinBrightness = SyncMode.getBuiltinDisplayBrightnessContrast()?.0.str(decimals: 2) ?? "nil"

                            self.renderSeparated("""
                            **Built-in brightness (as reported by):**

                            * IOKit: `\(iokitBrightness)`
                            * ARM Props: `\(armBrightness)`
                            * CoreDisplay: `\(coreDisplayBrightness)`
                            * DisplayServices: `\(displayServicesBrightness)`
                            * Sync Mode Consensus: `\(builtinBrightness)`
                            """)

                            var monitorBrightness = "nil"

                            if coreDisplayReadWorked {
                                monitorBrightness = coreDisplayControl.getBrightness()?.s ?? "nil"
                                self.render("**\(display.name) monitor brightness (as reported by CoreDisplay): `\(monitorBrightness)`**")
                            }
                            if networkReadWorked {
                                monitorBrightness = networkControl.getBrightness()?.s ?? "nil"
                                self.render("**\(display.name) monitor brightness (as reported by NetworkControl): `\(monitorBrightness)`**")
                            }
                            if ddcReadWorked {
                                monitorBrightness = ddcControl.getBrightness()?.s ?? "nil"
                                self.render("**\(display.name) monitor brightness (as reported by DDC): `\(monitorBrightness)`**")
                            }
                        }
                        printBrightness()
                        Thread.sleep(forTimeInterval: 0.5)

                        let trySync = { (brightness: UInt8, method: CoreDisplayMethod) in
                            guard !self.stopped else { return }
                            self.render("\n#### Setting built-in brightness to `\(brightness)` using `\(method)`")
                            SyncMode.setBuiltinDisplayBrightness(brightness)
                            Thread.sleep(forTimeInterval: 3)
                            guard !self.stopped else { return }
                            printBrightness()
                            Thread.sleep(forTimeInterval: 1)
                        }

                        trySync(100, .coreDisplay)
                        trySync(10, .coreDisplay)
                        trySync(1, .coreDisplay)
                        trySync(100, .displayServices)
                        trySync(10, .displayServices)
                        trySync(1, .displayServices)
                        if let oldBrightness = builtinBrightness {
                            trySync(oldBrightness.u8, .coreDisplay)
                            trySync(oldBrightness.u8, .displayServices)
                        }
                    }
                }

                self.renderSeparated("**Diagnostics done for display \(display.name) [\(display.serial)]**")
            }

            self.renderSeparated("""
            **If you want to send diagnostics, make sure to fill in the Name and Email fields.**
            **Don't copy/paste this output in an email as that is not enough, clicking the button will send more useful technical data.**
            You can also add additional comments below this line.
            """)

            mainThread {
                self.percentDone = 100
                self.stopDiagnostics(self)
                self.textView.isEditable = true
                self.setSendButtonEnabled()
            }
        }
    }

    deinit {
        stopped = true
        continueTestCondition.signal()
        for display in displayController.activeDisplays.values {
            display.adaptivePaused = false
        }
    }

    override func keyDown(with event: NSEvent) {
        keyPressed = event.keyCode
        continueTestCondition.signal()
        if stopped {
            super.keyDown(with: event)
        }
    }

    @IBAction func restartDiagnostics(_: Any) {
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
        continueTestCondition.broadcast()
    }

    @IBAction func sendDiagnostics(_: Any) {
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
            self?.continueTestCondition.signal()
        }

        textView?.isEditable = false
        textView?.isSelectable = true
        textView.delegate = self
        backingTextView.isEditable = false

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
