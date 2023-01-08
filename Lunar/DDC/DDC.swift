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
    case tuner2 = 10
    case tuner3 = 11
    case componentVideoYPrPbYCrCb1 = 12
    case componentVideoYPrPbYCrCb2 = 13
    case componentVideoYPrPbYCrCb3 = 14
    case displayPort1 = 15
    case displayPort2 = 16
    case hdmi1 = 17
    case hdmi2 = 18
    case thunderbolt1 = 25
    case thunderbolt2 = 27
    case unknown = 246

    init?(stringValue: String) {
        switch #"[^\w\s]+"#.r!.replaceAll(in: stringValue.lowercased().stripped, with: "") {
        case "vga": self = .vga1
        case "vga1": self = .vga1
        case "vga2": self = .vga2
        case "dvi": self = .dvi1
        case "dvi1": self = .dvi1
        case "dvi2": self = .dvi2
        case "composite": self = .compositeVideo1
        case "compositevideo": self = .compositeVideo1
        case "compositevideo1": self = .compositeVideo1
        case "compositevideo2": self = .compositeVideo2
        case "svideo": self = .sVideo1
        case "svideo1": self = .sVideo1
        case "svideo2": self = .sVideo2
        case "tuner": self = .tuner1
        case "tuner1": self = .tuner1
        case "tuner2": self = .tuner2
        case "tuner3": self = .tuner3
        case "component": self = .componentVideoYPrPbYCrCb1
        case "componentvideo": self = .componentVideoYPrPbYCrCb1
        case "componentvideoyprpbycrcb": self = .componentVideoYPrPbYCrCb1
        case "componentvideoyprpbycrcb1": self = .componentVideoYPrPbYCrCb1
        case "componentvideoyprpbycrcb2": self = .componentVideoYPrPbYCrCb2
        case "componentvideoyprpbycrcb3": self = .componentVideoYPrPbYCrCb3
        case "dp", "minidp", "minidisplayport", "displayport", "dp1", "displayport1": self = .displayPort1
        case "dp2", "minidp2", "minidisplayport2", "displayport2": self = .displayPort2
        case "hdmi": self = .hdmi1
        case "hdmi1": self = .hdmi1
        case "hdmi2": self = .hdmi2
        case "thunderbolt": self = .thunderbolt2
        case "thunderbolt1": self = .thunderbolt1
        case "thunderbolt2": self = .thunderbolt2
        case "thunderbolt3": self = .thunderbolt2
        case "usbc": self = .thunderbolt2
        case "usbc1": self = .thunderbolt1
        case "usbc2": self = .thunderbolt2
        case "unknown": self = .unknown
        default:
            return nil
        }
    }

    static var mostUsed: [VideoInputSource] {
        [.thunderbolt1, .thunderbolt2, .displayPort1, .displayPort2, .hdmi1, .hdmi2]
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

    var description: String { displayName() }

    var name: String {
        get { displayName() }
        set {}
    }

    var image: String? {
        switch self {
        case .vga1, .vga2: return "vga"
        case .dvi1, .dvi2: return "dvi"
        case .compositeVideo1, .compositeVideo2: return "composite"
        case .sVideo1, .sVideo2: return "svideo"
        case .tuner1, .tuner2, .tuner3: return "tuner"
        case .componentVideoYPrPbYCrCb1, .componentVideoYPrPbYCrCb2, .componentVideoYPrPbYCrCb3: return "component"
        case .displayPort1, .displayPort2: return "displayport"
        case .hdmi1, .hdmi2: return "hdmi"
        case .thunderbolt1, .thunderbolt2: return "usbc"
        case .unknown: return "input"
        }
    }

    var tag: Int? { rawValue.i }
    var str: String { displayName() }
    var enabled: Bool { true }

    func displayName() -> String {
        switch self {
        case .vga1: return "VGA 1"
        case .vga2: return "VGA 2"
        case .dvi1: return "DVI 1"
        case .dvi2: return "DVI 2"
        case .compositeVideo1: return "Composite video 1"
        case .compositeVideo2: return "Composite video 2"
        case .sVideo1: return "S-Video 1"
        case .sVideo2: return "S-Video 2"
        case .tuner1: return "Tuner 1"
        case .tuner2: return "Tuner 2"
        case .tuner3: return "Tuner 3"
        case .componentVideoYPrPbYCrCb1: return "Component video (YPrPb/YCrCb) 1"
        case .componentVideoYPrPbYCrCb2: return "Component video (YPrPb/YCrCb) 2"
        case .componentVideoYPrPbYCrCb3: return "Component video (YPrPb/YCrCb) 3"
        case .displayPort1: return "DisplayPort 1"
        case .displayPort2: return "DisplayPort 2"
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .thunderbolt1: return "USB-C 1"
        case .thunderbolt2: return "USB-C 2"
        case .unknown: return "Unknown"
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

// MARK: - IOServiceDetector

class IOServiceDetector {
    init? (
        serviceName: String? = nil,
        serviceClass: String? = nil,
        callbackQueue: DispatchQueue = .main,
        callback: IOServiceCallback? = nil
    ) {
        guard serviceName != nil || serviceClass != nil else { return nil }
        self.serviceName = serviceName
        self.serviceClass = serviceClass
        self.callbackQueue = callbackQueue
        self.callback = callback

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
        _ event: Event,
        _ service: io_service_t
    ) -> Void

    enum Event {
        case Matched
        case Terminated
    }

    let serviceName: String?
    let serviceClass: String?

    var callbackQueue: DispatchQueue?
    var callback: IOServiceCallback?

    func startDetection() -> Bool {
        guard matchedIterator == 0 else { return true }

        let matchingDict =
            (serviceName != nil ? IOServiceNameMatching(serviceName!) : IOServiceMatching(serviceClass!)) as NSMutableDictionary

        let matchCallback: IOServiceMatchingCallback = {
            userData, iterator in
            let detector = Unmanaged<IOServiceDetector>
                .fromOpaque(userData!).takeUnretainedValue()
            detector.dispatchEvent(
                event: .Matched, iterator: iterator
            )
        }
        let termCallback: IOServiceMatchingCallback = {
            userData, iterator in
            let detector = Unmanaged<IOServiceDetector>
                .fromOpaque(userData!).takeUnretainedValue()
            detector.dispatchEvent(
                event: .Terminated, iterator: iterator
            )
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addMatchError = IOServiceAddMatchingNotification(
            notifyPort, kIOFirstMatchNotification,
            matchingDict, matchCallback, selfPtr, &matchedIterator
        )
        let addTermError = IOServiceAddMatchingNotification(
            notifyPort, kIOTerminatedNotification,
            matchingDict, termCallback, selfPtr, &terminatedIterator
        )

        guard addMatchError == 0, addTermError == 0 else {
            if matchedIterator != 0 {
                IOObjectRelease(matchedIterator)
                matchedIterator = 0
            }
            if terminatedIterator != 0 {
                IOObjectRelease(terminatedIterator)
                terminatedIterator = 0
            }
            return false
        }

        dispatchEvent(event: .Matched, iterator: matchedIterator)
        dispatchEvent(event: .Terminated, iterator: terminatedIterator)

        return true
    }

    func stopDetection() {
        guard matchedIterator != 0 else { return }
        IOObjectRelease(matchedIterator)
        IOObjectRelease(terminatedIterator)
        matchedIterator = 0
        terminatedIterator = 0
    }

    private let notifyPort: IONotificationPortRef

    private var matchedIterator: io_iterator_t = 0

    private var terminatedIterator: io_iterator_t = 0

    private func dispatchEvent(
        event: Event, iterator: io_iterator_t
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

enum DDC {
    static let queue = DispatchQueue(label: "DDC", qos: .userInteractive, autoreleaseFrequency: .workItem)
    @Atomic static var apply = true
    @Atomic static var applyLimits = true
    static let requestDelay: useconds_t = 20000
    static let recoveryDelay: useconds_t = 40000
    static var displayPortByUUID = [CFUUID: io_service_t]()
    static var displayUUIDByEDID = [Data: CFUUID]()
    static var skipReadingPropertyById = [CGDirectDisplayID: Set<ControlID>]()
    static var skipWritingPropertyById = [CGDirectDisplayID: Set<ControlID>]()
    static var readFaults: ThreadSafeDictionary<CGDirectDisplayID, ThreadSafeDictionary<ControlID, Int>> = ThreadSafeDictionary()
    static var writeFaults: ThreadSafeDictionary<CGDirectDisplayID, ThreadSafeDictionary<ControlID, Int>> = ThreadSafeDictionary()
    static let lock = NSRecursiveLock()

    static var lastKnownBuiltinDisplayID: CGDirectDisplayID = GENERIC_DISPLAY_ID

    static func extractSerialNumber(from edid: EDID, hex: Bool = false) -> String? {
        extractDescriptorText(from: edid, desType: EDIDTextType.serial, hex: hex)
    }

    static func sync<T>(barrier: Bool = false, _ action: () -> T) -> T {
        guard !Thread.isMainThread else {
            return action()
        }

        if let q = DispatchQueue.current, q == queue {
            return action()
        }
        return queue.sync(flags: barrier ? [.barrier] : [], execute: action)
    }

    #if arch(arm64)
        static func hasAVService(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> Bool {
            guard !isTestID(displayID) else { return false }
            return AVService(displayID: displayID, ignoreCache: ignoreCache) != nil
        }

        static func DCP(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> DCP? {
            guard !isTestID(displayID) else { return nil }

            return sync(barrier: true) {
                if !ignoreCache, let dcp = dcpMapping[displayID], dcp.avService != nil {
                    return dcp
                }

                dcpList = buildDCPList()

                return dcpMapping[displayID]
            }
        }

        static func AVService(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> IOAVService? {
            DCP(displayID: displayID, ignoreCache: ignoreCache)?.avService
        }
    #endif

    static var i2cControllerCache: ThreadSafeDictionary<CGDirectDisplayID, io_service_t?> = ThreadSafeDictionary()

    static var serviceDetectors = [IOServiceDetector]()
    static var observers: Set<AnyCancellable> = []
    static var ioRegistryTreeChanged: PassthroughSubject<Bool, Never> = {
        let p = PassthroughSubject<Bool, Never>()

        p.debounce(for: .seconds(1), scheduler: queue)
            .sink { _ in
                guard !displayController.screensSleeping else { return }
                IORegistryTreeChanged()
            }
            .store(in: &observers)

        return p
    }()

    static var waitAfterWakeSeconds: Int = {
        waitAfterWakeSecondsPublisher.debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { waitAfterWakeSeconds = $0.newValue }
            .store(in: &observers)

        return CachedDefaults[.waitAfterWakeSeconds]
    }()

    static var delayDDCAfterWake: Bool = CachedDefaults[.delayDDCAfterWake]

    static var shouldWait: Bool {
        delayDDCAfterWake && waitAfterWakeSeconds > 0 && wakeTime != startTime && timeSince(wakeTime) > waitAfterWakeSeconds.d
    }

    #if arch(arm64)
        static var dcpList: [DCP] = buildDCPList() {
            didSet {
                dcpScores = buildDCPScoreMapping(dcpList: dcpList, displays: displayController.externalHardwareActiveDisplays)
            }
        }
        static var dcpScores: [DCP: [CGDirectDisplayID: Int]] = buildDCPScoreMapping(dcpList: dcpList, displays: displayController.externalHardwareActiveDisplays) {
            didSet {
                dcpMapping = matchDisplayToDCP(dcpScores: dcpScores)
            }
        }
        static var dcpMapping: [CGDirectDisplayID: DCP] = matchDisplayToDCP(dcpScores: dcpScores)
    #endif

    static func IORegistryTreeChanged() {
        #if DEBUG
            print("IORegistryTreeChanged")
            print("secondPhase", Defaults[.secondPhase] as Any)
        #endif
        DDC.sync(barrier: true) {
            #if !DEBUG
                if Defaults[.secondPhase] == nil || Defaults[.secondPhase] == true {
                    Thread.sleep(until: .distantFuture)
                }
            #endif
            #if arch(arm64)
                DDC.dcpList = buildDCPList()
            #else
                DDC.i2cControllerCache.removeAll()
            #endif

            displayController.activeDisplays.values.forEach { display in
                display.nsScreen = display.getScreen()
                display.primaryMirrorScreen = display.getPrimaryMirrorScreen()
                display.detectI2C()
                display.startI2CDetection()
            }
        }
    }

    static func setup() {
        initThirdPhase()

        #if arch(arm64)
            log.debug("Adding IOKit notification for dispext")
            serviceDetectors += (["AppleCLCD2", "DCPAVServiceProxy"] + DISP_NAMES + DCP_NAMES)
                .compactMap { IOServiceDetector(serviceName: $0, callback: { _, _, _ in ioRegistryTreeChanged.send(true) }) }
        #else
            log.debug("Adding IOKit notification for IOFRAMEBUFFER_CONFORMSTO")
            serviceDetectors += [IOFRAMEBUFFER_CONFORMSTO]
                .compactMap { IOServiceDetector(serviceClass: $0, callback: { _, _, _ in ioRegistryTreeChanged.send(true) }) }
        #endif
        serviceDetectors.forEach { _ = $0.startDetection() }
        addObservers()
        #if arch(arm64)
            dcpList = buildDCPList()
        #endif

    }

    static func reset() {
        sync(barrier: true) {
            DDC.displayPortByUUID.removeAll()
            DDC.displayUUIDByEDID.removeAll()
            DDC.skipReadingPropertyById.removeAll()
            DDC.skipWritingPropertyById.removeAll()
            DDC.readFaults.removeAll()
            DDC.writeFaults.removeAll()
            #if arch(arm64)
                DDC.dcpList = buildDCPList()
            #else
                DDC.i2cControllerCache.removeAll()
            #endif
        }
    }

    static func findExternalDisplays(
        includeVirtual: Bool = true,
        includeAirplay: Bool = false,
        includeProjector: Bool = false,
        includeDummy: Bool = false
    ) -> [CGDirectDisplayID] {
        var displayIDs = NSScreen.onlineDisplayIDs.filter { id in
            let name = Display.printableName(id)
            return !isBuiltinDisplay(id) &&
                (includeVirtual || !isVirtualDisplay(id, name: name)) &&
                (includeProjector || !isProjectorDisplay(id, name: name)) &&
                (includeDummy || !isDummyDisplay(id, name: name)) &&
                (includeAirplay || !(isSidecarDisplay(id, name: name) || isAirplayDisplay(id, name: name)))
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
        return (realName =~ Display.notDummyNamePattern && vendorID == DUMMY_VENDOR_ID)
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
        return (
            CGDisplayIsBuiltin(id) == 1 ||
                id == lastKnownBuiltinDisplayID ||
                (
                    checkName && Display
                        .printableName(id).stripped
                        .lowercased().replacingOccurrences(of: "-", with: "")
                        .contains("builtin")
                )
        )
    }

    static func write(displayID: CGDirectDisplayID, controlID: ControlID, newValue: UInt16) -> Bool {
        #if DEBUG
            guard apply, !isTestID(displayID), !shouldWait, !displayController.screensSleeping else { return true }
        #else
            guard apply, !shouldWait, !displayController.screensSleeping else { return true }
        #endif

        #if arch(arm64)
            guard let dcp = DCP(displayID: displayID) else { return false }
        #else
            guard let fb = I2CController(displayID: displayID) else { return false }
        #endif

        return sync(barrier: true) {
            if let propertiesToSkip = DDC.skipWritingPropertyById[displayID], propertiesToSkip.contains(controlID) {
                log.debug("Skipping write for \(controlID)", context: displayID)
                return false
            }

            var command = DDCWriteCommand(
                control_id: controlID.rawValue,
                new_value: newValue
            )

            let writeStartedAt = DispatchTime.now()

            #if arch(arm64)
                let result = DDCWrite(avService: dcp.avService, command: &command, displayID: displayID, isMCDP: dcp.isMCDP)
            #else
                let result = DDCWrite(fb: fb, command: &command)
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
                displayController.averageDDCWriteNanoseconds(for: displayID, ns: writeNs)
            }
            if let display = displayController.displays[displayID], !display.responsiveDDC {
                display.responsiveDDC = true
            }

            if let propertyFaults = DDC.writeFaults[displayID], let faults = propertyFaults[controlID] {
                DDC.writeFaults[displayID]![controlID] = max(faults - 1, 0)
            }

            return result
        }
    }

    static func readFault(severity: Int, displayID: CGDirectDisplayID, controlID: ControlID) {
        guard let propertyFaults = DDC.readFaults[displayID] else {
            DDC.readFaults[displayID] = ThreadSafeDictionary(dict: [controlID: severity])
            return
        }
        guard var faults = propertyFaults[controlID] else {
            DDC.readFaults[displayID]![controlID] = severity
            return
        }
        faults = min(severity + faults, MAX_READ_FAULTS + 1)
        DDC.readFaults[displayID]![controlID] = faults

        if faults > MAX_READ_FAULTS {
            DDC.skipReadingProperty(displayID: displayID, controlID: controlID)
        }
    }

    static func writeFault(severity: Int, displayID: CGDirectDisplayID, controlID: ControlID) {
        guard let propertyFaults = DDC.writeFaults[displayID] else {
            DDC.writeFaults[displayID] = ThreadSafeDictionary(dict: [controlID: severity])
            return
        }
        guard var faults = propertyFaults[controlID] else {
            DDC.writeFaults[displayID]![controlID] = severity
            return
        }
        faults = min(severity + faults, MAX_WRITE_FAULTS + 1)
        DDC.writeFaults[displayID]![controlID] = faults

        if faults > MAX_WRITE_FAULTS {
            DDC.skipWritingProperty(displayID: displayID, controlID: controlID)
        }
    }

    static func skipReadingProperty(displayID: CGDirectDisplayID, controlID: ControlID) {
        if var propertiesToSkip = DDC.skipReadingPropertyById[displayID] {
            propertiesToSkip.insert(controlID)
            DDC.skipReadingPropertyById[displayID] = propertiesToSkip
        } else {
            DDC.skipReadingPropertyById[displayID] = Set([controlID])
        }
    }

    static func skipWritingProperty(displayID: CGDirectDisplayID, controlID: ControlID) {
        if var propertiesToSkip = DDC.skipWritingPropertyById[displayID] {
            propertiesToSkip.insert(controlID)
            DDC.skipWritingPropertyById[displayID] = propertiesToSkip
        } else {
            DDC.skipWritingPropertyById[displayID] = Set([controlID])
        }
        if controlID == ControlID.BRIGHTNESS, CachedDefaults[.detectResponsiveness] {
            mainAsyncAfter(ms: 100) {
                #if DEBUG
                    displayController.displays[displayID]?.responsiveDDC = TEST_IDS.contains(displayID)
                #else
                    displayController.displays[displayID]?.responsiveDDC = false
                #endif
            }
        }
    }

    static func read(displayID: CGDirectDisplayID, controlID: ControlID) -> DDCReadResult? {
        guard !isTestID(displayID), !shouldWait, !displayController.screensSleeping else { return nil }

        #if arch(arm64)
            guard let dcp = DCP(displayID: displayID) else { return nil }
        #else
            guard let fb = I2CController(displayID: displayID) else { return nil }
        #endif

        return sync(barrier: true) {
            if let propertiesToSkip = DDC.skipReadingPropertyById[displayID], propertiesToSkip.contains(controlID) {
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
                displayController.averageDDCReadNanoseconds(for: displayID, ns: readNs)
            }
            if let display = displayController.displays[displayID], !display.responsiveDDC {
                display.responsiveDDC = true
            }

            if let propertyFaults = DDC.readFaults[displayID], let faults = propertyFaults[controlID] {
                DDC.readFaults[displayID]![controlID] = max(faults - 1, 0)
            }

            return DDCReadResult(
                controlID: controlID,
                maxValue: command.max_value,
                currentValue: command.current_value
            )
        }
    }

    static func sendEdidRequest(displayID: CGDirectDisplayID) -> (EDID, Data)? {
        guard !isTestID(displayID), !displayController.screensSleeping else { return nil }

        #if arch(arm64)
            guard let avService = AVService(displayID: displayID) else { return nil }
        #else
            guard let fb = I2CController(displayID: displayID) else { return nil }
        #endif

        return sync(barrier: true) {
            var edidData = [UInt8](repeating: 0, count: 256)
            var edid = EDID()

            #if arch(arm64)
                _ = EDIDTest(avService: avService, edid: &edid, data: &edidData)
            #else
                _ = EDIDTest(fb: fb, edid: &edid, data: &edidData)
            #endif

            return (edid, Data(bytes: &edidData, count: 256))
        }
    }

    static func getEdid(displayID: CGDirectDisplayID) -> EDID? {
        guard let (edid, _) = DDC.sendEdidRequest(displayID: displayID) else {
            return nil
        }
        return edid
    }

    static func getEdidData(displayID: CGDirectDisplayID) -> Data? {
        guard let (_, data) = DDC.sendEdidRequest(displayID: displayID) else {
            return nil
        }
        return data
    }

    static func getEdidData() -> [Data] {
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

    static func getDisplayIdentificationData(displayID: CGDirectDisplayID) -> String {
        guard let edid = DDC.getEdid(displayID: displayID) else {
            return ""
        }
        return "\(edid.eisaid.str())-\(edid.productcode.str())-\(edid.serial.str()) \(edid.week.str())/\(edid.year.str()) \(edid.versionmajor.str()).\(edid.versionminor.str())"
    }

    static func getTextData(_ descriptor: descriptor, hex: Bool = false) -> String? {
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

    static func extractDescriptorText(from edid: EDID, desType: EDIDTextType, hex: Bool = false) -> String? {
        switch desType.rawValue {
        case edid.descriptors.0.text.type:
            return DDC.getTextData(edid.descriptors.0, hex: hex)
        case edid.descriptors.1.text.type:
            return DDC.getTextData(edid.descriptors.1, hex: hex)
        case edid.descriptors.2.text.type:
            return DDC.getTextData(edid.descriptors.2, hex: hex)
        case edid.descriptors.3.text.type:
            return DDC.getTextData(edid.descriptors.3, hex: hex)
        default:
            return nil
        }
    }

    static func addObservers() {
        delayDDCAfterWake = CachedDefaults[.delayDDCAfterWake]
        delayDDCAfterWakePublisher.debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { change in
                delayDDCAfterWake = change.newValue

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

                displayController.displays.values.forEach { d in
                    d.reapplyColorGain = false
                }
            }
            .store(in: &observers)
    }

    static func extractName(from edid: EDID, hex: Bool = false) -> String? {
        extractDescriptorText(from: edid, desType: EDIDTextType.name, hex: hex)
    }

    static func hasI2CController(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> Bool {
        guard !isTestID(displayID) else { return false }
        return I2CController(displayID: displayID, ignoreCache: ignoreCache) != nil
    }

    static func I2CController(displayID: CGDirectDisplayID, ignoreCache: Bool = false) -> io_service_t? {
        sync(barrier: true) {
            if !ignoreCache, let controllerTemp = i2cControllerCache[displayID], let controller = controllerTemp {
                return controller
            }
            let controller = I2CController(displayID)
            i2cControllerCache[displayID] = controller
            return controller
        }
    }

    static func I2CController(_ displayID: CGDirectDisplayID) -> io_service_t? {
        guard !isTestID(displayID) else { return nil }

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

    static func getDisplayName(for displayID: CGDirectDisplayID) -> String? {
        guard let edid = DDC.getEdid(displayID: displayID) else {
            return nil
        }
        return extractName(from: edid)
    }

    static func getDisplaySerial(for displayID: CGDirectDisplayID) -> String? {
        guard let edid = DDC.getEdid(displayID: displayID) else {
            return nil
        }

        let serialNumber = extractSerialNumber(from: edid) ?? "NO_SERIAL"
        let name = extractName(from: edid) ?? "NO_NAME"
        return "\(name)-\(serialNumber)-\(edid.serial)-\(edid.productcode)-\(edid.year)-\(edid.week)"
    }

    static func getDisplaySerialAndName(for displayID: CGDirectDisplayID) -> (String?, String?) {
        guard let edid = DDC.getEdid(displayID: displayID) else {
            return (nil, nil)
        }

        let serialNumber = extractSerialNumber(from: edid) ?? "NO_SERIAL"
        let name = extractName(from: edid) ?? "NO_NAME"
        return ("\(name)-\(serialNumber)-\(edid.serial)-\(edid.productcode)-\(edid.year)-\(edid.week)", name)
    }

    static func setInput(for displayID: CGDirectDisplayID, input: VideoInputSource) -> Bool {
        if input == .unknown {
            return false
        }
        return write(displayID: displayID, controlID: ControlID.INPUT_SOURCE, newValue: input.rawValue)
    }

    static func readInput(for displayID: CGDirectDisplayID) -> DDCReadResult? {
        read(displayID: displayID, controlID: ControlID.INPUT_SOURCE)
    }

    static func setBrightness(for displayID: CGDirectDisplayID, brightness: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.BRIGHTNESS, newValue: brightness)
    }

    static func readBrightness(for displayID: CGDirectDisplayID) -> DDCReadResult? {
        read(displayID: displayID, controlID: ControlID.BRIGHTNESS)
    }

    static func readContrast(for displayID: CGDirectDisplayID) -> DDCReadResult? {
        read(displayID: displayID, controlID: ControlID.CONTRAST)
    }

    static func setContrast(for displayID: CGDirectDisplayID, contrast: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.CONTRAST, newValue: contrast)
    }

    static func setRedGain(for displayID: CGDirectDisplayID, redGain: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.RED_GAIN, newValue: redGain)
    }

    static func setGreenGain(for displayID: CGDirectDisplayID, greenGain: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.GREEN_GAIN, newValue: greenGain)
    }

    static func setBlueGain(for displayID: CGDirectDisplayID, blueGain: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.BLUE_GAIN, newValue: blueGain)
    }

    static func setAudioSpeakerVolume(for displayID: CGDirectDisplayID, audioSpeakerVolume: UInt16) -> Bool {
        write(displayID: displayID, controlID: ControlID.AUDIO_SPEAKER_VOLUME, newValue: audioSpeakerVolume)
    }

    static func setAudioMuted(for displayID: CGDirectDisplayID, audioMuted: Bool) -> Bool {
        write(displayID: displayID, controlID: ControlID.AUDIO_MUTE, newValue: audioMuted ? 1 : 2)
    }

    static func setPower(for displayID: CGDirectDisplayID, power: Bool) -> Bool {
        write(displayID: displayID, controlID: ControlID.DPMS, newValue: power ? 1 : 5)
    }

    static func reset(displayID: CGDirectDisplayID) -> Bool {
        write(displayID: displayID, controlID: ControlID.RESET, newValue: 100)
    }

    static func getValue(for displayID: CGDirectDisplayID, controlID: ControlID) -> UInt16? {
        log.debug("DDC reading \(controlID) for \(displayID)")

        guard let result = DDC.read(displayID: displayID, controlID: controlID) else {
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

    static func getMaxValue(for displayID: CGDirectDisplayID, controlID: ControlID) -> UInt16? {
        guard let result = DDC.read(displayID: displayID, controlID: controlID) else {
            return nil
        }
        return result.maxValue
    }

    static func getRedGain(for displayID: CGDirectDisplayID) -> UInt16? {
        DDC.getValue(for: displayID, controlID: ControlID.RED_GAIN)
    }

    static func getGreenGain(for displayID: CGDirectDisplayID) -> UInt16? {
        DDC.getValue(for: displayID, controlID: ControlID.GREEN_GAIN)
    }

    static func getBlueGain(for displayID: CGDirectDisplayID) -> UInt16? {
        DDC.getValue(for: displayID, controlID: ControlID.BLUE_GAIN)
    }

    static func getAudioSpeakerVolume(for displayID: CGDirectDisplayID) -> UInt16? {
        DDC.getValue(for: displayID, controlID: ControlID.AUDIO_SPEAKER_VOLUME)
    }

    static func isAudioMuted(for displayID: CGDirectDisplayID) -> Bool? {
        guard let mute = DDC.getValue(for: displayID, controlID: ControlID.AUDIO_MUTE) else {
            return nil
        }
        return mute != 2
    }

    static func getContrast(for displayID: CGDirectDisplayID) -> UInt16? {
        DDC.getValue(for: displayID, controlID: ControlID.CONTRAST)
    }

    static func getInput(for displayID: CGDirectDisplayID) -> UInt16? {
        DDC.readInput(for: displayID)?.currentValue
    }

    static func getBrightness(for id: CGDirectDisplayID) -> UInt16? {
        log.debug("DDC reading brightness for \(id)")
        return DDC.getValue(for: id, controlID: ControlID.BRIGHTNESS)
    }

    static func resetBrightnessAndContrast(for displayID: CGDirectDisplayID) -> Bool {
        DDC.write(displayID: displayID, controlID: .RESET_BRIGHTNESS_AND_CONTRAST, newValue: 1)
    }

    static func resetColors(for displayID: CGDirectDisplayID) -> Bool {
        DDC.write(displayID: displayID, controlID: .RESET_COLOR, newValue: 1)
    }
}
