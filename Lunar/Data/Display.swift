//
//  Display.swift
//  Lunar
//
//  Created by Alin on 05/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import AnyCodable
import ArgumentParser
import Atomics
import Cocoa
import Combine
import CoreGraphics
import DataCompression
import Defaults
import Foundation
import Magnet
import OSLog
import Regex
import Sentry
import Surge
import SwiftDate

let MIN_VOLUME: Int = 0
let MAX_VOLUME: Int = 100
let MIN_BRIGHTNESS: UInt8 = 0
let MAX_BRIGHTNESS: UInt8 = 100
let MIN_CONTRAST: UInt8 = 0
let MAX_CONTRAST: UInt8 = 100

let DEFAULT_MIN_BRIGHTNESS: UInt8 = 0
let DEFAULT_MAX_BRIGHTNESS: UInt8 = 100
let DEFAULT_MIN_CONTRAST: UInt8 = 50
let DEFAULT_MAX_CONTRAST: UInt8 = 75
let DEFAULT_COLOR_GAIN: UInt8 = 90

let DEFAULT_SENSOR_BRIGHTNESS_CURVE_FACTOR = 0.5
let DEFAULT_SYNC_BRIGHTNESS_CURVE_FACTOR = 0.5
let DEFAULT_LOCATION_BRIGHTNESS_CURVE_FACTOR = 1.0
let DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR = 1.0

let DEFAULT_SENSOR_CONTRAST_CURVE_FACTOR = 0.2
let DEFAULT_SYNC_CONTRAST_CURVE_FACTOR = 2.0
let DEFAULT_LOCATION_CONTRAST_CURVE_FACTOR = 0.8
let DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR = 1.0

let GENERIC_DISPLAY_ID: CGDirectDisplayID = UINT32_MAX
#if DEBUG
    let TEST_DISPLAY_ID: CGDirectDisplayID = UINT32_MAX / 2
    let TEST_DISPLAY_PERSISTENT_ID: CGDirectDisplayID = UINT32_MAX / 3
    let TEST_DISPLAY_PERSISTENT2_ID: CGDirectDisplayID = UINT32_MAX / 4
    // let TEST_DISPLAY_PERSISTENT3_ID: CGDirectDisplayID = 1
    let TEST_DISPLAY_PERSISTENT3_ID: CGDirectDisplayID = UINT32_MAX / 5
    let TEST_DISPLAY_PERSISTENT4_ID: CGDirectDisplayID = UINT32_MAX / 6
    let TEST_IDS = Set(
        arrayLiteral: GENERIC_DISPLAY_ID,
        TEST_DISPLAY_ID,
        TEST_DISPLAY_PERSISTENT_ID,
        TEST_DISPLAY_PERSISTENT2_ID,
        TEST_DISPLAY_PERSISTENT3_ID,
        TEST_DISPLAY_PERSISTENT4_ID
    )
#endif

let GENERIC_DISPLAY = Display(
    id: GENERIC_DISPLAY_ID,
    serial: "GENERIC_SERIAL",
    name: "No Display",
    minBrightness: 0,
    maxBrightness: 100,
    minContrast: 0,
    maxContrast: 100
)
#if DEBUG
    var TEST_DISPLAY: Display = {
        let d = Display(
            id: TEST_DISPLAY_ID,
            serial: "TEST_DISPLAY_SERIAL",
            name: "LG Ultra HD",
            active: true,
            minBrightness: 0,
            maxBrightness: 60,
            minContrast: 50,
            maxContrast: 75,
            adaptive: true
        )
        d.hasI2C = true
        return d
    }()

    var TEST_DISPLAY_PERSISTENT: Display = {
        let d = datastore.displays(serials: ["TEST_DISPLAY_PERSISTENT_SERIAL"])?.first ?? Display(
            id: TEST_DISPLAY_PERSISTENT_ID,
            serial: "TEST_DISPLAY_PERSISTENT_SERIAL_PERSISTENT",
            name: "DELL U3419W",
            active: true,
            minBrightness: 0,
            maxBrightness: 100,
            minContrast: 0,
            maxContrast: 100,
            adaptive: true
        )
        d.hasI2C = true
        return d
    }()

    var TEST_DISPLAY_PERSISTENT2: Display = {
        let d = datastore.displays(serials: ["TEST_DISPLAY_PERSISTENT2_SERIAL"])?.first ?? Display(
            id: TEST_DISPLAY_PERSISTENT2_ID,
            serial: "TEST_DISPLAY_PERSISTENT2_SERIAL_PERSISTENT_TWO",
            name: "LG Ultrafine",
            active: true,
            minBrightness: 0,
            maxBrightness: 100,
            minContrast: 0,
            maxContrast: 100,
            adaptive: true
        )
        d.hasI2C = true
        return d
    }()

    var TEST_DISPLAY_PERSISTENT3: Display = {
        let d = datastore.displays(serials: ["TEST_DISPLAY_PERSISTENT3_SERIAL"])?.first ?? Display(
            id: TEST_DISPLAY_PERSISTENT3_ID,
            serial: "TEST_DISPLAY_PERSISTENT3_SERIAL_PERSISTENT_THREE",
            name: "Pro Display XDR",
            active: true,
            minBrightness: 0,
            maxBrightness: 100,
            minContrast: 0,
            maxContrast: 100,
            adaptive: true
        )
        d.hasI2C = true
        return d
    }()

    var TEST_DISPLAY_PERSISTENT4: Display = {
        let d = datastore.displays(serials: ["TEST_DISPLAY_PERSISTENT4_SERIAL"])?.first ?? Display(
            id: TEST_DISPLAY_PERSISTENT4_ID,
            serial: "TEST_DISPLAY_PERSISTENT4_SERIAL_PERSISTENT_FOUR",
            name: "Thunderbolt",
            active: true,
            minBrightness: 0,
            maxBrightness: 100,
            minContrast: 0,
            maxContrast: 100,
            adaptive: true
        )
        d.hasI2C = true
        return d
    }()
#endif

let MAX_SMOOTH_STEP_TIME_NS: UInt64 = 70 * 1_000_000 // 70ms

let ULTRAFINE_NAME = "LG UltraFine"
let THUNDERBOLT_NAME = "Thunderbolt"
let LED_CINEMA_NAME = "LED Cinema"
let CINEMA_NAME = "Cinema"
let CINEMA_HD_NAME = "Cinema HD"
let COLOR_LCD_NAME = "Color LCD"
let APPLE_DISPLAY_VENDOR_ID = 0x610

// MARK: - Transport

struct Transport: Equatable, CustomStringConvertible {
    var upstream: String
    var downstream: String

    var description: String {
        "Transport(up: \(upstream), down: \(downstream))"
    }
}

// MARK: - Gamma

struct Gamma: Equatable {
    var red: CGGammaValue
    var green: CGGammaValue
    var blue: CGGammaValue
    var contrast: CGGammaValue

    func stride(to gamma: Gamma, samples: Int) -> [Gamma] {
        guard gamma != self, samples > 0 else { return [gamma] }

        var (red, green, blue, contrast) = (red, green, blue, contrast)
        let ramps = (
            ramp(targetValue: gamma.red, lastTargetValue: &red, samples: samples, step: 0.01),
            ramp(targetValue: gamma.green, lastTargetValue: &green, samples: samples, step: 0.01),
            ramp(targetValue: gamma.blue, lastTargetValue: &blue, samples: samples, step: 0.01),
            ramp(targetValue: gamma.contrast, lastTargetValue: &contrast, samples: samples, step: 0.01)
        )
        return zip4(ramps.0, ramps.1, ramps.2, ramps.3).map { Gamma(red: $0, green: $1, blue: $2, contrast: $3) }
    }
}

let STEP_256: Float = 1.0 / 256.0

// MARK: - GammaTable

struct GammaTable: Equatable {
    // MARK: Lifecycle

    init(
        redMin: CGGammaValue = 0,
        redMax: CGGammaValue = 1,
        redValue: CGGammaValue = 1,
        greenMin: CGGammaValue = 0,
        greenMax: CGGammaValue = 1,
        greenValue: CGGammaValue = 1,
        blueMin: CGGammaValue = 0,
        blueMax: CGGammaValue = 1,
        blueValue: CGGammaValue = 1
    ) {
        red = Swift.stride(from: 0.00, through: 1.00, by: STEP_256).map { index in
            redMin + ((redMax - redMin) * powf(index, redValue))
        }
        green = Swift.stride(from: 0.00, through: 1.00, by: STEP_256).map { index in
            greenMin + ((greenMax - greenMin) * powf(index, greenValue))
        }
        blue = Swift.stride(from: 0.00, through: 1.00, by: STEP_256).map { index in
            blueMin + ((blueMax - blueMin) * powf(index, blueValue))
        }
        samples = 256
    }

    init(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue], samples: UInt32, brightness: Brightness? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.samples = samples
        self.brightness = brightness
    }

    init(for id: CGDirectDisplayID) {
        var redTable = [CGGammaValue](repeating: 0, count: 256)
        var greenTable = [CGGammaValue](repeating: 0, count: 256)
        var blueTable = [CGGammaValue](repeating: 0, count: 256)
        var sampleCount: UInt32 = 0

        CGGetDisplayTransferByTable(id, 256, &redTable, &greenTable, &blueTable, &sampleCount)

        red = redTable
        green = greenTable
        blue = blueTable
        samples = sampleCount
    }

    // MARK: Internal

    static let original = GammaTable()
    static let zero = GammaTable(
        red: [CGGammaValue](repeating: 0, count: 256),
        green: [CGGammaValue](repeating: 0, count: 256),
        blue: [CGGammaValue](repeating: 0, count: 256),
        samples: 256
    )

    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]
    var samples: UInt32
    var brightness: Brightness?

    var isZero: Bool {
        samples == 0 || (
            !red.contains(where: { $0 != 0 }) &&
                !green.contains(where: { $0 != 0 }) &&
                !blue.contains(where: { $0 != 0 })
        )
    }

    @discardableResult
    func apply(to id: CGDirectDisplayID, force: Bool = false) -> Bool {
        log.debug("Applying gamma table to ID \(id)")
        guard force || !isZero else {
            log.debug("Zero gamma table: samples=\(samples)")
            GammaTable.original.apply(to: id)
            return false
        }
        CGSetDisplayTransferByTable(id, samples, red, green, blue)
        return true
    }

    func adjust(brightness: UInt8, preciseBrightness: Double? = nil) -> GammaTable {
        let gammaBrightness: Float = mapNumber(
            powf(preciseBrightness?.f ?? (brightness.f / 100), 0.8),
            fromLow: 0.00, fromHigh: 1.00, toLow: 0.08, toHigh: 1.00
        )
        return GammaTable(
            red: red.map { $0 * gammaBrightness },
            green: green.map { $0 * gammaBrightness },
            blue: blue.map { $0 * gammaBrightness },
            samples: samples, brightness: brightness
        )
    }

    func stride(from brightness: Brightness, to newBrightness: Brightness) -> [GammaTable] {
        guard brightness != newBrightness else { return [] }

        return Swift.stride(from: brightness, through: newBrightness, by: newBrightness < brightness ? -1 : 1).compactMap { b in
            let table = adjust(brightness: b)
            return table.isZero ? nil : table
        }
    }
}

// MARK: - ValueType

enum ValueType {
    case brightness
    case contrast
}

// MARK: - Display

@objc class Display: NSObject, Codable, Defaults.Serializable, ObservableObject {
    // MARK: Lifecycle

