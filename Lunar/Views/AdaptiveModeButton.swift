//
//  AdaptiveModeButton.swift
//  Lunar
//
//  Created by Alin Panaitiu on 22.11.2020.
//  Copyright © 2020 Alin. All rights reserved.
//

import Cocoa
import Combine
import Defaults
import Foundation
import Regex

let MODE_DISABLED_REASON_PATTERN = "\\sMode.*".r!

// MARK: - AdaptiveModeButton

final class AdaptiveModeButton: NSPopUpButton, NSMenuItemValidation {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    static var syncDisabledReason: String {
        if Sysctl.isMacBook, DC.lidClosed {
            return "lid needs to be opened"
        }
        if !DC.sourceDisplay.isAllDisplays, DC.sourceDisplay.blackOutEnabled {
            return "BlackOut has to be disabled"
        }

        return "no source display"
    }

    let defaultAutoModeTitle = "Auto Mode"
    var adaptiveModeObserver: Cancellable?
    var pausedAdaptiveModeObserver = false

    var observers: Set<AnyCancellable> = []

    static func spacer(_ menuItem: NSMenuItem) -> String {
        menuItem.tag == AdaptiveModeKey.location.rawValue ? "\t" : "\t\t"
    }

    static func proDisabledString(_ menuItem: NSMenuItem) -> NSAttributedString {
        disabledString(menuItem, reason: "needs Lunar Pro")
    }

    static func enabledString(_ menuItem: NSMenuItem, reason: String = "") -> NSAttributedString {
        let title = MODE_DISABLED_REASON_PATTERN.replaceAll(
            in: menuItem.title,
            with: reason.isEmpty ? " Mode" : " Mode\(spacer(menuItem))(\(reason))"
        )
        return title.withFont(.monospacedSystemFont(ofSize: 12, weight: .semibold)).withTextColor(.labelColor)
    }

    static func disabledString(_ menuItem: NSMenuItem, reason: String) -> NSAttributedString {
        MENU_MARKDOWN.attributedString(
            from: MODE_DISABLED_REASON_PATTERN.replaceAll(
                in: menuItem.title,
                with: reason.isEmpty ? " Mode" : " Mode\(spacer(menuItem))(\(reason))"
            )
        )
    }

    static func validate(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.tag != AUTO_MODE_TAG else {
            menuItem.attributedTitle = enabledString(menuItem)
            return true
        }
        guard let mode = AdaptiveModeKey(rawValue: menuItem.tag) else {
            return false
        }

        guard mode.available else {
            switch mode {
            case .location:
                if proactive {
                    menuItem
                        .toolTip =
                        "Disabled because location can't be requested.\nCheck if Lunar has access to Location Services in System Preferences -> Security & Privacy"
                    menuItem.attributedTitle = disabledString(menuItem, reason: "missing permissions")
                } else {
                    menuItem.attributedTitle = proDisabledString(menuItem)
                    menuItem.toolTip = "Only available with a Lunar Pro license"
                }
            case .sensor:
                if proactive {
                    menuItem.toolTip = "Disabled because there is no light sensor connected to this \(Sysctl.device)"
                    menuItem.attributedTitle = disabledString(menuItem, reason: "no sensor available")
                } else {
                    menuItem.attributedTitle = proDisabledString(menuItem)
                    menuItem.toolTip = "Only available with a Lunar Pro license"
                }
            case .sync:
                if proactive {
                    menuItem
                        .toolTip =
                        "Disabled because no source display was found"
                    menuItem.attributedTitle = disabledString(menuItem, reason: syncDisabledReason)
                } else {
                    menuItem.attributedTitle = proDisabledString(menuItem)
                    menuItem.toolTip = "Only available with a Lunar Pro license"
                }
            case .clock:
                menuItem.toolTip = "Only available with a Lunar Pro license"
                menuItem.attributedTitle = proDisabledString(menuItem)
            default:
                break
            }
            return false
        }

        if mode == .location {
            if CachedDefaults[.manualLocation] {
                menuItem.toolTip =
                    "Lunar is using the manually configured coordinates in Display Settings -> Configuration"
                menuItem.attributedTitle = enabledString(menuItem, reason: "manual coordinates")
            } else if let lm = appDelegate?.locationManager, let auth = lm.auth, auth == .denied || auth == .notDetermined || auth == .restricted {
                menuItem.toolTip =
                    "Location can't be requested.\nCheck if Lunar has access to Location Services in System Preferences -> Security & Privacy"
                menuItem.attributedTitle = enabledString(menuItem, reason: "missing permissions")
            } else {
                menuItem.toolTip = nil
                menuItem.attributedTitle = enabledString(menuItem)
            }
        } else {
            menuItem.toolTip = nil
            menuItem.attributedTitle = enabledString(menuItem)
        }
        return true
    }

