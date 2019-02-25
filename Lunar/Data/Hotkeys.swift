//
//  Hotkeys.swift
//  Lunar
//
//  Created by Alin on 25/02/2019.
//  Copyright © 2019 Alin. All rights reserved.
//

import Carbon.HIToolbox
import Magnet

enum HotkeyIdentifier: String, CaseIterable {
    case toggle,
        start,
        pause,
        lunar,
        percent0,
        percent25,
        percent50,
        percent75,
        percent100,
        preciseBrightnessUp,
        preciseBrightnessDown,
        preciseContrastUp,
        preciseContrastDown,
        brightnessUp,
        brightnessDown,
        contrastUp,
        contrastDown
}

enum HotkeyPart: String, CaseIterable {
    case modifiers, keyCode, enabled
}

class Hotkey {
    static var keys: [HotkeyIdentifier: Magnet.HotKey?] = [:]

    static let defaults: [HotkeyIdentifier: [HotkeyPart: Int]] = [
        .toggle: [
            .enabled: 1,
            .keyCode: kVK_ANSI_L,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control]),
        ],
        .start: [
            .enabled: 1,
            .keyCode: kVK_ANSI_L,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control, .option]),
        ],
        .pause: [
            .enabled: 1,
            .keyCode: kVK_ANSI_L,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control, .option, .shift]),
        ],
        .lunar: [
            .enabled: 1,
            .keyCode: kVK_ANSI_L,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .option, .shift]),
        ],
        .percent0: [
            .enabled: 1,
            .keyCode: kVK_ANSI_0,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control]),
        ],
        .percent25: [
            .enabled: 1,
            .keyCode: kVK_ANSI_1,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control]),
        ],
        .percent50: [
            .enabled: 1,
            .keyCode: kVK_ANSI_2,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control]),
        ],
        .percent75: [
            .enabled: 1,
            .keyCode: kVK_ANSI_3,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control]),
        ],
        .percent100: [
            .enabled: 1,
            .keyCode: kVK_ANSI_4,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control]),
        ],
        .preciseBrightnessUp: [
            .enabled: 0,
            .keyCode: kVK_UpArrow,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control, .option]),
        ],
        .preciseBrightnessDown: [
            .enabled: 0,
            .keyCode: kVK_DownArrow,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control, .option]),
        ],
        .preciseContrastUp: [
            .enabled: 0,
            .keyCode: kVK_UpArrow,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control, .option, .shift]),
        ],
        .preciseContrastDown: [
            .enabled: 0,
            .keyCode: kVK_DownArrow,
            .modifiers: KeyTransformer.carbonFlags(from: [.command, .control, .option, .shift]),
        ],
        .brightnessUp: [
            .enabled: 1,
            .keyCode: kVK_F2,
            .modifiers: KeyTransformer.carbonFlags(from: [.control]),
        ],
        .brightnessDown: [
            .enabled: 1,
            .keyCode: kVK_F1,
            .modifiers: KeyTransformer.carbonFlags(from: [.control]),
        ],
        .contrastUp: [
            .enabled: 1,
            .keyCode: kVK_F2,
            .modifiers: KeyTransformer.carbonFlags(from: [.control, .shift]),
        ],
        .contrastDown: [
            .enabled: 1,
            .keyCode: kVK_F1,
            .modifiers: KeyTransformer.carbonFlags(from: [.control, .shift]),
        ],
    ]

    static var defaultHotkeys: NSDictionary = Hotkey.toNSDictionary(Hotkey.defaults)

    static func toNSDictionary(_ hotkeys: [HotkeyIdentifier: [HotkeyPart: Int]]) -> NSDictionary {
        let keyDict: NSMutableDictionary = [:]
        for (identifier, hotkey) in hotkeys {
            let key: NSMutableDictionary = [:]
            for (part, value) in hotkey {
                key[part.rawValue] = value
            }
            keyDict[identifier.rawValue] = key
        }
        return keyDict
    }

    static func handler(identifier: HotkeyIdentifier) -> Selector {
        switch identifier {
        case .toggle:
            return #selector(AppDelegate.toggleHotkeyHandler)
        case .start:
            return #selector(AppDelegate.startHotkeyHandler)
        case .pause:
            return #selector(AppDelegate.pauseHotkeyHandler)
        case .lunar:
            return #selector(AppDelegate.lunarHotkeyHandler)
        case .percent0:
            return #selector(AppDelegate.percent0HotkeyHandler)
        case .percent25:
            return #selector(AppDelegate.percent25HotkeyHandler)
        case .percent50:
            return #selector(AppDelegate.percent50HotkeyHandler)
        case .percent75:
            return #selector(AppDelegate.percent75HotkeyHandler)
        case .percent100:
            return #selector(AppDelegate.percent100HotkeyHandler)
        case .preciseBrightnessUp:
            return #selector(AppDelegate.preciseBrightnessUpHotkeyHandler)
        case .preciseBrightnessDown:
            return #selector(AppDelegate.preciseBrightnessDownHotkeyHandler)
        case .preciseContrastUp:
            return #selector(AppDelegate.preciseContrastUpHotkeyHandler)
        case .preciseContrastDown:
            return #selector(AppDelegate.preciseContrastDownHotkeyHandler)
        case .brightnessUp:
            return #selector(AppDelegate.brightnessUpHotkeyHandler)
        case .brightnessDown:
            return #selector(AppDelegate.brightnessDownHotkeyHandler)
        case .contrastUp:
            return #selector(AppDelegate.contrastUpHotkeyHandler)
        case .contrastDown:
            return #selector(AppDelegate.contrastDownHotkeyHandler)
        }
    }
}

extension AppDelegate {
    @objc func toggleHotkeyHandler() {
        brightnessAdapter.toggle()
        log.debug("Toggle Hotkey pressed")
    }

    @objc func pauseHotkeyHandler() {
        brightnessAdapter.disable()
        log.debug("Pause Hotkey pressed")
    }

    @objc func startHotkeyHandler() {
        brightnessAdapter.enable()
        log.debug("Start Hotkey pressed")
    }

    @objc func lunarHotkeyHandler() {
        showWindow()
        log.debug("Show Window Hotkey pressed")
    }

    @objc func percent0HotkeyHandler() {
        setLightPercent(percent: 0)
        log.debug("0% Hotkey pressed")
    }

    @objc func percent25HotkeyHandler() {
        setLightPercent(percent: 25)
        log.debug("25% Hotkey pressed")
    }

    @objc func percent50HotkeyHandler() {
        setLightPercent(percent: 50)
        log.debug("50% Hotkey pressed")
    }

    @objc func percent75HotkeyHandler() {
        setLightPercent(percent: 75)
        log.debug("75% Hotkey pressed")
    }

    @objc func percent100HotkeyHandler() {
        setLightPercent(percent: 100)
        log.debug("100% Hotkey pressed")
    }

    @objc func brightnessUpHotkeyHandler() {
        increaseBrightness()
    }

    @objc func brightnessDownHotkeyHandler() {
        decreaseBrightness()
    }

    @objc func contrastUpHotkeyHandler() {
        increaseContrast()
    }

    @objc func contrastDownHotkeyHandler() {
        decreaseContrast()
    }

    @objc func preciseBrightnessUpHotkeyHandler() {
        increaseBrightness(by: 1)
    }

    @objc func preciseBrightnessDownHotkeyHandler() {
        decreaseBrightness(by: 1)
    }

    @objc func preciseContrastUpHotkeyHandler() {
        increaseContrast(by: 1)
    }

    @objc func preciseContrastDownHotkeyHandler() {
        decreaseContrast(by: 1)
    }
}
