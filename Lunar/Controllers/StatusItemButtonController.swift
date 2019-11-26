//
//  StatusItemButton.swift
//  Lunar
//
//  Created by Alin Panaitiu on 25/11/2019.
//  Copyright © 2019 Alin. All rights reserved.
//

import Cocoa

class StatusItemButtonController: NSView {
    var statusButton: NSStatusBarButton?
    var menuPopoverOpener: DispatchWorkItem?

    convenience init(button: NSStatusBarButton) {
        self.init(frame: button.frame)
        statusButton = button
    }

    override func mouseEntered(with event: NSEvent) {
        menuPopoverOpener = menuPopoverOpener ?? DispatchWorkItem {
            if let area = event.trackingArea, let button = self.statusButton {
                menuPopover.show(relativeTo: area.rect, of: button, preferredEdge: .maxY)
                menuPopover.becomeFirstResponder()
            }
            self.menuPopoverOpener = nil
        }
        let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(700_000_000))

        DispatchQueue.main.asyncAfter(deadline: deadline, execute: menuPopoverOpener!)
    }

    override func mouseExited(with _: NSEvent) {
        if let opener = menuPopoverOpener {
            opener.cancel()
            menuPopoverOpener = nil
        }
        menuPopoverCloser = DispatchWorkItem {
            menuPopover.close()
        }
        let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(1_000_000_000))

        DispatchQueue.main.asyncAfter(deadline: deadline, execute: menuPopoverCloser)
    }

    override func mouseDown(with event: NSEvent) {
        menuPopover.close()
        if let button = statusButton {
            button.mouseDown(with: event)
        }
    }
}