    func listenForAdaptiveModeChange() {
        adaptiveModeObserver = adaptiveModeObserver ?? adaptiveBrightnessModePublisher.sink { [weak self] change in
            mainAsync {
                guard let self, !self.pausedAdaptiveModeObserver else { return }
                self.pausedAdaptiveModeObserver = true
                Defaults.withoutPropagation { self.update(modeKey: change.newValue) }
                self.pausedAdaptiveModeObserver = false
            }
        }
    }

    func setAutoModeItemTitle(modeKey: AdaptiveModeKey? = nil, menuItem: NSMenuItem? = nil) {
        if CachedDefaults[.overrideAdaptiveMode] {
            if let item = menuItem ?? lastItem {
                item.attributedTitle = defaultAutoModeTitle
                    .withFont(.monospacedSystemFont(ofSize: 12, weight: .semibold))
                    .withTextColor(.labelColor)
            }
        } else {
            let modeKey = modeKey ?? DisplayController.getAdaptiveMode().key
            if let item = menuItem ?? lastItem {
                item.attributedTitle = defaultAutoModeTitle
                    .replacingOccurrences(of: "Auto Mode", with: "Auto: \(modeKey.str)")
                    .withFont(.monospacedSystemFont(ofSize: 12, weight: .semibold))
                    .withTextColor(.labelColor)
            }
        }
    }

    func update(modeKey: AdaptiveModeKey? = nil) {
        if CachedDefaults[.overrideAdaptiveMode] {
            selectItem(withTag: (modeKey ?? CachedDefaults[.adaptiveBrightnessMode]).rawValue)
        } else {
            selectItem(withTag: AUTO_MODE_TAG)
        }
        setAutoModeItemTitle(modeKey: modeKey)
        // fade(modeKey: modeKey)
    }

    func setup() {
        action = #selector(setAdaptiveMode(sender:))
        target = self
        listenForAdaptiveModeChange()
        radius = (frame.height / 2).ns

        for item in itemArray {
            item.attributedTitle = AdaptiveModeButton.enabledString(item)
        }
        update()
    }

    @IBAction func setAdaptiveMode(sender button: AdaptiveModeButton?) {
        guard let button else { return }
        if let mode = AdaptiveModeKey(rawValue: button.selectedTag()), mode != .auto {
            if !mode.available {
                log.warning("Mode \(mode) not available!")
                button
                    .selectItem(withTag: CachedDefaults[.overrideAdaptiveMode] ? DC.adaptiveModeKey.rawValue : AUTO_MODE_TAG)
            } else {
                log.debug("Changed mode to \(mode)")
                CachedDefaults[.overrideAdaptiveMode] = true
                CachedDefaults[.adaptiveBrightnessMode] = mode
            }
        } else if button.selectedTag() == AUTO_MODE_TAG {
            CachedDefaults[.overrideAdaptiveMode] = false

            let mode = DisplayController.getAdaptiveMode()
            log.debug("Changed mode to Auto: \(mode)")
            CachedDefaults[.adaptiveBrightnessMode] = mode.key
        }
        button.setAutoModeItemTitle()
        // button.fade(modeKey: AdaptiveModeKey(rawValue: button.selectedTag()))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.tag != AUTO_MODE_TAG else {
            setAutoModeItemTitle(menuItem: menuItem)
            return true
        }
        return AdaptiveModeButton.validate(menuItem)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}

extension NSParagraphStyle {
    static var centered: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }

    static var leftAligned: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        return p
    }

    static var rightAligned: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }
}
