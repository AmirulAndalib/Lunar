//
//  ConfigurationViewController.swift
//  Lunar
//
//  Created by Alin on 16/04/2018.
//  Copyright © 2018 Alin. All rights reserved.
//

import AnyCodable
import Cocoa
import Combine
import Defaults

class ConfigurationViewController: NSViewController {
    let CHART_LINK = "https://www.desmos.com/calculator/zciiqhtnov"
    let UI_NOTE_INFO = """
    **Note:** Manual adjustments through the UI on the Display page of Lunar won't take these values into account.
    """
    let ADJUSTING_VALUES_INFO = """
    ## Adjusting values
    Use one of the following gestures **while hovering on the value with your mouse or trackpad**
    - Scroll vertically using the mouse or trackpad
    - Click to edit text, press enter to set the value
    	- Press the up/down arrow keys on your keyboard to increment/decrement the value
    """
    lazy var SYNC_POLLING_INTERVAL_TOOLTIP = """
    ## Description
    Value that describes how often Lunar should check for changes in the built-in display brightness.

    ## Effect
    The adaptive algorithm synchronizes the monitors with the built-in display brightness using the following steps:
        - Read built-in display brightness
        - Compute each monitor's brightness by taking into account the configured offsets
        - Apply the brightness for each monitor
        - *Sleep for `x` seconds*

    The last step uses this value to know how much to sleep.
    If you experience lags and system freeze in Sync mode, your monitor might have slow DDC response time.

    In this case, you might benefit from a larger polling interval like 10 seconds.

    \(ADJUSTING_VALUES_INFO)
    """
    lazy var SENSOR_POLLING_INTERVAL_TOOLTIP = """
    ## Description
    Value that describes how often the Ambient Light Sensor should send lux values to Lunar.

    \(ADJUSTING_VALUES_INFO)
    """
    lazy var HOTKEY_STEP_TOOLTIP = """
    ## Description
    Value for adjusting how much to increase/decrease the brightness/contrast/volume when using hotkeys.

    ## Effect
    When using the Brightness/Contrast/Volume Up/Down actions, the values will be computed using the following formulas:
    * Brightness Up: `brightness = oldValue + step`
    * Brightness Down: `brightness = oldValue - step`
    * Contrast Up: `contrast = oldValue + step`
    * Contrast Down: `contrast = oldValue - step`
    * Volume Up: `volume = oldValue + step`
    * Volume Down: `volume = oldValue - step`

    \(ADJUSTING_VALUES_INFO)

    \(UI_NOTE_INFO)
    """
    let LOCATION_TOOLTIP = """
    ## Description
    Adjustable location coordinates.

    ## Effect
    The sunrise, noon and sunset times will be computed based on these coordinates.

    ## Adjusting values
    - Click to edit then press enter to set custom values.
    - Press reset to use the last location stored by the system.
    """
    let BRIGHTNESS_TRANSITION_TOOLTIP = """
    ## Description
    Allows brightness/contrast to change smoothly from a value to another.

    ## Effect
    A custom algorithm is used to auto-adapt the smoothing logic based on each monitor's response time.

    If the monitor isn't fast enough, changing the brightness/contrast may look jaggy or cause flashes.

    **Note:** This can make the system lag in transitions if the monitor has a *very* slow response time
    """
    let SCHEDULE_TRANSITION_TOOLTIP = """
    ## Description

    1. `None`: the brightness and contrast are applied at the exact time of the schedule
    2 `30 minutes`: the brightness and contrast start transitioning 30 minutes before the schedule time, from your current brightness to the schedule brightness
        - *When the transition starts, the algorithm applies the computed values every 30 seconds so it doesn't allow for manual adjustments in the 30 minutes before the schedule*
    3. `Full`: the brightness and contrast transition from schedule to schedule
        - *This transition applies the computed values every 30 seconds so it doesn't allow for manual adjustments*

    """

