//
//  HotkeyViewController.swift
//  Lunar
//
//  Created by Alin on 24/02/2019.
//  Copyright © 2019 Alin. All rights reserved.
//

import Cocoa
import Defaults
import Down
import Magnet

class HotkeyViewController: NSViewController {
    @IBOutlet var toggleHotkeyView: HotkeyView!
    @IBOutlet var lunarHotkeyView: HotkeyView!
    @IBOutlet var percent0HotkeyView: HotkeyView!
    @IBOutlet var percent25HotkeyView: HotkeyView!
    @IBOutlet var percent50HotkeyView: HotkeyView!
    @IBOutlet var percent75HotkeyView: HotkeyView!
    @IBOutlet var percent100HotkeyView: HotkeyView!
    @IBOutlet var brightnessUpHotkeyView: HotkeyView!
    @IBOutlet var brightnessDownHotkeyView: HotkeyView!
    @IBOutlet var contrastUpHotkeyView: HotkeyView!
    @IBOutlet var contrastDownHotkeyView: HotkeyView!
    @IBOutlet var volumeDownHotkeyView: HotkeyView!
    @IBOutlet var volumeUpHotkeyView: HotkeyView!
    @IBOutlet var muteAudioHotkeyView: HotkeyView!
    @IBOutlet var faceLightHotkeyView: HotkeyView!

    @IBOutlet var preciseBrightnessUpCheckbox: NSButton!
    @IBOutlet var preciseBrightnessDownCheckbox: NSButton!
    @IBOutlet var preciseContrastUpCheckbox: NSButton!
    @IBOutlet var preciseContrastDownCheckbox: NSButton!
    @IBOutlet var preciseVolumeUpCheckbox: NSButton!
    @IBOutlet var preciseVolumeDownCheckbox: NSButton!

    @IBOutlet var hotkeysInfoButton: ResetButton!
    @IBOutlet var resetButton: ResetButton!
    @IBOutlet var fnKeysNotice: NSTextField!

    var cachedFnState = Defaults[.fKeysAsFunctionKeys]

    @IBAction func resetHotkeys(_: Any) {
        CachedDefaults.reset(.hotkeys)
        setHotkeys()
    }

    @IBAction func toggleFineAdjustments(_ sender: NSButton) {
        var hotkey: PersistentHotkey?

        switch sender.tag {
        case 1:
            hotkey = CachedDefaults[.hotkeys].first { $0.identifier == HotkeyIdentifier.preciseBrightnessDown.rawValue }
        case 2:
            hotkey = CachedDefaults[.hotkeys].first { $0.identifier == HotkeyIdentifier.preciseBrightnessUp.rawValue }
        case 3:
            hotkey = CachedDefaults[.hotkeys].first { $0.identifier == HotkeyIdentifier.preciseContrastDown.rawValue }
        case 4:
            hotkey = CachedDefaults[.hotkeys].first { $0.identifier == HotkeyIdentifier.preciseContrastUp.rawValue }
        case 5:
            hotkey = CachedDefaults[.hotkeys].first { $0.identifier == HotkeyIdentifier.preciseVolumeDown.rawValue }
        case 6:
            hotkey = CachedDefaults[.hotkeys].first { $0.identifier == HotkeyIdentifier.preciseVolumeUp.rawValue }
        default:
            log.warning("Unknown tag: \(sender.tag)")
        }

        guard let hk = hotkey else { return }

        if sender.state == .on {
            hk.register()
        } else {
            hk.unregister()
        }

        hk.isEnabled = sender.state == .on
        CachedDefaults[.hotkeys].update(with: hk)
    }

    func setHotkeys() {
        let hotkeys = CachedDefaults[.hotkeys]

        toggleHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.toggle.rawValue }
        lunarHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.lunar.rawValue }
        percent0HotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.percent0.rawValue }
        percent25HotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.percent25.rawValue }
        percent50HotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.percent50.rawValue }
        percent75HotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.percent75.rawValue }
        percent100HotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.percent100.rawValue }
        faceLightHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.faceLight.rawValue }

        brightnessUpHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.brightnessUp.rawValue }
        brightnessDownHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.brightnessDown.rawValue }
        contrastUpHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.contrastUp.rawValue }
        contrastDownHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.contrastDown.rawValue }
        volumeUpHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.volumeUp.rawValue }
        volumeDownHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.volumeDown.rawValue }

        brightnessUpHotkeyView.preciseHotkeyCheckbox = preciseBrightnessUpCheckbox
        brightnessDownHotkeyView.preciseHotkeyCheckbox = preciseBrightnessDownCheckbox
        contrastUpHotkeyView.preciseHotkeyCheckbox = preciseContrastUpCheckbox
        contrastDownHotkeyView.preciseHotkeyCheckbox = preciseContrastDownCheckbox
        volumeUpHotkeyView.preciseHotkeyCheckbox = preciseVolumeUpCheckbox
        volumeDownHotkeyView.preciseHotkeyCheckbox = preciseVolumeDownCheckbox

        muteAudioHotkeyView.hotkey = hotkeys.first { $0.identifier == HotkeyIdentifier.muteAudio.rawValue }
    }

    func setupFKeysNotice(asFunctionKeys: Bool? = nil) {
        let notice: String
        if asFunctionKeys ?? Defaults[.fKeysAsFunctionKeys] {
            notice = """
            Your F keys are configured as **function keys**.
            You have to **hold `Fn`** while pressing:
            * `F1`/`F2` for Brightness
            * `Ctrl+F1`/`Ctrl+F2` for Contrast
            * `F10`/`F11`/`F12` for Volume/Mute
            """
        } else {
            notice = """
            Your F keys are configured as **media keys**.

            You have to **hold `Fn`** to be able to activate any of the hotkeys containing keys like `F1,` `F2,` `F10` etc.
            """
        }
        let down = Down(markdownString: notice)
        fnKeysNotice.attributedStringValue = (try? down.toAttributedString(.smart, stylesheet: DARK_STYLESHEET)) ?? notice.attributedString
        fnKeysNotice.isEnabled = false
    }

    var fkeysSettingWatcher: Timer?

    @IBAction func howDoHotkeysWork(_: Any) {
        NSWorkspace.shared.open(try! "https://lunar.fyi/faq#hotkeys".asURL())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.bg = hotkeysBgColor

        resetButton.page = .hotkeysReset
        hotkeysInfoButton.page = .hotkeys

        setHotkeys()
        setupFKeysNotice()
    }

    override func viewDidAppear() {
        let handler = { [weak self] in
            guard let self = self, self.cachedFnState != Defaults[.fKeysAsFunctionKeys] else { return }
            self.cachedFnState = Defaults[.fKeysAsFunctionKeys]
            self.setupFKeysNotice(asFunctionKeys: self.cachedFnState)
        }
        handler()
        cachedFnState = Defaults[.fKeysAsFunctionKeys]
        setupFKeysNotice(asFunctionKeys: cachedFnState)
        fkeysSettingWatcher = asyncEvery(10.seconds, handler)
    }

    deinit {
        log.verbose("")
        fkeysSettingWatcher?.invalidate()
        fkeysSettingWatcher = nil
    }

    override func viewDidDisappear() {
        fkeysSettingWatcher?.invalidate()
        fkeysSettingWatcher = nil
    }

    override func mouseDown(with event: NSEvent) {
        view.window?.makeFirstResponder(nil)
        super.mouseDown(with: event)
    }
}
