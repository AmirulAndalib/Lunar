//
//  Control.swift
//  Lunar
//
//  Created by Alin Panaitiu on 18.02.2021.
//  Copyright © 2021 Alin. All rights reserved.
//

import ArgumentParser
import Foundation

enum PowerState {
    case on
    case off
}

enum DisplayControl: Int, Codable, EnumerableFlag {
    case network
    case coreDisplay
    case ddc
    case gamma
    case ddcctl

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(str)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let strValue = try? container.decode(String.self) else {
            let intValue = try container.decode(Int.self)
            self = DisplayControl(rawValue: intValue) ?? .ddc
            return
        }

        self = DisplayControl.fromstr(strValue)
    }

    var str: String {
        switch self {
        case .network:
            return "Network"
        case .coreDisplay:
            return "CoreDisplay"
        case .ddc:
            return "DDC"
        case .gamma:
            return "Gamma"
        case .ddcctl:
            return "ddcctl"
        }
    }

    static func fromstr(_ strValue: String) -> Self {
        switch strValue.lowercased().stripped {
        case "network", DisplayControl.network.rawValue.s:
            return .network
        case "coredisplay", DisplayControl.coreDisplay.rawValue.s:
            return .coreDisplay
        case "ddc", DisplayControl.ddc.rawValue.s:
            return .ddc
        case "gamma", DisplayControl.gamma.rawValue.s:
            return .gamma
        case "ddcctl", DisplayControl.ddcctl.rawValue.s:
            return .ddcctl
        default:
            return .ddc
        }
    }
}

protocol Control {
    var display: Display! { get set }
    var str: String { get }
    var displayControl: DisplayControl { get }

    func setBrightness(_ brightness: Brightness, oldValue: Brightness?) -> Bool
    func setContrast(_ contrast: Contrast, oldValue: Brightness?) -> Bool
    func setVolume(_ volume: UInt8) -> Bool
    func setInput(_ input: InputSource) -> Bool
    func setMute(_ muted: Bool) -> Bool
    func setPower(_ power: PowerState) -> Bool

    func getBrightness() -> Brightness?
    func getContrast() -> Contrast?
    func getVolume() -> UInt8?
    func getMute() -> Bool?
    func getInput() -> InputSource?

    func getMaxBrightness() -> Brightness?
    func getMaxContrast() -> Contrast?

    func reset() -> Bool
    func resetState()

    func isAvailable() -> Bool
    func isResponsive() -> Bool
    func supportsSmoothTransition(for controlID: ControlID) -> Bool
}

extension Control {
    func reapply() {
        _ = setBrightness(display.brightness.uint8Value, oldValue: nil)
        _ = setContrast(display.contrast.uint8Value, oldValue: nil)
    }

    func read(_ key: Display.CodingKeys) -> Any? {
        switch key {
        case .brightness:
            return getBrightness()
        case .contrast:
            return getContrast()
        case .maxBrightness:
            return getMaxBrightness()
        case .maxContrast:
            return getMaxContrast()
        case .volume:
            return getVolume()
        case .input:
            return getInput()
        case .audioMuted:
            return getMute()
        default:
            log.warning("\(key) is not readable")
            return nil
        }
    }

    @discardableResult func write(_ key: Display.CodingKeys, _ value: Any) -> Any? {
        switch key {
        case .brightness:
            return setBrightness(value as! Brightness, oldValue: nil)
        case .contrast:
            return setContrast(value as! Contrast, oldValue: nil)
        case .volume:
            return setVolume(value as! UInt8)
        case .input:
            return setInput(value as! InputSource)
        case .audioMuted:
            return setMute(value as! Bool)
        case .power:
            return setPower(value as! PowerState)
        default:
            log.warning("\(key) is not writable")
            return nil
        }
    }
}