    @IBOutlet var _helpButton1: NSButton?
    @IBOutlet var _helpButton2: NSButton?
    @IBOutlet var _helpButton3: NSButton?
    @IBOutlet var brightnessStepField: ScrollableTextField!
    @IBOutlet var brightnessStepCaption: ScrollableTextFieldCaption!
    @IBOutlet var contrastStepField: ScrollableTextField!
    @IBOutlet var contrastStepCaption: ScrollableTextFieldCaption!
    @IBOutlet var volumeStepField: ScrollableTextField!
    @IBOutlet var volumeStepCaption: ScrollableTextFieldCaption!
    @IBOutlet var hotkeyStepLabel: NSTextField!
    @IBOutlet var pollingIntervalLabel: NSTextField!
    @IBOutlet var syncPollingIntervalField: ScrollableTextField!
    @IBOutlet var syncPollingIntervalCaption: ScrollableTextFieldCaption!
    @IBOutlet var sensorPollingIntervalField: ScrollableTextField!
    @IBOutlet var sensorPollingIntervalCaption: ScrollableTextFieldCaption!
    @IBOutlet var locationLatField: ScrollableTextField!
    @IBOutlet var locationLonField: ScrollableTextField!
    @IBOutlet var locationLatCaption: ScrollableTextFieldCaption!
    @IBOutlet var locationLonCaption: ScrollableTextFieldCaption!
    @IBOutlet var locationLabel: NSTextField!
    @IBOutlet var locationReset: TextButton!
    @IBOutlet var scheduleTransitionLabel: NSTextField!
    @IBOutlet var scheduleTransitionSelector: NSSegmentedControl!
    weak var settingsController: SettingsPageController?

    var dayMomentsObserver: Cancellable?
    var locationObserver: Cancellable?
    var brightnessStepObserver: Cancellable?
    var syncPollingSecondsObserver: Cancellable?
    var sensorPollingSecondsObserver: Cancellable?
    var contrastStepObserver: Cancellable?
    var volumeStepObserver: Cancellable?
    var adaptiveBrightnessModeObserver: Cancellable?

    var helpButton1: HelpButton? {
        _helpButton1 as? HelpButton
    }

    var helpButton2: HelpButton? {
        _helpButton2 as? HelpButton
    }

    var helpButton3: HelpButton? {
        _helpButton3 as? HelpButton
    }

    var hotkeyStepVisible = false {
        didSet {
            brightnessStepField?.isHidden = !hotkeyStepVisible
            brightnessStepCaption?.isHidden = !hotkeyStepVisible
            contrastStepField?.isHidden = !hotkeyStepVisible
            contrastStepCaption?.isHidden = !hotkeyStepVisible
            volumeStepField?.isHidden = !hotkeyStepVisible
            volumeStepCaption?.isHidden = !hotkeyStepVisible
            hotkeyStepLabel?.isHidden = !hotkeyStepVisible
        }
    }

    var syncPollingIntervalVisible = false {
        didSet {
            syncPollingIntervalField?.isHidden = !syncPollingIntervalVisible
            syncPollingIntervalCaption?.isHidden = !syncPollingIntervalVisible
            pollingIntervalLabel?.isHidden = !syncPollingIntervalVisible && !sensorPollingIntervalVisible
        }
    }

    var sensorPollingIntervalVisible = false {
        didSet {
            sensorPollingIntervalField?.isHidden = !sensorPollingIntervalVisible
            sensorPollingIntervalCaption?.isHidden = !sensorPollingIntervalVisible
            pollingIntervalLabel?.isHidden = !syncPollingIntervalVisible && !sensorPollingIntervalVisible
        }
    }

    var scheduleTransitionVisible = false {
        didSet {
            scheduleTransitionLabel?.isHidden = !scheduleTransitionVisible
            scheduleTransitionSelector?.isHidden = !scheduleTransitionVisible
        }
    }

    var locationVisible = false {
        didSet {
            locationLatField?.isHidden = !locationVisible
            locationLonField?.isHidden = !locationVisible
            locationLatCaption?.isHidden = !locationVisible
            locationLonCaption?.isHidden = !locationVisible
            locationLabel?.isHidden = !locationVisible
            locationReset?.isHidden = !locationVisible
        }
    }

    func showRelevantSettings(_ adaptiveMode: AdaptiveModeKey) {
        let locationMode = adaptiveMode == .location
        let syncMode = adaptiveMode == .sync
        let sensorMode = adaptiveMode == .sensor
        let clockMode = adaptiveMode == .clock
        // let manualMode = adaptiveMode == .manual

        locationVisible = locationMode
        syncPollingIntervalVisible = syncMode
        sensorPollingIntervalVisible = sensorMode
        scheduleTransitionVisible = clockMode
        hotkeyStepVisible = true

        helpButton1?.helpText = HOTKEY_STEP_TOOLTIP
        helpButton2?.helpText = BRIGHTNESS_TRANSITION_TOOLTIP

        switch adaptiveMode {
        case .location:
            helpButton3?.helpText = LOCATION_TOOLTIP
        case .sync:
            helpButton3?.helpText = SYNC_POLLING_INTERVAL_TOOLTIP
        case .sensor:
            helpButton3?.helpText = SENSOR_POLLING_INTERVAL_TOOLTIP
        case .clock:
            helpButton3?.helpText = SCHEDULE_TRANSITION_TOOLTIP
        case .manual:
            break
        }

        helpButton3?.isHidden = adaptiveMode == .manual
    }

