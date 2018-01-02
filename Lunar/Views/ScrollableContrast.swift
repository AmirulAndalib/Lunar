//
//  ScrollableValueController.swift
//  Lunar
//
//  Created by Alin on 25/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import Cocoa

class ScrollableContrast: NSView {
    @IBOutlet weak var label: NSTextField!
    @IBOutlet weak var minValue: ScrollableTextField!
    @IBOutlet weak var maxValue: ScrollableTextField!
    @IBOutlet weak var currentValue: ScrollableTextField!
    
    var display: Display! {
        didSet {
            update(from: display)
        }
    }
    var name: String! {
        didSet {
            label?.stringValue = name
        }
    }
    var displayMinValue: Int {
        get {
            return (display.value(forKey: "minContrast") as! NSNumber).intValue
        }
        set {
            display.setValue(newValue, forKey: "minContrast")
        }
    }
    var displayMaxValue: Int {
        get {
            return (display.value(forKey: "maxContrast") as! NSNumber).intValue
        }
        set {
            display.setValue(newValue, forKey: "maxContrast")
        }
    }
    var displayValue: Int {
        get {
            return (display.value(forKey: "contrast") as! NSNumber).intValue
        }
        set {
            display.setValue(newValue, forKey: "contrast")
        }
    }
    
    func update(from display: Display) {
        minValue?.intValue = Int32(displayMinValue)
        minValue?.upperLimit = displayMaxValue
        maxValue?.intValue = Int32(displayMaxValue)
        maxValue?.lowerLimit = displayMinValue
        currentValue?.intValue = Int32(displayValue)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        minValue?.onValueChanged = { (value: Int) in
            self.maxValue?.lowerLimit = value
            if self.display != nil {
                self.displayMinValue = value
            }
        }
        maxValue?.onValueChanged = { (value: Int) in
            self.minValue?.upperLimit = value
            if self.display != nil {
                self.displayMaxValue = value
            }
        }
        currentValue?.onValueChanged = { (value: Int) in
            if self.display != nil {
                self.displayValue = value
            }
        }
    }
    
}
