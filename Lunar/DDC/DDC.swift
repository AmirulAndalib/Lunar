//
//  DDC.swift
//  Lunar
//
//  Created by Alin on 02/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import ArgumentParser
import Cocoa
import Combine
import CoreGraphics
import Foundation
import FuzzyMatcher
import Regex

let MAX_REQUESTS = 10
let MAX_READ_DURATION_MS = 1500
let MAX_WRITE_DURATION_MS = 2000
let MAX_READ_FAULTS = 10
let MAX_WRITE_FAULTS = 20

let DDC_MIN_REPLY_DELAY_AMD = 30_000_000
let DDC_MIN_REPLY_DELAY_INTEL = 1
let DDC_MIN_REPLY_DELAY_NVIDIA = 1

let DUMMY_VENDOR_ID: UInt32 = 0xF0F0

// MARK: - DDCReadResult

struct DDCReadResult: Encodable {
    enum CodingKeys: String, CodingKey {
        case controlID
        case maxValue
        case currentValue
    }

    var controlID: ControlID
    var maxValue: UInt16
    var currentValue: UInt16

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(controlID.rawValue, forKey: .controlID)
        try container.encode(maxValue, forKey: .maxValue)
        try container.encode(currentValue, forKey: .currentValue)
    }
}

// MARK: - EDIDTextType

enum EDIDTextType: UInt8 {
    case name = 0xFC
    case serial = 0xFF
}

// MARK: - VideoInputSource

enum VideoInputSource: UInt16, Sendable, CaseIterable, Nameable, CustomStringConvertible {
    case vga1 = 1
    case vga2 = 2
    case dvi1 = 3
    case dvi2 = 4
    case compositeVideo1 = 5
    case compositeVideo2 = 6
    case sVideo1 = 7
    case sVideo2 = 8
    case tuner1 = 9
    case tuner2 = 0x0A
    case tuner3 = 0x0B
    case componentVideoYPrPbYCrCb1 = 0x0C
    case componentVideoYPrPbYCrCb2 = 0x0D
    case componentVideoYPrPbYCrCb3 = 0x0E
    case displayPort1 = 0x0F
    case displayPort2 = 0x10
    case hdmi1 = 0x11
    case hdmi2 = 0x12
    case hdmi3 = 0x13
    case hdmi4 = 0x14
    case thunderbolt1 = 0x19
    case thunderbolt2 = 0x1B
    case thunderbolt3 = 0x1C
    case unknown = 0xF6

    case lgSpecificDisplayPort1 = 0xD0
    case lgSpecificDisplayPort2 = 0xD1
    case lgSpecificDisplayPort3 = 0xC0
    case lgSpecificDisplayPort4 = 0xC1
    case lgSpecificHdmi1 = 0x90
    case lgSpecificHdmi2 = 0x91
    case lgSpecificHdmi3 = 0x92
    case lgSpecificHdmi4 = 0x93
    case lgSpecificThunderbolt1 = 0xD2
    case lgSpecificThunderbolt2 = 0xD3
    case lgSpecificThunderbolt3 = 0xE0
    case lgSpecificThunderbolt4 = 0xE1

    case separator = 0x7FDF

    init?(stringValue: String) {
        switch #"[^\w\s]+"#.r!.replaceAll(in: stringValue.lowercased().stripped, with: "") {
        case "vga", "vga1": self = .vga1
        case "vga2": self = .vga2
        case "dvi", "dvi1": self = .dvi1
        case "dvi2": self = .dvi2
        case "composite", "compositevideo", "compositevideo1": self = .compositeVideo1
        case "compositevideo2": self = .compositeVideo2
        case "svideo", "svideo1": self = .sVideo1
        case "svideo2": self = .sVideo2
        case "tuner", "tuner1": self = .tuner1
        case "tuner2": self = .tuner2
        case "tuner3": self = .tuner3
        case "component", "componentvideo", "componentvideoyprpbycrcb", "componentvideoyprpbycrcb1": self = .componentVideoYPrPbYCrCb1
        case "componentvideoyprpbycrcb2": self = .componentVideoYPrPbYCrCb2
        case "componentvideoyprpbycrcb3": self = .componentVideoYPrPbYCrCb3
        case "dp", "minidp", "minidisplayport", "displayport", "dp1", "displayport1": self = .displayPort1
        case "dp2", "minidp2", "minidisplayport2", "displayport2": self = .displayPort2
        case "hdmi", "hdmi1": self = .hdmi1
        case "hdmi2": self = .hdmi2
        case "hdmi3": self = .hdmi3
        case "hdmi4": self = .hdmi4
        case "thunderbolt", "thunderbolt2", "usbc", "usbc2": self = .thunderbolt2
        case "thunderbolt1", "usbc1": self = .thunderbolt1
        case "thunderbolt3", "usbc3": self = .thunderbolt3
        case "lgdp", "lgminidp", "lgminidisplayport", "lgdisplayport", "lgdp1", "lgdisplayport1": self = .lgSpecificDisplayPort1
        case "lgdp2", "lgminidp2", "lgminidisplayport2", "lgdisplayport2": self = .lgSpecificDisplayPort2
        case "lgdp3", "lgminidp3", "lgminidisplayport3", "lgdisplayport3": self = .lgSpecificDisplayPort3
        case "lgdp4", "lgminidp4", "lgminidisplayport4", "lgdisplayport4": self = .lgSpecificDisplayPort4
        case "lghdmi", "lghdmi1": self = .lgSpecificHdmi1
        case "lghdmi2": self = .lgSpecificHdmi2
        case "lghdmi3": self = .lgSpecificHdmi3
        case "lghdmi4": self = .lgSpecificHdmi4
        case "lgthunderbolt2", "lgusbc2": self = .lgSpecificThunderbolt2
        case "lgthunderbolt1", "lgusbc1", "lgusbc", "lgthunderbolt": self = .lgSpecificThunderbolt1
        case "lgthunderbolt3", "lgusbc3": self = .lgSpecificThunderbolt3
        case "lgthunderbolt4", "lgusbc4": self = .lgSpecificThunderbolt4
        case "unknown": self = .unknown
        default:
            return nil
        }
    }

    static var mostUsed: [VideoInputSource] {
        [.thunderbolt1, .thunderbolt2, .thunderbolt3, .displayPort1, .displayPort2, .hdmi1, .hdmi2, .hdmi3, .hdmi4]
    }
    static var lgSpecific: [VideoInputSource] {
        [
            .lgSpecificThunderbolt1, .lgSpecificThunderbolt2, .lgSpecificThunderbolt3, .lgSpecificThunderbolt4,
            .lgSpecificDisplayPort1, .lgSpecificDisplayPort2, .lgSpecificDisplayPort3, .lgSpecificDisplayPort4,
            .lgSpecificHdmi1, .lgSpecificHdmi2, .lgSpecificHdmi3, .lgSpecificHdmi4,
        ]
    }

    static var leastUsed: [VideoInputSource] {
        [
            .vga1,
            .vga2,
            .dvi1,
            .dvi2,
            .compositeVideo1,
            .compositeVideo2,
            .sVideo1,
            .sVideo2,
            .tuner1,
            .tuner2,
            .tuner3,
            .componentVideoYPrPbYCrCb1,
            .componentVideoYPrPbYCrCb2,
            .componentVideoYPrPbYCrCb3,
        ]
    }

    var isSeparator: Bool { self == .separator }

    var isLGSpecific: Bool {
        switch self {
        case .lgSpecificDisplayPort1,
             .lgSpecificDisplayPort2,
             .lgSpecificDisplayPort3,
             .lgSpecificDisplayPort4,
             .lgSpecificHdmi1,
             .lgSpecificHdmi2,
             .lgSpecificHdmi3,
             .lgSpecificHdmi4,
             .lgSpecificThunderbolt1,
             .lgSpecificThunderbolt2,
             .lgSpecificThunderbolt3,
             .lgSpecificThunderbolt4:
            true
        default:
            false
        }
    }

    var description: String { displayName() }

    var name: String {
        get { displayName() }
        set {}
    }

    var image: String? {
        switch self {
        case .vga1, .vga2: "vga"
        case .dvi1, .dvi2: "dvi"
        case .compositeVideo1, .compositeVideo2: "composite"
        case .sVideo1, .sVideo2: "svideo"
        case .tuner1, .tuner2, .tuner3: "tuner"
        case .componentVideoYPrPbYCrCb1, .componentVideoYPrPbYCrCb2, .componentVideoYPrPbYCrCb3: "component"
        case .displayPort1, .displayPort2, .lgSpecificDisplayPort1, .lgSpecificDisplayPort2, .lgSpecificDisplayPort3, .lgSpecificDisplayPort4: "displayport"
        case .hdmi1, .hdmi2, .hdmi3, .hdmi4, .lgSpecificHdmi1, .lgSpecificHdmi2, .lgSpecificHdmi3, .lgSpecificHdmi4: "hdmi"
        case .thunderbolt1, .thunderbolt2, .thunderbolt3, .lgSpecificThunderbolt1, .lgSpecificThunderbolt2, .lgSpecificThunderbolt3, .lgSpecificThunderbolt4: "usbc"
        case .unknown: "input"
        case .separator: nil
        }
    }

    var tag: Int? { rawValue.i }
    var str: String { displayName() }
    var enabled: Bool { true }

    func displayName() -> String {
        switch self {
        case .vga1: "VGA 1"
        case .vga2: "VGA 2"
        case .dvi1: "DVI 1"
        case .dvi2: "DVI 2"
        case .compositeVideo1: "Composite video 1"
        case .compositeVideo2: "Composite video 2"
        case .sVideo1: "S-Video 1"
        case .sVideo2: "S-Video 2"
        case .tuner1: "Tuner 1"
        case .tuner2: "Tuner 2"
        case .tuner3: "Tuner 3"
        case .componentVideoYPrPbYCrCb1: "Component video (YPrPb/YCrCb) 1"
        case .componentVideoYPrPbYCrCb2: "Component video (YPrPb/YCrCb) 2"
        case .componentVideoYPrPbYCrCb3: "Component video (YPrPb/YCrCb) 3"
        case .displayPort1: "DisplayPort 1"
        case .displayPort2: "DisplayPort 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .hdmi3: "HDMI 3"
        case .hdmi4: "HDMI 4"
        case .thunderbolt1: "USB-C 1"
        case .thunderbolt2: "USB-C 2"
        case .thunderbolt3: "USB-C 3"

        case .lgSpecificDisplayPort1: "DisplayPort 1 (LG specific)"
        case .lgSpecificDisplayPort2: "DisplayPort 2 (LG specific)"
        case .lgSpecificDisplayPort3: "DisplayPort 3 (LG specific)"
        case .lgSpecificDisplayPort4: "DisplayPort 4 (LG specific)"
        case .lgSpecificHdmi1: "HDMI 1 (LG specific)"
        case .lgSpecificHdmi2: "HDMI 2 (LG specific)"
        case .lgSpecificHdmi3: "HDMI 3 (LG specific)"
        case .lgSpecificHdmi4: "HDMI 4 (LG specific)"
        case .lgSpecificThunderbolt1: "USB-C 1 (LG specific)"
        case .lgSpecificThunderbolt2: "USB-C 2 (LG specific)"
        case .lgSpecificThunderbolt3: "USB-C 3 (LG specific)"
        case .lgSpecificThunderbolt4: "USB-C 4 (LG specific)"

        case .unknown: "Unknown"
        case .separator: "------"
        }
    }
}