    func listenForLocationChange() {
        locationObserver = locationObserver ?? locationPublisher.sink { [weak self] change in
            mainAsync {
                self?.locationLatField?.doubleValue = change.newValue?.latitude ?? 0.0
                self?.locationLonField?.doubleValue = change.newValue?.longitude ?? 0.0
            }
        }
    }

    func listenForBrightnessStepChange() {
        brightnessStepObserver = brightnessStepObserver ?? brightnessStepPublisher.sink { [weak self] change in
            mainAsync {
                self?.brightnessStepField?.stringValue = String(change.newValue)
            }
        }
    }

    func listenForSyncPollingIntervalChange() {
        syncPollingSecondsObserver = syncPollingSecondsObserver ?? syncPollingSecondsPublisher.sink { [weak self] change in
            mainAsync {
                self?.syncPollingIntervalField?.stringValue = String(change.newValue)
            }
        }
    }

    func listenForSensorPollingIntervalChange() {
        sensorPollingSecondsObserver = sensorPollingSecondsObserver ?? sensorPollingSecondsPublisher.sink { [weak self] change in
            mainAsync {
                self?.sensorPollingIntervalField?.stringValue = String(change.newValue)
            }
        }
    }

    func listenForContrastStepChange() {
        contrastStepObserver = contrastStepObserver ?? contrastStepPublisher.sink { [weak self] change in
            mainAsync {
                self?.contrastStepField?.stringValue = String(change.newValue)
            }
        }
    }

    func listenForVolumeStepChange() {
        volumeStepObserver = volumeStepObserver ?? volumeStepPublisher.sink { [weak self] change in
            mainAsync {
                self?.volumeStepField?.stringValue = String(change.newValue)
            }
        }
    }

    func listenForAdaptiveModeChange() {
        adaptiveBrightnessModeObserver = adaptiveBrightnessModeObserver ?? adaptiveBrightnessModePublisher.sink { [weak self] change in
            mainAsync {
                self?.showRelevantSettings(change.newValue)
            }
        }
    }

    func setupBrightnessStep() {
        guard let field = brightnessStepField, let caption = brightnessStepCaption else { return }

        setupScrollableTextField(
            field, caption: caption,
            settingKeyInt: Defaults.Keys.brightnessStep,
            lowerLimit: 1, upperLimit: 99,
            onMouseEnter: nil
        )
    }

    func setupSyncPollingInterval() {
        guard let field = syncPollingIntervalField, let caption = syncPollingIntervalCaption else { return }

        setupScrollableTextField(
            field, caption: caption,
            settingKeyInt: Defaults.Keys.syncPollingSeconds,
            lowerLimit: 1, upperLimit: 300,
            onMouseEnter: nil
        )
    }

    func setupSensorPollingInterval() {
        guard let field = sensorPollingIntervalField, let caption = sensorPollingIntervalCaption else { return }

        setupScrollableTextField(
            field, caption: caption,
            settingKeyInt: Defaults.Keys.sensorPollingSeconds,
            lowerLimit: 1, upperLimit: 300,
            onMouseEnter: nil
        )
    }

    func setupContrastStep() {
        guard let field = contrastStepField, let caption = contrastStepCaption else { return }

        setupScrollableTextField(
            field, caption: caption,
            settingKeyInt: Defaults.Keys.contrastStep,
            lowerLimit: 1, upperLimit: 99,
            onMouseEnter: nil
        )
    }

    func setupVolumeStep() {
        guard let field = volumeStepField, let caption = volumeStepCaption else { return }

        setupScrollableTextField(
            field, caption: caption,
            settingKeyInt: Defaults.Keys.volumeStep,
            lowerLimit: 1, upperLimit: 99,
            onMouseEnter: nil
        )
    }

