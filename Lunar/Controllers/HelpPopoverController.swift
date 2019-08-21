//
//  HelpPopoverController.swift
//  Lunar
//
//  Created by Alin on 14/06/2019.
//  Copyright © 2019 Alin. All rights reserved.
//

import Cocoa

class HelpPopoverController: NSViewController {
    @IBOutlet weak var helpTextField: NSTextField!
    var onClick: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
    
}
