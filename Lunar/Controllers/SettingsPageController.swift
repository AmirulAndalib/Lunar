//
//  SettingsPageController.swift
//  Lunar
//
//  Created by Alin on 21/06/2018.
//  Copyright © 2018 Alin. All rights reserved.
//

import Cocoa
import Combine
import Defaults

class SettingsPageController: NSViewController {
    @IBOutlet var settingsContainerView: NSView!
    @IBOutlet var advancedSettingsContainerView: NSView!
    @IBOutlet var advancedSettingsButton: ToggleButton!
    @objc dynamic var advancedSettingsShown = CachedDefaults[.advancedSettingsShown]

    var advancedSettingsShownObserver: Cancellable?

    @IBAction func toggleAdvancedSettings(_ sender: ToggleButton) {
        advancedSettingsShown = sender.state == .on
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.bg = settingsBgColor

        advancedSettingsShownObserver = advancedSettingsShownPublisher.sink { [weak self] shown in
            guard let self = self else { return }
            mainThread {
                self.advancedSettingsShown = shown.newValue
                self.advancedSettingsButton?.state = shown.newValue ? .on : .off
            }
        }

        advancedSettingsButton.page = .settings
        advancedSettingsButton.isHidden = false
        advancedSettingsButton.state = advancedSettingsShown ? .on : .off
    }
}