    // MARK: Initializers

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let userBrightnessContainer = try container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .userBrightness)
        let userContrastContainer = try container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .userContrast)
        let enabledControlsContainer = try container.nestedContainer(keyedBy: DisplayControlKeys.self, forKey: .enabledControls)
        let brightnessCurveFactorsContainer = try container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .brightnessCurveFactors)
        let contrastCurveFactorsContainer = try container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .contrastCurveFactors)

        let id = try container.decode(CGDirectDisplayID.self, forKey: .id)
        _id = id
        let isSmartBuiltin = DDC.isSmartBuiltinDisplay(id)
        let appleNativeControlEnabled = try enabledControlsContainer.decodeIfPresent(Bool.self, forKey: .appleNative) ?? false
        let isNative = isSmartBuiltin && appleNativeControlEnabled
        serial = try container.decode(String.self, forKey: .serial)

        adaptive = try container.decode(Bool.self, forKey: .adaptive) && !Self.ambientLightCompensationEnabled(id)
        name = try container.decode(String.self, forKey: .name)
        edidName = try container.decode(String.self, forKey: .edidName)
        active = try container.decode(Bool.self, forKey: .active)

        let brightness = isNative ? (AppleNativeControl.readBrightnessDisplayServices(id: id) * 100)
            .ns : (try container.decode(UInt8.self, forKey: .brightness)).ns
        self.brightness = brightness
        let contrast = (try container.decode(UInt8.self, forKey: .contrast)).ns
        self.contrast = contrast

        let minBrightness = isSmartBuiltin ? 0 : (try container.decode(UInt8.self, forKey: .minBrightness)).ns
        let maxBrightness = isSmartBuiltin ? 100 : (try container.decode(UInt8.self, forKey: .maxBrightness)).ns
        self.minBrightness = minBrightness
        self.maxBrightness = maxBrightness
        minContrast = isSmartBuiltin ? 0 : (try container.decode(UInt8.self, forKey: .minContrast)).ns
        maxContrast = isSmartBuiltin ? 100 : (try container.decode(UInt8.self, forKey: .maxContrast)).ns

        defaultGammaRedMin = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaRedMin)?.ns) ?? 0.ns
        defaultGammaRedMax = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaRedMax)?.ns) ?? 1.ns
        defaultGammaRedValue = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaRedValue)?.ns) ?? 1.ns
        defaultGammaGreenMin = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaGreenMin)?.ns) ?? 0.ns
        defaultGammaGreenMax = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaGreenMax)?.ns) ?? 1.ns
        defaultGammaGreenValue = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaGreenValue)?.ns) ?? 1.ns
        defaultGammaBlueMin = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaBlueMin)?.ns) ?? 0.ns
        defaultGammaBlueMax = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaBlueMax)?.ns) ?? 1.ns
        defaultGammaBlueValue = (try container.decodeIfPresent(Float.self, forKey: .defaultGammaBlueValue)?.ns) ?? 1.ns

        let _maxDDCBrightness = isSmartBuiltin ? 100 : (try container.decodeIfPresent(UInt8.self, forKey: .maxDDCBrightness)?.ns) ?? 100.ns
        let _maxDDCContrast = isSmartBuiltin ? 100 : (try container.decodeIfPresent(UInt8.self, forKey: .maxDDCContrast)?.ns) ?? 100.ns
        maxDDCVolume = isSmartBuiltin ? 100 : (try container.decodeIfPresent(UInt8.self, forKey: .maxDDCVolume)?.ns) ?? 100.ns
        maxDDCBrightness = _maxDDCBrightness
        maxDDCContrast = _maxDDCContrast

        minDDCBrightness = isSmartBuiltin ? 0 : (try container.decodeIfPresent(UInt8.self, forKey: .minDDCBrightness)?.ns) ?? 0.ns
        minDDCContrast = isSmartBuiltin ? 0 : (try container.decodeIfPresent(UInt8.self, forKey: .minDDCContrast)?.ns) ?? 0.ns
        minDDCVolume = isSmartBuiltin ? 0 : (try container.decodeIfPresent(UInt8.self, forKey: .minDDCVolume)?.ns) ?? 0.ns

        faceLightBrightness = (try container.decodeIfPresent(UInt8.self, forKey: .faceLightBrightness)?.ns) ?? _maxDDCBrightness
        faceLightContrast = (try container.decodeIfPresent(UInt8.self, forKey: .faceLightContrast)?.ns) ??
            (_maxDDCContrast.doubleValue * 0.9).intround.ns

        cornerRadius = (try container.decodeIfPresent(Int.self, forKey: .cornerRadius)?.ns) ?? 0

        redGain = (try container.decodeIfPresent(UInt8.self, forKey: .redGain)?.ns) ?? DEFAULT_COLOR_GAIN.ns
        greenGain = (try container.decodeIfPresent(UInt8.self, forKey: .greenGain)?.ns) ?? DEFAULT_COLOR_GAIN.ns
        blueGain = (try container.decodeIfPresent(UInt8.self, forKey: .blueGain)?.ns) ?? DEFAULT_COLOR_GAIN.ns

        lockedBrightness = (try container.decodeIfPresent(Bool.self, forKey: .lockedBrightness)) ?? false
        lockedContrast = (try container.decodeIfPresent(Bool.self, forKey: .lockedContrast)) ?? false

        lockedBrightnessCurve = (try container.decodeIfPresent(Bool.self, forKey: .lockedBrightnessCurve)) ?? false
        lockedContrastCurve = (try container.decodeIfPresent(Bool.self, forKey: .lockedContrastCurve)) ?? false

        alwaysUseNetworkControl = (try container.decodeIfPresent(Bool.self, forKey: .alwaysUseNetworkControl)) ?? false
        neverUseNetworkControl = (try container.decodeIfPresent(Bool.self, forKey: .neverUseNetworkControl)) ?? false
        alwaysFallbackControl = (try container.decodeIfPresent(Bool.self, forKey: .alwaysFallbackControl)) ?? false
        neverFallbackControl = (try container.decodeIfPresent(Bool.self, forKey: .neverFallbackControl)) ?? false

        let volume = ((try container.decodeIfPresent(UInt8.self, forKey: .volume))?.ns ?? 50.ns)
        self.volume = volume
        preciseVolume = volume.doubleValue / 100.0
        audioMuted = (try container.decodeIfPresent(Bool.self, forKey: .audioMuted)) ?? false
        canChangeVolume = (try container.decodeIfPresent(Bool.self, forKey: .canChangeVolume)) ?? true
        isSource = try container.decodeIfPresent(Bool.self, forKey: .isSource) ?? DDC.isSmartBuiltinDisplay(id)
        showVolumeOSD = try container.decodeIfPresent(Bool.self, forKey: .showVolumeOSD) ?? true
        applyGamma = try container.decodeIfPresent(Bool.self, forKey: .applyGamma) ?? false
        input = (try container.decodeIfPresent(UInt8.self, forKey: .input))?.ns ?? InputSource.unknown.rawValue.ns

        hotkeyInput1 = try (
            (try container.decodeIfPresent(UInt8.self, forKey: .hotkeyInput1))?
                .ns ?? (try container.decodeIfPresent(UInt8.self, forKey: .hotkeyInput))?.ns ?? InputSource.unknown.rawValue.ns
        )
        hotkeyInput2 = (try container.decodeIfPresent(UInt8.self, forKey: .hotkeyInput2))?.ns ?? InputSource.unknown.rawValue.ns
        hotkeyInput3 = (try container.decodeIfPresent(UInt8.self, forKey: .hotkeyInput3))?.ns ?? InputSource.unknown.rawValue.ns

        brightnessOnInputChange1 = (
            try (try container.decodeIfPresent(UInt8.self, forKey: .brightnessOnInputChange1))?
            .ns ?? (try container.decodeIfPresent(UInt8.self, forKey: .brightnessOnInputChange))?.ns ?? 100.ns
        )
        brightnessOnInputChange2 = (try container.decodeIfPresent(UInt8.self, forKey: .brightnessOnInputChange2))?.ns ?? 100.ns
        brightnessOnInputChange3 = (try container.decodeIfPresent(UInt8.self, forKey: .brightnessOnInputChange3))?.ns ?? 100.ns

        contrastOnInputChange1 = try (
            (try container.decodeIfPresent(UInt8.self, forKey: .contrastOnInputChange1))?
                .ns ?? (try container.decodeIfPresent(UInt8.self, forKey: .contrastOnInputChange))?.ns ?? 75.ns
        )
        contrastOnInputChange2 = (try container.decodeIfPresent(UInt8.self, forKey: .contrastOnInputChange2))?.ns ?? 75.ns
        contrastOnInputChange3 = (try container.decodeIfPresent(UInt8.self, forKey: .contrastOnInputChange3))?.ns ?? 75.ns

        applyBrightnessOnInputChange1 = (try container.decodeIfPresent(Bool.self, forKey: .applyBrightnessOnInputChange1)) ?? true
        applyBrightnessOnInputChange2 = (try container.decodeIfPresent(Bool.self, forKey: .applyBrightnessOnInputChange2)) ?? false
        applyBrightnessOnInputChange3 = (try container.decodeIfPresent(Bool.self, forKey: .applyBrightnessOnInputChange3)) ?? false

        if let syncUserBrightness = try userBrightnessContainer.decodeIfPresent([Int: Int].self, forKey: .sync) {
            userBrightness[.sync] = syncUserBrightness.threadSafe
        }
        if let sensorUserBrightness = try userBrightnessContainer.decodeIfPresent([Int: Int].self, forKey: .sensor) {
            userBrightness[.sensor] = sensorUserBrightness.threadSafe
        }
        if let locationUserBrightness = try userBrightnessContainer.decodeIfPresent([Int: Int].self, forKey: .location) {
            userBrightness[.location] = locationUserBrightness.threadSafe
        }
        if let manualUserBrightness = try userBrightnessContainer.decodeIfPresent([Int: Int].self, forKey: .manual) {
            userBrightness[.manual] = manualUserBrightness.threadSafe
        }
        if let clockUserBrightness = try userBrightnessContainer.decodeIfPresent([Int: Int].self, forKey: .clock) {
            userBrightness[.clock] = clockUserBrightness.threadSafe
        }

        if let syncUserContrast = try userContrastContainer.decodeIfPresent([Int: Int].self, forKey: .sync) {
            userContrast[.sync] = syncUserContrast.threadSafe
        }
        if let sensorUserContrast = try userContrastContainer.decodeIfPresent([Int: Int].self, forKey: .sensor) {
            userContrast[.sensor] = sensorUserContrast.threadSafe
        }
        if let locationUserContrast = try userContrastContainer.decodeIfPresent([Int: Int].self, forKey: .location) {
            userContrast[.location] = locationUserContrast.threadSafe
        }
        if let manualUserContrast = try userContrastContainer.decodeIfPresent([Int: Int].self, forKey: .manual) {
            userContrast[.manual] = manualUserContrast.threadSafe
        }
        if let clockUserContrast = try userContrastContainer.decodeIfPresent([Int: Int].self, forKey: .clock) {
            userContrast[.clock] = clockUserContrast.threadSafe
        }

        if let sensorFactor = try brightnessCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .sensor) {
            brightnessCurveFactors[.sensor] = sensorFactor > 0 ? sensorFactor : DEFAULT_SENSOR_BRIGHTNESS_CURVE_FACTOR
        }
        if let syncFactor = try brightnessCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .sync) {
            brightnessCurveFactors[.sync] = syncFactor > 0 ? syncFactor : DEFAULT_SYNC_BRIGHTNESS_CURVE_FACTOR
        }
        if let locationFactor = try brightnessCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .location) {
            brightnessCurveFactors[.location] = locationFactor > 0 ? locationFactor : DEFAULT_LOCATION_BRIGHTNESS_CURVE_FACTOR
        }
        if let manualFactor = try brightnessCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .manual) {
            brightnessCurveFactors[.manual] = manualFactor > 0 ? manualFactor : DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR
        }
        if let clockFactor = try brightnessCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .clock) {
            brightnessCurveFactors[.clock] = clockFactor > 0 ? clockFactor : DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR
        }

        if let sensorFactor = try contrastCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .sensor) {
            contrastCurveFactors[.sensor] = sensorFactor > 0 ? sensorFactor : DEFAULT_SENSOR_CONTRAST_CURVE_FACTOR
        }
        if let syncFactor = try contrastCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .sync) {
            contrastCurveFactors[.sync] = syncFactor > 0 ? syncFactor : DEFAULT_SYNC_CONTRAST_CURVE_FACTOR
        }
        if let locationFactor = try contrastCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .location) {
            contrastCurveFactors[.location] = locationFactor > 0 ? locationFactor : DEFAULT_LOCATION_CONTRAST_CURVE_FACTOR
        }
        if let manualFactor = try contrastCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .manual) {
            contrastCurveFactors[.manual] = manualFactor > 0 ? manualFactor : DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR
        }
        if let clockFactor = try contrastCurveFactorsContainer.decodeIfPresent(Double.self, forKey: .clock) {
            contrastCurveFactors[.clock] = clockFactor > 0 ? clockFactor : DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR
        }

        super.init()
        defer { initialised = true }

        preciseBrightness = brightnessToSliderValue(brightness)
        preciseContrast = contrastToSliderValue(contrast, merged: CachedDefaults[.mergeBrightnessContrast])
        preciseBrightnessContrast = brightnessToSliderValue(brightness)

        if !supportsGammaByDefault {
            useOverlay = true
        } else {
            useOverlay = (try container.decodeIfPresent(Bool.self, forKey: .useOverlay)) ?? false
        }

        if let networkControlEnabled = try enabledControlsContainer.decodeIfPresent(Bool.self, forKey: .network) {
            enabledControls[.network] = networkControlEnabled
        }
        if let appleNativeControlEnabled = try enabledControlsContainer.decodeIfPresent(Bool.self, forKey: .appleNative) {
            enabledControls[.appleNative] = appleNativeControlEnabled
        }
        if let ddcControlEnabled = try enabledControlsContainer.decodeIfPresent(Bool.self, forKey: .ddc) {
            enabledControls[.ddc] = ddcControlEnabled
        }
        if let gammaControlEnabled = try enabledControlsContainer.decodeIfPresent(Bool.self, forKey: .gamma) {
            enabledControls[.gamma] = gammaControlEnabled
        } else {
            enabledControls[.gamma] = !DDC.isSmartBuiltinDisplay(_id)
        }

        mirroredBeforeBlackOut = ((try container.decodeIfPresent(Bool.self, forKey: .mirroredBeforeBlackOut)) ?? false)
        blackOutEnabled = ((try container.decodeIfPresent(Bool.self, forKey: .blackOutEnabled)) ?? false) && !isIndependentDummy
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .brightnessBeforeBlackout)?.ns) {
            brightnessBeforeBlackout = value
        }
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .contrastBeforeBlackout)?.ns) {
            contrastBeforeBlackout = value
        }
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .minBrightnessBeforeBlackout)?.ns) {
            minBrightnessBeforeBlackout = value
        }
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .minContrastBeforeBlackout)?.ns) {
            minContrastBeforeBlackout = value
        }

        faceLightEnabled = ((try container.decodeIfPresent(Bool.self, forKey: .faceLightEnabled)) ?? false)
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .brightnessBeforeFacelight)?.ns) {
            brightnessBeforeFacelight = value
        }
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .contrastBeforeFacelight)?.ns) {
            contrastBeforeFacelight = value
        }
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .maxBrightnessBeforeFacelight)?.ns) {
            maxBrightnessBeforeFacelight = value
        }
        if let value = (try container.decodeIfPresent(UInt8.self, forKey: .maxContrastBeforeFacelight)?.ns) {
            maxContrastBeforeFacelight = value
        }

        if let value = (try container.decodeIfPresent([BrightnessSchedule].self, forKey: .schedules)),
           value.count == Display.DEFAULT_SCHEDULES.count
        {
            schedules = value
        }
        setupHotkeys()
        guard active else { return }

        if let dict = displayInfoDictionary(id) {
            infoDictionary = dict
        }
    }

    init(
        id: CGDirectDisplayID,
        serial: String? = nil,
        name: String? = nil,
        active: Bool = false,
        minBrightness: UInt8 = DEFAULT_MIN_BRIGHTNESS,
        maxBrightness: UInt8 = DEFAULT_MAX_BRIGHTNESS,
        minContrast: UInt8 = DEFAULT_MIN_CONTRAST,
        maxContrast: UInt8 = DEFAULT_MAX_CONTRAST,
        adaptive: Bool = true
    ) {
        _id = id
        self.active = active
        activeAndResponsive = active || id != GENERIC_DISPLAY_ID
        self.adaptive = adaptive && !Self.ambientLightCompensationEnabled(id)

        let isSmartBuiltin = DDC.isSmartBuiltinDisplay(id)
        isSource = isSmartBuiltin

        self.minBrightness = isSmartBuiltin ? 0 : minBrightness.ns
        self.maxBrightness = isSmartBuiltin ? 100 : maxBrightness.ns
        self.minContrast = isSmartBuiltin ? 0 : minContrast.ns
        self.maxContrast = isSmartBuiltin ? 100 : maxContrast.ns

        if isSmartBuiltin {
            preciseBrightness = AppleNativeControl.readBrightnessDisplayServices(id: id)
            brightness = (preciseBrightness * 100).ns
        } else {
            preciseBrightnessContrast = mapNumber(
                50,
                fromLow: minBrightness.d,
                fromHigh: maxBrightness.d,
                toLow: 0,
                toHigh: 100
            ) / 100.0
        }

        edidName = Self.printableName(id)
        if let n = name, !n.isEmpty {
            self.name = n
        } else {
            self.name = edidName
        }
        self.serial = (serial ?? Display.uuid(id: id))

        super.init()
        defer { initialised = true }

        useOverlay = !supportsGammaByDefault
        enabledControls[.gamma] = !isSmartBuiltin
        guard active else { return }
        if let dict = displayInfoDictionary(id) {
            infoDictionary = dict
        }

        startControls()
        setupHotkeys()
        refreshGamma()
        if supportsGamma {
            reapplyGamma()
        } else {
            shade(amount: 1.0 - preciseBrightness)
        }
        updateCornerWindow()
    }

    deinit {
        gammaWindowController?.close()
        gammaWindowController = nil
        cornerWindowController?.close()
        cornerWindowController = nil
    }

    // MARK: Internal

    // MARK: Codable

    enum CodingKeys: String, CodingKey, CaseIterable, ExpressibleByArgument {
        case id
        case name
        case edidName
        case serial
        case adaptive
        case defaultGammaRedMin
        case defaultGammaRedMax
        case defaultGammaRedValue
        case defaultGammaGreenMin
        case defaultGammaGreenMax
        case defaultGammaGreenValue
        case defaultGammaBlueMin
        case defaultGammaBlueMax
        case defaultGammaBlueValue
        case maxDDCBrightness
        case maxDDCContrast
        case maxDDCVolume
        case minDDCBrightness
        case minDDCContrast
        case minDDCVolume

        case faceLightBrightness
        case faceLightContrast

        case mirroredBeforeBlackOut
        case blackOutEnabled
        case brightnessBeforeBlackout
        case contrastBeforeBlackout
        case minBrightnessBeforeBlackout
        case minContrastBeforeBlackout

        case faceLightEnabled
        case brightnessBeforeFacelight
        case contrastBeforeFacelight
        case maxBrightnessBeforeFacelight
        case maxContrastBeforeFacelight

        case cornerRadius

        case redGain
        case greenGain
        case blueGain
        case lockedBrightness
        case lockedContrast
        case lockedBrightnessCurve
        case lockedContrastCurve
        case minContrast
        case minBrightness
        case maxContrast
        case maxBrightness
        case contrast
        case brightness
        case volume
        case audioMuted
        case canChangeVolume
        case power
        case active
        case responsiveDDC
        case input
        case hotkeyInput
        case hotkeyInput1
        case hotkeyInput2
        case hotkeyInput3
        case userBrightness
        case userContrast
        case useOverlay
        case alwaysUseNetworkControl
        case neverUseNetworkControl
        case alwaysFallbackControl
        case neverFallbackControl
        case enabledControls
        case schedules
        case brightnessCurveFactors
        case contrastCurveFactors
        case activeAndResponsive
        case hasDDC
        case hasI2C
        case hasNetworkControl
        case sendingBrightness
        case sendingContrast
        case sendingInput
        case sendingVolume
        case isSource
        case showVolumeOSD
        case applyGamma
        case brightnessOnInputChange
        case brightnessOnInputChange1
        case brightnessOnInputChange2
        case brightnessOnInputChange3
        case contrastOnInputChange
        case contrastOnInputChange1
        case contrastOnInputChange2
        case contrastOnInputChange3
        case applyBrightnessOnInputChange1
        case applyBrightnessOnInputChange2
        case applyBrightnessOnInputChange3
        case rotation

        // MARK: Internal

        static var bool: Set<CodingKeys> = [
            .adaptive,
            .lockedBrightness,
            .lockedContrast,
            .lockedBrightnessCurve,
            .lockedContrastCurve,
            .audioMuted,
            .canChangeVolume,
            .power,
            .useOverlay,
            .alwaysUseNetworkControl,
            .neverUseNetworkControl,
            .alwaysFallbackControl,
            .neverFallbackControl,
            .isSource,
            .showVolumeOSD,
            .applyGamma,
            .faceLightEnabled,
            .blackOutEnabled,
            .mirroredBeforeBlackOut,
        ]

        static var hidden: Set<CodingKeys> = [
            .hotkeyInput,
            .brightnessOnInputChange,
            .contrastOnInputChange,
        ]

        static var settableWithControl: Set<CodingKeys> = [
            .contrast,
            .brightness,
            .volume,
            .audioMuted,
            .power,
            .input,
            .redGain,
            .greenGain,
            .blueGain,
        ]

        static var settable: Set<CodingKeys> = [
            .name,
            .adaptive,
            .defaultGammaRedMin,
            .defaultGammaRedMax,
            .defaultGammaRedValue,
            .defaultGammaGreenMin,
            .defaultGammaGreenMax,
            .defaultGammaGreenValue,
            .defaultGammaBlueMin,
            .defaultGammaBlueMax,
            .defaultGammaBlueValue,
            .maxDDCBrightness,
            .maxDDCContrast,
            .maxDDCVolume,
            .minDDCBrightness,
            .minDDCContrast,
            .minDDCVolume,
            .faceLightBrightness,
            .faceLightContrast,
            .cornerRadius,
            .redGain,
            .greenGain,
            .blueGain,
            .lockedBrightness,
            .lockedContrast,
            .lockedBrightnessCurve,
            .lockedContrastCurve,
            .minContrast,
            .minBrightness,
            .maxContrast,
            .maxBrightness,
            .contrast,
            .brightness,
            .volume,
            .audioMuted,
            .canChangeVolume,
            .power,
            .input,
            .hotkeyInput1,
            .hotkeyInput2,
            .hotkeyInput3,
            .useOverlay,
            .alwaysUseNetworkControl,
            .neverUseNetworkControl,
            .alwaysFallbackControl,
            .neverFallbackControl,
            .isSource,
            .showVolumeOSD,
            .applyGamma,
            .brightnessOnInputChange1,
            .brightnessOnInputChange2,
            .brightnessOnInputChange3,
            .contrastOnInputChange1,
            .contrastOnInputChange2,
            .contrastOnInputChange3,
            .rotation,
        ]

        var isHidden: Bool {
            Self.hidden.contains(self)
        }
    }

    enum AdaptiveModeKeys: String, CodingKey {
        case sensor
        case sync
        case location
        case manual
        case clock
    }

    enum DisplayControlKeys: String, CodingKey {
        case network
        case appleNative
        case ddc
        case gamma
    }

    enum Vendor: Int64 {
        case dell = 4268
        case lg = 7789
        case samsung = 19501
        case benq = 2513
        case prism = -2
        case lenovo = 12462
        case xiaomi = 10007
        case philips = 16652
        case sceptre = 19988
        case huawei = 8950
        case eizo = 5571
        case apple = 0x610
        case asus = 1129
        case proart = 1715
        case acer = 1138
        case hp = 8718
        case unknown = -1
    }

    static let DEFAULT_SCHEDULES = [
        BrightnessSchedule(type: .disabled, hour: 0, minute: 30, brightness: 70, contrast: 65, negative: true),
        BrightnessSchedule(type: .disabled, hour: 10, minute: 20, brightness: 80, contrast: 70, negative: false),
        BrightnessSchedule(type: .disabled, hour: 0, minute: 0, brightness: 100, contrast: 75, negative: false),
        BrightnessSchedule(type: .disabled, hour: 1, minute: 30, brightness: 60, contrast: 60, negative: false),
        BrightnessSchedule(type: .disabled, hour: 7, minute: 30, brightness: 20, contrast: 45, negative: false),
    ]

    @Atomic static var applySource = true

    static let dummyNamePattern = "dummy|[^u]28e850|^28e850".r!

    @objc dynamic var appPreset: AppException? = nil

    @objc dynamic lazy var hasAmbientLightAdaptiveBrightness: Bool = DisplayServicesHasAmbientLightCompensation(id)
    dynamic lazy var controlResult = isBuiltin ? ControlResult.onlyBrightnessWorked : ControlResult.allWorked
    @objc dynamic lazy var brightnessReadWorks = controlResult.read.brightness
    @objc dynamic lazy var contrastReadWorks = controlResult.read.contrast
    @objc dynamic lazy var volumeReadWorks = controlResult.read.volume

    @objc dynamic lazy var brightnessWriteWorks = controlResult.write.brightness
    @objc dynamic lazy var contrastWriteWorks = controlResult.write.contrast
    @objc dynamic lazy var volumeWriteWorks = controlResult.write.volume

    @objc dynamic lazy var isBuiltin: Bool = DDC.isBuiltinDisplay(id)
    lazy var isSmartBuiltin: Bool = isBuiltin && isSmartDisplay
    lazy var canChangeBrightnessDS: Bool = DisplayServicesCanChangeBrightness(id)

    lazy var _hotkeyPopover: NSPopover? = POPOVERS[serial] ?? nil
    lazy var hotkeyPopoverController: HotkeyPopoverController? = {
        mainThread {
            guard let popover = _hotkeyPopover else {
                _hotkeyPopover = NSPopover()
                if let popover = _hotkeyPopover, popover.contentViewController == nil, let stb = NSStoryboard.main,
                   let controller = stb.instantiateController(
                       withIdentifier: NSStoryboard.SceneIdentifier("HotkeyPopoverController")
                   ) as? HotkeyPopoverController
                {
                    POPOVERS[serial] = _hotkeyPopover
                    popover.contentViewController = controller
                    popover.contentViewController!.loadView()
                }

                return _hotkeyPopover?.contentViewController as? HotkeyPopoverController
            }
            return popover.contentViewController as? HotkeyPopoverController
        }
    }()

    // MARK: Stored Properties

    var _idLock = NSRecursiveLock()
    var _id: CGDirectDisplayID

    var transport: Transport? = nil

    var edidName: String
    lazy var lastVolume: NSNumber = volume

    @Published @objc dynamic var activeAndResponsive: Bool = false

    var schedules: [BrightnessSchedule] = Display.DEFAULT_SCHEDULES
    @Published var enabledControls: [DisplayControl: Bool] = [
        .network: true,
        .appleNative: true,
        .ddc: true,
        .gamma: true,
    ]

    var brightnessCurveFactors: [AdaptiveModeKey: Double] = [
        .sensor: DEFAULT_SENSOR_BRIGHTNESS_CURVE_FACTOR,
        .sync: DEFAULT_SYNC_BRIGHTNESS_CURVE_FACTOR,
        .location: DEFAULT_LOCATION_BRIGHTNESS_CURVE_FACTOR,
        .manual: DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR,
        .clock: DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR,
    ]

    var contrastCurveFactors: [AdaptiveModeKey: Double] = [
        .sensor: DEFAULT_SENSOR_CONTRAST_CURVE_FACTOR,
        .sync: DEFAULT_SYNC_CONTRAST_CURVE_FACTOR,
        .location: DEFAULT_LOCATION_CONTRAST_CURVE_FACTOR,
        .manual: DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR,
        .clock: DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR,
    ]

    @objc dynamic var sentBrightnessCondition = NSCondition()
    @objc dynamic var sentContrastCondition = NSCondition()
    @objc dynamic var sentInputCondition = NSCondition()
    @objc dynamic var sentVolumeCondition = NSCondition()

    // MARK: Gamma and User values

    var infoDictionary: NSDictionary = [:]

    var userBrightness: ThreadSafeDictionary<AdaptiveModeKey, ThreadSafeDictionary<Int, Int>> = ThreadSafeDictionary()
    var userContrast: ThreadSafeDictionary<AdaptiveModeKey, ThreadSafeDictionary<Int, Int>> = ThreadSafeDictionary()

    var redMin: CGGammaValue = 0.0
    var redMax: CGGammaValue = 1.0
    var redGamma: CGGammaValue = 1.0

    var greenMin: CGGammaValue = 0.0
    var greenMax: CGGammaValue = 1.0
    var greenGamma: CGGammaValue = 1.0

    var blueMin: CGGammaValue = 0.0
    var blueMax: CGGammaValue = 1.0
    var blueGamma: CGGammaValue = 1.0

    // MARK: Misc Properties

    var onReadapt: (() -> Void)?
    var smoothStep = 1
    @AtomicLock var brightnessDataPointInsertionTask: DispatchWorkItem? = nil
    @AtomicLock var contrastDataPointInsertionTask: DispatchWorkItem? = nil

    var slowRead = false
    var slowWrite = false
    var macMiniHDMI = false

    var onControlChange: ((Control) -> Void)? = nil
    @AtomicLock var context: [String: Any]? = nil

    lazy var isForTesting = isTestID(id)

    var observers: Set<AnyCancellable> = []

    lazy var primaryMirrorScreen: NSScreen? = {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification, object: nil)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.primaryMirrorScreen = self.getPrimaryMirrorScreen()
                asyncEvery(2.seconds, uniqueTaskKey: "primaryMirrorScreen-\(self.serial)", runs: 5, skipIfExists: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.primaryMirrorScreen = self.getPrimaryMirrorScreen()
                }
            }
            .store(in: &observers)

        return getPrimaryMirrorScreen()
    }()

    lazy var secondaryMirrorScreenID: CGDirectDisplayID? = {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification, object: nil)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.secondaryMirrorScreenID = self.getSecondaryMirrorScreenID()
                asyncEvery(
                    2.seconds,
                    uniqueTaskKey: "secondaryMirrorScreen-\(self.serial)",
                    runs: 5,
                    skipIfExists: false
                ) { [weak self] _ in
                    guard let self = self else { return }
                    self.secondaryMirrorScreenID = self.getSecondaryMirrorScreenID()
                }
            }
            .store(in: &observers)

        return getSecondaryMirrorScreenID()
    }()

    lazy var screen: NSScreen? = {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification, object: nil)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.screen = self.getScreen()
                asyncEvery(2.seconds, uniqueTaskKey: "screen-\(self.serial)", runs: 5, skipIfExists: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.screen = self.getScreen()
                }
            }
            .store(in: &observers)

        return getScreen()
    }()

    lazy var armProps = DisplayController.armDisplayProperties(display: self)
    @Atomic var force = false

    @Atomic var faceLightEnabled = false
    lazy var brightnessBeforeFacelight = brightness
    lazy var contrastBeforeFacelight = contrast
    lazy var maxBrightnessBeforeFacelight = maxBrightness
    lazy var maxContrastBeforeFacelight = maxContrast

    @Atomic var mirroredBeforeBlackOut = false
    @Atomic @objc dynamic var blackOutEnabled = false
    lazy var brightnessBeforeBlackout = brightness
    lazy var contrastBeforeBlackout = contrast
    lazy var minBrightnessBeforeBlackout = minBrightness
    lazy var minContrastBeforeBlackout = minContrast

    @Atomic var inSmoothTransition = false

    lazy var hotkeyIdentifiers = [
        "toggle-last-input-\(serial)",
        "toggle-last-input2-\(serial)",
        "toggle-last-input3-\(serial)",
    ]

    lazy var gammaLockPath = "/tmp/lunar-gamma-lock-\(serial)"
    lazy var gammaDistributedLock: NSDistributedLock? = NSDistributedLock(path: gammaLockPath)

    var lastConnectionTime = Date()
    @Atomic var gammaChanged = false

    let VALID_ROTATION_VALUES: Set<Int> = [0, 90, 180, 270]
    @objc dynamic lazy var rotationTooltip: String? = canRotate ? nil : "This monitor doesn't support rotation"
    @objc dynamic lazy var inputTooltip: String? = hasDDC ? nil :
        "This monitor doesn't support input switching because DDC is not available"

    lazy var defaultGammaTable = GammaTable(for: id)
    var lunarGammaTable: GammaTable? = nil
    var lastGammaTable: GammaTable? = nil

    // MARK: Gamma

    let DEFAULT_GAMMA_PARAMETERS: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (0, 1, 1, 0, 1, 1, 0, 1, 1)

    @Atomic var settingGamma: Bool = false

    lazy var isSidecar: Bool = DDC.isSidecarDisplay(id, name: edidName)
    lazy var isAirplay: Bool = DDC.isAirplayDisplay(id, name: edidName)
    lazy var isVirtual: Bool = DDC.isVirtualDisplay(id, name: edidName)
    lazy var isProjector: Bool = DDC.isProjectorDisplay(id, name: edidName)

    @objc dynamic lazy var supportsGamma: Bool = supportsGammaByDefault && !useOverlay
    @objc dynamic lazy var supportsGammaByDefault: Bool = !isSidecar && !isAirplay && !isVirtual && !isProjector

    @objc dynamic lazy var panelModes: [MPDisplayMode] = {
        let modes = ((panel?.allModes() as? [MPDisplayMode]) ?? []).filter {
            (panel?.isTV ?? false) || !($0.isTVMode && $0.tvMode != 0)
        }
        guard !modes.isEmpty else { return modes }

        let grouped = Dictionary(grouping: modes, by: \.depth)
        return Array(grouped.values.map { $0.sorted(by: { $0.dotsPerInch <= $1.dotsPerInch }).reversed() }.joined())
    }()

    var modeChangeAsk = true

    lazy var isOnline = NSScreen.isOnline(id)

    @objc dynamic lazy var isSmartDisplay = panel?.isSmartDisplay ?? DisplayServicesIsSmartDisplay(id)

    @Atomic var shouldStopBrightnessTransition = true
    @Atomic var shouldStopContrastTransition = true
    @Atomic var lastWrittenBrightness: UInt8 = 50
    @Atomic var lastWrittenContrast: UInt8 = 50

    let DEFAULT_DDC_BLOCKERS = """
    * Disable any **Ambient Light Sensing** feature
    * Disable any **Automatic Brightness** or **Dynamic Brightness** feature
    * Set **Picture Mode** or **Preset** to `Custom`, `Standard` or `User`
    """
    let DDC_BLOCKERS_TRAILER = """
    #### Other possible blockers

    * Some `HDMI-to-USB-C` Cables
        * If possible, try a `DisplayPort to USB-C` cable
    * Smart monitors
        * Samsung M7/M9
        * Samsung G7/G9
    * Non-compliant hub/dock/adapter

    For more information, [click here](https://lunar.fyi/faq#brightness-not-changing).
    """

    @Atomic var applyPreciseValue = true

    @objc dynamic lazy var preciseMaxBrightness: Double = maxBrightness.doubleValue / 100.0
    @objc dynamic lazy var preciseMinBrightness: Double = minBrightness.doubleValue / 100.0
    @objc dynamic lazy var preciseMaxContrast: Double = maxContrast.doubleValue / 100.0
    @objc dynamic lazy var preciseMinContrast: Double = minContrast.doubleValue / 100.0

    #if DEBUG
        @objc dynamic lazy var showOrientation: Bool = CachedDefaults[.showOrientationInQuickActions]
    #else
        @objc dynamic lazy var showOrientation: Bool = canRotate && CachedDefaults[.showOrientationInQuickActions]
    #endif

    // #if DEBUG
    //     @objc dynamic lazy var showVolumeSlider: Bool = CachedDefaults[.showVolumeSlider]
    // #else
    @objc dynamic lazy var showVolumeSlider: Bool = canChangeVolume && CachedDefaults[.showVolumeSlider]
    lazy var preciseBrightnessKey = "setPreciseBrightness-\(serial)"
    lazy var preciseContrastKey = "setPreciseContrast-\(serial)"

    var onBrightnessCurveFactorChange: ((Double) -> Void)? = nil
    var onContrastCurveFactorChange: ((Double) -> Void)? = nil

    @Atomic var initialised = false

    var preciseContrastBeforeAppPreset: Double = 0.5

    @objc dynamic lazy var isDummy: Bool = Self.dummyNamePattern.matches(name) && vendor != .samsung

    @objc dynamic lazy var otherDisplays: [Display] = displayController.activeDisplayList.filter { $0.serial != serial }

    var preciseBrightnessContrastBeforeAppPreset: Double = 0.5 {
        didSet {
            guard CachedDefaults[.mergeBrightnessContrast] else { return }
            preciseBrightnessBeforeAppPreset = preciseBrightnessContrastBeforeAppPreset
            preciseContrastBeforeAppPreset = preciseBrightnessContrastBeforeAppPreset
        }
    }

    var preciseBrightnessBeforeAppPreset: Double = 0.5 {
        didSet {
            guard !CachedDefaults[.mergeBrightnessContrast] else { return }
            preciseBrightnessContrastBeforeAppPreset = preciseBrightnessBeforeAppPreset
        }
    }

    // #endif

    @Published @objc dynamic var canChangeVolume: Bool = true {
        didSet {
            showVolumeSlider = canChangeVolume && CachedDefaults[.showVolumeSlider]
            save()
        }
    }

    var noControls: Bool {
        guard let control = control else { return true }
        return control is GammaControl && !gammaEnabled
    }

    @objc dynamic var ambientLightAdaptiveBrightnessEnabled: Bool {
        get { Self.ambientLightCompensationEnabled(id) && hasAmbientLightAdaptiveBrightness }
        set {
            guard ambientLightCompensationEnabledByUser else { return }
            DisplayServicesEnableAmbientLightCompensation(id, newValue)
        }
    }

    var ambientLightCompensationEnabledByUser: Bool {
        guard let enabled = Self.getThreadDictValue(id, type: "ambientLightCompensationEnabledByUser") as? Bool
        else {
            // First time checking out this flag, set it manually
            let value = ambientLightAdaptiveBrightnessEnabled
            Self.setThreadDictValue(id, type: "ambientLightCompensationEnabledByUser", value: value)
            return value
        }
        if enabled { return true }
        if ambientLightAdaptiveBrightnessEnabled {
            // User must have enabled this manually in the meantime, set it to true manually
            Self.setThreadDictValue(id, type: "ambientLightCompensationEnabledByUser", value: true)
            return true
        }
        return false
    }

    var cornerWindowController: NSWindowController? {
        get { Self.getWindowController(id, type: "corner") }
        set { Self.setWindowController(id, type: "corner", windowController: newValue) }
    }

    var gammaWindowController: NSWindowController? {
        get { Self.getWindowController(id, type: "gamma") }
        set { Self.setWindowController(id, type: "gamma", windowController: newValue) }
    }

    var shadeWindowController: NSWindowController? {
        get { Self.getWindowController(id, type: "shade") }
        set { Self.setWindowController(id, type: "shade", windowController: newValue) }
    }

    var faceLightWindowController: NSWindowController? {
        get { Self.getWindowController(id, type: "faceLight") }
        set { Self.setWindowController(id, type: "faceLight", windowController: newValue) }
    }

    var prevSchedule: BrightnessSchedule? {
        let now = DateInRegion().convertTo(region: Region.local)
        return schedules.prefix(schedulesToConsider).filter(\.enabled).sorted().reversed().first { sch in
            guard let date = sch.dateInRegion else { return false }
            return date <= now
        }
    }

    var schedulesToConsider: Int {
        if CachedDefaults[.showFiveSchedules] { return 5 }
        if CachedDefaults[.showFourSchedules] { return 4 }
        if CachedDefaults[.showThreeSchedules] { return 3 }
        if CachedDefaults[.showTwoSchedules] { return 2 }
        return 1
    }

    var currentSchedule: BrightnessSchedule? {
        let now = DateInRegion().convertTo(region: Region.local)
        return schedules.prefix(schedulesToConsider).filter(\.enabled).sorted().first { sch in
            guard let (hour, minute) = sch.getHourMinute() else { return false }
            return hour == now.hour && minute == now.minute
        }
    }

    var nextSchedule: BrightnessSchedule? {
        let now = DateInRegion().convertTo(region: Region.local)
        return schedules.prefix(schedulesToConsider).filter(\.enabled).sorted().first { sch in
            guard let date = sch.dateInRegion else { return false }
            return date >= now
        }
    }

