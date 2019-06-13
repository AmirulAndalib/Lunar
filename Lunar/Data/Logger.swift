//
//  Logger.swift
//  Lunar
//
//  Created by Alin on 07/07/2018.
//  Copyright © 2018 Alin. All rights reserved.
//

import Crashlytics
import Foundation
import SwiftyBeaver

class Logger: SwiftyBeaver {
    static let console = ConsoleDestination()
    static let file = FileDestination()
//    static let platform = SBPlatformDestination(appID: "0G8Ek7", appSecret: secrets.appSecret, encryptionKey: secrets.encryptionKey)
    static var debugModeObserver: NSKeyValueObservation?

    class func initLogger() {
        console.format = "$DHH:mm:ss.SSS$d $C$L$c $N.$F:$l - $M <$X>"
        file.format = "$DHH:mm:ss.SSS$d $L $N.$F:$l - $M <$X>"
//        platform.format = "$DHH:mm:ss.SSS$d $C$L$c $N.$F:$l - $M <$X>"
//        platform.minLevel = .info

        setMinLevel(debug: datastore.defaults.debug)
        debugModeObserver = datastore.defaults.observe(\.debug, options: [.new], changeHandler: { _, change in
            self.setMinLevel(debug: change.newValue ?? false)
        })

        Logger.addDestination(console)
        Logger.addDestination(file)
//        Logger.addDestination(platform)
    }

    class func setMinLevel(debug _: Bool) {
        if !datastore.defaults.debug {
            console.minLevel = .info
            file.minLevel = .info
        } else {
            console.minLevel = .verbose
            file.minLevel = .verbose
        }
    }

    open override class func verbose(
        _ message: @autoclosure () -> Any,
        _
        file: String = #file,
        _ function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        super.verbose(message(), file, function, line: line, context: context)
        crashlog(String(describing: message()))
    }

    open override class func debug(
        _ message: @autoclosure () -> Any,
        _
        file: String = #file,
        _ function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        super.debug(message(), file, function, line: line, context: context)
        crashlog(String(describing: message()))
    }

    open override class func info(
        _ message: @autoclosure () -> Any,
        _
        file: String = #file,
        _ function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        super.info(message(), file, function, line: line, context: context)
        crashlog(String(describing: message()))
    }

    open override class func warning(
        _ message: @autoclosure () -> Any,
        _
        file: String = #file,
        _ function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        super.warning(message(), file, function, line: line, context: context)
        crashlog(String(describing: message()))
    }

    open override class func error(
        _ message: @autoclosure () -> Any,
        _
        file: String = #file,
        _ function: String = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        super.error(message(), file, function, line: line, context: context)
        crashlog(String(describing: message()))
    }

    class func crashlog(_ message: String) {
        CLSLogv("%@", getVaList([message]))
    }
}