    func setupLocation() {
        guard let latField = locationLatField,
              let lonField = locationLonField,
              let latCaption = locationLatCaption,
              let lonCaption = locationLonCaption else { return }

        latField.decimalPoints = 2
        latField.step = 0.01
        lonField.decimalPoints = 2
        lonField.step = 0.01

        setupScrollableTextField(
            latField, caption: latCaption, lowerLimit: -90.00, upperLimit: 90.00,
            onValueChangedDouble: { value, _ in
                CachedDefaults[.manualLocation] = true

                let geolocation = Geolocation(
                    latitude: value,
                    longitude: LocationMode.specific.geolocation?.longitude ?? 0,
                    altitude: LocationMode.specific.geolocation?.altitude ?? 0
                )
                geolocation.store()
                LocationMode.specific.geolocation = geolocation
            }
        )
        setupScrollableTextField(
            lonField, caption: lonCaption, lowerLimit: -180.00, upperLimit: 180.00,
            onValueChangedDouble: { value, _ in
                CachedDefaults[.manualLocation] = true

                let geolocation = Geolocation(
                    latitude: LocationMode.specific.geolocation?.latitude ?? 0,
                    longitude: value,
                    altitude: LocationMode.specific.geolocation?.altitude ?? 0
                )
                geolocation.store()
                LocationMode.specific.geolocation = geolocation
            }
        )
    }

    func resetScrollableTextField(_ field: ScrollableTextField?) {
        if let field = field {
            field.onValueChanged = nil
            field.onValueChangedDouble = nil
            field.onMouseEnter = nil
            field.caption = nil
        }
    }

    func setupScrollableTextField(
        _ field: ScrollableTextField, caption: ScrollableTextFieldCaption,
        settingKeyInt: Defaults.Key<Int>? = nil,
        settingKeyDouble: Defaults.Key<Double>? = nil,
        lowerLimit: Double, upperLimit: Double,
        onMouseEnter: ((SettingsPageController?) -> Void)? = nil,
        onMouseExit: ((SettingsPageController?) -> Void)? = nil,
        onValueChanged: ((Int, SettingsPageController?) -> Void)? = nil,
        onValueChangedDouble: ((Double, SettingsPageController?) -> Void)? = nil
    ) {
        field.textFieldColor = scrollableTextFieldColorWhite
        field.textFieldColorHover = scrollableTextFieldColorHoverWhite
        field.textFieldColorLight = scrollableTextFieldColorLightWhite
        caption.textColor = scrollableCaptionColorWhite
        field.caption = caption

        if field.decimalPoints > 0, let key = settingKeyDouble {
            field.doubleValue = CachedDefaults[key]
            field.onValueChangedDouble = { (value: Double) in
                CachedDefaults[settingKeyDouble!] = value
            }
        } else if let key = settingKeyInt {
            field.integerValue = CachedDefaults[key]
            field.onValueChanged = { (value: Int) in
                CachedDefaults[settingKeyInt!] = value
            }
        }
        field.lowerLimit = lowerLimit
        field.upperLimit = upperLimit
        if let handler = onValueChanged {
            field.onValueChanged = { [weak self] value in
                guard let self = self else { return }
                if let key = settingKeyInt {
                    CachedDefaults[key] = value
                }
                handler(value, self.settingsController)
            }
        }
        if let handler = onValueChangedDouble {
            field.onValueChangedDouble = { [weak self] value in
                guard let self = self else { return }
                if let key = settingKeyDouble {
                    CachedDefaults[key] = value
                }
                handler(value, self.settingsController)
            }
        }
        if let handler = onMouseExit {
            field.onMouseExit = { [weak self] in
                guard let self = self else { return }
                handler(self.settingsController)
            }
        }

        if let handler = onMouseEnter {
            field.onMouseEnter = { [weak self] in
                guard let self = self else { return }
                handler(self.settingsController)
            }
        }
    }

    @IBAction func resetLocation(_: Any?) {
        CachedDefaults[.manualLocation] = false
        mainAsync { appDelegate!.startReceivingSignificantLocationChanges() }
    }

    func setup() {
        setupBrightnessStep()
        setupSyncPollingInterval()
        setupSensorPollingInterval()
        setupContrastStep()
        setupVolumeStep()
        setupLocation()

        showRelevantSettings(CachedDefaults[.adaptiveBrightnessMode])

        listenForLocationChange()
        listenForBrightnessStepChange()
        listenForSyncPollingIntervalChange()
        listenForSensorPollingIntervalChange()
        listenForContrastStepChange()
        listenForVolumeStepChange()
        listenForAdaptiveModeChange()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settingsController = parent?.parent as? SettingsPageController
        setup()
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }
}