//    deinit {
//        #if DEBUG
//            log.verbose("START DEINIT: \(description)")
//            log.verbose("popover: \(_hotkeyPopover)")
//            log.verbose("POPOVERS: \(POPOVERS.map { "\($0.key): \($0.value)" })")
//            do { log.verbose("END DEINIT: \(description)") }
//        #endif
//    }

    var isInMirrorSet: Bool {
        CGDisplayIsInMirrorSet(id) != 0
    }

    lazy var panel: MPDisplay? = DisplayController.panel(with: id) {
        didSet {
            #if DEBUG
                canRotate = isForTesting || panel?.canChangeOrientation() ?? false
            #else
                canRotate = panel?.canChangeOrientation() ?? false
            #endif
        }
    }

    override var description: String {
        "\(name) [ID \(id)]"
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(serial)
        return hasher.finalize()
    }

    var id: CGDirectDisplayID {
        get { _idLock.around { _id } }
        set { _idLock.around { _id = newValue } }
    }

    @objc dynamic var serial: String {
        didSet {
            save()
        }
    }

    @objc dynamic var name: String {
        didSet {
            context = getContext()
            save()
        }
    }

    @Published @objc dynamic var applyGamma: Bool = false {
        didSet {
            save()
            if !applyGamma {
                lunarGammaTable = nil
                if apply(gamma: defaultGammaTable) {
                    lastGammaTable = defaultGammaTable
                }
                gammaChanged = false
            } else {
                reapplyGamma()
            }

            if control is GammaControl {
                displayController.adaptBrightness(for: self, force: true)
            } else {
                if applyGamma || gammaChanged {
                    resetSoftwareControl()
                }
                readapt(newValue: applyGamma, oldValue: oldValue)
            }
        }
    }

    @Published var adaptivePaused: Bool = false {
        didSet {
            readapt(newValue: adaptivePaused, oldValue: oldValue)
        }
    }

    var shouldAdapt: Bool { adaptive && !adaptivePaused && !ambientLightAdaptiveBrightnessEnabled }
    @Published @objc dynamic var adaptive: Bool {
        didSet {
            save()
            readapt(newValue: adaptive, oldValue: oldValue)
            guard hasAmbientLightAdaptiveBrightness || (ambientLightAdaptiveBrightnessEnabled && adaptive) else { return }
            ambientLightAdaptiveBrightnessEnabled = !adaptive
        }
    }

    @Published @objc dynamic var defaultGammaRedMin: NSNumber = 0.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaRedMax: NSNumber = 1.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaRedValue: NSNumber = 1.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaGreenMin: NSNumber = 0.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaGreenMax: NSNumber = 1.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaGreenValue: NSNumber = 1.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaBlueMin: NSNumber = 0.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaBlueMax: NSNumber = 1.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var defaultGammaBlueValue: NSNumber = 1.0 {
        didSet {
            save()
            reapplyGamma()
        }
    }

    @Published @objc dynamic var cornerRadius: NSNumber = 0 {
        didSet {
            save()
            updateCornerWindow()
        }
    }

    @objc dynamic var blacks: Double = 0.0 {
        didSet {
            defaultGammaRedMin = blacks.ns
            defaultGammaGreenMin = blacks.ns
            defaultGammaBlueMin = blacks.ns
        }
    }

    @objc dynamic var whites: Double = 1.0 {
        didSet {
            defaultGammaRedMax = whites.ns
            defaultGammaGreenMax = whites.ns
            defaultGammaBlueMax = whites.ns
        }
    }

    @objc dynamic var red: Double = 0.5 {
        didSet {
            if red == 0.5 {
                defaultGammaRedValue = 1.0
            } else if red > 0.5 {
                defaultGammaRedValue = mapNumber(red, fromLow: 0.5, fromHigh: 1.0, toLow: 1.0, toHigh: 0.0).ns
            } else {
                defaultGammaRedValue = mapNumber(red, fromLow: 0.0, fromHigh: 0.5, toLow: 3.0, toHigh: 1.0).ns
            }
        }
    }

    @objc dynamic var green: Double = 0.5 {
        didSet {
            if green == 0.5 {
                defaultGammaGreenValue = 1.0
            } else if green > 0.5 {
                defaultGammaGreenValue = mapNumber(green, fromLow: 0.5, fromHigh: 1.0, toLow: 1.0, toHigh: 0.0).ns
            } else {
                defaultGammaGreenValue = mapNumber(green, fromLow: 0.0, fromHigh: 0.5, toLow: 3.0, toHigh: 1.0).ns
            }
        }
    }

    @objc dynamic var blue: Double = 0.5 {
        didSet {
            if blue == 0.5 {
                defaultGammaBlueValue = 1.0
            } else if blue > 0.5 {
                defaultGammaBlueValue = mapNumber(blue, fromLow: 0.5, fromHigh: 1.0, toLow: 1.0, toHigh: 0.0).ns
            } else {
                defaultGammaBlueValue = mapNumber(blue, fromLow: 0.0, fromHigh: 0.5, toLow: 3.0, toHigh: 1.0).ns
            }
        }
    }

    @Published @objc dynamic var redGain: NSNumber = DEFAULT_COLOR_GAIN.ns {
        didSet {
            save()
            guard DDC.apply else { return }
            if let control = control, !control.setRedGain(redGain.uint8Value) {
                log.warning(
                    "Error writing RedGain using \(control.str)",
                    context: context
                )
            }
        }
    }

    @Published @objc dynamic var greenGain: NSNumber = DEFAULT_COLOR_GAIN.ns {
        didSet {
            save()
            guard DDC.apply else { return }
            if let control = control, !control.setGreenGain(greenGain.uint8Value) {
                log.warning(
                    "Error writing GreenGain using \(control.str)",
                    context: context
                )
            }
        }
    }

    @Published @objc dynamic var blueGain: NSNumber = DEFAULT_COLOR_GAIN.ns {
        didSet {
            save()
            guard DDC.apply else { return }
            if let control = control, !control.setBlueGain(blueGain.uint8Value) {
                log.warning(
                    "Error writing BlueGain using \(control.str)",
                    context: context
                )
            }
        }
    }

    @Published @objc dynamic var maxDDCBrightness: NSNumber = 100 {
        didSet {
            save()
            readapt(newValue: maxDDCBrightness, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var maxDDCContrast: NSNumber = 100 {
        didSet {
            save()
            readapt(newValue: maxDDCContrast, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var maxDDCVolume: NSNumber = 100 {
        didSet {
            save()
            readapt(newValue: maxDDCVolume, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var minDDCBrightness: NSNumber = 0 {
        didSet {
            save()
            readapt(newValue: minDDCBrightness, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var minDDCContrast: NSNumber = 0 {
        didSet {
            save()
            readapt(newValue: minDDCContrast, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var minDDCVolume: NSNumber = 0 {
        didSet {
            save()
            readapt(newValue: minDDCVolume, oldValue: oldValue)
        }
    }

    @objc dynamic var faceLightBrightness: NSNumber = 100 {
        didSet {
            save()
            readapt(newValue: faceLightBrightness, oldValue: oldValue)
        }
    }

    @objc dynamic var faceLightContrast: NSNumber = 90 {
        didSet {
            save()
            readapt(newValue: faceLightContrast, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var lockedBrightness: Bool = false {
        didSet {
            save()
        }
    }

    @Published @objc dynamic var lockedContrast: Bool = false {
        didSet {
            save()
        }
    }

    @Published @objc dynamic var lockedBrightnessCurve: Bool = false {
        didSet {
            save()
        }
    }

    @Published @objc dynamic var lockedContrastCurve: Bool = false {
        didSet {
            save()
        }
    }

    @Published @objc dynamic var minBrightness: NSNumber = DEFAULT_MIN_BRIGHTNESS.ns {
        didSet {
            save()
            preciseMinBrightness = minBrightness.doubleValue / 100
            readapt(newValue: minBrightness, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var maxBrightness: NSNumber = DEFAULT_MAX_BRIGHTNESS.ns {
        didSet {
            save()
            preciseMaxBrightness = maxBrightness.doubleValue / 100
            readapt(newValue: maxBrightness, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var minContrast: NSNumber = DEFAULT_MIN_CONTRAST.ns {
        didSet {
            save()
            preciseMinContrast = minContrast.doubleValue / 100
            readapt(newValue: minContrast, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var maxContrast: NSNumber = DEFAULT_MAX_CONTRAST.ns {
        didSet {
            save()
            preciseMaxContrast = maxContrast.doubleValue / 100
            readapt(newValue: maxContrast, oldValue: oldValue)
        }
    }

    var limitedBrightness: UInt8 {
        guard maxDDCBrightness.uint8Value != 100 || minDDCBrightness.uint8Value != 0 else {
            return brightness.uint8Value
        }
        return mapNumber(
            brightness.doubleValue,
            fromLow: 0,
            fromHigh: 100,
            toLow: minDDCBrightness.doubleValue,
            toHigh: maxDDCBrightness.doubleValue
        ).rounded().u8
    }

    var limitedContrast: UInt8 {
        guard maxDDCContrast.uint8Value != 100 || minDDCContrast.uint8Value != 0 else {
            return contrast.uint8Value
        }
        return mapNumber(
            contrast.doubleValue,
            fromLow: 0,
            fromHigh: 100,
            toLow: minDDCContrast.doubleValue,
            toHigh: maxDDCContrast.doubleValue
        ).rounded().u8
    }

    var limitedVolume: UInt8 {
        guard maxDDCVolume.uint8Value != 100 || minDDCVolume.uint8Value != 0 else {
            return volume.uint8Value
        }
        return mapNumber(
            volume.doubleValue,
            fromLow: 0,
            fromHigh: 100,
            toLow: minDDCVolume.doubleValue,
            toHigh: maxDDCVolume.doubleValue
        ).rounded().u8
    }

    @objc dynamic var preciseBrightnessContrast: Double = 0.5 {
        didSet {
            guard applyPreciseValue else { return }

            let (brightness, contrast) = sliderValueToBrightnessContrast(preciseBrightnessContrast)

            var smallDiff = abs(brightness.i - self.brightness.intValue) < 5
            withBrightnessTransition(smallDiff ? .instant : brightnessTransition) {
                mainThread {
                    self.brightness = brightness.ns
                    self.insertBrightnessUserDataPoint(
                        displayController.adaptiveMode.brightnessDataPoint.last,
                        brightness.i, modeKey: displayController.adaptiveModeKey
                    )
                }
            }

            smallDiff = abs(contrast.i - self.contrast.intValue) < 5
            withBrightnessTransition(smallDiff ? .instant : brightnessTransition) {
                mainThread {
                    self.contrast = contrast.ns
                    self.insertContrastUserDataPoint(
                        displayController.adaptiveMode.contrastDataPoint.last,
                        contrast.i, modeKey: displayController.adaptiveModeKey
                    )
                }
            }
        }
    }

    @objc dynamic var preciseBrightness: Double = 0.5 {
        didSet {
            guard applyPreciseValue else { return }

            var smallDiff = abs(preciseBrightness - oldValue) < 0.05

            guard !(control is GammaControl) else {
                let brightness = (preciseBrightness * 100)
                if supportsGamma {
                    setGamma(
                        brightness: brightness.u8,
                        oldBrightness: smallDiff ? nil : (oldValue * 100).u8,
                        preciseBrightness: preciseBrightness
                    )
                } else {
                    shade(amount: 1.0 - preciseBrightness, smooth: !smallDiff)
                }
                withoutDDC {
                    self.brightness = brightness.ns
                    self.insertBrightnessUserDataPoint(
                        displayController.adaptiveMode.brightnessDataPoint.last,
                        brightness.i, modeKey: displayController.adaptiveModeKey
                    )
                }
                return
            }

            guard !(control is AppleNativeControl) else {
                withBrightnessTransition(smallDiff ? .instant : brightnessTransition) {
                    mainThread {
                        let brightness = (preciseBrightness * 100)
                        self.brightness = brightness.ns
                        self.insertBrightnessUserDataPoint(
                            displayController.adaptiveMode.brightnessDataPoint.last,
                            brightness.i, modeKey: displayController.adaptiveModeKey
                        )
                    }
                }
                return
            }

            let brightness = (mapNumber(
                cap(preciseBrightness, minVal: 0.0, maxVal: 1.0),
                fromLow: 0.0,
                fromHigh: 1.0,
                toLow: minBrightness.doubleValue / 100.0,
                toHigh: maxBrightness.doubleValue / 100.0
            ) * 100).intround

            smallDiff = abs(brightness - self.brightness.intValue) < 5
            withBrightnessTransition(smallDiff ? .instant : brightnessTransition) {
                mainThread {
                    self.brightness = brightness.ns
                    self.insertBrightnessUserDataPoint(
                        displayController.adaptiveMode.brightnessDataPoint.last,
                        brightness.i, modeKey: displayController.adaptiveModeKey
                    )
                }
            }
        }
    }

    @objc dynamic var preciseContrast: Double = 0.5 {
        didSet {
            guard applyPreciseValue else { return }

            let contrast = (mapNumber(
                cap(preciseContrast, minVal: 0.0, maxVal: 1.0),
                fromLow: 0.0,
                fromHigh: 1.0,
                toLow: minContrast.doubleValue / 100.0,
                toHigh: maxContrast.doubleValue / 100.0
            ) * 100).intround

            let smallDiff = abs(contrast - self.contrast.intValue) < 5
            withBrightnessTransition(smallDiff ? .instant : brightnessTransition) {
                mainThread {
                    self.contrast = contrast.ns
                    self.insertContrastUserDataPoint(
                        displayController.adaptiveMode.contrastDataPoint.last,
                        contrast.i, modeKey: displayController.adaptiveModeKey
                    )
                }
            }
        }
    }

    @objc dynamic var preciseVolume: Double = 0.5 {
        didSet {
            guard applyPreciseValue else { return }
            volume = (preciseVolume * 100).ns
        }
    }

    @Published @objc dynamic var brightness: NSNumber = 50 {
        didSet {
            save()

            applyPreciseValue = false
            preciseBrightness = brightnessToSliderValue(brightness)
            if !lockedBrightness || lockedContrast {
                preciseBrightnessContrast = brightnessToSliderValue(brightness)
            }
            applyPreciseValue = true

            guard DDC.apply, !lockedBrightness, force || brightness != oldValue else { return }
            if control is GammaControl, !(enabledControls[.gamma] ?? false) { return }

            if !force {
                guard checkRemainingAdjustments() else { return }
            }

            guard !isForTesting else { return }
            var brightness: UInt8
            if displayController.adaptiveModeKey == AdaptiveModeKey.manual || control is GammaControl {
                brightness = cap(self.brightness.uint8Value, minVal: 0, maxVal: 100)
            } else {
                brightness = cap(self.brightness.uint8Value, minVal: minBrightness.uint8Value, maxVal: maxBrightness.uint8Value)
            }

            var oldBrightness: UInt8 = oldValue.uint8Value
            if DDC.applyLimits, maxDDCBrightness.uint8Value != 100 || minDDCBrightness.uint8Value != 0, !(control is GammaControl) {
                oldBrightness = mapNumber(
                    oldBrightness.d,
                    fromLow: 0,
                    fromHigh: 100,
                    toLow: minDDCBrightness.doubleValue,
                    toHigh: maxDDCBrightness.doubleValue
                ).rounded().u8
                brightness = mapNumber(
                    brightness.d,
                    fromLow: 0,
                    fromHigh: 100,
                    toLow: minDDCBrightness.doubleValue,
                    toHigh: maxDDCBrightness.doubleValue
                ).rounded().u8
            }

            log.verbose("Set BRIGHTNESS to \(brightness) for \(description) (old: \(oldBrightness))", context: context)
            let startTime = DispatchTime.now()

            if let control = control as? DDCControl {
                _ = control.setBrightnessDebounced(brightness, oldValue: oldBrightness)
            } else if let control = control, !control.setBrightness(brightness, oldValue: oldBrightness, onChange: nil) {
                log.warning(
                    "Error writing brightness using \(control.str)",
                    context: context
                )
            }

            let elapsedTime: UInt64 = DispatchTime.now().rawValue - startTime.rawValue
            checkSlowWrite(elapsedNS: elapsedTime)
            NotificationCenter.default.post(name: currentDataPointChanged, object: nil)
        }
    }

    @Published @objc dynamic var contrast: NSNumber = 50 {
        didSet {
            save()

            applyPreciseValue = false
            preciseContrast = contrastToSliderValue(contrast, merged: CachedDefaults[.mergeBrightnessContrast])
            if lockedBrightness && !lockedContrast {
                preciseBrightnessContrast = contrastToSliderValue(contrast)
            }
            applyPreciseValue = true

            guard DDC.apply, !lockedContrast, force || contrast != oldValue else { return }
            if control is GammaControl, !(enabledControls[.gamma] ?? false) { return }

            if !force {
                guard checkRemainingAdjustments() else { return }
            }

            guard !isForTesting else { return }
            var contrast: UInt8
            if displayController.adaptiveModeKey == AdaptiveModeKey.manual || control is GammaControl {
                contrast = cap(self.contrast.uint8Value, minVal: 0, maxVal: 100)
            } else {
                contrast = cap(self.contrast.uint8Value, minVal: minContrast.uint8Value, maxVal: maxContrast.uint8Value)
            }

            var oldContrast: UInt8 = oldValue.uint8Value
            if DDC.applyLimits, maxDDCContrast.uint8Value != 100 || minDDCContrast.uint8Value != 0, !(control is GammaControl) {
                oldContrast = mapNumber(
                    oldContrast.d,
                    fromLow: 0,
                    fromHigh: 100,
                    toLow: minDDCContrast.doubleValue,
                    toHigh: maxDDCContrast.doubleValue
                ).rounded().u8
                contrast = mapNumber(
                    contrast.d,
                    fromLow: 0,
                    fromHigh: 100,
                    toLow: minDDCContrast.doubleValue,
                    toHigh: maxDDCContrast.doubleValue
                ).rounded().u8
            }

            log.verbose("Set CONTRAST to \(contrast) for \(description) (old: \(oldContrast))", context: context)
            let startTime = DispatchTime.now()

            if let control = control as? DDCControl {
                _ = control.setContrastDebounced(contrast, oldValue: oldContrast)
            } else if let control = control, !control.setContrast(contrast, oldValue: oldContrast, onChange: nil) {
                log.warning(
                    "Error writing contrast using \(control.str)",
                    context: context
                )
            }

            let elapsedTime: UInt64 = DispatchTime.now().rawValue - startTime.rawValue
            checkSlowWrite(elapsedNS: elapsedTime)
            NotificationCenter.default.post(name: currentDataPointChanged, object: nil)
        }
    }

    @Published @objc dynamic var volume: NSNumber = 10 {
        didSet {
            if oldValue.uint8Value > 0 {
                lastVolume = oldValue
            }

            save()

            applyPreciseValue = false
            preciseVolume = volume.doubleValue / 100
            applyPreciseValue = true

            guard !isForTesting else { return }

            var volume = volume.uint8Value
            if DDC.applyLimits, maxDDCVolume.uint8Value != 100, minDDCVolume.uint8Value != 0, !(control is GammaControl) {
                volume = mapNumber(volume.d, fromLow: 0, fromHigh: 100, toLow: minDDCVolume.doubleValue, toHigh: maxDDCVolume.doubleValue)
                    .rounded().u8
            }

            if let control = control, !control.setVolume(volume) {
                log.warning(
                    "Error writing volume using \(control.str)",
                    context: context
                )
            }
        }
    }

    var canChangeOrientation: Bool {
        #if DEBUG
            if isForTesting { return true }
        #endif

        return panel?.canChangeOrientation() ?? false
    }

    @objc dynamic lazy var canRotate: Bool = canChangeOrientation {
        didSet {
            rotationTooltip = canRotate ? nil : "This monitor doesn't support rotation"
            #if DEBUG
                showOrientation = CachedDefaults[.showOrientationInQuickActions]
            #else
                showOrientation = canRotate && CachedDefaults[.showOrientationInQuickActions]
            #endif
        }
    }

    @objc dynamic lazy var rotation: Int = CGDisplayRotation(id).intround {
        didSet {
            guard DDC.apply, canRotate, VALID_ROTATION_VALUES.contains(rotation) else { return }

            reconfigure { panel in
                panel.orientation = rotation.i32
                guard modeChangeAsk, rotation != oldValue,
                      let window = appDelegate!.windowController?.window else { return }
                ask(
                    message: "Orientation Change",
                    info: "Do you want to keep this orientation?\n\nLunar will revert to the last orientation if no option is selected in 15 seconds.",
                    window: window,
                    okButton: "Keep", cancelButton: "Revert",
                    onCompletion: { [weak self] keep in
                        if !keep, let self = self {
                            self.modeChangeAsk = false
                            mainThread { self.rotation = oldValue }
                            self.modeChangeAsk = true
                        }
                    }
                )
            }
            withoutDDC {
                panelMode = panel?.currentMode
                modeNumber = panelMode?.modeNumber ?? -1
            }
        }
    }

    @objc dynamic lazy var panelMode: MPDisplayMode? = panel?.currentMode {
        didSet {
            guard DDC.apply, modeChangeAsk, let window = appDelegate!.windowController?.window else { return }
            modeNumber = panelMode?.modeNumber ?? -1
            if modeNumber != -1 {
                ask(
                    message: "Resolution Change",
                    info: "Do you want to keep this resolution?\n\nLunar will revert to the last resolution if no option is selected in 15 seconds.",
                    window: window,
                    okButton: "Keep", cancelButton: "Revert",
                    onCompletion: { [weak self] keep in
                        if !keep, let self = self {
                            self.modeChangeAsk = false
                            mainThread {
                                self.panelMode = oldValue
                                self.modeNumber = oldValue?.modeNumber ?? -1
                            }
                            self.modeChangeAsk = true
                        }
                    }
                )
            }
        }
    }

    @objc dynamic lazy var modeNumber: Int32 = panel?.currentMode?.modeNumber ?? -1 {
        didSet {
            guard modeNumber != -1, DDC.apply else { return }
            reconfigure { panel in
                panel.setModeNumber(modeNumber)
            }
        }
    }

    @Published @objc dynamic var input: NSNumber = InputSource.unknown.rawValue.ns {
        didSet {
            save()

            guard !isForTesting,
                  let input = InputSource(rawValue: input.uint8Value),
                  input != .unknown
            else { return }
            if let control = control, !control.setInput(input) {
                log.warning(
                    "Error writing input using \(control.str)",
                    context: context
                )
            }
        }
    }

    @Published @objc dynamic var hotkeyInput1: NSNumber = InputSource.unknown.rawValue.ns { didSet { save() } }
    @Published @objc dynamic var hotkeyInput2: NSNumber = InputSource.unknown.rawValue.ns { didSet { save() } }
    @Published @objc dynamic var hotkeyInput3: NSNumber = InputSource.unknown.rawValue.ns { didSet { save() } }

    @Published @objc dynamic var brightnessOnInputChange1: NSNumber = 100 { didSet { save() } }
    @Published @objc dynamic var brightnessOnInputChange2: NSNumber = 100 { didSet { save() } }
    @Published @objc dynamic var brightnessOnInputChange3: NSNumber = 100 { didSet { save() } }
    @Published @objc dynamic var contrastOnInputChange1: NSNumber = 75 { didSet { save() } }
    @Published @objc dynamic var contrastOnInputChange2: NSNumber = 75 { didSet { save() } }
    @Published @objc dynamic var contrastOnInputChange3: NSNumber = 75 { didSet { save() } }

    @Published @objc dynamic var applyBrightnessOnInputChange1: Bool = true { didSet { save() } }
    @Published @objc dynamic var applyBrightnessOnInputChange2: Bool = false { didSet { save() } }
    @Published @objc dynamic var applyBrightnessOnInputChange3: Bool = false { didSet { save() } }

    @Published @objc dynamic var audioMuted: Bool = false {
        didSet {
            save()

            guard !isForTesting else { return }
            if let control = control, !control.setMute(audioMuted) {
                log.warning(
                    "Error writing muted audio using \(control.str)",
                    context: context
                )
            }

            guard CachedDefaults[.muteVolumeZero] else { return }
            volume = audioMuted ? 0 : lastVolume
        }
    }

    @Published @objc dynamic var power: Bool = true {
        didSet {
            save()
        }
    }

    // MARK: Computed Properties

    @Published @objc dynamic var active: Bool = false {
        didSet {
            if active {
                startControls()
                refreshGamma()
                if supportsGamma {
                    reapplyGamma()
                } else {
                    shade(amount: 1.0 - preciseBrightness)
                }

                if let controller = hotkeyPopoverController {
                    #if DEBUG
                        log.info("Display \(description) is now active, enabling hotkeys")
                    #endif
                    // if controller.display == nil || controller.display!.serial != serial {
                    controller.setup(from: self)
                    // }
                    if let h = controller.hotkey1, h.isEnabled { h.register() }
                    if let h = controller.hotkey2, h.isEnabled { h.register() }
                    if let h = controller.hotkey3, h.isEnabled { h.register() }
                }
            } else {
                if let controller = hotkeyPopoverController {
                    #if DEBUG
                        log.info("Display \(description) is now inactive, disabling hotkeys")
                    #endif

                    controller.hotkey1?.unregister()
                    controller.hotkey2?.unregister()
                    controller.hotkey3?.unregister()
                }
            }

            updateCornerWindow()

            save()
            mainThread {
                activeAndResponsive = (active && responsiveDDC) || !(control is DDCControl)
                hasDDC = active && (hasI2C || hasNetworkControl)
            }
        }
    }

    @Published @objc dynamic var responsiveDDC: Bool = true {
        didSet {
            context = getContext()
            mainThread {
                activeAndResponsive = (active && responsiveDDC) || !(control is DDCControl)
            }
        }
    }

    @Published @objc dynamic var hasI2C: Bool = false {
        didSet {
            context = getContext()
            mainThread {
                hasDDC = active && (hasI2C || hasNetworkControl)
            }
        }
    }

    @Published @objc dynamic var hasNetworkControl: Bool = false {
        didSet {
            context = getContext()
            mainThread {
                hasDDC = active && (hasI2C || hasNetworkControl)
            }
        }
    }

    @objc dynamic var copyFromDisplay: Display? = nil {
        didSet {
            guard let display = copyFromDisplay else { return }
            defer { mainAsyncAfter(ms: 200) { self.copyFromDisplay = nil }}

            brightnessCurveFactors = display.brightnessCurveFactors
            contrastCurveFactors = display.contrastCurveFactors
            sliderBrightnessCurveFactor = display.sliderBrightnessCurveFactor
            sliderContrastCurveFactor = display.sliderContrastCurveFactor
        }
    }

    @objc dynamic var noDDCOrMergedBrightnessContrast: Bool { !hasDDC || CachedDefaults[.mergeBrightnessContrast] }

    @Published @objc dynamic var hasDDC: Bool = false {
        didSet {
            inputTooltip = hasDDC ? nil : "This monitor doesn't support input switching because DDC is not available"
        }
    }

    @Published @objc dynamic var useOverlay: Bool = false {
        didSet {
            supportsGammaByDefault = !isSidecar && !isAirplay && !isVirtual && !isProjector
            supportsGamma = supportsGammaByDefault && !useOverlay
            guard initialised else { return }

            save()
            resetSoftwareControl()
            if ddcEnabled {
                resetDDC()
            } else if networkEnabled {
                resetNetworkController()
            } else {
                resetControl()
            }

            thrice { d in
                displayController.adaptBrightness(for: d, force: true)
            }
        }
    }

    @objc dynamic var ddcEnabled: Bool {
        get { enabledControls[.ddc] ?? true }
        set {
            enabledControls[.ddc] = newValue
            guard initialised else { return }
            resetDDC()
        }
    }

    @objc dynamic var networkEnabled: Bool {
        get { enabledControls[.network] ?? true }
        set {
            enabledControls[.network] = newValue
            guard initialised else { return }
            resetNetworkController()
        }
    }

    @objc dynamic var appleNativeEnabled: Bool {
        get { enabledControls[.appleNative] ?? true }
        set {
            enabledControls[.appleNative] = newValue
            guard initialised else { return }
            resetControl()
        }
    }

    @objc dynamic var gammaEnabled: Bool {
        get { enabledControls[.gamma] ?? true }
        set {
            enabledControls[.gamma] = newValue
            guard initialised else { return }
            resetControl()
        }
    }

    @Published @objc dynamic var alwaysUseNetworkControl: Bool = false {
        didSet {
            context = getContext()
        }
    }

    @Published @objc dynamic var neverUseNetworkControl: Bool = false {
        didSet {
            context = getContext()
        }
    }

    @Published @objc dynamic var alwaysFallbackControl: Bool = false {
        didSet {
            context = getContext()
        }
    }

    @Published @objc dynamic var neverFallbackControl: Bool = false {
        didSet {
            context = getContext()
        }
    }

    @Published @objc dynamic var showVolumeOSD: Bool = true {
        didSet {
            context = getContext()
            save()
        }
    }

    @Published @objc dynamic var isSource: Bool {
        didSet {
            context = getContext()
            guard Self.applySource else { return }
            Self.applySource = false
            defer {
                Self.applySource = true
            }

            if isSource {
                displayController.displays.values.filter { $0.id != id }.forEach { d in
                    d.isSource = false
                }
            } else if let builtinDisplay = displayController.builtinDisplay, builtinDisplay.serial != serial {
                builtinDisplay.isSource = true
            } else if let smartDisplay = displayController.externalActiveDisplays.first(where: \.hasAmbientLightAdaptiveBrightness),
                      smartDisplay.serial != serial
            {
                smartDisplay.isSource = true
            }

            datastore.storeDisplays(displayController.displays.values.map { $0 })
            SyncMode.refresh()
        }
    }

    @objc dynamic var sliderBrightnessCurveFactor: Double {
        get {
            let factor = brightnessCurveFactor
            return factor <= 1 ?
                mapNumber(factor, fromLow: 0.01, fromHigh: 1, toLow: 1, toHigh: 0.5) :
                mapNumber(cap(factor, minVal: 1, maxVal: 9), fromLow: 1, fromHigh: 9, toLow: 0.5, toHigh: 0)
        }
        set {
            let factor = newValue <= 0.5 ?
                mapNumber(newValue, fromLow: 0, fromHigh: 0.5, toLow: 9, toHigh: 1) :
                mapNumber(newValue, fromLow: 0.5, fromHigh: 1, toLow: 1, toHigh: 0.01)
            brightnessCurveFactor = factor
        }
    }

    @objc dynamic var sliderContrastCurveFactor: Double {
        get {
            let factor = contrastCurveFactor
            return factor <= 1 ?
                mapNumber(factor, fromLow: 0.01, fromHigh: 1, toLow: 1, toHigh: 0.5) :
                mapNumber(cap(factor, minVal: 1, maxVal: 9), fromLow: 1, fromHigh: 9, toLow: 0.5, toHigh: 0)
        }
        set {
            let factor = newValue <= 0.5 ?
                mapNumber(newValue, fromLow: 0, fromHigh: 0.5, toLow: 9, toHigh: 1) :
                mapNumber(newValue, fromLow: 0.5, fromHigh: 1, toLow: 1, toHigh: 0.01)
            contrastCurveFactor = factor
        }
    }

    @objc dynamic var brightnessCurveFactor: Double {
        get { brightnessCurveFactors[displayController.adaptiveModeKey] ?? 1.0 }
        set {
            let oldValue = brightnessCurveFactors[displayController.adaptiveModeKey]
            brightnessCurveFactors[displayController.adaptiveModeKey] = newValue
            readapt(newValue: newValue, oldValue: oldValue)
            onBrightnessCurveFactorChange?(newValue)
        }
    }

    @objc dynamic var contrastCurveFactor: Double {
        get { contrastCurveFactors[displayController.adaptiveModeKey] ?? 1.0 }
        set {
            let oldValue = contrastCurveFactors[displayController.adaptiveModeKey]
            contrastCurveFactors[displayController.adaptiveModeKey] = newValue
            readapt(newValue: newValue, oldValue: oldValue)
            onContrastCurveFactorChange?(newValue)
        }
    }

    @Published @objc dynamic var sendingBrightness: Bool = false {
        didSet {
            manageSendingValue(.sendingBrightness, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var sendingContrast: Bool = false {
        didSet {
            manageSendingValue(.sendingContrast, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var sendingInput: Bool = false {
        didSet {
            manageSendingValue(.sendingInput, oldValue: oldValue)
        }
    }

    @Published @objc dynamic var sendingVolume: Bool = false {
        didSet {
            manageSendingValue(.sendingVolume, oldValue: oldValue)
        }
    }

    var readableID: String {
        if name.isEmpty || name == "Unknown" {
            return shortHash(string: serial)
        }
        let safeName = "[^\\w\\d]+".r!.replaceAll(in: name.lowercased(), with: "")
        return "\(safeName)-\(shortHash(string: serial))"
    }

    var alternativeControlForAppleNative: Control? = nil {
        didSet {
            context = getContext()
            if let control = alternativeControlForAppleNative {
                log.debug(
                    "Display got alternativeControlForAppleNative \(control.str)",
                    context: context
                )
                mainAsyncAfter(ms: 1) { [weak self] in
                    guard let self = self else { return }
                    self.hasNetworkControl = control is NetworkControl || self.alternativeControlForAppleNative is NetworkControl
                }
            }
        }
    }

    @AtomicLock var control: Control? = nil {
        didSet {
            context = getContext()
            if let control = control {
                log.debug(
                    "Display got \(control.str)",
                    context: context
                )
                mainAsyncAfter(ms: 1) { [weak self] in
                    guard let self = self else { return }
                    self.activeAndResponsive = (self.active && self.responsiveDDC) || !(self.control is DDCControl)
                    self.hasNetworkControl = self.control is NetworkControl || self.alternativeControlForAppleNative is NetworkControl
                }
                if !(oldValue is GammaControl), control is GammaControl {
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: FLUX_IDENTIFIER).first {
                        (control as! GammaControl).fluxChecker(flux: app)
                    }
                    setGamma()
                }
                if control is AppleNativeControl {
                    alternativeControlForAppleNative = getBestAlternativeControlForAppleNative()
                }
                onControlChange?(control)
            }
        }
    }

    var defaultGammaChanged: Bool {
        defaultGammaRedMin.floatValue != 0 ||
            defaultGammaRedMax.floatValue != 1 ||
            defaultGammaRedValue.floatValue != 1 ||
            defaultGammaGreenMin.floatValue != 0 ||
            defaultGammaGreenMax.floatValue != 1 ||
            defaultGammaGreenValue.floatValue != 1 ||
            defaultGammaBlueMin.floatValue != 0 ||
            defaultGammaBlueMax.floatValue != 1 ||
            defaultGammaBlueValue.floatValue != 1
    }

    var vendor: Vendor {
        guard let vendorID = infoDictionary[kDisplayVendorID] as? Int64, let v = Vendor(rawValue: vendorID) else {
            return .unknown
        }
        return v
    }

    var hasBrightnessChangeObserver: Bool { Self.isObservingBrightnessChangeDS(id) }

    var displaysInMirrorSet: [Display]? {
        guard isInMirrorSet else { return nil }
        return displayController.activeDisplayList.filter { d in
            d.id == id || d.primaryMirrorScreen?.displayID == id || d.secondaryMirrorScreenID == id
        }
    }

    var primaryMirror: Display? {
        guard let id = primaryMirrorScreen?.displayID else { return nil }
        return displayController.activeDisplays[id]
    }

    var secondaryMirror: Display? {
        guard let id = secondaryMirrorScreenID else { return nil }
        return displayController.activeDisplays[id]
    }

    var isInHardwareMirrorSet: Bool {
        guard isInMirrorSet else { return false }

        if let primary = primaryMirrorScreen {
            return !primary.isDummy
        }
        return true
    }

    var isInDummyMirrorSet: Bool {
        guard isInMirrorSet else { return false }

        if isDummy { return true }
        if let primary = primaryMirrorScreen {
            return primary.isDummy
        }
        if let secondary = secondaryMirrorScreenID {
            return DDC.isDummyDisplay(secondary)
        }
        return false
    }

    var isIndependentDummy: Bool {
        isDummy && !isInMirrorSet
    }

    static func ambientLightCompensationEnabled(_ id: CGDirectDisplayID) -> Bool {
        var enabled = false
        DisplayServicesAmbientLightCompensationEnabled(id, &enabled)
        return enabled
    }

    static func isObservingBrightnessChangeDS(_ id: CGDirectDisplayID) -> Bool {
        mainThread { Thread.current.threadDictionary["observingBrightnessChangeDS-\(id)"] as? Bool } ?? false
    }

    static func observeBrightnessChangeDS(_ id: CGDirectDisplayID) -> Bool {
        guard DisplayServicesCanChangeBrightness(id), !isObservingBrightnessChangeDS(id) else { return true }

        let result = DisplayServicesRegisterForBrightnessChangeNotifications(id, id) { _, observer, _, _, userInfo in
            guard let value = (userInfo as NSDictionary?)?["value"] as? Double, let observer = observer else { return }
            let id = CGDirectDisplayID(UInt(bitPattern: observer))
            guard let display = displayController.activeDisplays[id] else {
                return
            }
            let newBrightness = (value * 100).u8
            guard display.brightness.uint8Value != newBrightness else {
                return
            }

            display.withoutDDC {
                mainThread { display.brightness = newBrightness.ns }
            }
        }
        mainThread { Thread.current.threadDictionary["observingBrightnessChangeDS-\(id)"] = (result == KERN_SUCCESS) }

        return result == KERN_SUCCESS
    }

    static func getThreadDictValue(_ id: CGDirectDisplayID, type: String) -> Any? {
        windowControllerQueue.sync { Thread.current.threadDictionary["\(type)-\(id)"] }
    }

    static func setThreadDictValue(_ id: CGDirectDisplayID, type: String, value: Any?) {
        windowControllerQueue.sync { Thread.current.threadDictionary["\(type)-\(id)"] = value }
    }

    static func getWindowController(_ id: CGDirectDisplayID, type: String) -> NSWindowController? {
        windowControllerQueue.sync { Thread.current.threadDictionary["window-\(type)-\(id)"] as? NSWindowController }
    }

    static func setWindowController(_ id: CGDirectDisplayID, type: String, windowController: NSWindowController?) {
        windowControllerQueue.sync { Thread.current.threadDictionary["window-\(type)-\(id)"] = windowController }
    }

    // MARK: EDID

    static func printableName(_ id: CGDirectDisplayID) -> String {
        #if DEBUG
            switch id {
            case TEST_DISPLAY_ID:
                return "LG Ultra HD"
            case TEST_DISPLAY_PERSISTENT_ID:
                return "DELL U3419W"
            case TEST_DISPLAY_PERSISTENT2_ID:
                return "LG Ultrafine"
            case TEST_DISPLAY_PERSISTENT3_ID:
                return "Pro Display XDR"
            case TEST_DISPLAY_PERSISTENT4_ID:
                return "Thunderbolt"
            default:
                break
            }
        #endif

        if DDC.isBuiltinDisplay(id, checkName: false) {
            return "Built-in"
        }

        if DDC.isSidecarDisplay(id, checkName: false) {
            return "Sidecar"
        }

        if let screen = NSScreen.forDisplayID(id) {
            return screen.localizedName
        }

        if let infoDict = displayInfoDictionary(id), let names = infoDict["DisplayProductName"] as? [String: String],
           let name = names[Locale.current.identifier] ?? names["en_US"] ?? names.first?.value
        {
            return name
        }

//        if var name = DDC.getDisplayName(for: id) {
//            name = name.stripped
//            let minChars = floor(name.count.d * 0.8)
//            if name.utf8.map({ c in (0x21 ... 0x7E).contains(c) ? 1 : 0 }).reduce(0, { $0 + $1 }) >= minChars {
//                return name
//            }
//        }
        return "Unknown"
    }

    static func uuid(id: CGDirectDisplayID) -> String {
        #if DEBUG
            switch id {
            case TEST_DISPLAY_ID:
                return "TEST_DISPLAY_SERIAL"
            case TEST_DISPLAY_PERSISTENT_ID:
                return "TEST_DISPLAY_PERSISTENT_SERIAL"
            case TEST_DISPLAY_PERSISTENT2_ID:
                return "TEST_DISPLAY_PERSISTENT2_SERIAL"
            case TEST_DISPLAY_PERSISTENT3_ID:
                return "TEST_DISPLAY_PERSISTENT3_SERIAL"
            case TEST_DISPLAY_PERSISTENT4_ID:
                return "TEST_DISPLAY_PERSISTENT4_SERIAL"
            default:
                break
            }
        #endif

        if let uuid = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuidValue = uuid.takeRetainedValue()
            let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuidValue) as String
            return uuidString
        }
        if let edid = Display.edid(id: id) {
            return edid
        }
        return String(describing: id)
    }

    static func edid(id: CGDirectDisplayID) -> String? {
        DDC.getEdidData(displayID: id)?.map { $0 }.str(hex: true)
    }

    // MARK: User Data Points

    static func insertDataPoint(values: inout ThreadSafeDictionary<Int, Int>, featureValue: Int, targetValue: Int, logValue: Bool = true) {
        for (x, y) in values.dictionary {
            if (x < featureValue && y > targetValue) || (x > featureValue && y < targetValue) {
                if logValue {
                    log.debug("Removing data point \(x) => \(y)")
                }
                values.removeValue(forKey: x)
            }
        }
        if logValue {
            log.debug("Adding data point \(featureValue) => \(targetValue)")
        }
        values[featureValue] = targetValue
    }

    static func getSecondaryMirrorScreenID(_ id: CGDirectDisplayID) -> CGDirectDisplayID? {
        guard displayIsInMirrorSet(id),
              let secondaryID = NSScreen.onlineDisplayIDs.first(where: { CGDisplayMirrorsDisplay($0) == id })
        else { return nil }
        return secondaryID
    }

    static func getPrimaryMirrorScreen(_ id: CGDirectDisplayID) -> NSScreen? {
        guard displayIsInMirrorSet(id),
              let primaryID = NSScreen.onlineDisplayIDs.first(where: { CGDisplayMirrorsDisplay(id) == $0 })
        else { return nil }
        return NSScreen.screens.first(where: { screen in screen.hasDisplayID(primaryID) })
    }

    func observeBrightnessChangeDS() -> Bool {
        Self.observeBrightnessChangeDS(id)
    }

    func sliderValueToBrightness(_ brightness: PreciseBrightness) -> NSNumber {
        (mapNumber(
            cap(brightness, minVal: 0.0, maxVal: 1.0),
            fromLow: 0.0,
            fromHigh: 1.0,
            toLow: minBrightness.doubleValue / 100.0,
            toHigh: maxBrightness.doubleValue / 100.0
        ) * 100).intround.ns
    }

    func sliderValueToContrast(_ contrast: PreciseContrast) -> NSNumber {
        (mapNumber(
            cap(contrast, minVal: 0.0, maxVal: 1.0),
            fromLow: 0.0,
            fromHigh: 1.0,
            toLow: minContrast.doubleValue / 100.0,
            toHigh: maxContrast.doubleValue / 100.0
        ) * 100).intround.ns
    }

    func brightnessToSliderValue(_ brightness: NSNumber) -> PreciseBrightness {
        mapNumber(
            cap(brightness.doubleValue, minVal: 0, maxVal: 100),
            fromLow: minBrightness.doubleValue,
            fromHigh: maxBrightness.doubleValue,
            toLow: 0,
            toHigh: 100
        ) / 100.0
    }

    func contrastToSliderValue(_ contrast: NSNumber, merged: Bool = true) -> PreciseContrast {
        let c = mapNumber(
            cap(contrast.doubleValue, minVal: 0, maxVal: 100),
            fromLow: minContrast.doubleValue,
            fromHigh: maxContrast.doubleValue,
            toLow: 0,
            toHigh: 100
        ) / 100.0

        return merged ? pow(c, 2) : c
    }

    func sliderValueToBrightnessContrast(_ value: Double) -> (Brightness, Contrast) {
        var brightness = brightness.uint8Value
        var contrast = contrast.uint8Value

        if !lockedBrightness {
            brightness = (mapNumber(
                cap(value, minVal: 0.0, maxVal: 1.0),
                fromLow: 0.0,
                fromHigh: 1.0,
                toLow: minBrightness.doubleValue / 100.0,
                toHigh: maxBrightness.doubleValue / 100.0
            ) * 100).intround.u8
        }
        if !lockedContrast {
            contrast = (mapNumber(
                pow(cap(value, minVal: 0.0, maxVal: 1.0), 0.5),
                fromLow: 0.0,
                fromHigh: 1.0,
                toLow: minContrast.doubleValue / 100.0,
                toHigh: maxContrast.doubleValue / 100.0
            ) * 100).intround.u8
        }

        return (brightness, contrast)
    }

    func updateCornerWindow() {
        mainThread {
            guard cornerRadius.intValue > 0, active, !isInHardwareMirrorSet,
                  !isIndependentDummy, let screen = screen ?? primaryMirrorScreen
            else {
                cornerWindowController?.close()
                cornerWindowController = nil
                return
            }
            createWindow(
                "cornerWindowController",
                controller: &cornerWindowController,
                screen: screen,
                show: true,
                backgroundColor: .clear,
                level: .screenSaver,
                fillScreen: true,
                stationary: true
            )
            if let wc = cornerWindowController as? CornerWindowController {
                wc.display = self
            }
        }
    }

    func getScreen() -> NSScreen? {
        guard !isForTesting else { return nil }
        return NSScreen.screens.first(where: { screen in screen.hasDisplayID(id) })
    }

    func getSecondaryMirrorScreenID() -> CGDirectDisplayID? {
        guard !isForTesting else { return nil }
        return Self.getSecondaryMirrorScreenID(id)
    }

    func getPrimaryMirrorScreen() -> NSScreen? {
        guard !isForTesting else { return nil }
        return Self.getPrimaryMirrorScreen(id)
    }

    func refreshPanel() {
        withoutDDC {
            rotation = CGDisplayRotation(id).intround

            guard let mgr = DisplayController.panelManager else { return }
            panel = mgr.display(withID: id.i32) as? MPDisplay

            panelMode = panel?.currentMode
            modeNumber = panel?.currentMode?.modeNumber ?? -1
        }
    }

    func shade(amount: Double, smooth: Bool = true) {
        guard !isInHardwareMirrorSet, !isIndependentDummy, let screen = screen ?? primaryMirrorScreen,
              timeSince(lastConnectionTime) >= 5
        else {
            shadeWindowController?.close()
            shadeWindowController = nil
            return
        }

        let key = "shade-0-\(serial)"
        cancelTask(key)
        mainThread {
            if shadeWindowController?.window == nil {
                createWindow(
                    "shadeWindowController",
                    controller: &shadeWindowController,
                    screen: screen,
                    show: true,
                    backgroundColor: .clear,
                    level: .screenSaver,
                    fillScreen: true,
                    stationary: true
                )

                if let w = shadeWindowController?.window {
                    w.ignoresMouseEvents = true
                    w.contentView?.wantsLayer = true

                    w.contentView?.alphaValue = 0.0
                    w.contentView?.bg = NSColor.black
                    w.contentView?.setNeedsDisplay(w.frame)
                }
            }
            guard let w = shadeWindowController?.window else { return }
            w.setFrameOrigin(CGPoint(x: screen.frame.minX, y: screen.frame.minY))
            w.setFrame(screen.frame, display: false)

            let delay = brightnessTransition == .slow ? 2.0 : 0.6
            if smooth { w.contentView?.transition(delay) }
            w.contentView?.alphaValue = mapNumber(
                cap(amount, minVal: 0.0, maxVal: 1.0),
                fromLow: 0.0,
                fromHigh: 1.0,
                toLow: 0.01,
                toHigh: 0.85
            )

            if amount == 0, smooth {
                asyncAfter(ms: (delay * 1000).intround + 100, uniqueTaskKey: key, mainThread: true) {
                    w.contentView?.alphaValue = 0
                }
            }
        }
    }

    func resetSoftwareControl() {
        guard active else { return }
        resetGamma()
        shadeWindowController?.close()
        shadeWindowController = nil
    }

    func reconfigure(_ action: (MPDisplay) -> Void) {
        guard let panel = panel, let manager = DisplayController.panelManager,
              manager.tryLockAccess()
        else { return }

        manager.notifyWillReconfigure()
        action(panel)
        manager.notifyReconfigure()
        manager.unlockAccess()
    }

    func reapplyGamma() {
        if defaultGammaChanged, applyGamma {
            refreshGamma()
        } else {
            lunarGammaTable = nil
        }

        if control is GammaControl {
            setGamma()
        } else if applyGamma, !blackOutEnabled {
            resetSoftwareControl()
        }
    }

    func thrice(_ action: @escaping ((Display) -> Void), onFinish: ((Display) -> Void)? = nil) {
        asyncNow { [weak self] in
            self?.withoutSmoothTransition {
                self?.withForce {
                    for _ in 1 ... 3 { if let self = self { action(self) } }
                    if let self = self {
                        onFinish?(self)
                    }
                }
            }
        }
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Display else {
            return false
        }
        return serial == other.serial
    }

    // MARK: "Sending" states

    func manageSendingValue(_ key: CodingKeys, oldValue _: Bool) {
        let name = key.rawValue
        guard let value = value(forKey: name) as? Bool,
              let condition =
              self.value(forKey: name.replacingOccurrences(of: "sending", with: "sent") + "Condition") as? NSCondition
        else {
            log.error("No condition property found for \(name)")
            return
        }

        if !value {
            condition.broadcast()
        } else {
            let subscriberKey = "\(name)-\(serial)"
            debounce(ms: 5000, uniqueTaskKey: name, subscriberKey: subscriberKey) { [weak self] in
                guard let self = self else {
                    cancelTask(name, subscriberKey: subscriberKey)
                    return
                }
                self.setValue(false, forKey: name)

                guard let condition = self.value(
                    forKey: name.replacingOccurrences(of: "sending", with: "sent") + "Condition"
                ) as? NSCondition
                else {
                    log.error("No condition property found for \(name)")
                    return
                }
                condition.broadcast()
            }
        }
    }

    // MARK: Functions

    func getContext() -> [String: Any] {
        [
            "connected": active,
            "name": name,
            "id": id,
            "serial": serial,
            "control": control?.str ?? "Unknown",
            "alternativeControlForAppleNative": alternativeControlForAppleNative?.str ?? "Unknown",
            "hasI2C": hasI2C,
            "hasNetworkControl": hasNetworkControl,
            "alwaysFallbackControl": alwaysFallbackControl,
            "neverFallbackControl": neverFallbackControl,
            "alwaysUseNetworkControl": alwaysUseNetworkControl,
            "neverUseNetworkControl": neverUseNetworkControl,
            "isAppleDisplay": isAppleDisplay(),
            "isSource": isSource,
            "showVolumeOSD": showVolumeOSD,
            "applyGamma": applyGamma,
        ]
    }

    func getBestControl(reapply: Bool = true) -> Control {
        let gammaControl = GammaControl(display: self)
        // guard supportsGamma else {return gammaControl}

        let networkControl = NetworkControl(display: self)
        let appleNativeControl = AppleNativeControl(display: self)
        let ddcControl = DDCControl(display: self)

        if appleNativeControl.isAvailable() {
            if reapply, applyGamma || gammaChanged {
                if !blackOutEnabled { resetSoftwareControl() }
                appleNativeControl.reapply()
            }
            return appleNativeControl
        }
        if ddcControl.isAvailable() {
            if reapply, applyGamma || gammaChanged {
                if !blackOutEnabled { resetSoftwareControl() }
                ddcControl.reapply()
            }
            return ddcControl
        }
        if networkControl.isAvailable() {
            if reapply, applyGamma || gammaChanged {
                if !blackOutEnabled { resetSoftwareControl() }
                networkControl.reapply()
            }
            return networkControl
        }

        return gammaControl
    }

    func getBestAlternativeControlForAppleNative() -> Control? {
        let networkControl = NetworkControl(display: self)
        let ddcControl = DDCControl(display: self)

        if ddcControl.isAvailable() {
            return ddcControl
        }
        if networkControl.isAvailable() {
            return networkControl
        }

        return nil
    }

    func values(_ monitorValue: MonitorValue, modeKey: AdaptiveModeKey) -> (Double, Double, Double, [Int: Int]) {
        var minValue, maxValue, value: Double
        var userValues: [Int: Int]

        switch monitorValue {
        case let .preciseBrightness(brightness):
            value = brightness
            minValue = minBrightness.doubleValue
            maxValue = maxBrightness.doubleValue
            userValues = userBrightness[modeKey]?.dictionary ?? [:]
        case let .preciseContrast(contrast):
            value = contrast
            minValue = minContrast.doubleValue
            maxValue = maxContrast.doubleValue
            userValues = userContrast[modeKey]?.dictionary ?? [:]
        case let .brightness(brightness):
            value = brightness.d
            minValue = minBrightness.doubleValue
            maxValue = maxBrightness.doubleValue
            userValues = userBrightness[modeKey]?.dictionary ?? [:]
        case let .contrast(contrast):
            value = contrast.d
            minValue = minContrast.doubleValue
            maxValue = maxContrast.doubleValue
            userValues = userContrast[modeKey]?.dictionary ?? [:]
        case let .nsBrightness(brightness):
            value = brightness.doubleValue
            minValue = minBrightness.doubleValue
            maxValue = maxBrightness.doubleValue
            userValues = userBrightness[modeKey]?.dictionary ?? [:]
        case let .nsContrast(contrast):
            value = contrast.doubleValue
            minValue = minContrast.doubleValue
            maxValue = maxContrast.doubleValue
            userValues = userContrast[modeKey]?.dictionary ?? [:]
        }

        return (value, minValue, maxValue, userValues)
    }

    func startControls() {
        guard !isGeneric(id) else { return }

        if CachedDefaults[.refreshValues] {
            serialQueue.async { [weak self] in
                guard let self = self else { return }
                self.refreshBrightness()
                self.refreshContrast()
                self.refreshVolume()
                // self.refreshInput()
                self.refreshColors()
            }
        }
        refreshGamma()

        startI2CDetection()
        detectI2C()

        control = getBestControl()

        guard isSmartBuiltin else { return }
        let listensForBrightnessChange = observeBrightnessChangeDS() && hasBrightnessChangeObserver

        asyncEvery(
            listensForBrightnessChange ? 3.seconds : 1.seconds,
            uniqueTaskKey: "Builtin Brightness Refresher",
            skipIfExists: true,
            eager: true
        ) { [weak self] timer in
            guard let self = self, !screensSleeping.load(ordering: .relaxed), !(self.control is GammaControl) else {
                timer.tolerance = 10
                return
            }
            if timer.tolerance != 1 { timer.tolerance = 1 }
            self.refreshBrightness()
        }
        asyncEvery(10.seconds, uniqueTaskKey: "Builtin Contrast Refresher", skipIfExists: true, eager: true) { [weak self] timer in
            guard let self = self, !screensSleeping.load(ordering: .relaxed), !(self.control is GammaControl) else {
                timer.tolerance = 30
                return
            }

            if timer.tolerance != 10 { timer.tolerance = 10 }
            self.refreshContrast()
        }
    }

    func matchesEDIDUUID(_ edidUUID: String) -> Bool {
        let uuids = possibleEDIDUUIDs()
        guard !uuids.isEmpty else {
            log.info("No EDID UUID pattern to test with \(edidUUID) for display \(self)")
            return false
        }

        return uuids.contains { uuid in
            guard let uuidPattern = uuid.r else { return false }
            log.info("Testing EDID UUID pattern \(uuid) with \(edidUUID) for display \(self)")

            let matched = uuidPattern.matches(edidUUID)
            if matched {
                log.info("Matched EDID UUID pattern \(uuid) with \(edidUUID) for display \(self)")
            }
            return matched
        }
    }

    func possibleEDIDUUIDs() -> [String] {
        let infoDict = infoDictionary
        guard let manufactureYear = infoDict[kDisplayYearOfManufacture] as? Int64, manufactureYear >= 1990,
              let manufactureWeek = infoDict[kDisplayWeekOfManufacture] as? Int64,
              let serialNumber = infoDict[kDisplaySerialNumber] as? Int64,
              let productID = infoDict[kDisplayProductID] as? Int64,
              let vendorID = infoDict[kDisplayVendorID] as? Int64,
              let verticalPixels = infoDict[kDisplayVerticalImageSize] as? Int64,
              let horizontalPixels = infoDict[kDisplayHorizontalImageSize] as? Int64
        else { return [] }

        let yearByte = (manufactureYear - 1990).u8.hex.uppercased()
        let weekByte = manufactureWeek.u8.hex.uppercased()
        let vendorBytes = vendorID.u16.str(reversed: true, separator: "").uppercased()
        let productBytes = productID.u16.str(reversed: false, separator: "").uppercased()
        let serialBytes = serialNumber.u32.str(reversed: false, separator: "").uppercased()
        let verticalBytes = (verticalPixels / 10).u8.hex.uppercased()
        let horizontalBytes = (horizontalPixels / 10).u8.hex.uppercased()

        return [
            "\(vendorBytes)\(productBytes)-0000-0000-\(weekByte)\(yearByte)-0104B5\(horizontalBytes)\(verticalBytes)78",
            "\(vendorBytes)\(productBytes)-\(serialBytes.prefix(4))-\(serialBytes.suffix(4))-\(weekByte)\(yearByte)-0104B5\(horizontalBytes)\(verticalBytes)78",
            "\(vendorBytes)\(productBytes)-0000-0000-\(weekByte)\(yearByte)-[\\dA-F]{6}\(horizontalBytes)\(verticalBytes)[\\dA-F]{2}",
            "\(vendorBytes)\(productBytes)-\(serialBytes.prefix(4))-\(serialBytes.suffix(4))-\(weekByte)\(yearByte)-[\\dA-F]{6}\(horizontalBytes)\(verticalBytes)[\\dA-F]{2}",
        ]
    }

    func detectI2C() {
        guard let ddcEnabled = enabledControls[.ddc], ddcEnabled, !isSmartBuiltin, supportsGammaByDefault, !isDummy
        else {
            if isSmartBuiltin {
                log.debug("Built-in smart displays don't support DDC, ignoring for display \(description)")
            }
            if !supportsGammaByDefault {
                log.debug("Virtual/Airplay displays don't support DDC, ignoring for display \(description)")
            }
            if isDummy {
                log.debug("Dummy displays don't support DDC, ignoring for display \(description)")
            }
            mainThread { hasI2C = false }
            return
        }
        if panel?.isTV ?? false {
            log.warning("This could be a TV, and TVs don't support DDC: \(description)")
        }

        #if DEBUG
            #if arch(arm64)
                hasI2C = (id == TEST_DISPLAY_ID || id == TEST_DISPLAY_PERSISTENT_ID || id == TEST_DISPLAY_PERSISTENT2_ID) ? true : DDC
                    .hasAVService(
                        displayID: id,
                        display: self,
                        ignoreCache: true
                    )
            #else
                hasI2C = (id == TEST_DISPLAY_ID || id == TEST_DISPLAY_PERSISTENT_ID || id == TEST_DISPLAY_PERSISTENT2_ID) ? true : DDC
                    .hasI2CController(
                        displayID: id,
                        ignoreCache: true
                    )
            #endif
        #else
            #if arch(arm64)
                hasI2C = DDC.hasAVService(displayID: id, display: self, ignoreCache: true)
            #else
                hasI2C = DDC.hasI2CController(displayID: id, ignoreCache: true)
            #endif
        #endif
    }

    func startI2CDetection() {
        let taskKey = "i2c-detector-\(serial)"
        asyncEvery(1.seconds, uniqueTaskKey: taskKey, runs: 15, eager: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateCornerWindow()
            self.detectI2C()
            if self.hasI2C {
                cancelTask(taskKey)
            }
        }
    }

    func setupHotkeys() {
        #if DEBUG
            log.info("Trying to setup hotkeys for \(description)")
        #endif
        guard active else { return }

        if let controller = hotkeyPopoverController {
            controller.setup(from: self)
            log.info("Initialized hotkeyPopoverController for \(description)")
        } else {
            log.info("Error initializing hotkeyPopoverController for \(description)")
        }
    }

    func redraw() {
        guard let screen = screen ?? primaryMirrorScreen else { return }
        mainThread {
            createWindow(
                "gammaWindowController",
                controller: &gammaWindowController,
                screen: screen,
                show: true,
                backgroundColor: .clear,
                level: .screenSaver,
                stationary: true
            )

            guard let w = gammaWindowController?.window,
                  let c = w.contentViewController as? GammaViewController else { return }
            c.change()
        }
    }

    func hideGammaDot() {
        mainThread {
            guard let w = gammaWindowController?.window,
                  let c = w.contentViewController as? GammaViewController else { return }
            c.hide()
        }
    }

    @objc func resetColors() {
        _ = control?.resetColors()
        if !refreshColors() {
            redGain = DEFAULT_COLOR_GAIN.ns
            greenGain = DEFAULT_COLOR_GAIN.ns
            blueGain = DEFAULT_COLOR_GAIN.ns
        }
    }

    @objc func resetLimits() {
        minDDCBrightness = 0.ns
        minDDCContrast = 0.ns
        minDDCVolume = 0.ns

        maxDDCBrightness = 100.ns
        maxDDCContrast = 100.ns
        maxDDCVolume = 100.ns
    }

    func resetControl() {
        control = getBestControl()
        if let control = control, let onControlChange = onControlChange {
            onControlChange(control)
        }

        if !gammaEnabled, applyGamma || gammaChanged || !supportsGamma {
            resetSoftwareControl()
        }

        mainAsync { [weak self] in
            guard let self = self else { return }
            self.withForce {
                #if DEBUG
                    log.debug("Setting brightness to \(self.brightness) for \(self.description)")
                #endif
                self.brightness = self.brightness.uint8Value.ns

                #if DEBUG
                    log.debug("Setting contrast to \(self.contrast) for \(self.description)")
                #endif
                self.contrast = self.contrast.uint8Value.ns
            }
        }
    }

    func resetDDC() {
        detectI2C()
        let key = "resetDDCTask"
        let subscriberKey = "\(key)-\(serial)"
        debounce(ms: 10, uniqueTaskKey: key, subscriberKey: subscriberKey) { [weak self] in
            guard let self = self else {
                cancelTask(key, subscriberKey: subscriberKey)
                return
            }
            if self.control is DDCControl {
                self.control?.resetState()
            } else {
                DDCControl(display: self).resetState()
            }

            self.resetControl()

            asyncEvery(2.seconds, uniqueTaskKey: SCREEN_WAKE_ADAPTER_TASK_KEY, runs: 3, skipIfExists: true) { _ in
                displayController.adaptBrightness(force: true)
            }
        }
    }

    func resetNetworkController() {
        let key = "resetNetworkControlTask"
        let subscriberKey = "\(key)-\(serial)"
        debounce(ms: 10, uniqueTaskKey: key, subscriberKey: subscriberKey) { [weak self] in
            guard let self = self else {
                cancelTask(key, subscriberKey: subscriberKey)
                return
            }
            if self.control is NetworkControl {
                self.control?.resetState()
            } else {
                NetworkControl.resetState(serial: self.serial)
            }

            self.resetControl()

            asyncEvery(2.seconds, uniqueTaskKey: SCREEN_WAKE_ADAPTER_TASK_KEY, runs: 5, skipIfExists: true) { _ in
                displayController.adaptBrightness(force: true)
            }
        }
    }

    @objc func resetDefaultGamma() {
        red = 0.5
        green = 0.5
        blue = 0.5
        blacks = 0
        whites = 1
        // defaultGammaRedMin = 0.0
        // defaultGammaRedMax = 1.0
        // defaultGammaRedValue = 1.0
        // defaultGammaGreenMin = 0.0
        // defaultGammaGreenMax = 1.0
        // defaultGammaGreenValue = 1.0
        // defaultGammaBlueMin = 0.0
        // defaultGammaBlueMax = 1.0
        // defaultGammaBlueValue = 1.0
        lunarGammaTable = nil
    }

    func resetBrightnessCurveFactor(mode: AdaptiveModeKey? = nil) {
        let mode = mode ?? displayController.adaptiveModeKey
        switch mode {
        case .sensor:
            brightnessCurveFactors[mode] = DEFAULT_SENSOR_BRIGHTNESS_CURVE_FACTOR
        case .sync:
            brightnessCurveFactors[mode] = DEFAULT_SYNC_BRIGHTNESS_CURVE_FACTOR
        case .location:
            brightnessCurveFactors[mode] = DEFAULT_LOCATION_BRIGHTNESS_CURVE_FACTOR
        case .manual, .clock:
            brightnessCurveFactors[mode] = DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR
        }
    }

    func resetContrastCurveFactor(mode: AdaptiveModeKey? = nil) {
        let mode = mode ?? displayController.adaptiveModeKey
        switch mode {
        case .sensor:
            contrastCurveFactors[mode] = DEFAULT_SENSOR_CONTRAST_CURVE_FACTOR
        case .sync:
            contrastCurveFactors[mode] = DEFAULT_SYNC_CONTRAST_CURVE_FACTOR
        case .location:
            contrastCurveFactors[mode] = DEFAULT_LOCATION_CONTRAST_CURVE_FACTOR
        case .manual, .clock:
            contrastCurveFactors[mode] = DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR
        }
    }

    func save(now: Bool = false) {
        if now {
            DataStore.storeDisplay(display: self, now: now)
            return
        }
        debounce(ms: 800, uniqueTaskKey: "displaySave", value: self) { display in
            DataStore.storeDisplay(display: display)
        }
    }

    func resetName() {
        name = Display.printableName(id)
    }

    func encode(to encoder: Encoder) throws {
        try displayEncodingLock.aroundThrows(ignoreMainThread: true) {
            var container = encoder.container(keyedBy: CodingKeys.self)
            var userBrightnessContainer = container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .userBrightness)
            var userContrastContainer = container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .userContrast)
            var enabledControlsContainer = container.nestedContainer(keyedBy: DisplayControlKeys.self, forKey: .enabledControls)
            var brightnessCurveFactorsContainer = container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .brightnessCurveFactors)
            var contrastCurveFactorsContainer = container.nestedContainer(keyedBy: AdaptiveModeKeys.self, forKey: .contrastCurveFactors)

            try container.encode(active, forKey: .active)
            try container.encode(adaptive, forKey: .adaptive)
            try container.encode(audioMuted, forKey: .audioMuted)
            try container.encode(canChangeVolume, forKey: .canChangeVolume)
            try container.encode(brightness.uint8Value, forKey: .brightness)
            try container.encode(contrast.uint8Value, forKey: .contrast)
            try container.encode(edidName, forKey: .edidName)

            try container.encode(defaultGammaRedMin.floatValue, forKey: .defaultGammaRedMin)
            try container.encode(defaultGammaRedMax.floatValue, forKey: .defaultGammaRedMax)
            try container.encode(defaultGammaRedValue.floatValue, forKey: .defaultGammaRedValue)
            try container.encode(defaultGammaGreenMin.floatValue, forKey: .defaultGammaGreenMin)
            try container.encode(defaultGammaGreenMax.floatValue, forKey: .defaultGammaGreenMax)
            try container.encode(defaultGammaGreenValue.floatValue, forKey: .defaultGammaGreenValue)
            try container.encode(defaultGammaBlueMin.floatValue, forKey: .defaultGammaBlueMin)
            try container.encode(defaultGammaBlueMax.floatValue, forKey: .defaultGammaBlueMax)
            try container.encode(defaultGammaBlueValue.floatValue, forKey: .defaultGammaBlueValue)

            try container.encode(maxDDCBrightness.uint8Value, forKey: .maxDDCBrightness)
            try container.encode(maxDDCContrast.uint8Value, forKey: .maxDDCContrast)
            try container.encode(maxDDCVolume.uint8Value, forKey: .maxDDCVolume)

            try container.encode(minDDCBrightness.uint8Value, forKey: .minDDCBrightness)
            try container.encode(minDDCContrast.uint8Value, forKey: .minDDCContrast)
            try container.encode(minDDCVolume.uint8Value, forKey: .minDDCVolume)

            try container.encode(faceLightBrightness.uint8Value, forKey: .faceLightBrightness)
            try container.encode(faceLightContrast.uint8Value, forKey: .faceLightContrast)

            try container.encode(mirroredBeforeBlackOut, forKey: .mirroredBeforeBlackOut)
            try container.encode(blackOutEnabled, forKey: .blackOutEnabled)
            try container.encode(brightnessBeforeBlackout.uint8Value, forKey: .brightnessBeforeBlackout)
            try container.encode(contrastBeforeBlackout.uint8Value, forKey: .contrastBeforeBlackout)
            try container.encode(minBrightnessBeforeBlackout.uint8Value, forKey: .minBrightnessBeforeBlackout)
            try container.encode(minContrastBeforeBlackout.uint8Value, forKey: .minContrastBeforeBlackout)

            try container.encode(faceLightEnabled, forKey: .faceLightEnabled)
            try container.encode(brightnessBeforeFacelight.uint8Value, forKey: .brightnessBeforeFacelight)
            try container.encode(contrastBeforeFacelight.uint8Value, forKey: .contrastBeforeFacelight)
            try container.encode(maxBrightnessBeforeFacelight.uint8Value, forKey: .maxBrightnessBeforeFacelight)
            try container.encode(maxContrastBeforeFacelight.uint8Value, forKey: .maxContrastBeforeFacelight)

            try container.encode(cornerRadius.intValue, forKey: .cornerRadius)

            try container.encode(redGain.uint8Value, forKey: .redGain)
            try container.encode(greenGain.uint8Value, forKey: .greenGain)
            try container.encode(blueGain.uint8Value, forKey: .blueGain)

            try container.encode(id, forKey: .id)
            try container.encode(lockedBrightness, forKey: .lockedBrightness)
            try container.encode(lockedContrast, forKey: .lockedContrast)
            try container.encode(lockedBrightnessCurve, forKey: .lockedBrightnessCurve)
            try container.encode(lockedContrastCurve, forKey: .lockedContrastCurve)
            try container.encode(maxBrightness.uint8Value, forKey: .maxBrightness)
            try container.encode(maxContrast.uint8Value, forKey: .maxContrast)
            try container.encode(minBrightness.uint8Value, forKey: .minBrightness)
            try container.encode(minContrast.uint8Value, forKey: .minContrast)
            try container.encode(name, forKey: .name)
            try container.encode(responsiveDDC, forKey: .responsiveDDC)
            try container.encode(serial, forKey: .serial)
            try container.encode(volume.uint8Value, forKey: .volume)
            try container.encode(input.uint8Value, forKey: .input)

            try container.encode(hotkeyInput1.uint8Value, forKey: .hotkeyInput1)
            try container.encode(hotkeyInput2.uint8Value, forKey: .hotkeyInput2)
            try container.encode(hotkeyInput3.uint8Value, forKey: .hotkeyInput3)

            try container.encode(brightnessOnInputChange1.uint8Value, forKey: .brightnessOnInputChange1)
            try container.encode(brightnessOnInputChange2.uint8Value, forKey: .brightnessOnInputChange2)
            try container.encode(brightnessOnInputChange3.uint8Value, forKey: .brightnessOnInputChange3)

            try container.encode(contrastOnInputChange1.uint8Value, forKey: .contrastOnInputChange1)
            try container.encode(contrastOnInputChange2.uint8Value, forKey: .contrastOnInputChange2)
            try container.encode(contrastOnInputChange3.uint8Value, forKey: .contrastOnInputChange3)

            try container.encode(applyBrightnessOnInputChange1, forKey: .applyBrightnessOnInputChange1)
            try container.encode(applyBrightnessOnInputChange2, forKey: .applyBrightnessOnInputChange2)
            try container.encode(applyBrightnessOnInputChange3, forKey: .applyBrightnessOnInputChange3)

            try container.encode(rotation, forKey: .rotation)

            try userBrightnessContainer.encodeIfPresent(userBrightness[.sync]?.dictionary, forKey: .sync)
            try userBrightnessContainer.encodeIfPresent(userBrightness[.sensor]?.dictionary, forKey: .sensor)
            try userBrightnessContainer.encodeIfPresent(userBrightness[.location]?.dictionary, forKey: .location)
            try userBrightnessContainer.encodeIfPresent(userBrightness[.manual]?.dictionary, forKey: .manual)
            try userBrightnessContainer.encodeIfPresent(userBrightness[.clock]?.dictionary, forKey: .clock)

            try userContrastContainer.encodeIfPresent(userContrast[.sync]?.dictionary, forKey: .sync)
            try userContrastContainer.encodeIfPresent(userContrast[.sensor]?.dictionary, forKey: .sensor)
            try userContrastContainer.encodeIfPresent(userContrast[.location]?.dictionary, forKey: .location)
            try userContrastContainer.encodeIfPresent(userContrast[.manual]?.dictionary, forKey: .manual)
            try userContrastContainer.encodeIfPresent(userContrast[.clock]?.dictionary, forKey: .clock)

            try enabledControlsContainer.encodeIfPresent(enabledControls[.network], forKey: .network)
            try enabledControlsContainer.encodeIfPresent(enabledControls[.appleNative], forKey: .appleNative)
            try enabledControlsContainer.encodeIfPresent(enabledControls[.ddc], forKey: .ddc)
            try enabledControlsContainer.encodeIfPresent(enabledControls[.gamma], forKey: .gamma)

            try brightnessCurveFactorsContainer.encodeIfPresent(brightnessCurveFactors[.sync], forKey: .sync)
            try brightnessCurveFactorsContainer.encodeIfPresent(brightnessCurveFactors[.sensor], forKey: .sensor)
            try brightnessCurveFactorsContainer.encodeIfPresent(brightnessCurveFactors[.location], forKey: .location)
            try brightnessCurveFactorsContainer.encodeIfPresent(brightnessCurveFactors[.manual], forKey: .manual)
            try brightnessCurveFactorsContainer.encodeIfPresent(brightnessCurveFactors[.clock], forKey: .clock)

            try contrastCurveFactorsContainer.encodeIfPresent(contrastCurveFactors[.sync], forKey: .sync)
            try contrastCurveFactorsContainer.encodeIfPresent(contrastCurveFactors[.sensor], forKey: .sensor)
            try contrastCurveFactorsContainer.encodeIfPresent(contrastCurveFactors[.location], forKey: .location)
            try contrastCurveFactorsContainer.encodeIfPresent(contrastCurveFactors[.manual], forKey: .manual)
            try contrastCurveFactorsContainer.encodeIfPresent(contrastCurveFactors[.clock], forKey: .clock)

            try container.encode(useOverlay, forKey: .useOverlay)
            try container.encode(alwaysUseNetworkControl, forKey: .alwaysUseNetworkControl)
            try container.encode(neverUseNetworkControl, forKey: .neverUseNetworkControl)
            try container.encode(alwaysFallbackControl, forKey: .alwaysFallbackControl)
            try container.encode(neverFallbackControl, forKey: .neverFallbackControl)
            try container.encode(power, forKey: .power)
            try container.encode(isSource, forKey: .isSource)
            try container.encode(showVolumeOSD, forKey: .showVolumeOSD)
            try container.encode(applyGamma, forKey: .applyGamma)
            try container.encode(schedules, forKey: .schedules)
        }
    }

    // MARK: Sentry

    func addSentryData() {
        SentrySDK.configureScope { [weak self] scope in
            guard let self = self, var dict = self.dictionary else { return }
            if let panel = self.panel,
               let encoded = try? encoder.encode(ForgivingEncodable(getMonitorPanelDataJSON(panel))),
               let compressed = encoded.gzip()?.base64EncodedString()
            {
                dict["panelData"] = compressed
            }
            if let encoded = try? encoder.encode(ForgivingEncodable(self.infoDictionary)),
               let compressed = encoded.gzip()?.base64EncodedString()
            {
                dict["infoDictionary"] = compressed
            }
            if var armProps = self.armProps {
                armProps.removeValue(forKey: "TimingElements")
                armProps.removeValue(forKey: "ColorElements")
                if let encoded = try? encoder.encode(ForgivingEncodable(armProps)),
                   let compressed = encoded.gzip()?.base64EncodedString()
                {
                    dict["armProps"] = compressed
                }
            }
            if let deviceDescription = self.screen?.deviceDescription,
               let encoded = try? encoder.encode(ForgivingEncodable(deviceDescription)),
               let compressed = encoded.gzip()?.base64EncodedString()
            {
                dict["deviceDescription"] = compressed
            }
            #if arch(arm64)
                let avService = DDC.AVService(displayID: self.id)
                dict["avService"] = avService == nil ? "NONE" : CFCopyDescription(avService!) as String
            #else
                dict["i2cController"] = DDC.I2CController(displayID: self.id)
            #endif

            dict["hasNetworkControl"] = self.hasNetworkControl
            dict["hasI2C"] = self.hasI2C
            dict["hasDDC"] = self.hasDDC
            dict["activeAndResponsive"] = self.activeAndResponsive
            dict["responsiveDDC"] = self.responsiveDDC
            dict["gamma"] = [
                "redMin": self.redMin,
                "redMax": self.redMax,
                "redGamma": self.redGamma,
                "greenMin": self.greenMin,
                "greenMax": self.greenMax,
                "greenGamma": self.greenGamma,
                "blueMin": self.blueMin,
                "blueMax": self.blueMax,
                "blueGamma": self.blueGamma,
            ]
            scope.setExtra(value: dict, key: "display-\(self.serial)")
        }
    }

    // MARK: AppleNative Detection

    func isUltraFine() -> Bool {
        name.contains(ULTRAFINE_NAME) || edidName.contains(ULTRAFINE_NAME)
    }

    func isThunderbolt() -> Bool {
        name.contains(THUNDERBOLT_NAME) || edidName.contains(THUNDERBOLT_NAME)
    }

    func isLEDCinema() -> Bool {
        name.contains(LED_CINEMA_NAME) || edidName.contains(LED_CINEMA_NAME)
    }

    func isCinema() -> Bool {
        name == CINEMA_NAME || edidName == CINEMA_NAME || name == CINEMA_HD_NAME || edidName == CINEMA_HD_NAME
    }

    func isColorLCD() -> Bool {
        name.contains(COLOR_LCD_NAME) || edidName.contains(COLOR_LCD_NAME)
    }

    func isAppleDisplay() -> Bool {
        isUltraFine() || isThunderbolt() || isLEDCinema() || isCinema() || isAppleVendorID()
    }

    func isAppleVendorID() -> Bool {
        guard let vendorID = infoDictionary["DisplayVendorID"] as? Int else { return false }
        return vendorID == APPLE_DISPLAY_VENDOR_ID
    }

    func checkSlowWrite(elapsedNS: UInt64) {
        if !slowWrite, elapsedNS > MAX_SMOOTH_STEP_TIME_NS * 2 {
            slowWrite = true
        }
        if slowWrite, elapsedNS < MAX_SMOOTH_STEP_TIME_NS * 2 {
            slowWrite = false
        }
    }

    func smoothTransition(
        from currentValue: UInt8,
        to value: UInt8,
        delay: TimeInterval? = nil,
        onStart: (() -> Void)? = nil,
        adjust: @escaping ((UInt8) -> Void)
    ) -> DispatchWorkItem {
        inSmoothTransition = true

        let task = DispatchWorkItem(name: "smoothTransitionDDC: \(self)", flags: .barrier) { [weak self] in
            guard let self = self else { return }

            var steps = abs(value.distance(to: currentValue))

            var step: Int
            let minVal: UInt8
            let maxVal: UInt8
            if value < currentValue {
                step = cap(-self.smoothStep, minVal: -steps, maxVal: -1)
                minVal = value
                maxVal = currentValue
            } else {
                step = cap(self.smoothStep, minVal: 1, maxVal: steps)
                minVal = currentValue
                maxVal = value
            }

            let startTime = DispatchTime.now()
            var elapsedTime: UInt64
            var elapsedSeconds: Double
            var elapsedSecondsStr: String

            onStart?()
            adjust((currentValue.i + step).u8)

            elapsedTime = DispatchTime.now().rawValue - startTime.rawValue
            elapsedSeconds = elapsedTime.d / 1_000_000_000.0
            elapsedSecondsStr = String(format: "%.3f", elapsedSeconds)
            log.debug("It took \(elapsedTime)ns (\(elapsedSecondsStr)s) to change brightness by \(step)")

            self.checkSlowWrite(elapsedNS: elapsedTime)

            steps = steps - abs(step)
            if steps <= 0 {
                adjust(value)
                return
            }

            self.smoothStep = cap((elapsedTime / MAX_SMOOTH_STEP_TIME_NS).i, minVal: 1, maxVal: 100)
            if value < currentValue {
                step = cap(-self.smoothStep, minVal: -steps, maxVal: -1)
            } else {
                step = cap(self.smoothStep, minVal: 1, maxVal: steps)
            }

            for newValue in stride(from: currentValue.i, through: value.i, by: step) {
                adjust(cap(newValue.u8, minVal: minVal, maxVal: maxVal))
                if let delay = delay {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
            adjust(value)

            elapsedTime = DispatchTime.now().rawValue - startTime.rawValue
            elapsedSeconds = elapsedTime.d / 1_000_000_000.0
            elapsedSecondsStr = String(format: "%.3f", elapsedSeconds)
            log.debug("It took \(elapsedTime)ns (\(elapsedSeconds)s) to change brightness from \(currentValue) to \(value) by \(step)")

            self.checkSlowWrite(elapsedNS: elapsedTime)

            self.inSmoothTransition = false
        }
        smoothDDCQueue.asyncAfter(deadline: DispatchTime.now(), execute: task.workItem)
        return task
    }

    func readapt<T: Equatable>(newValue: T?, oldValue: T?) {
        if let readaptListener = onReadapt {
            readaptListener()
        }
        if adaptive, displayController.adaptiveModeKey != .manual, let newVal = newValue, let oldVal = oldValue, newVal != oldVal {
            displayController.adaptBrightness(for: self, force: true)
        }
    }

    func possibleDDCBlockers() -> String {
        let specificBlockers: String
        switch vendor {
        case .dell:
            specificBlockers = """
            * Disable **Uniformity Compensation**
            * Set **Preset Mode** to `Custom` or `Standard`
            """
        case .acer:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .lg:
            specificBlockers = """
            * Disable **Uniformity**
            * Disable **Auto Brightness**
            * Set **Picture Mode** to `Custom` or `Standard`
            """
        case .samsung:
            specificBlockers = """
            * Disable **Input Signal Plus**
            * Disable **Magic Bright**
            * Disable **Eye Saver Mode**
            * Disable **Eco Saving Plus**
            * Disable **Smart ECO Saving**
            * Disable **Game Mode**
            * Disable **PIP/PBP Mode**
            * Disable **Dynamic Brightness**
            """
        case .benq:
            specificBlockers = """
            * Disable **Bright Intelligence**
            * Disable **Bright Intelligence Plus** or **B.I.+**
            * Set **Picture Mode** to `Standard`
            """
        case .prism:
            specificBlockers = """
            * Set **On-the-Fly Mode** to `Standard`
            """
        case .lenovo:
            specificBlockers = """
            * Disable **Local Dimming**
            * Disable **HDR**
            * Disable **Dynamic Contrast**
            * Set **Color Mode** to `Custom`
            * Set **Scenario Modes** to `Panel Native`
            """
        case .xiaomi:
            specificBlockers = """
            * Disable **Dynamic Brightness**
            * Set **Smart Mode** to `Standard`
            """
        case .eizo:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .apple:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .asus:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .hp:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .huawei:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .philips:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .sceptre:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .proart:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        case .unknown:
            specificBlockers = DEFAULT_DDC_BLOCKERS
        }

        return """
        #### DDC Blocking Settings

        *Note: some settings might not exist in your monitor OSD depending on the monitor model*

        Use the physical buttons of your monitor to change the following settings and try to unlock DDC controls for this monitor:

        \(specificBlockers)

        \(DDC_BLOCKERS_TRAILER)
        """
    }

    // MARK: Reading Functions

    func readRedGain() -> UInt8? {
        control?.getRedGain()
    }

    func readGreenGain() -> UInt8? {
        control?.getGreenGain()
    }

    func readBlueGain() -> UInt8? {
        control?.getBlueGain()
    }

    func readAudioMuted() -> Bool? {
        control?.getMute()
    }

    func readVolume() -> UInt8? {
        control?.getVolume()
    }

    func readContrast() -> UInt8? {
        guard !isBuiltin else {
            guard let contrast = SyncMode.readBuiltinContrast() else {
                return nil
            }
            return (contrast * 100).u8
        }
        return control?.getContrast()
    }

    func readInput() -> UInt8? {
        control?.getInput()?.rawValue
    }

    func readBrightness() -> UInt8? {
        control?.getBrightness()
    }

    @discardableResult
    func refreshColors() -> Bool {
        guard !isTestID(id) else { return false }
        let newRedGain = readRedGain()
        let newGreenGain = readGreenGain()
        let newBlueGain = readBlueGain()

        guard newRedGain != nil || newGreenGain != nil || newBlueGain != nil else {
            log.warning("Can't read color gain for \(description)")
            return false
        }

        if let newRedGain = newRedGain, newRedGain != redGain.uint8Value {
            log.info("Refreshing red gain value: \(redGain.uint8Value) <> \(newRedGain)")
            withoutSmoothTransition { withoutDDC { redGain = newRedGain.ns } }
        }
        if let newGreenGain = newGreenGain, newGreenGain != greenGain.uint8Value {
            log.info("Refreshing green gain value: \(greenGain.uint8Value) <> \(newGreenGain)")
            withoutSmoothTransition { withoutDDC { greenGain = newGreenGain.ns } }
        }
        if let newBlueGain = newBlueGain, newBlueGain != blueGain.uint8Value {
            log.info("Refreshing blue gain value: \(blueGain.uint8Value) <> \(newBlueGain)")
            withoutSmoothTransition { withoutDDC { blueGain = newBlueGain.ns } }
        }

        return true
    }

    func refreshBrightness() {
        guard !isTestID(id), !inSmoothTransition, !isUserAdjusting(), !sendingBrightness,
              !SyncMode.possibleClamshellModeSoon, !(control is GammaControl) else { return }
        guard let newBrightness = readBrightness() else {
            log.warning("Can't read brightness for \(name)")
            return
        }

        guard !inSmoothTransition, !isUserAdjusting(), !sendingBrightness else { return }
        if newBrightness != brightness.uint8Value {
            log.info("Refreshing brightness: \(brightness.uint8Value) <> \(newBrightness)")

            if displayController.adaptiveModeKey != .manual, displayController.adaptiveModeKey != .clock,
               timeSince(lastConnectionTime) > 10
            {
                insertBrightnessUserDataPoint(
                    displayController.adaptiveMode.brightnessDataPoint.last,
                    newBrightness.i, modeKey: displayController.adaptiveModeKey
                )
            }

            withoutSmoothTransition {
                withoutDDC {
                    mainThread { brightness = newBrightness.ns }
                }
            }
        }
    }

    func refreshContrast() {
        guard !isTestID(id), !inSmoothTransition, !isUserAdjusting(), !sendingContrast else { return }
        guard let newContrast = readContrast() else {
            log.warning("Can't read contrast for \(name)")
            return
        }

        guard !inSmoothTransition, !isUserAdjusting(), !sendingContrast else { return }
        if newContrast != contrast.uint8Value {
            log.info("Refreshing contrast: \(contrast.uint8Value) <> \(newContrast)")

            if displayController.adaptiveModeKey != .manual, displayController.adaptiveModeKey != .clock,
               timeSince(lastConnectionTime) > 10
            {
                insertContrastUserDataPoint(
                    displayController.adaptiveMode.contrastDataPoint.last,
                    newContrast.i, modeKey: displayController.adaptiveModeKey
                )
            }

            withoutSmoothTransition {
                withoutDDC {
                    mainThread { contrast = newContrast.ns }
                }
            }
        }
    }

    func refreshInput() {
        let hotkeys = CachedDefaults[.hotkeys]
        let hotkeyInputEnabled = hotkeyIdentifiers.compactMap { identifier in
            hotkeys.first { $0.identifier == identifier }
        }.first { $0.isEnabled }?.isEnabled ?? false

        guard !isTestID(id), !hotkeyInputEnabled else { return }
        guard let newInput = readInput() else {
            log.warning("Can't read input for \(name)")
            return
        }
        if newInput != input.uint8Value {
            log.info("Refreshing input: \(input.uint8Value) <> \(newInput)")

            withoutSmoothTransition {
                withoutDDC {
                    mainThread { input = newInput.ns }
                }
            }
        }
    }

    func refreshVolume() {
        guard !isTestID(id) else { return }
        guard let newVolume = readVolume(), let newAudioMuted = readAudioMuted() else {
            log.warning("Can't read volume for \(name)")
            return
        }

        if newAudioMuted != audioMuted {
            log.info("Refreshing mute value: \(audioMuted) <> \(newAudioMuted)")
            mainThread { audioMuted = newAudioMuted }
        }
        if newVolume != volume.uint8Value {
            log.info("Refreshing volume: \(volume.uint8Value) <> \(newVolume)")

            withoutSmoothTransition {
                withoutDDC {
                    mainThread { volume = newVolume.ns }
                }
            }
        }
    }

    func refreshGamma() {
        guard !isForTesting, isOnline else { return }

        guard !defaultGammaChanged || !applyGamma else {
            lunarGammaTable = GammaTable(
                redMin: defaultGammaRedMin.floatValue,
                redMax: defaultGammaRedMax.floatValue,
                redValue: defaultGammaRedValue.floatValue,
                greenMin: defaultGammaGreenMin.floatValue,
                greenMax: defaultGammaGreenMax.floatValue,
                greenValue: defaultGammaGreenValue.floatValue,
                blueMin: defaultGammaBlueMin.floatValue,
                blueMax: defaultGammaBlueMax.floatValue,
                blueValue: defaultGammaBlueValue.floatValue
            )
            return
        }

        lunarGammaTable = nil
        defaultGammaTable = GammaTable(for: id)
    }

    func resetGamma() {
        guard !isForTesting else { return }

        let gammaTable = (lunarGammaTable ?? defaultGammaTable)
        if apply(gamma: gammaTable) {
            lastGammaTable = gammaTable
        }
        gammaChanged = true
    }

    @discardableResult func gammaLock() -> Bool {
        log.verbose("Locking gamma", context: context)
        return gammaDistributedLock?.try() ?? false
    }

    func gammaUnlock() {
        log.verbose("Unlocking gamma", context: context)
        gammaDistributedLock?.unlock()
    }

    @discardableResult
    func apply(gamma: GammaTable, force: Bool = false) -> Bool {
        let result = gamma.apply(to: id, force: force)
        redraw()

        return result
    }

    func setGamma(
        brightness: UInt8? = nil,
        oldBrightness: UInt8? = nil,
        preciseBrightness: Double? = nil,
        onChange: ((Brightness) -> Void)? = nil
    ) {
        #if DEBUG
            guard !isForTesting else { return }
        #endif

        guard enabledControls[.gamma] ?? false, timeSince(lastConnectionTime) > 5 else { return }
        gammaLock()
        settingGamma = true
        defer { settingGamma = false }

        let brightness = brightness ?? self.brightness.uint8Value
        let gammaTable = lunarGammaTable ?? defaultGammaTable
        let newGammaTable = gammaTable.adjust(brightness: brightness, preciseBrightness: preciseBrightness)
        let gammaSemaphore = DispatchSemaphore(value: 0, name: "gammaSemaphore")

        if let oldBrightness = oldBrightness {
            asyncNow(runLoopQueue: realtimeQueue) { [weak self] in
                guard let self = self else {
                    gammaSemaphore.signal()
                    return
                }
                Thread.sleep(forTimeInterval: 0.002)

                self.gammaChanged = true
                for gammaTable in gammaTable.stride(from: oldBrightness, to: brightness) {
                    self.apply(gamma: gammaTable)
                    if let onChange = onChange, let brightness = gammaTable.brightness {
                        onChange(brightness)
                    }
                    Thread.sleep(forTimeInterval: brightnessTransition == .slow ? 0.025 : 0.002)
                }
                gammaSemaphore.signal()
            }
        }
        asyncNow(runLoopQueue: lowprioQueue) { [weak self] in
            guard let self = self else { return }
            if oldBrightness != nil { gammaSemaphore.wait(for: 1.8) }

            self.gammaChanged = true

            guard !newGammaTable.isZero else {
                gammaSemaphore.signal()
                return
            }

            if self.apply(gamma: newGammaTable) {
                self.lastGammaTable = newGammaTable
            }
            onChange?(brightness)
            gammaSemaphore.signal()
        }
    }

    func reset(resetControl: Bool = true) {
        maxDDCBrightness = 100.ns
        maxDDCContrast = 100.ns
        maxDDCVolume = 100.ns

        minDDCBrightness = 0.ns
        minDDCContrast = 0.ns
        minDDCVolume = 0.ns

        faceLightBrightness = 100.ns
        faceLightContrast = 90.ns

        userContrast[displayController.adaptiveModeKey]?.removeAll()
        userBrightness[displayController.adaptiveModeKey]?.removeAll()

        resetDefaultGamma()

        useOverlay = !supportsGammaByDefault
        alwaysFallbackControl = false
        neverFallbackControl = false
        alwaysUseNetworkControl = false
        neverUseNetworkControl = false
        enabledControls = [
            .network: true,
            .appleNative: true,
            .ddc: true,
            .gamma: !DDC.isSmartBuiltinDisplay(id),
        ]
        brightnessCurveFactors = [
            .sensor: DEFAULT_SENSOR_BRIGHTNESS_CURVE_FACTOR,
            .sync: DEFAULT_SYNC_BRIGHTNESS_CURVE_FACTOR,
            .location: DEFAULT_LOCATION_BRIGHTNESS_CURVE_FACTOR,
            .manual: DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR,
            .clock: DEFAULT_MANUAL_BRIGHTNESS_CURVE_FACTOR,
        ]

        contrastCurveFactors = [
            .sensor: DEFAULT_SENSOR_CONTRAST_CURVE_FACTOR,
            .sync: DEFAULT_SYNC_CONTRAST_CURVE_FACTOR,
            .location: DEFAULT_LOCATION_CONTRAST_CURVE_FACTOR,
            .manual: DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR,
            .clock: DEFAULT_MANUAL_CONTRAST_CURVE_FACTOR,
        ]

        save()

        if resetControl {
            _ = control?.reset()
        }
        readapt(newValue: false, oldValue: true)
    }

    // MARK: "With/out" functions

    @inline(__always) func withoutDDCLimits(_ block: () -> Void) {
        DDC.sync {
            DDC.applyLimits = false
            block()
            DDC.applyLimits = true
        }
    }

    @inline(__always) func withoutDDC(_ block: () -> Void) {
        DDC.sync {
            DDC.apply = false
            block()
            DDC.apply = true
        }
    }

    @inline(__always) func withForce(_ force: Bool = true, _ block: () -> Void) {
        self.force = force
        block()
        self.force = false
    }

    @inline(__always) func withoutSmoothTransition(_ block: () -> Void) {
        withBrightnessTransition(.instant, block)
    }

    @inline(__always) func withBrightnessTransition(_ transition: BrightnessTransition = .smooth, _ block: () -> Void) {
        if brightnessTransition == transition {
            block()
            return
        }

        let oldTransition = brightnessTransition
        brightnessTransition = transition
        block()
        brightnessTransition = oldTransition
    }

    // MARK: Computing Values

    func getMinMaxFactor(
        type: ValueType,
        factor: Double? = nil,
        minVal: Double? = nil,
        maxVal: Double? = nil
    ) -> (Double, Double, Double) {
        let minValue: Double
        let maxValue: Double
        if type == .brightness {
            maxValue = maxVal ?? maxBrightness.doubleValue
            minValue = minVal ?? minBrightness.doubleValue
        } else {
            maxValue = maxVal ?? maxContrast.doubleValue
            minValue = minVal ?? minContrast.doubleValue
        }

        return (minValue, maxValue, factor ?? 1.0)
    }

    func computeValue(
        from percent: Double,
        type: ValueType,
        factor: Double? = nil,
        appOffset: Int = 0,
        minVal: Double? = nil,
        maxVal: Double? = nil
    ) -> Double {
        let (minValue, maxValue, factor) = getMinMaxFactor(type: type, factor: factor, minVal: minVal, maxVal: maxVal)

        var value: Double
        if percent == 1.0 {
            value = maxValue
        } else if percent == 0.0 {
            value = minValue
        } else {
            value = pow((percent * (maxValue - minValue) + minValue) / 100.0, factor) * 100.0
            value = cap(value, minVal: minValue, maxVal: maxValue)
        }

        if appOffset > 0 {
            value = cap(value + appOffset.d, minVal: minValue, maxVal: maxValue)
        }
        return value.rounded()
    }

    func computeSIMDValue(
        from percent: [Double],
        type: ValueType,
        factor: Double? = nil,
        appOffset: Int = 0,
        minVal: Double? = nil,
        maxVal: Double? = nil
    ) -> [Double] {
        let (minValue, maxValue, factor) = getMinMaxFactor(type: type, factor: factor, minVal: minVal, maxVal: maxVal)

        var value = (percent * (maxValue - minValue) + minValue)
        value /= 100.0
        value = pow(value, factor)

        value = (value * 100.0 + appOffset.d)
        return value.map {
            b in cap(b, minVal: minValue, maxVal: maxValue)
        }
    }

    func insertBrightnessUserDataPoint(_ featureValue: Int, _ targetValue: Int, modeKey: AdaptiveModeKey) {
        guard !lockedBrightnessCurve, !adaptivePaused, displayController.adaptiveModeKey != .sync || !isSource,
              timeSince(lastConnectionTime) > 5 else { return }

        brightnessDataPointInsertionTask?.cancel()
        if userBrightness[modeKey] == nil {
            userBrightness[modeKey] = ThreadSafeDictionary()
        }
        let targetValue = mapNumber(
            targetValue.f,
            fromLow: minBrightness.floatValue,
            fromHigh: maxBrightness.floatValue,
            toLow: MIN_BRIGHTNESS.f,
            toHigh: MAX_BRIGHTNESS.f
        ).intround

        brightnessDataPointInsertionTask = DispatchWorkItem(name: "brightnessDataPointInsertionTask") { [weak self] in
            while let self = self, self.sendingBrightness {
                self.sentBrightnessCondition.wait(until: Date().addingTimeInterval(5.seconds.timeInterval))
            }

            guard let self = self, var userValues = self.userBrightness[modeKey] else { return }
            Display.insertDataPoint(values: &userValues, featureValue: featureValue, targetValue: targetValue)
            self.save()
            self.brightnessDataPointInsertionTask = nil
        }
        serialAsyncAfter(ms: 5000, brightnessDataPointInsertionTask!)

        var userValues = userBrightness[modeKey]!
        Display.insertDataPoint(values: &userValues, featureValue: featureValue, targetValue: targetValue, logValue: false)
        NotificationCenter.default.post(name: brightnessDataPointInserted, object: self, userInfo: ["values": userValues.dictionary])
    }

    func insertContrastUserDataPoint(_ featureValue: Int, _ targetValue: Int, modeKey: AdaptiveModeKey) {
        guard !lockedContrastCurve, !adaptivePaused, displayController.adaptiveModeKey != .sync || !isSource,
              timeSince(lastConnectionTime) > 5 else { return }

        contrastDataPointInsertionTask?.cancel()
        if userContrast[modeKey] == nil {
            userContrast[modeKey] = ThreadSafeDictionary()
        }
        let targetValue = mapNumber(
            targetValue.f,
            fromLow: minContrast.floatValue,
            fromHigh: maxContrast.floatValue,
            toLow: MIN_CONTRAST.f,
            toHigh: MAX_CONTRAST.f
        ).intround

        contrastDataPointInsertionTask = DispatchWorkItem(name: "contrastDataPointInsertionTask") { [weak self] in
            while let self = self, self.sendingContrast {
                self.sentContrastCondition.wait(until: Date().addingTimeInterval(5.seconds.timeInterval))
            }

            guard let self = self, var userValues = self.userContrast[modeKey] else { return }
            Display.insertDataPoint(values: &userValues, featureValue: featureValue, targetValue: targetValue)
            self.save()
            self.contrastDataPointInsertionTask = nil
        }
        serialAsyncAfter(ms: 5000, contrastDataPointInsertionTask!)

        var userValues = userContrast[modeKey]!
        Display.insertDataPoint(values: &userValues, featureValue: featureValue, targetValue: targetValue, logValue: false)
        NotificationCenter.default.post(name: contrastDataPointInserted, object: self, userInfo: ["values": userValues.dictionary])
    }

    func isUserAdjusting() -> Bool {
        brightnessDataPointInsertionTask != nil || contrastDataPointInsertionTask != nil
    }
}