let inputSourceMapping: [String: VideoInputSource] = Dictionary(uniqueKeysWithValues: VideoInputSource.allCases.map { input in
    (input.displayName(), input)
})

// MARK: - ControlID

enum ControlID: UInt8, ExpressibleByArgument, CaseIterable {
    case DEGAUSS = 0x01
    case RESET = 0x04
    case RESET_BRIGHTNESS_AND_CONTRAST = 0x05
    case RESET_GEOMETRY = 0x06
    case RESET_COLOR = 0x08
    case RESTORE_FACTORY_TV_DEFAULTS = 0x0A
    case COLOR_TEMPERATURE_INCREMENT = 0x0B
    case COLOR_TEMPERATURE_REQUEST = 0x0C
    case CLOCK = 0x0E
    case BRIGHTNESS = 0x10
    case FLESH_TONE_ENHANCEMENT = 0x11
    case CONTRAST = 0x12
    case COLOR_PRESET_A = 0x14
    case RED_GAIN = 0x16
    case USER_VISION_COMPENSATION = 0x17
    case GREEN_GAIN = 0x18
    case BLUE_GAIN = 0x1A
    case FOCUS = 0x1C
    case AUTO_SIZE_CENTER = 0x1E
    case AUTO_COLOR_SETUP = 0x1F
    case HORIZONTAL_POSITION_PHASE = 0x20
    case WIDTH = 0x22
    case HORIZONTAL_PINCUSHION = 0x24
    case HORIZONTAL_PINCUSHION_BALANCE = 0x26
    case HORIZONTAL_STATIC_CONVERGENCE = 0x28
    case HORIZONTAL_CONVERGENCE_MG = 0x29
    case HORIZONTAL_LINEARITY = 0x2A
    case HORIZONTAL_LINEARITY_BALANCE = 0x2C
    case GREY_SCALE_EXPANSION = 0x2E
    case VERTICAL_POSITION_PHASE = 0x30
    case HEIGHT = 0x32
    case VERTICAL_PINCUSHION = 0x34
    case VERTICAL_PINCUSHION_BALANCE = 0x36
    case VERTICAL_STATIC_CONVERGENCE = 0x38
    case VERTICAL_LINEARITY = 0x3A
    case VERTICAL_LINEARITY_BALANCE = 0x3C
    case CLOCK_PHASE = 0x3E
    case HORIZONTAL_PARALLELOGRAM = 0x40
    case VERTICAL_PARALLELOGRAM = 0x41
    case HORIZONTAL_KEYSTONE = 0x42
    case VERTICAL_KEYSTONE = 0x43
    case VERTICAL_ROTATION = 0x44
    case TOP_PINCUSHION_AMP = 0x46
    case TOP_PINCUSHION_BALANCE = 0x48
    case BOTTOM_PINCUSHION_AMP = 0x4A
    case BOTTOM_PINCUSHION_BALANCE = 0x4C
    case ACTIVE_CONTROL = 0x52
    case PERFORMANCE_PRESERVATION = 0x54
    case HORIZONTAL_MOIRE = 0x56
    case VERTICAL_MOIRE = 0x58
    case RED_SATURATION = 0x59
    case YELLOW_SATURATION = 0x5A
    case GREEN_SATURATION = 0x5B
    case CYAN_SATURATION = 0x5C
    case BLUE_SATURATION = 0x5D
    case MAGENTA_SATURATION = 0x5E
    case INPUT_SOURCE = 0x60
    case AUDIO_SPEAKER_VOLUME = 0x62
    case AUDIO_SPEAKER_PAIR_SELECT = 0x63
    case AUDIO_MICROPHONE_VOLUME = 0x64
    case AUDIO_JACK_CONNECTION_STATUS = 0x65
    case BACKLIGHT_LEVEL_WHITE = 0x6B
    case RED_BLACK_LEVEL = 0x6C
    case BACKLIGHT_LEVEL_RED = 0x6D
    case GREEN_BLACK_LEVEL = 0x6E
    case BACKLIGHT_LEVEL_GREEN = 0x6F
    case BLUE_BLACK_LEVEL = 0x70
    case BACKLIGHT_LEVEL_BLUE = 0x71
    case GAMMA = 0x72
    case ADJUST_ZOOM = 0x7C
    case HORIZONTAL_MIRROR_FLIP = 0x82
    case VERTICAL_MIRROR_FLIP = 0x84
    case DISPLAY_SCALING = 0x86
    case VELOCITY_SCAN_MODULATION = 0x88
    case COLOR_SATURATION = 0x8A
    case TV_CHANNEL_UP_DOWN = 0x8B
    case TV_SHARPNESS = 0x8C
    case AUDIO_MUTE = 0x8D
    case TV_CONTRAST = 0x8E
    case AUDIO_TREBLE = 0x8F
    case HUE = 0x90
    case AUDIO_BASS = 0x91
    case TV_BLACK_LEVEL_LUMINANCE = 0x92
    case WINDOW_POSITION_TL_X = 0x95
    case WINDOW_POSITION_TL_Y = 0x96
    case WINDOW_POSITION_BR_X = 0x97
    case WINDOW_POSITION_BR_Y = 0x98
    case WINDOW_BACKGROUND = 0x9A
    case RED_HUE = 0x9B
    case YELLOW_HUE = 0x9C
    case GREEN_HUE = 0x9D
    case CYAN_HUE = 0x9E
    case BLUE_HUE = 0x9F
    case MAGENTA_HUE = 0xA0
    case AUTO_SETUP_ON_OFF = 0xA2
    case WINDOW_MASK_CONTROL = 0xA4
    case WINDOW_SELECT = 0xA5
    case ORIENTATION = 0xAA
    case STORE_RESTORE_SETTINGS = 0xB0
    case MONITOR_STATUS = 0xB7
    case PACKET_COUNT = 0xB8
    case MONITOR_X_ORIGIN = 0xB9
    case MONITOR_Y_ORIGIN = 0xBA
    case HEADER_ERROR_COUNT = 0xBB
    case BAD_CRC_ERROR_COUNT = 0xBC
    case CLIENT_ID = 0xBD
    case LINK_CONTROL = 0xBE
    case ON_SCREEN_DISPLAY = 0xCA
    case OSD_LANGUAGE = 0xCC
    case STEREO_VIDEO_MODE = 0xD4
    case DPMS = 0xD6
    case SCAN_MODE = 0xDA
    case IMAGE_MODE = 0xDB
    case COLOR_PRESET_B = 0xDC
    case VCP_VERSION = 0xDF
    case COLOR_PRESET_C = 0xE0
    case POWER_CONTROL = 0xE1

