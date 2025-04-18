//
//  ScrollableContrast.swift
//  Lunar
//
//  Created by Alin on 25/12/2017.
//  Copyright © 2017 Alin. All rights reserved.
//

import Cocoa
import Combine
import Defaults

final class ScrollableContrast: NSView {
    deinit {
        #if DEBUG
            log.verbose("START DEINIT")
            defer { log.verbose("END DEINIT") }
        #endif
        for observer in displayObservers.values {
            observer.cancel()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    @IBOutlet var label: NSTextField!
    @IBOutlet var minValue: ScrollableTextField!
    @IBOutlet var maxValue: ScrollableTextField!
    @IBOutlet var currentValue: ScrollableTextField!

    @IBOutlet var minValueCaption: ScrollableTextFieldCaption!
    @IBOutlet var maxValueCaption: ScrollableTextFieldCaption!
    @IBOutlet var currentValueCaption: ScrollableTextFieldCaption!

    @IBOutlet var lockButton: LockButton!

    var minObserver: Cancellable?
    var maxObserver: Cancellable?
    var onMinValueChanged: ((Int) -> Void)?
    var onMaxValueChanged: ((Int) -> Void)?
    var onCurrentValueChanged: ((Int) -> Void)?
    var displayObservers = [String: AnyCancellable]()

    var disabled = false {
        didSet {
            minValue.isEnabled = !disabled
            maxValue.isEnabled = !disabled
        }
    }

    weak var display: Display? {
        didSet {
            if let d = display {
                update(from: d)
            }
        }
    }

    var name: String! {
        didSet {
            label?.stringValue = name
        }
    }

    var displayMinValue: Int {
        get {
            display?.minContrast.intValue ?? 0
        }
        set {
            cancelScreenWakeAdapterTask()
            display?.minContrast = newValue.ns
        }
    }

    var displayMaxValue: Int {
        get {
            display?.maxContrast.intValue ?? 100
        }
        set {
            cancelScreenWakeAdapterTask()
            display?.maxContrast = newValue.ns
        }
    }

    var displayValue: Int {
        get {
            display?.contrast.intValue ?? 50
        }
        set {
            guard let display else { return }
            cancelScreenWakeAdapterTask()

            display.withoutLockedContrast {
                display.contrast = newValue.ns
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        setup()
    }

    func addObserver(_ display: Display) {
        display.$contrast
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] newContrast in
                guard let display = self?.display, display.id != GENERIC_DISPLAY_ID else { return }
                let minContrast = display.minContrast.uint16Value
                let maxContrast = display.maxContrast.uint16Value

                let newContrast = cap(newContrast.uint16Value, minVal: minContrast, maxVal: maxContrast)
                self?.currentValue?.stringValue = String(newContrast)
            }.store(in: &displayObservers, for: "contrast")
        display.$minContrast
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] value in
                guard let self, let display = self.display, display.id != GENERIC_DISPLAY_ID else { return }
                minValue?.integerValue = value.intValue
                maxValue?.lowerLimit = value.doubleValue + 1
            }.store(in: &displayObservers, for: "minContrast")
        display.$maxContrast
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] value in
                guard let self, let display = self.display, display.id != GENERIC_DISPLAY_ID else { return }
                maxValue?.integerValue = value.intValue
                minValue?.upperLimit = value.doubleValue - 1
            }.store(in: &displayObservers, for: "maxContrast")
    }

    func update(from display: Display) {
        minValue?.intValue = displayMinValue.i32
        minValue?.upperLimit = (displayMaxValue - 1).d
        maxValue?.intValue = displayMaxValue.i32
        maxValue?.lowerLimit = (displayMinValue + 1).d
        currentValue?.intValue = displayValue.i32
        currentValue?.lowerLimit = displayMinValue.d
        currentValue?.upperLimit = displayMaxValue.d

        if let button = lockButton {
            if display.lockedContrast {
                button.state = .on
            } else {
                button.state = .off
            }
        }

        addObserver(display)
    }

    @IBAction func toggleLock(_ sender: LockButton) {
        switch sender.state {
        case .on:
            sender.bg = lockButtonBgOn
            display?.lockedContrast = true
        case .off:
            sender.bg = lockButtonBgOff
            display?.lockedContrast = false
        default:
            return
        }
        DC.adaptBrightness()
    }

    func setup() {
        minValue?.onValueChangedInstant = minValue?.onValueChangedInstant ?? onMinValueChanged
        minValue?.onValueChanged = minValue?.onValueChanged ?? { [weak self] (value: Int) in
            guard let self else { return }

            maxValue?.lowerLimit = (value + 1).d
            currentValue?.lowerLimit = value.d
            currentValue.integerValue = max(currentValue.integerValue, value)
            if display != nil {
                displayMinValue = value
            }
        }
        maxValue?.onValueChangedInstant = maxValue?.onValueChangedInstant ?? onMaxValueChanged
        maxValue?.onValueChanged = maxValue?.onValueChanged ?? { [weak self] (value: Int) in
            guard let self else { return }

            minValue?.upperLimit = (value - 1).d
            currentValue?.upperLimit = value.d
            currentValue.integerValue = min(currentValue.integerValue, value)
            if display != nil {
                displayMaxValue = value
            }
        }

        currentValue?.onValueChangedInstant = currentValue?.onValueChangedInstant ?? onCurrentValueChanged
        currentValue?.onValueChanged = currentValue?.onValueChanged ?? { [weak self] (value: Int) in
            if self?.display != nil {
                self?.displayValue = value
            }
        }

        minValue?.caption = minValue?.caption ?? minValueCaption
        maxValue?.caption = maxValue?.caption ?? maxValueCaption
        currentValue?.caption = currentValue?.caption ?? currentValueCaption
    }

}
