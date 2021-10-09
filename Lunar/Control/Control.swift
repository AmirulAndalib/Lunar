//
//  Control.swift
//  Lunar
//
//  Created by Alin Panaitiu on 18.02.2021.
//  Copyright © 2021 Alin. All rights reserved.
//

import ArgumentParser
import Foundation

// MARK: - PowerState

enum PowerState {
    case on
    case off
}

// MARK: - DisplayControl

enum DisplayControl: Int, Codable, EnumerableFlag {
    case network
    case coreDisplay
    case ddc
    case gamma
    case ddcctl

    // MARK: Lifecycle

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let strValue = try? container.decode(String.self) else {
            let intValue = try container.decode(Int.self)
            self = DisplayControl(rawValue: intValue) ?? .ddc
            return
        }

        self = DisplayControl.fromstr(strValue)
    }

    // MARK: Internal

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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(str)
    }
}

// MARK: - Control

protocol Control {
    var display: Display? { get set }
    var str: String { get }
    var displayControl: DisplayControl { get }

    func setBrightness(_ brightness: Brightness, oldValue: Brightness?, onChange: ((Brightness) -> Void)?) -> Bool
    func setContrast(_ contrast: Contrast, oldValue: Contrast?, onChange: ((Contrast) -> Void)?) -> Bool
    func setVolume(_ volume: UInt8) -> Bool
    func setInput(_ input: InputSource) -> Bool
    func setMute(_ muted: Bool) -> Bool
    func setPower(_ power: PowerState) -> Bool

    func setRedGain(_ gain: UInt8) -> Bool
    func setGreenGain(_ gain: UInt8) -> Bool
    func setBlueGain(_ gain: UInt8) -> Bool

    func getRedGain() -> UInt8?
    func getGreenGain() -> UInt8?
    func getBlueGain() -> UInt8?

    func getBrightness() -> Brightness?
    func getContrast() -> Contrast?
    func getVolume() -> UInt8?
    func getMute() -> Bool?
    func getInput() -> InputSource?

    func getMaxBrightness() -> Brightness?
    func getMaxContrast() -> Contrast?
    func getMaxVolume() -> UInt8?

    func reset() -> Bool
    func resetState()
    func resetColors() -> Bool

    func isAvailable() -> Bool
    func isResponsive() -> Bool
    func supportsSmoothTransition(for controlID: ControlID) -> Bool
}

extension Control {
    func reapply() {
        guard let display = display else { return }
        _ = setBrightness(display.limitedBrightness, oldValue: nil, onChange: nil)
        _ = setContrast(display.limitedContrast, oldValue: nil, onChange: nil)
    }

    func read(_ key: Display.CodingKeys) -> Any? {
        switch key {
        case .brightness:
            return getBrightness()
        case .contrast:
            return getContrast()
        case .maxBrightness, .maxDDCBrightness:
            return getMaxBrightness()
        case .maxContrast, .maxDDCContrast:
            return getMaxContrast()
        case .maxDDCVolume:
            return getMaxVolume()
        case .volume:
            return getVolume()
        case .input:
            return getInput()
        case .audioMuted:
            return getMute()
        case .redGain:
            return getRedGain()
        case .greenGain:
            return getGreenGain()
        case .blueGain:
            return getBlueGain()
        default:
            log.warning("\(key) is not readable")
            return nil
        }
    }

    @discardableResult func write(_ key: Display.CodingKeys, _ value: Any) -> Any? {
        switch key {
        case .brightness:
            return setBrightness(value as! Brightness, oldValue: nil, onChange: nil)
        case .contrast:
            return setContrast(value as! Contrast, oldValue: nil, onChange: nil)
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