    case MANUFACTURER_SPECIFIC_E2 = 0xE2
    case MANUFACTURER_SPECIFIC_E3 = 0xE3
    case MANUFACTURER_SPECIFIC_E4 = 0xE4
    case MANUFACTURER_SPECIFIC_E5 = 0xE5
    case MANUFACTURER_SPECIFIC_E6 = 0xE6
    case MANUFACTURER_SPECIFIC_E7 = 0xE7
    case MANUFACTURER_SPECIFIC_E8 = 0xE8
    case MANUFACTURER_SPECIFIC_E9 = 0xE9
    case MANUFACTURER_SPECIFIC_EA = 0xEA
    case MANUFACTURER_SPECIFIC_EB = 0xEB
    case MANUFACTURER_SPECIFIC_EC = 0xEC
    case MANUFACTURER_SPECIFIC_ED = 0xED
    case MANUFACTURER_SPECIFIC_EE = 0xEE
    case MANUFACTURER_SPECIFIC_EF = 0xEF

    case MANUFACTURER_SPECIFIC_F1 = 0xF1
    case MANUFACTURER_SPECIFIC_F2 = 0xF2
    case MANUFACTURER_SPECIFIC_F3 = 0xF3
    case MANUFACTURER_SPECIFIC_F4 = 0xF4
    case MANUFACTURER_SPECIFIC_F5 = 0xF5
    case MANUFACTURER_SPECIFIC_F6 = 0xF6
    case MANUFACTURER_SPECIFIC_F7 = 0xF7
    case MANUFACTURER_SPECIFIC_F8 = 0xF8
    case MANUFACTURER_SPECIFIC_F9 = 0xF9
    case MANUFACTURER_SPECIFIC_FA = 0xFA
    case MANUFACTURER_SPECIFIC_FB = 0xFB
    case MANUFACTURER_SPECIFIC_FC = 0xFC
    case MANUFACTURER_SPECIFIC_FD = 0xFD
    case MANUFACTURER_SPECIFIC_FE = 0xFE
    case MANUFACTURER_SPECIFIC_FF = 0xFF

    init?(argument: String) {
        var arg = argument
        if arg.starts(with: "0x") {
            arg = String(arg.suffix(from: arg.index(arg.startIndex, offsetBy: 2)))
        }
        if arg.starts(with: "x") {
            arg = String(arg.suffix(from: arg.index(after: arg.startIndex)))
        }
        if arg.count <= 2 {
            guard let value = Int(arg, radix: 16),
                  let control = ControlID(rawValue: value.u8)
            else { return nil }
            self = control
            return
        }

        if let controlID = CONTROLS_BY_NAME[arg] {
            self = controlID
            return
        }

        let filter = arg.lowercased().stripped.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        switch filter {
        case "degauss": self = ControlID.DEGAUSS
        case "reset": self = ControlID.RESET
        case "reset brightness and contrast": self = ControlID.RESET_BRIGHTNESS_AND_CONTRAST
        case "reset geometry": self = ControlID.RESET_GEOMETRY
        case "reset color": self = ControlID.RESET_COLOR
        case "restore factory tv defaults": self = ControlID.RESTORE_FACTORY_TV_DEFAULTS
        case "color temperature increment": self = ControlID.COLOR_TEMPERATURE_INCREMENT
        case "color temperature request": self = ControlID.COLOR_TEMPERATURE_REQUEST
        case "clock": self = ControlID.CLOCK
        case "brightness": self = ControlID.BRIGHTNESS
        case "flesh tone enhancement": self = ControlID.FLESH_TONE_ENHANCEMENT
        case "contrast": self = ControlID.CONTRAST
        case "color preset a": self = ControlID.COLOR_PRESET_A
        case "red gain": self = ControlID.RED_GAIN
        case "user vision compensation": self = ControlID.USER_VISION_COMPENSATION
        case "green gain": self = ControlID.GREEN_GAIN
        case "blue gain": self = ControlID.BLUE_GAIN
        case "focus": self = ControlID.FOCUS
        case "auto size center": self = ControlID.AUTO_SIZE_CENTER
        case "auto color setup": self = ControlID.AUTO_COLOR_SETUP
        case "horizontal position phase": self = ControlID.HORIZONTAL_POSITION_PHASE
        case "width": self = ControlID.WIDTH
        case "horizontal pincushion": self = ControlID.HORIZONTAL_PINCUSHION
        case "horizontal pincushion balance": self = ControlID.HORIZONTAL_PINCUSHION_BALANCE
        case "horizontal static convergence": self = ControlID.HORIZONTAL_STATIC_CONVERGENCE
        case "horizontal convergence mg": self = ControlID.HORIZONTAL_CONVERGENCE_MG
        case "horizontal linearity": self = ControlID.HORIZONTAL_LINEARITY
        case "horizontal linearity balance": self = ControlID.HORIZONTAL_LINEARITY_BALANCE
        case "grey scale expansion": self = ControlID.GREY_SCALE_EXPANSION
        case "vertical position phase": self = ControlID.VERTICAL_POSITION_PHASE
        case "height": self = ControlID.HEIGHT
        case "vertical pincushion": self = ControlID.VERTICAL_PINCUSHION
        case "vertical pincushion balance": self = ControlID.VERTICAL_PINCUSHION_BALANCE
        case "vertical static convergence": self = ControlID.VERTICAL_STATIC_CONVERGENCE
        case "vertical linearity": self = ControlID.VERTICAL_LINEARITY
        case "vertical linearity balance": self = ControlID.VERTICAL_LINEARITY_BALANCE
        case "clock phase": self = ControlID.CLOCK_PHASE
        case "horizontal parallelogram": self = ControlID.HORIZONTAL_PARALLELOGRAM
        case "vertical parallelogram": self = ControlID.VERTICAL_PARALLELOGRAM
        case "horizontal keystone": self = ControlID.HORIZONTAL_KEYSTONE
        case "vertical keystone": self = ControlID.VERTICAL_KEYSTONE
        case "vertical rotation": self = ControlID.VERTICAL_ROTATION
        case "top pincushion amp": self = ControlID.TOP_PINCUSHION_AMP
        case "top pincushion balance": self = ControlID.TOP_PINCUSHION_BALANCE
        case "bottom pincushion amp": self = ControlID.BOTTOM_PINCUSHION_AMP
        case "bottom pincushion balance": self = ControlID.BOTTOM_PINCUSHION_BALANCE
        case "active control": self = ControlID.ACTIVE_CONTROL
        case "performance preservation": self = ControlID.PERFORMANCE_PRESERVATION
        case "horizontal moire": self = ControlID.HORIZONTAL_MOIRE
        case "vertical moire": self = ControlID.VERTICAL_MOIRE
        case "red saturation": self = ControlID.RED_SATURATION
        case "yellow saturation": self = ControlID.YELLOW_SATURATION
        case "green saturation": self = ControlID.GREEN_SATURATION
        case "cyan saturation": self = ControlID.CYAN_SATURATION
        case "blue saturation": self = ControlID.BLUE_SATURATION
        case "magenta saturation": self = ControlID.MAGENTA_SATURATION
        case "input source": self = ControlID.INPUT_SOURCE
        case "volume", "audio speaker volume": self = ControlID.AUDIO_SPEAKER_VOLUME
        case "audio speaker pair select": self = ControlID.AUDIO_SPEAKER_PAIR_SELECT
        case "audio microphone volume": self = ControlID.AUDIO_MICROPHONE_VOLUME
        case "audio jack connection status": self = ControlID.AUDIO_JACK_CONNECTION_STATUS
        case "backlight level white": self = ControlID.BACKLIGHT_LEVEL_WHITE
        case "red black level": self = ControlID.RED_BLACK_LEVEL
        case "backlight level red": self = ControlID.BACKLIGHT_LEVEL_RED
        case "green black level": self = ControlID.GREEN_BLACK_LEVEL
        case "backlight level green": self = ControlID.BACKLIGHT_LEVEL_GREEN
        case "blue black level": self = ControlID.BLUE_BLACK_LEVEL
        case "backlight level blue": self = ControlID.BACKLIGHT_LEVEL_BLUE
        case "gamma": self = ControlID.GAMMA
        case "adjust zoom": self = ControlID.ADJUST_ZOOM
        case "horizontal mirror flip": self = ControlID.HORIZONTAL_MIRROR_FLIP
        case "vertical mirror flip": self = ControlID.VERTICAL_MIRROR_FLIP
        case "display scaling": self = ControlID.DISPLAY_SCALING
        case "velocity scan modulation": self = ControlID.VELOCITY_SCAN_MODULATION
        case "color saturation": self = ControlID.COLOR_SATURATION
        case "tv channel up down": self = ControlID.TV_CHANNEL_UP_DOWN
        case "tv sharpness": self = ControlID.TV_SHARPNESS
        case "mute", "muted", "audio mute": self = ControlID.AUDIO_MUTE
        case "tv contrast": self = ControlID.TV_CONTRAST
        case "audio treble": self = ControlID.AUDIO_TREBLE
        case "hue": self = ControlID.HUE
        case "audio bass": self = ControlID.AUDIO_BASS
        case "tv black level luminance": self = ControlID.TV_BLACK_LEVEL_LUMINANCE
        case "window position tl x": self = ControlID.WINDOW_POSITION_TL_X
        case "window position tl y": self = ControlID.WINDOW_POSITION_TL_Y
        case "window position br x": self = ControlID.WINDOW_POSITION_BR_X
        case "window position br y": self = ControlID.WINDOW_POSITION_BR_Y
        case "window background": self = ControlID.WINDOW_BACKGROUND
        case "red hue": self = ControlID.RED_HUE
        case "yellow hue": self = ControlID.YELLOW_HUE
        case "green hue": self = ControlID.GREEN_HUE
        case "cyan hue": self = ControlID.CYAN_HUE
        case "blue hue": self = ControlID.BLUE_HUE
        case "magenta hue": self = ControlID.MAGENTA_HUE
        case "auto setup on off": self = ControlID.AUTO_SETUP_ON_OFF
        case "window mask control": self = ControlID.WINDOW_MASK_CONTROL
        case "window select": self = ControlID.WINDOW_SELECT
        case "orientation": self = ControlID.ORIENTATION
        case "store restore settings": self = ControlID.STORE_RESTORE_SETTINGS
        case "monitor status": self = ControlID.MONITOR_STATUS
        case "packet count": self = ControlID.PACKET_COUNT
        case "monitor x origin": self = ControlID.MONITOR_X_ORIGIN
        case "monitor y origin": self = ControlID.MONITOR_Y_ORIGIN
        case "header error count": self = ControlID.HEADER_ERROR_COUNT
        case "bad crc error count": self = ControlID.BAD_CRC_ERROR_COUNT
        case "client id": self = ControlID.CLIENT_ID
        case "link control": self = ControlID.LINK_CONTROL
        case "on screen display": self = ControlID.ON_SCREEN_DISPLAY
        case "osd language": self = ControlID.OSD_LANGUAGE
        case "stereo video mode": self = ControlID.STEREO_VIDEO_MODE
        case "dpms": self = ControlID.DPMS
        case "scan mode": self = ControlID.SCAN_MODE
        case "image mode": self = ControlID.IMAGE_MODE
        case "color preset b": self = ControlID.COLOR_PRESET_B
        case "vcp version": self = ControlID.VCP_VERSION
        case "color preset c": self = ControlID.COLOR_PRESET_C
        case "power control": self = ControlID.POWER_CONTROL
        default:
            guard let control = CONTROLS_BY_NAME.keys.map({ $0 }).fuzzyFind(arg),
                  let controlID = CONTROLS_BY_NAME[control]
            else {
                return nil
            }
            self = controlID
        }
    }

