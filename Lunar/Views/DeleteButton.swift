//
//  DeleteButton.swift
//  Lunar
//
//  Created by Alin on 26/01/2018.
//  Copyright © 2018 Alin. All rights reserved.
//

import Cocoa

class DeleteButton: NSButton {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: Internal

    func setup() {
        alphaValue = 0.0
    }

    override func mouseEntered(with _: NSEvent) {
        transition(0.2)
        alphaValue = 1.0
    }

    override func mouseExited(with _: NSEvent) {
        transition(0.3)
        alphaValue = 0.0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}
