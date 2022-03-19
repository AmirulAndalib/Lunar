//
//  HotkeyButton.swift
//  Lunar
//
//  Created by Alin Panaitiu on 23.12.2020.
//  Copyright © 2020 Alin. All rights reserved.
//

import Cocoa
import Foundation
import Magnet
import Regex

class HotkeyButton: PopoverButton<HotkeyPopoverController> {
    // MARK: Lifecycle

    deinit {
        #if DEBUG
            log.verbose("START DEINIT")
            do { log.verbose("END DEINIT") }
        #endif
    }

    // MARK: Internal

    weak var display: Display?

    override var popoverController: HotkeyPopoverController? {
        guard let display = display else {
            return nil
        }
        return display.hotkeyPopoverController
    }

    func setup(from display: Display) {
        self.display = display

        guard let controller = popoverController else { return }
        controller.setup(from: display)

        controller.onDropdownSelect = { [weak self] dropdown in
            guard let input = InputSource(rawValue: dropdown.selectedTag().u16), let display = self?.display else { return }
            switch dropdown.tag {
            case 1:
                display.hotkeyInput1 = input.rawValue.ns
            case 2:
                display.hotkeyInput2 = input.rawValue.ns
            case 3:
                display.hotkeyInput3 = input.rawValue.ns
            default:
                break
            }
        }

        for dropdown in [controller.dropdown1, controller.dropdown2, controller.dropdown3] {
            guard let dropdown = dropdown else { continue }
            dropdown.removeAllItems()
            dropdown.addItems(
                withTitles: InputSource.mostUsed
                    .map { input in input.str } + InputSource.leastUsed
                    .map { input in input.str } + ["Unknown"]
            )
            for item in dropdown.itemArray {
                switch item.title.lowercased() {
                case "thunderbolt".r, "usb-c".r:
                    item.image = NSImage(named: "usbc")
                case "hdmi".r:
                    item.image = NSImage(named: "hdmi")
                case "dvi".r:
                    item.image = NSImage(named: "dvi")
                case "displayport".r:
                    item.image = NSImage(named: "displayport")
                case "tuner".r:
                    item.image = NSImage(named: "tuner")
                case "composite".r:
                    item.image = NSImage(named: "composite")
                case "component".r:
                    item.image = NSImage(named: "component")
                case "s-video".r:
                    item.image = NSImage(named: "svideo")
                case "vga".r:
                    item.image = NSImage(named: "vga")
                default:
                    break
                }
            }

            dropdown.menu?.insertItem(.separator(), at: InputSource.mostUsed.count)
            for item in dropdown.itemArray {
                guard let input = inputSourceMapping[item.title] else { continue }
                item.tag = input.rawValue.i
                item.attributedTitle = item.title.withFont(.monospacedSystemFont(ofSize: 12, weight: .semibold)).withTextColor(.labelColor)

                if input == .unknown {
                    item.isEnabled = true
                    item.isHidden = true
                    item.title = "Video input"
                    item.image = NSImage(named: "input")
                }
            }
            switch dropdown.tag {
            case 1:
                dropdown.selectItem(withTag: display.hotkeyInput1.intValue)
            case 2:
                dropdown.selectItem(withTag: display.hotkeyInput2.intValue)
            case 3:
                dropdown.selectItem(withTag: display.hotkeyInput3.intValue)
            default:
                break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()

        guard let display = display, let popover = display._hotkeyPopover, isEnabled else { return }
        if popover.contentViewController == nil {
            setup(from: display)
        }
        handlePopoverClick(popover, with: event)
        window?.makeFirstResponder(popoverController?.dropdown1)
    }
}