    static let reset: [ControlID] = [
        .RESET,
        .RESET_BRIGHTNESS_AND_CONTRAST,
        .RESET_GEOMETRY,
        .RESET_COLOR,
    ]
    static let common: [ControlID] = [
        .BRIGHTNESS,
        .CONTRAST,
        .AUDIO_SPEAKER_VOLUME,
        .AUDIO_MUTE,
        .DPMS,
        .INPUT_SOURCE,
        .RED_GAIN,
        .GREEN_GAIN,
        .BLUE_GAIN,
    ]

}

let CONTROLS_BY_NAME = [String: ControlID](uniqueKeysWithValues: ControlID.allCases.map { (String(describing: $0), $0) })
import Defaults

final class IOServicePropertyObserver {
    deinit {
        if notificationHandle != 0 {
            IOObjectRelease(notificationHandle)
        }
        if service != 0 {
            IOObjectRelease(service)
        }

        cancellable = nil
    }

    init(service: io_service_t, property: String, throttle: RunLoop.SchedulerTimeType.Stride? = nil, debounce: RunLoop.SchedulerTimeType.Stride? = nil, callback: @escaping () -> Void) {
        self.service = service
        self.callback = callback
        self.property = property

        if let debounce {
            cancellable = callbackSubject
                .debounce(for: debounce, scheduler: RunLoop.main)
                .sink { _ in
//                    #if DEBUG
//                        log.debug("Change in service observing '\(property)'")
//                    #endif
                    self.callback()
                }
        } else if let throttle {
            cancellable = callbackSubject
                .throttle(for: throttle, scheduler: RunLoop.main, latest: true)
                .sink { _ in
//                    #if DEBUG
//                        log.debug("Change in service observing '\(property)'")
//                    #endif
                    self.callback()
                }
        } else {
            cancellable = callbackSubject
                .sink { _ in
                    self.callback()
                }
        }

        guard let notifyPort = IONotificationPortCreate(kIOMasterPortDefault) else {
            #if DEBUG
                log.error("No notification port for service \(service): \(property)")
            #endif
            return
        }

        let observerCallback: IOServiceInterestCallback = { refcon, service, type, argument in
            guard let ctx = refcon else { return }
            let observer = Unmanaged<IOServicePropertyObserver>.fromOpaque(ctx).takeUnretainedValue()

            observer.callbackSubject.send(true)
        }

        self.notifyPort = notifyPort
        IONotificationPortSetDispatchQueue(notifyPort, .main)

        let ctx = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        let err = IOServiceAddInterestNotification(notifyPort, service, kIOGeneralInterest, observerCallback, ctx, &notificationHandle)

        #if DEBUG
            if err != KERN_SUCCESS {
                log.error("Error adding observer for service \(service): \(property)")
            }
        #endif
    }

    var notifyPort: IONotificationPortRef?
    var notificationHandle: io_object_t = 0
    var service: io_service_t = 0
    let property: String
    let callback: () -> Void

    let callbackSubject = PassthroughSubject<Bool, Never>()
    var cancellable: AnyCancellable?

}

// MARK: - IOServiceDetector

final class IOServiceDetector {
    init? (
        serviceName: String? = nil,
        serviceClass: String? = nil,
        events: [String] = [kIOFirstMatchNotification, kIOTerminatedNotification],
        callbackQueue: DispatchQueue = .main,
        callback: IOServiceCallback? = nil
    ) {
        guard serviceName != nil || serviceClass != nil else { return nil }
        self.serviceName = serviceName
        self.serviceClass = serviceClass
        self.callbackQueue = callbackQueue
        self.callback = callback
        self.events = events

        guard let notifyPort = IONotificationPortCreate(kIOMasterPortDefault) else {
            return nil
        }

        self.notifyPort = notifyPort
        IONotificationPortSetDispatchQueue(notifyPort, .main)
    }

    deinit {
        self.stopDetection()
    }

    typealias IOServiceCallback = (
        _ detector: IOServiceDetector,
        _ event: String,
        _ service: io_service_t
    ) -> Void

    let serviceName: String?
    let serviceClass: String?

    var callbackQueue: DispatchQueue?
    var callback: IOServiceCallback?
    var events: [String] = []
    var iterators: [io_iterator_t: String] = [:]

    func startDetection() -> Bool {
        guard iterators.isEmpty else { return true }

        let matchingDict =
            (serviceName != nil ? IOServiceNameMatching(serviceName!) : IOServiceMatching(serviceClass!)) as NSMutableDictionary

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        iterators = events.dict { event in
            let callback: IOServiceMatchingCallback = { userData, iterator in
                let detector = Unmanaged<IOServiceDetector>.fromOpaque(userData!).takeUnretainedValue()
                guard let event = detector.iterators[iterator] else {
                    return
                }
                detector.dispatchEvent(event: event, iterator: iterator)
            }

            var iterator: io_iterator_t = 0
            let addMatchError = IOServiceAddMatchingNotification(
                notifyPort, event,
                matchingDict, callback, selfPtr, &iterator
            )

            guard addMatchError == KERN_SUCCESS else {
                return nil
            }

            dispatchEvent(event: event, iterator: iterator)
            return (iterator, event)
        }

        return !iterators.isEmpty
    }

    func stopDetection() {
        guard !iterators.isEmpty else { return }

        iterators.keys.forEach {
            IOObjectRelease($0)
        }
        iterators = [:]
    }

    private let notifyPort: IONotificationPortRef

