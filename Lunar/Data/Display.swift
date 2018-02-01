//
//  Display.swift
//  Lunar
//
//  Created by Alin on 05/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import Cocoa
import SwiftDate

let MIN_BRIGHTNESS: UInt8 = 0
let MAX_BRIGHTNESS: UInt8 = 100
let MIN_CONTRAST: UInt8 = 0
let MAX_CONTRAST: UInt8 = 100
let GENERIC_DISPLAY_ID: CGDirectDisplayID = 0
let GENERIC_DISPLAY: Display = Display(id: GENERIC_DISPLAY_ID, serial: "GENERIC_SERIAL", name: "No display", context: datastore.container.newBackgroundContext())


class Display: NSManagedObject {
    @NSManaged var id: CGDirectDisplayID
    @NSManaged var serial: String
    @NSManaged var name: String
    @NSManaged var adaptive: Bool
    
    @NSManaged var minBrightness: NSNumber
    @NSManaged var maxBrightness: NSNumber
    
    @NSManaged var minContrast: NSNumber
    @NSManaged var maxContrast: NSNumber
    
    @NSManaged var brightness: NSNumber
    @NSManaged var contrast: NSNumber
    
    var active: Bool = false
    var observers: [NSKeyValueObservation] = []
    
    convenience init(id: CGDirectDisplayID, serial: String? = nil, name: String? = nil, active: Bool = false, minBrightness: UInt8 = MIN_BRIGHTNESS, maxBrightness: UInt8 = MAX_BRIGHTNESS, minContrast: UInt8 = MIN_CONTRAST, maxContrast: UInt8 = MAX_CONTRAST, context: NSManagedObjectContext? = nil) {
        let context = context ?? datastore.context
        let entity = NSEntityDescription.entity(forEntityName: "Display", in: context)!
        self.init(entity: entity, insertInto: context)
        
        self.id = id
        self.name = name ?? DDC.getDisplayName(for: id)
        self.serial = serial ?? DDC.getDisplaySerial(for: id)
        self.active = active
        if id != GENERIC_DISPLAY_ID {
            self.minBrightness = NSNumber(value: minBrightness)
            self.maxBrightness = NSNumber(value: maxBrightness)
            self.minContrast = NSNumber(value: minContrast)
            self.maxContrast = NSNumber(value: maxContrast)
        }
    }
    
    func resetName() {
        self.name = DDC.getDisplayName(for: id)
    }
    
    func readapt<T>(display: Display, change: NSKeyValueObservedChange<T>) {
        if display.adaptive && change.newValue as! NSNumber != change.oldValue as! NSNumber {
            display.adapt(moment: brightnessAdapter.moment)
        }
    }
    
    func addObservers() {
        observers = [
            observe(\.minBrightness, options: [.new, .old], changeHandler: readapt),
            observe(\.maxBrightness, options: [.new, .old], changeHandler: readapt),
            observe(\.minContrast, options: [.new, .old], changeHandler: readapt),
            observe(\.maxContrast, options: [.new, .old], changeHandler: readapt),
            observe(\.brightness, options: [.new], changeHandler: {display, change in
                let newBrightness = min(max(change.newValue!.uint8Value, self.minBrightness.uint8Value), self.maxBrightness.uint8Value)
                let _ = DDC.setBrightness(for: self.id, brightness: newBrightness)
                log.debug("\(self.name): Set brightness to \(newBrightness)")
            }),
            observe(\.contrast, options: [.new], changeHandler: {display, change in
                let newContrast = min(max(change.newValue!.uint8Value, self.minContrast.uint8Value), self.maxContrast.uint8Value)
                let _ = DDC.setContrast(for: self.id, contrast: newContrast)
                log.debug("\(self.name): Set contrast to \(newContrast)")
            })
        ]
    }
    
    func removeObservers() {
        observers.removeAll(keepingCapacity: true)
    }
    
    func interpolate(value: Double, span: Double, min: UInt8, max: UInt8, factor: Double) -> NSNumber {
        let maxValue = Double(max)
        let minValue = Double(min)
        let valueSpan = maxValue - minValue
        var interpolated = ((value * valueSpan) / span)
        let normalized = interpolated / valueSpan
        interpolated = minValue + pow(normalized, factor) * valueSpan
        return NSNumber(value: UInt8(interpolated))
    }
    
    func adapt(moment: Moment) {
        let now = DateInRegion()
        let seconds = 60.0
        let minBrightness = self.minBrightness.uint8Value
        let maxBrightness = self.maxBrightness.uint8Value
        let minContrast = self.minContrast.uint8Value
        let maxContrast = self.maxContrast.uint8Value
        var newBrightness = self.minBrightness
        var newContrast = self.minContrast
        let interpolationFactor = datastore.defaults.interpolationFactor
        let daylightExtension = datastore.defaults.daylightExtensionMinutes
        let noonDuration = datastore.defaults.noonDurationMinutes
        
        let daylightStart = moment.civilSunrise - daylightExtension.minutes
        let daylightEnd = moment.civilSunset + daylightExtension.minutes
        
        let noonStart = moment.solarNoon - (noonDuration / 2).minutes
        let noonEnd = moment.solarNoon + (noonDuration / 2).minutes
        
        switch now {
        case daylightStart...noonStart:
            let firstHalfDayMinutes = ((noonStart - daylightStart) / seconds)
            let minutesSinceSunrise = ((now - daylightStart) / seconds)
            newBrightness = interpolate(value: minutesSinceSunrise, span: firstHalfDayMinutes, min: minBrightness, max: maxBrightness, factor: interpolationFactor)
            newContrast = interpolate(value: minutesSinceSunrise, span: firstHalfDayMinutes, min: minContrast, max: maxContrast, factor: interpolationFactor)
            self.setValue(newBrightness, forKey: "brightness")
            self.setValue(newContrast, forKey: "contrast")
            log.info("\n\(name):\n\tBrightness: \(newBrightness)\n\tContrast: \(newContrast)")
        case noonEnd...daylightEnd:
            let secondHalfDayMinutes = ((daylightEnd - noonEnd) / seconds)
            let minutesSinceNoon = ((now - noonEnd) / seconds)
            let interpolatedBrightness = interpolate(value: minutesSinceNoon, span: secondHalfDayMinutes, min: minBrightness, max: maxBrightness, factor: interpolationFactor)
            let interpolatedContrast = interpolate(value: minutesSinceNoon, span: secondHalfDayMinutes, min: minContrast, max: maxContrast, factor: interpolationFactor)
            newBrightness = NSNumber(value: maxBrightness + minBrightness - interpolatedBrightness.uint8Value)
            newContrast = NSNumber(value: maxContrast + minContrast - interpolatedContrast.uint8Value)
            self.setValue(newBrightness, forKey: "brightness")
            self.setValue(newContrast, forKey: "contrast")
            log.info("\n\(name):\n\tBrightness: \(newBrightness)\n\tContrast: \(newContrast)")
        case noonStart...noonEnd:
            log.debug("Setting brightness/contrast to maximum values.")
            self.setValue(self.maxBrightness, forKey: "brightness")
            self.setValue(self.maxContrast, forKey: "contrast")
            log.info("\n\(name):\n\tBrightness: \(maxBrightness)\n\tContrast: \(maxContrast)")
        default:
            log.debug("Setting brightness/contrast to minimum values.")
            self.setValue(self.minBrightness, forKey: "brightness")
            self.setValue(self.minContrast, forKey: "contrast")
            log.info("\n\(name):\n\tBrightness: \(minBrightness)\n\tContrast: \(minContrast)")
        }
        datastore.save(context: managedObjectContext!)
    }
}
