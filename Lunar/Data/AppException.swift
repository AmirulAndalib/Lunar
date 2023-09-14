//
//  AppException.swift
//  Lunar
//
//  Created by Alin on 29/01/2018.
//  Copyright © 2018 Alin. All rights reserved.
//

import AnyCodable
import Cocoa
import Combine
import Defaults
import Sentry

let APP_MAX_BRIGHTNESS_OFFSET: Int8 = 30
let APP_MAX_CONTRAST_OFFSET: Int8 = 20
let DEFAULT_APP_BRIGHTNESS_CONTRAST = 0.8

// MARK: - AppException

@objc final class AppException: NSObject, Codable, Defaults.Serializable {
    init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
        super.init()

        manualObserver = adaptiveBrightnessModePublisher
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] change in
                guard let self else { return }
                self.showManualValues = change.newValue == .manual || self.useStaticValuesInAdaptiveModes
                self.hideManualValuesMerged = !self.showManualValues || !CachedDefaults[.mergeBrightnessContrast]
                self.hideManualValuesNonMerged = !self.showManualValues || CachedDefaults[.mergeBrightnessContrast]
            }
        mergeBrightnessContrastObserver = mergeBrightnessContrastPublisher
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] change in
                guard let self else { return }
                self.hideManualValuesMerged = !self.showManualValues || !change.newValue
                self.hideManualValuesNonMerged = !self.showManualValues || change.newValue
            }
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        brightness = try container.decodeIfPresent(Int8.self, forKey: .brightness) ?? APP_MAX_BRIGHTNESS_OFFSET
        contrast = try container.decodeIfPresent(Int8.self, forKey: .contrast) ?? APP_MAX_CONTRAST_OFFSET

        manualBrightnessContrast = try container.decodeIfPresent(Double.self, forKey: .manualBrightnessContrast) ?? DEFAULT_APP_BRIGHTNESS_CONTRAST
        manualBrightness = try container.decodeIfPresent(Double.self, forKey: .manualBrightness) ?? DEFAULT_APP_BRIGHTNESS_CONTRAST
        manualContrast = try container.decodeIfPresent(Double.self, forKey: .manualContrast) ?? DEFAULT_APP_BRIGHTNESS_CONTRAST

        applyBuiltin = try container.decodeIfPresent(Bool.self, forKey: .applyBuiltin) ?? false
        useStaticValuesInAdaptiveModes = try container.decodeIfPresent(Bool.self, forKey: .useStaticValuesInAdaptiveModes) ?? false
        reapplyPreviousBrightness = try container.decodeIfPresent(Bool.self, forKey: .reapplyPreviousBrightness) ?? true

        super.init()
        manualObserver = adaptiveBrightnessModePublisher
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] change in
                guard let self else { return }
                self.showManualValues = change.newValue == .manual || self.useStaticValuesInAdaptiveModes
                self.hideManualValuesMerged = !self.showManualValues || !CachedDefaults[.mergeBrightnessContrast]
                self.hideManualValuesNonMerged = !self.showManualValues || CachedDefaults[.mergeBrightnessContrast]
            }
        mergeBrightnessContrastObserver = mergeBrightnessContrastPublisher
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] change in
                guard let self else { return }
                self.hideManualValuesMerged = !self.showManualValues || !change.newValue
                self.hideManualValuesNonMerged = !self.showManualValues || change.newValue
            }
    }

    enum CodingKeys: String, CodingKey {
        case identifier
        case name
        case brightness
        case contrast
        case manualBrightnessContrast
        case manualBrightness
        case manualContrast
        case applyBuiltin
        case reapplyPreviousBrightness
        case useStaticValuesInAdaptiveModes
    }

    var manualObserver: Cancellable?
    var mergeBrightnessContrastObserver: Cancellable?
    @objc dynamic lazy var hideManualValuesMerged = !showManualValues || !CachedDefaults[.mergeBrightnessContrast]
    @objc dynamic lazy var hideManualValuesNonMerged = !showManualValues || CachedDefaults[.mergeBrightnessContrast]

    @objc dynamic lazy var showManualValues = DC.adaptiveModeKey == .manual || useStaticValuesInAdaptiveModes {
        didSet {
            hideManualValuesMerged = !showManualValues || !CachedDefaults[.mergeBrightnessContrast]
            hideManualValuesNonMerged = !showManualValues || CachedDefaults[.mergeBrightnessContrast]
        }
    }
    override var description: String {
        "\(name)[\(identifier)]"
    }

    var runningApps: [NSRunningApplication]? {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    }

    @objc dynamic var identifier: String {
        didSet {
            save()
        }
    }

    @objc dynamic var name: String {
        didSet {
            save()
        }
    }

    @objc dynamic var brightness: Int8 = APP_MAX_BRIGHTNESS_OFFSET {
        didSet {
            save()
            log.verbose("\(name): Set brightness to \(brightness)")
        }
    }

    @objc dynamic var contrast: Int8 = APP_MAX_CONTRAST_OFFSET {
        didSet {
            save()
            log.verbose("\(name): Set contrast to \(contrast)")
        }
    }

    @objc dynamic var manualBrightnessContrast: Double = DEFAULT_APP_BRIGHTNESS_CONTRAST {
        didSet {
            save()
            guard CachedDefaults[.mergeBrightnessContrast] else { return }
            manualBrightness = manualBrightnessContrast
            manualContrast = manualBrightnessContrast
        }
    }

    @objc dynamic var manualBrightness: Double = DEFAULT_APP_BRIGHTNESS_CONTRAST {
        didSet {
            save()
            guard !CachedDefaults[.mergeBrightnessContrast] else { return }
            manualBrightnessContrast = manualBrightness
        }
    }

    @objc dynamic var manualContrast: Double = DEFAULT_APP_BRIGHTNESS_CONTRAST {
        didSet { save() }
    }

    @objc dynamic var applyBuiltin = false {
        didSet { save() }
    }

    @objc dynamic var useStaticValuesInAdaptiveModes = false {
        didSet {
            save()
            showManualValues = DC.adaptiveModeKey == .manual || useStaticValuesInAdaptiveModes
        }
    }

    @objc dynamic var reapplyPreviousBrightness = true {
        didSet { save() }
    }

    func save() {
        DataStore.storeAppException(app: self)
    }

    @objc func remove() {
        if var apps = CachedDefaults[.appExceptions] {
            apps.removeAll(where: { $0.identifier == identifier })
            CachedDefaults[.appExceptions] = apps
        }
    }
}
