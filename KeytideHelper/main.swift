import Foundation

let listener = HelperXPCListener()
listener.resume()
NSLog("[KeytideHelper] listening on \(HelperLocations.machServiceName)")
CFRunLoopRun()