    private func dispatchEvent(
        event: String, iterator: io_iterator_t
    ) {
        repeat {
            let nextService = IOIteratorNext(iterator)
            guard nextService != 0 else { break }
            if let cb = callback, let q = callbackQueue {
                q.async {
                    cb(self, event, nextService)
                    IOObjectRelease(nextService)
                }
            } else {
                IOObjectRelease(nextService)
            }
        } while true
    }
}

// MARK: - DDC

let DDC = DDCActor.shared

@globalActor
actor DDCActor {
    static var shared = DDCActor()

    let queueKey = DispatchSpecificKey<String>()
//    let queue: DispatchQueue = {
//        let q = DispatchQueue(label: "DDC", qos: .userInteractive, autoreleaseFrequency: .workItem)
//        q.setSpecific(key: queueKey, value: "DDC")
//        return q
//    }()
    @Atomic static var apply = true
    @Atomic static var applyLimits = true
    let requestDelay: useconds_t = 20000
    let recoveryDelay: useconds_t = 40000
    var displayPortByUUID = [CFUUID: io_service_t]()
    var displayUUIDByEDID = [Data: CFUUID]()
    var skipReadingPropertyById = [CGDirectDisplayID: Set<ControlID>]()
    var skipWritingPropertyById = [CGDirectDisplayID: Set<ControlID>]()
    var readFaults: ThreadSafeDictionary<CGDirectDisplayID, ThreadSafeDictionary<ControlID, Int>> = ThreadSafeDictionary()
    var writeFaults: ThreadSafeDictionary<CGDirectDisplayID, ThreadSafeDictionary<ControlID, Int>> = ThreadSafeDictionary()
    let lock = NSRecursiveLock()

    @Atomic static var lastKnownBuiltinDisplayID: CGDirectDisplayID = GENERIC_DISPLAY_ID

    func extractSerialNumber(from edid: EDID, hex: Bool = false) -> String? {
        extractDescriptorText(from: edid, desType: EDIDTextType.serial, hex: hex)
    }

    // func sync<T>(barrier: Bool = false, _ action: () -> T) -> T {
    //     guard !Thread.isMainThread else {
    //         return action()
    //     }

    //     if let q = DispatchQueue.current, q == queue {
    //         return action()
    //     }
    //     if let q = DispatchQueue.getSpecific(key: queueKey), q == "DDC" {
    //         return action()
    //     }
    //     return queue.sync(flags: barrier ? [.barrier] : [], execute: action)
    // }

    #if arch(arm64)
        func hasAVService(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> Bool {
            AVService(displayID: displayID, ignoreCache: ignoreCache) != nil
        }

        func DCP(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> DCP? {
            // sync(barrier: true) {
            if !ignoreCache, let dcp = dcpMapping[displayID] {
                return dcp
            }

            dcpList = buildDCPList()

            return dcpMapping[displayID]
            // }
        }

        func AVService(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> IOAVService? {
            DCP(displayID: displayID, ignoreCache: ignoreCache)?.avService
        }

        var rebuildDCPTask: DispatchWorkItem? {
            didSet {
                oldValue?.cancel()
            }
        }
        func rebuildDCPList() {
            dcpList = buildDCPList()
//            rebuildDCPTask = asyncAfter(ms: 200) {
//                dcpList = buildDCPList()
//            }
        }
    #endif

    var i2cControllerCache: ThreadSafeDictionary<CGDirectDisplayID, io_service_t?> = ThreadSafeDictionary()

    var serviceDetectors = [IOServiceDetector]()
    var observers: Set<AnyCancellable> = []
    lazy var ioRegistryTreeChanged: PassthroughSubject<Bool, Never> = {
        let p = PassthroughSubject<Bool, Never>()

        p.debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in
                guard !DC.screensSleeping, !DC.locked else { return }
                log.debug("ioRegistryTreeChanged")
                self.IORegistryTreeChanged()
            }
            .store(in: &observers)

        return p
    }()

    lazy var waitAfterWakeSeconds: Int = {
        waitAfterWakeSecondsPublisher.debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { self.waitAfterWakeSeconds = $0.newValue }
            .store(in: &observers)

        return CachedDefaults[.waitAfterWakeSeconds]
    }()

    var delayDDCAfterWake: Bool = CachedDefaults[.delayDDCAfterWake]

    var shouldWait: Bool {
        delayDDCAfterWake && waitAfterWakeSeconds > 0 && wakeTime != startTime && timeSince(wakeTime) > waitAfterWakeSeconds.d
    }

//    @discardableResult
//    func asyncAfter(ms: Int, _ action: @escaping () -> Void) -> DispatchWorkItem {
//        let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1_000_000))
//
//        let workItem = DispatchWorkItem(name: "DDC Async After") {
//            action()
//        }
//        queue.asyncAfter(deadline: deadline, execute: workItem.workItem)
//
//        return workItem
//    }

    #if arch(arm64)
        var dcpList: [DCP] = buildDCPList() {
            didSet {
                dcpScores = buildDCPScoreMapping(dcpList: dcpList, displays: DC.externalHardwareActiveDisplays)
            }
        }
        lazy var dcpScores: [DCP: [CGDirectDisplayID: Int]] = buildDCPScoreMapping(dcpList: dcpList, displays: DC.externalHardwareActiveDisplays) {
            didSet {
                dcpMapping = matchDisplayToDCP(dcpScores: dcpScores)
            }
        }
        lazy var dcpMapping: [CGDirectDisplayID: DCP] = matchDisplayToDCP(dcpScores: dcpScores)
    #endif

    var lidClosedObserver: IOServicePropertyObserver?

    // var lidClosedNotifyPort: IONotificationPortRef?
    // var lidClosedNotificationHandle: io_object_t = 0

    func IORegistryTreeChanged() {
        #if DEBUG
            print("IORegistryTreeChanged")
        #endif

        // DDC.sync(barrier: true) {
        #if arch(arm64)
            dcpList = buildDCPList()
        #else
            i2cControllerCache.removeAll()
        #endif

        DC.activeDisplays.values.forEach { display in
            display.nsScreen = display.getScreen()
            display.detectI2C()
            display.startI2CDetection()
        }

        #if arch(arm64)
            mainAsync {
                DC.possiblyDisconnectedDisplays = DC.possiblyDisconnectedDisplayList.dict { d in
                    if d.isBuiltin, !DCPAVServiceExists(location: .embedded) { return (d.id, d) }

                    guard self.dcpList.contains(where: { $0.dcpName == d.dcpName }) else { return nil }
                    return (d.id, d)
                }

                if #available(macOS 13, *), IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("DCPAVServiceProxy")) == 0 {
                    log.info("Disabling AutoBlackOut (disconnect) if we're left with only the builtin screen")
                    DC.en()
                    DC.autoBlackoutPause = false
                }
            }
        #endif
        // }
    }

    func setup() {
        initFirstPhase()

        #if arch(arm64)
            log.debug("Adding IOKit notification for dispext")
            serviceDetectors += (["AppleCLCD2", "IOMobileFramebufferShim", "DCPAVServiceProxy"] + DISP_NAMES + DCP_NAMES)
                .compactMap { IOServiceDetector(serviceName: $0, callback: { _, _, _ in
                    self.ioRegistryTreeChanged.send(true)
                }) }
        #else
            log.debug("Adding IOKit notification for IOFRAMEBUFFER_CONFORMSTO")
            serviceDetectors += [IOFRAMEBUFFER_CONFORMSTO]
                .compactMap { IOServiceDetector(serviceClass: $0, callback: { _, _, _ in
                    self.ioRegistryTreeChanged.send(true)
                }) }
        #endif

        let rootDomain = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceNameMatching("IOPMrootDomain"))
        lidClosedObserver = IOServicePropertyObserver(service: rootDomain, property: "AppleClamshellState") {
            DC.lidClosed = isLidClosed()
        }

        serviceDetectors.forEach { _ = $0.startDetection() }
        addObservers()
        #if arch(arm64)
            dcpList = buildDCPList()
        #endif

    }
    func resetFaults(id: CGDirectDisplayID? = nil) {
        if let id {
            skipWritingPropertyById[id]?.removeAll()
            skipReadingPropertyById[id]?.removeAll()
            writeFaults[id]?.removeAll()
            readFaults[id]?.removeAll()
            mainActor {
                if let display = DC.activeDisplays[id] {
                    display.ddcBrightnessFailed = false
                    display.ddcVolumeFailed = false
                }
            }
        } else {
            skipWritingPropertyById.removeAll()
            skipReadingPropertyById.removeAll()
            writeFaults.removeAll()
            readFaults.removeAll()
            mainActor {
                DC.activeDisplayList.forEach { display in
                    display.ddcBrightnessFailed = false
                    display.ddcVolumeFailed = false
                }
            }
        }
    }
    func reset() {
        // sync(barrier: true) {
        displayPortByUUID.removeAll()
        displayUUIDByEDID.removeAll()
        skipReadingPropertyById.removeAll()
        skipWritingPropertyById.removeAll()
        readFaults.removeAll()
        writeFaults.removeAll()
        #if arch(arm64)
            dcpList = buildDCPList()
        #else
            i2cControllerCache.removeAll()
        #endif
        mainActor {
            DC.activeDisplayList.forEach { display in
                display.ddcBrightnessFailed = false
                display.ddcVolumeFailed = false
            }
        }
        // }
    }

    static func findExternalDisplays(
        includeVirtual: Bool = true,
        includeAirplay: Bool = false,
        includeProjector: Bool = false,
        includeDummy: Bool = false
    ) -> [CGDirectDisplayID] {
        var displayIDs = NSScreen.onlineDisplayIDs.filter { id in
            let name = Display.printableName(id)
            return !Self.isBuiltinDisplay(id) &&
                (includeVirtual || !Self.isVirtualDisplay(id, name: name)) &&
                (includeProjector || !Self.isProjectorDisplay(id, name: name)) &&
                (includeDummy || !Self.isDummyDisplay(id, name: name)) &&
                (includeAirplay || !(Self.isSidecarDisplay(id, name: name) || Self.isAirplayDisplay(id, name: name)))
        }

        #if DEBUG
//            return displayIDs
            if !displayIDs.isEmpty {
                // displayIDs.append(TEST_DISPLAY_PERSISTENT_ID)
                return displayIDs
            }
            return [
                // TEST_DISPLAY_ID,
                TEST_DISPLAY_PERSISTENT_ID,
                TEST_DISPLAY_PERSISTENT2_ID,
                TEST_DISPLAY_PERSISTENT3_ID,
                // TEST_DISPLAY_PERSISTENT4_ID,
            ]
        #else
            return displayIDs
        #endif
    }

    static func isProjectorDisplay(_ id: CGDirectDisplayID, name: String? = nil, checkName: Bool = true) -> Bool {
        guard !isGeneric(id) else {
            return false
        }

        var result = false
        let realName = (name ?? Display.printableName(id)).lowercased()
        if let panel = DisplayController.panel(with: id), panel.isProjector, !realName.contains("vx2453") {
            result = true
        }

        if checkName {
            result = result && (
                realName.contains("crestron") ||
                    realName.contains("optoma") ||
                    realName.contains("epson") ||
                    realName.contains("projector")
            )
        }

        return result
    }

    static func isDummyDisplay(_ id: CGDirectDisplayID, name: String? = nil) -> Bool {
        guard !isGeneric(id) else {
            return false
        }

        let realName = (name ?? Display.printableName(id)).lowercased()
        let vendorID = CGDisplayVendorNumber(id)
        return (realName =~ Display.dummyNamePattern || vendorID == DUMMY_VENDOR_ID) && vendorID != Display.Vendor.samsung.rawValue
            .u32 && realName !~ Display.notDummyNamePattern
    }

    static func isFakeDummyDisplay(_ id: CGDirectDisplayID, name: String? = nil) -> Bool {
        guard !isGeneric(id) else {
            return false
        }

        let realName = (name ?? Display.printableName(id)).lowercased()
        let vendorID = CGDisplayVendorNumber(id)
        return realName =~ Display.notDummyNamePattern && vendorID == DUMMY_VENDOR_ID
    }

    static func isVirtualDisplay(_ id: CGDirectDisplayID, name: String? = nil, checkName: Bool = true) -> Bool {
        var result = false
        guard !isGeneric(id) else {
            return result
        }

        if checkName {
            let realName = (name ?? Display.printableName(id)).lowercased()
            result = realName.contains("virtual") || realName.contains("displaylink") || realName.contains("luna display")
        }

        guard let infoDictionary = displayInfoDictionary(id) else {
            log.debug("No info dict for id \(id)")
            return result
        }

        let isVirtualDevice = infoDictionary["kCGDisplayIsVirtualDevice"] as? Bool

        return isVirtualDevice ?? result
    }

    static func isAirplayDisplay(_ id: CGDirectDisplayID, name: String? = nil, checkName: Bool = true) -> Bool {
        var result = false
        guard !isGeneric(id) else {
            return result
        }

        if let panel = DisplayController.panel(with: id), panel.isAirPlayDisplay {
            return true
        }

        if checkName {
            let realName = (name ?? Display.printableName(id)).lowercased()
            result = realName.contains("airplay")
        }

        guard !result else { return result }
        guard let infoDictionary = displayInfoDictionary(id) else {
            log.debug("No info dict for id \(id)")
            return result
        }

        return (infoDictionary["kCGDisplayIsAirPlay"] as? Bool) ?? false
    }

    static func isSidecarDisplay(_ id: CGDirectDisplayID, name: String? = nil, checkName: Bool = true) -> Bool {
        guard !isGeneric(id) else {
            return false
        }

        if let panel = DisplayController.panel(with: id), panel.isSidecarDisplay {
            return true
        }

        guard checkName else { return false }
        let realName = (name ?? Display.printableName(id)).lowercased()
        return realName.contains("sidecar") || realName.contains("ipad")
    }

    static func isSmartBuiltinDisplay(_ id: CGDirectDisplayID, checkName: Bool = true) -> Bool {
        isBuiltinDisplay(id, checkName: checkName) && DisplayServicesIsSmartDisplay(id)
    }

    static func isBuiltinDisplay(_ id: CGDirectDisplayID, checkName: Bool = true) -> Bool {
        guard !isGeneric(id) else { return false }
        if let panel = DisplayController.panel(with: id) {
            return panel.isBuiltIn || panel.isBuiltInRetina
        }
        return
            CGDisplayIsBuiltin(id) == 1 ||
            id == lastKnownBuiltinDisplayID ||
            (
                checkName && Display
                    .printableName(id).stripped
                    .lowercased().replacingOccurrences(of: "-", with: "")
                    .contains("builtin")
            )

    }

    func write(displayID: CGDirectDisplayID, controlID: ControlID, newValue: UInt16, sourceAddr: UInt8? = nil) -> Bool {
        guard DDCActor.apply, !shouldWait, !DC.screensSleeping, !DC.locked else { return true }

        #if arch(arm64)
            guard let dcp = DCP(displayID: displayID) else { return false }
        #else
            guard let fb = I2CController(displayID: displayID) else { return false }
        #endif

        // return sync(barrier: true) {
        if let propertiesToSkip = skipWritingPropertyById[displayID], propertiesToSkip.contains(controlID) {
            log.debug("Skipping write for \(controlID)", context: displayID)
            return false
        }

        var localControlID = controlID
        var localSourceAddr = sourceAddr ?? 0x51
        if controlID == .INPUT_SOURCE, let input = VideoInputSource(rawValue: newValue), input.isLGSpecific, sourceAddr == nil {
            localSourceAddr = 0x50
            localControlID = .MANUFACTURER_SPECIFIC_F4
        }

        var command = DDCWriteCommand(
            control_id: localControlID.rawValue,
            new_value: newValue
        )

        let writeStartedAt = DispatchTime.now()

        #if arch(arm64)
            let result = DDCWrite(avService: dcp.avService, command: &command, displayID: displayID, isMCDP: dcp.isMCDP, sourceAddr: localSourceAddr)
        #else
            let result = DDCWrite(fb: fb, command: &command, sourceAddr: localSourceAddr)
        #endif

        let writeNs = DispatchTime.now().rawValue - writeStartedAt.rawValue
        let writeMs = writeNs / 1_000_000
        if writeMs > MAX_WRITE_DURATION_MS {
            log.debug("Writing \(controlID) took too long: \(writeMs)ms", context: displayID)
            writeFault(severity: 4, displayID: displayID, controlID: controlID)
        }

        guard result else {
            log.debug("Error writing \(controlID)", context: displayID)
            writeFault(severity: 1, displayID: displayID, controlID: controlID)
            return false
        }

        if writeNs > 0 {
            DC.averageDDCWriteNanoseconds(for: displayID, ns: writeNs)
        }
        if let display = DC.displays[displayID], !display.responsiveDDC {
            display.responsiveDDC = true
        }

        if let propertyFaults = writeFaults[displayID], let faults = propertyFaults[controlID] {
            writeFaults[displayID]![controlID] = max(faults - 1, 0)
        }

        return result
        // }
    }

    func readFault(severity: Int, displayID: CGDirectDisplayID, controlID: ControlID) {
        guard let propertyFaults = readFaults[displayID] else {
            readFaults[displayID] = ThreadSafeDictionary(dict: [controlID: severity])
            return
        }
        guard var faults = propertyFaults[controlID] else {
            readFaults[displayID]![controlID] = severity
            return
        }
        faults = min(severity + faults, MAX_READ_FAULTS + 1)
        readFaults[displayID]![controlID] = faults

        if faults > MAX_READ_FAULTS {
            skipReadingProperty(displayID: displayID, controlID: controlID)
        }
    }

    func writeFault(severity: Int, displayID: CGDirectDisplayID, controlID: ControlID) {
        guard let propertyFaults = writeFaults[displayID] else {
            writeFaults[displayID] = ThreadSafeDictionary(dict: [controlID: severity])
            return
        }
        guard var faults = propertyFaults[controlID] else {
            writeFaults[displayID]![controlID] = severity
            return
        }
        faults = min(severity + faults, MAX_WRITE_FAULTS + 1)
        writeFaults[displayID]![controlID] = faults

        if faults > MAX_WRITE_FAULTS {
            skipWritingProperty(displayID: displayID, controlID: controlID)
        }
    }

    func skipReadingProperty(displayID: CGDirectDisplayID, controlID: ControlID) {
        if var propertiesToSkip = skipReadingPropertyById[displayID] {
            propertiesToSkip.insert(controlID)
            skipReadingPropertyById[displayID] = propertiesToSkip
        } else {
            skipReadingPropertyById[displayID] = Set([controlID])
        }
    }

    func skipWritingProperty(displayID: CGDirectDisplayID, controlID: ControlID) {
        if var propertiesToSkip = skipWritingPropertyById[displayID] {
            propertiesToSkip.insert(controlID)
            skipWritingPropertyById[displayID] = propertiesToSkip
        } else {
            skipWritingPropertyById[displayID] = Set([controlID])
        }
        if controlID == ControlID.BRIGHTNESS, CachedDefaults[.detectResponsiveness] {
            mainAsyncAfter(ms: 100) {
                #if DEBUG
                    DC.displays[displayID]?.responsiveDDC = TEST_IDS.contains(displayID)
                #else
                    DC.displays[displayID]?.responsiveDDC = false
                #endif
            }
        }
        mainActor {
            switch controlID {
            case .BRIGHTNESS:
                DC.activeDisplays[displayID]?.ddcBrightnessFailed = true
            case .AUDIO_SPEAKER_VOLUME:
                DC.activeDisplays[displayID]?.ddcVolumeFailed = true
            default:
                break
            }
        }
    }

    func read(displayID: CGDirectDisplayID, controlID: ControlID) -> DDCReadResult? {
        guard !shouldWait, !DC.screensSleeping, !DC.locked else { return nil }

        #if arch(arm64)
            guard let dcp = DCP(displayID: displayID) else { return nil }
        #else
            guard let fb = I2CController(displayID: displayID) else { return nil }
        #endif

        // return sync(barrier: true) {
        if let propertiesToSkip = skipReadingPropertyById[displayID], propertiesToSkip.contains(controlID) {
            log.debug("Skipping read for \(controlID)", context: displayID)
            return nil
        }

        var command = DDCReadCommand(
            control_id: controlID.rawValue,
            success: false,
            max_value: 0,
            current_value: 0
        )

        let readStartedAt = DispatchTime.now()

        #if arch(arm64)
            _ = DDCRead(avService: dcp.avService, command: &command, displayID: displayID, isMCDP: dcp.isMCDP)
        #else
            _ = DDCRead(fb: fb, command: &command)
        #endif

        let readNs = DispatchTime.now().rawValue - readStartedAt.rawValue
        let readMs = readNs / 1_000_000
        if readMs > MAX_READ_DURATION_MS {
            log.debug("Reading \(controlID) took too long: \(readMs)ms", context: displayID)
            readFault(severity: 4, displayID: displayID, controlID: controlID)
        }

        guard command.success else {
            log.debug("Error reading \(controlID)", context: displayID)
            readFault(severity: 1, displayID: displayID, controlID: controlID)

            return nil
        }

        if readNs > 0 {
            DC.averageDDCReadNanoseconds(for: displayID, ns: readNs)
        }
        if let display = DC.displays[displayID], !display.responsiveDDC {
            display.responsiveDDC = true
        }

        if let propertyFaults = readFaults[displayID], let faults = propertyFaults[controlID] {
            readFaults[displayID]![controlID] = max(faults - 1, 0)
        }

        return DDCReadResult(
            controlID: controlID,
            maxValue: command.max_value,
            currentValue: command.current_value
        )
        // }
    }

    func sendEdidRequest(displayID: CGDirectDisplayID) -> (EDID, Data)? {
        guard !DC.screensSleeping, !DC.locked else { return nil }

        #if arch(arm64)
            guard let avService = AVService(displayID: displayID) else { return nil }
        #else
            guard let fb = I2CController(displayID: displayID) else { return nil }
        #endif

        // return sync(barrier: true) {
        var edidData = [UInt8](repeating: 0, count: 256)
        var edid = EDID()

        #if arch(arm64)
            _ = EDIDTest(avService: avService, edid: &edid, data: &edidData)
        #else
            _ = EDIDTest(fb: fb, edid: &edid, data: &edidData)
        #endif

        return (edid, Data(bytes: &edidData, count: 256))
        // }
    }

    func getEdid(displayID: CGDirectDisplayID) -> EDID? {
        guard let (edid, _) = sendEdidRequest(displayID: displayID) else {
            return nil
        }
        return edid
    }

    func getEdidData(displayID: CGDirectDisplayID) -> Data? {
        guard let (_, data) = sendEdidRequest(displayID: displayID) else {
            return nil
        }
        return data
    }

    func getEdidData() -> [Data] {
        var result = [Data]()
        var object: io_object_t
        var serialPortIterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")

        let kernResult = IOServiceGetMatchingServices(
            kIOMasterPortDefault,
            matching,
            &serialPortIterator
        )
        if KERN_SUCCESS == kernResult, serialPortIterator != 0 {
            repeat {
                object = IOIteratorNext(serialPortIterator)
                let infoDict = IODisplayCreateInfoDictionary(
                    object, kIODisplayOnlyPreferredName.u32
                ).takeRetainedValue()
                let info = infoDict as NSDictionary as? [String: AnyObject]

                if let info, let displayEDID = info[kIODisplayEDIDKey] as? Data {
                    result.append(displayEDID)
                }

            } while object != 0
        }
        IOObjectRelease(serialPortIterator)

        return result
    }

    func getDisplayIdentificationData(displayID: CGDirectDisplayID) -> String {
        guard let edid = getEdid(displayID: displayID) else {
            return ""
        }
        return "\(edid.eisaid.str())-\(edid.productcode.str())-\(edid.serial.str()) \(edid.week.str())/\(edid.year.str()) \(edid.versionmajor.str()).\(edid.versionminor.str())"
    }

    func getTextData(_ descriptor: descriptor, hex: Bool = false) -> String? {
        let tmp = descriptor.text.data
        let nameChars = [
            tmp.0, tmp.1, tmp.2, tmp.3,
            tmp.4, tmp.5, tmp.6, tmp.7,
            tmp.8, tmp.9, tmp.10, tmp.11,
            tmp.12,
        ]
        if let name = NSString(bytes: nameChars, length: 13, encoding: String.Encoding.nonLossyASCII.rawValue) as String? {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if hex {
            let hexData = nameChars.map { String(format: "%02x", $0) }.joined(separator: " ")
            return hexData.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func extractDescriptorText(from edid: EDID, desType: EDIDTextType, hex: Bool = false) -> String? {
        switch desType.rawValue {
        case edid.descriptors.0.text.type:
            getTextData(edid.descriptors.0, hex: hex)
        case edid.descriptors.1.text.type:
            getTextData(edid.descriptors.1, hex: hex)
        case edid.descriptors.2.text.type:
            getTextData(edid.descriptors.2, hex: hex)
        case edid.descriptors.3.text.type:
            getTextData(edid.descriptors.3, hex: hex)
        default:
            nil
        }
    }

    func addObservers() {
        delayDDCAfterWake = CachedDefaults[.delayDDCAfterWake]
        delayDDCAfterWakePublisher.debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { change in
                self.delayDDCAfterWake = change.newValue

                guard change.newValue else {
                    if let oldVal = CachedDefaults[.oldReapplyValuesAfterWake] { CachedDefaults[.reapplyValuesAfterWake] = oldVal }
                    if let oldVal = CachedDefaults[.oldBrightnessTransition] { CachedDefaults[.brightnessTransition] = oldVal }
                    if let oldVal = CachedDefaults[.oldDetectResponsiveness] { CachedDefaults[.detectResponsiveness] = oldVal }
                    return
                }

                CachedDefaults[.oldReapplyValuesAfterWake] = CachedDefaults[.reapplyValuesAfterWake]
                CachedDefaults[.oldBrightnessTransition] = CachedDefaults[.brightnessTransition]
                CachedDefaults[.oldDetectResponsiveness] = CachedDefaults[.detectResponsiveness]

                CachedDefaults[.detectResponsiveness] = false
                CachedDefaults[.reapplyValuesAfterWake] = false
                CachedDefaults[.brightnessTransition] = .instant

                DC.displays.values.forEach { d in
                    d.reapplyColorGain = false
                }
            }
            .store(in: &observers)
    }

    func extractName(from edid: EDID, hex: Bool = false) -> String? {
        extractDescriptorText(from: edid, desType: EDIDTextType.name, hex: hex)
    }

    func hasI2CController(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> Bool {
        I2CController(displayID: displayID, ignoreCache: ignoreCache) != nil
    }

    func I2CController(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> io_service_t? {
        // sync(barrier: true) {
        if !ignoreCache, let controllerTemp = i2cControllerCache[displayID], let controller = controllerTemp {
            return controller
        }
        let controller = I2CController(displayID)
        i2cControllerCache[displayID] = controller
        return controller
        // }
    }

    func I2CController(_ displayID: CGDirectDisplayID) -> io_service_t? {
        let activeIDs = NSScreen.onlineDisplayIDs

        #if !DEBUG
            guard activeIDs.contains(displayID) else { return nil }
        #endif

        var fb = IOFramebufferPortFromCGSServiceForDisplayNumber(displayID)
        if fb != 0 {
            log.verbose("Got framebuffer using private CGSServiceForDisplayNumber: \(fb)", context: ["id": displayID])
            return fb
        }
        log.verbose(
            "CGSServiceForDisplayNumber returned invalid framebuffer, trying CGDisplayIOServicePort",
            context: ["id": displayID]
        )

        fb = IOFramebufferPortFromCGDisplayIOServicePort(displayID)
        if fb != 0 {
            log.verbose("Got framebuffer using private CGDisplayIOServicePort: \(fb)", context: ["id": displayID])
            return fb
        }
        log.verbose(
            "CGDisplayIOServicePort returned invalid framebuffer, trying manual search in IOKit registry",
            context: ["id": displayID]
        )

        let displayUUIDByEDIDCopy = displayUUIDByEDID
        let nsDisplayUUIDByEDID = NSMutableDictionary(dictionary: displayUUIDByEDIDCopy)
        fb = IOFramebufferPortFromCGDisplayID(displayID, nsDisplayUUIDByEDID as CFMutableDictionary)

        guard fb != 0 else {
            log.verbose(
                "IOFramebufferPortFromCGDisplayID returned invalid framebuffer. This display can't be controlled through DDC.",
                context: ["id": displayID]
            )
            return nil
        }

        displayUUIDByEDID.removeAll()
        for (key, value) in nsDisplayUUIDByEDID {
            if CFGetTypeID(key as CFTypeRef) == CFDataGetTypeID(), CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
                displayUUIDByEDID[key as! CFData as NSData as Data] = (value as! CFUUID)
            }
        }

        log.verbose("Got framebuffer using IOFramebufferPortFromCGDisplayID: \(fb)", context: ["id": displayID])
        return fb
    }

    func getDisplayName(for displayID: CGDirectDisplayID) -> String? {
        guard let edid = getEdid(displayID: displayID) else {
            return nil
        }
        return extractName(from: edid)
    }

    func getDisplaySerial(for displayID: CGDirectDisplayID) -> String? {
        guard let edid = getEdid(displayID: displayID) else {
            return nil
        }

        let serialNumber = extractSerialNumber(from: edid) ?? "NO_SERIAL"
        let name = extractName(from: edid) ?? "NO_NAME"
        return "\(name)-\(serialNumber)-\(edid.serial)-\(edid.productcode)-\(edid.year)-\(edid.week)"
    }

    func getDisplaySerialAndName(for displayID: CGDirectDisplayID) -> (String?, String?) {
        guard let edid = getEdid(displayID: displayID) else {
            return (nil, nil)
        }

        let serialNumber = extractSerialNumber(from: edid) ?? "NO_SERIAL"
        let name = extractName(from: edid) ?? "NO_NAME"
        return ("\(name)-\(serialNumber)-\(edid.serial)-\(edid.productcode)-\(edid.year)-\(edid.week)", name)
    }

    func setInput(for displayID: CGDirectDisplayID, input: VideoInputSource) -> Bool {
        if input == .unknown {
            return false
        }
        return write(displayID: displayID, controlID: ControlID.INPUT_SOURCE, newValue: input.rawValue)
    }

    func readInput(for displayID: CGDirectDisplayID) -> DDCReadResult? {
        read(displayID: displayID, controlID: ControlID.INPUT_SOURCE)
    }

    func setBrightness(for displayID: CGDirectDisplayID, brightness: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.BRIGHTNESS, newValue: brightness)
    }

    func readBrightness(for displayID: CGDirectDisplayID) -> DDCReadResult? {
        read(displayID: displayID, controlID: ControlID.BRIGHTNESS)
    }

    func readContrast(for displayID: CGDirectDisplayID) -> DDCReadResult? {
        read(displayID: displayID, controlID: ControlID.CONTRAST)
    }

    func setContrast(for displayID: CGDirectDisplayID, contrast: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.CONTRAST, newValue: contrast)
    }

    func setRedGain(for displayID: CGDirectDisplayID, redGain: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.RED_GAIN, newValue: redGain)
    }

    func setGreenGain(for displayID: CGDirectDisplayID, greenGain: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.GREEN_GAIN, newValue: greenGain)
    }

    func setBlueGain(for displayID: CGDirectDisplayID, blueGain: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.BLUE_GAIN, newValue: blueGain)
    }

    func setAudioSpeakerVolume(for displayID: CGDirectDisplayID, audioSpeakerVolume: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.AUDIO_SPEAKER_VOLUME, newValue: audioSpeakerVolume)
    }

    func setAudioMuted(for displayID: CGDirectDisplayID, audioMuted: Bool) -> Bool {
        write(displayID: displayID, controlID: ControlID.AUDIO_MUTE, newValue: audioMuted ? 1 : 2)
    }

    func setPower(for displayID: CGDirectDisplayID, power: Bool) -> Bool {
        write(displayID: displayID, controlID: ControlID.DPMS, newValue: power ? 1 : 5)
    }

    func reset(displayID: CGDirectDisplayID) -> Bool {
        write(displayID: displayID, controlID: ControlID.RESET, newValue: 100)
    }

    func getValue(for displayID: CGDirectDisplayID, controlID: ControlID) -> UInt16? {
        log.debug("DDC reading \(controlID) for \(displayID)")

        guard let result = read(displayID: displayID, controlID: controlID) else {
            #if DEBUG
                log.debug("DDC read \(controlID) nil for \(displayID)")
            #endif
            return nil
        }
        #if DEBUG
            log.debug("DDC read \(controlID) \(result.currentValue) for \(displayID)")
        #endif
        return result.currentValue
    }

    func getMaxValue(for displayID: CGDirectDisplayID, controlID: ControlID) -> UInt16? {
        guard let result = read(displayID: displayID, controlID: controlID) else {
            return nil
        }
        return result.maxValue
    }

    func getRedGain(for displayID: CGDirectDisplayID) -> UInt16? {
        getValue(for: displayID, controlID: ControlID.RED_GAIN)
    }

    func getGreenGain(for displayID: CGDirectDisplayID) -> UInt16? {
        getValue(for: displayID, controlID: ControlID.GREEN_GAIN)
    }

    func getBlueGain(for displayID: CGDirectDisplayID) -> UInt16? {
        getValue(for: displayID, controlID: ControlID.BLUE_GAIN)
    }

    func getAudioSpeakerVolume(for displayID: CGDirectDisplayID) -> UInt16? {
        getValue(for: displayID, controlID: ControlID.AUDIO_SPEAKER_VOLUME)
    }

    func isAudioMuted(for displayID: CGDirectDisplayID) -> Bool? {
        guard let mute = getValue(for: displayID, controlID: ControlID.AUDIO_MUTE) else {
            return nil
        }
        return mute != 2
    }

    func getContrast(for displayID: CGDirectDisplayID) -> UInt16? {
        getValue(for: displayID, controlID: ControlID.CONTRAST)
    }

    func getInput(for displayID: CGDirectDisplayID) -> UInt16? {
        readInput(for: displayID)?.currentValue
    }

    func getBrightness(for id: CGDirectDisplayID) -> UInt16? {
        log.debug("DDC reading brightness for \(id)")
        return getValue(for: id, controlID: ControlID.BRIGHTNESS)
    }

    func resetBrightnessAndContrast(for displayID: CGDirectDisplayID) -> Bool {
        write(displayID: displayID, controlID: .RESET_BRIGHTNESS_AND_CONTRAST, newValue: 1)
    }

    func resetColors(for displayID: CGDirectDisplayID) -> Bool {
        write(displayID: displayID, controlID: .RESET_COLOR, newValue: 1)
    }
}
