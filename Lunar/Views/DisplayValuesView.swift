//
//  ExceptionsView.swift
//  Lunar
//
//  Created by Alin on 29/01/2018.
//  Copyright © 2018 Alin. All rights reserved.
//

import Cocoa

let textFieldColor = sunYellow
let textFieldColorHover = sunYellow.blended(withFraction: 0.2, of: red)!
let textFieldColorLight = sunYellow.blended(withFraction: 0.4, of: red)!

class DisplayValuesView: NSTableView {
    var brightnessObservers: [CGDirectDisplayID: (NSNumber, NSNumber) -> Void] = [:]
    var contrastObservers: [CGDirectDisplayID: (NSNumber, NSNumber) -> Void] = [:]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    func setAdaptiveButtonHidden(_ hidden: Bool) {
        enumerateAvailableRowViews { rowView, _ in
            if let nameCell = rowView.view(atColumn: 1) as? NSTableCellView,
                let display = nameCell.objectValue as? Display,
                let adaptiveButton = nameCell.subviews.first(where: { v in (v as? QuickAdaptiveButton) != nil }) as? QuickAdaptiveButton,
                display.active {
                adaptiveButton.isHidden = hidden
            }
        }
    }

    deinit {
        enumerateAvailableRowViews { rowView, _ in
            if let display = (rowView.view(atColumn: 1) as? NSTableCellView)?.objectValue as? Display {
                display.numberObservers["brightness"]?.removeValue(forKey: "displayValuesView-\(accessibilityIdentifier())")
                display.numberObservers["contrast"]?.removeValue(forKey: "displayValuesView-\(accessibilityIdentifier())")
            }
        }
    }

    func resetDeleteButtons() {
        enumerateAvailableRowViews { rowView, row in
            guard let display = (rowView.view(atColumn: 1) as? NSTableCellView)?.objectValue as? Display,
                let notConnectedTextField = (rowView.view(atColumn: 1) as? NSTableCellView)?.subviews.first(
                    where: { v in (v as? NotConnectedTextField) != nil }
                ) as? NotConnectedTextField else {
                return
            }
            notConnectedTextField.onClick = getDeleteAction(displayID: display.id, row: row)
        }
    }

    func getDeleteAction(displayID: CGDirectDisplayID, row: Int) -> (() -> Void) {
        return {
            runInMainThread {
                self.beginUpdates()
                self.removeRows(at: [row], withAnimation: .effectFade)
                self.endUpdates()
                if let controller = self.superview?.superview?.nextResponder?.nextResponder as? MenuPopoverController {
                    runInMainThreadAsyncAfter(ms: 200) {
                        menuPopover.animates = false
                        controller.adaptViewSize()
                        menuPopover.animates = true
                        self.resetDeleteButtons()
                    }
                }
            }
            brightnessAdapter.removeDisplay(id: displayID)
        }
    }

    func removeRow(_ rowView: NSTableRowView, forRow _: Int) {
        guard let display = (rowView.view(atColumn: 1) as? NSTableCellView)?.objectValue as? Display else {
            return
        }
        display.numberObservers["brightness"]?.removeValue(forKey: "displayValuesView-\(accessibilityIdentifier())")
        display.numberObservers["contrast"]?.removeValue(forKey: "displayValuesView-\(accessibilityIdentifier())")
        brightnessObservers.removeValue(forKey: display.id)
        contrastObservers.removeValue(forKey: display.id)
    }

    override func didRemove(_ rowView: NSTableRowView, forRow row: Int) {
        runInMainThread {
            removeRow(rowView, forRow: row)
        }
    }

    func addRow(_ rowView: NSTableRowView, forRow row: Int) {
        guard let scrollableBrightness = (rowView.view(atColumn: 0) as? NSTableCellView)?.subviews[0] as? ScrollableTextField,
            let display = (rowView.view(atColumn: 1) as? NSTableCellView)?.objectValue as? Display,
            let adaptiveButton = (rowView.view(atColumn: 1) as? NSTableCellView)?.subviews.first(
                where: { v in (v as? QuickAdaptiveButton) != nil }
            ) as? QuickAdaptiveButton,
            let notConnectedTextField = (rowView.view(atColumn: 1) as? NSTableCellView)?.subviews.first(
                where: { v in (v as? NotConnectedTextField) != nil }
            ) as? NotConnectedTextField,
            let scrollableContrast = (rowView.view(atColumn: 2) as? NSTableCellView)?.subviews[0] as? ScrollableTextField,
            let scrollableBrightnessCaption = (rowView.view(atColumn: 0) as? NSTableCellView)?.subviews[1] as? ScrollableTextFieldCaption,
            let scrollableContrastCaption = (rowView.view(atColumn: 2) as? NSTableCellView)?.subviews[1] as? ScrollableTextFieldCaption else { return }

        notConnectedTextField.onClick = getDeleteAction(displayID: display.id, row: row)
        adaptiveButton.setup(displayID: display.id)
        if display.active {
            if brightnessAdapter.mode == .manual {
                adaptiveButton.isHidden = true
            } else {
                adaptiveButton.isHidden = false
            }
        }

        scrollableBrightness.textFieldColor = textFieldColor
        scrollableBrightness.textFieldColorHover = textFieldColorHover
        scrollableBrightness.textFieldColorLight = textFieldColorLight
        scrollableBrightness.doubleValue = display.brightness.doubleValue.rounded()
        scrollableBrightness.caption = scrollableBrightnessCaption
        if !display.active {
            scrollableBrightness.textColor = textFieldColorLight.blended(withFraction: 0.7, of: gray)?.shadow(withLevel: 0.3) ?? textFieldColor
        }

        scrollableContrast.textFieldColor = textFieldColor
        scrollableContrast.textFieldColorHover = textFieldColorHover
        scrollableContrast.textFieldColorLight = textFieldColorLight
        scrollableContrast.doubleValue = display.contrast.doubleValue.rounded()
        scrollableContrast.caption = scrollableContrastCaption
        if !display.active {
            scrollableContrast.textColor = textFieldColorLight.blended(withFraction: 0.7, of: gray)?.shadow(withLevel: 0.3) ?? textFieldColor
        }

        scrollableBrightnessCaption.textColor = NSColor.textColor
        scrollableContrastCaption.textColor = NSColor.textColor

        scrollableBrightness.onValueChanged = { value in
            display.brightness = NSNumber(value: value)
            if brightnessAdapter.mode != .manual {
                display.adaptive = false
            }
        }
        scrollableContrast.onValueChanged = { value in
            display.contrast = NSNumber(value: value)
            if brightnessAdapter.mode != .manual {
                display.adaptive = false
            }
        }
        let id = display.id
        brightnessObservers[id] = { newBrightness, _ in
            if id != GENERIC_DISPLAY_ID, id != TEST_DISPLAY_ID {
                runInMainThread {
                    scrollableBrightness.integerValue = newBrightness.intValue
                    scrollableBrightness.setNeedsDisplay()
                }
            }
        }

        contrastObservers[id] = { newContrast, _ in
            if id != GENERIC_DISPLAY_ID, id != TEST_DISPLAY_ID {
                runInMainThread {
                    scrollableContrast.integerValue = newContrast.intValue
                    scrollableContrast.setNeedsDisplay()
                }
            }
        }
        display.numberObservers["brightness"]?["displayValuesView-\(accessibilityIdentifier())"] = brightnessObservers[id]!
        display.numberObservers["contrast"]?["displayValuesView-\(accessibilityIdentifier())"] = contrastObservers[id]!
    }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        runInMainThread {
            addRow(rowView, forRow: row)
        }
    }
}
