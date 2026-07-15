import Foundation

let fanControlHelperIdentifier = "local.mac-fan-control.smc-helper"
let fanControlHelperPlistName = "\(fanControlHelperIdentifier).plist"

@objc protocol SMCHelperProtocol {
    func setFanTarget(id: Int, rpm: Double, completion: @escaping @Sendable (String?) -> Void)
    func restoreAutomatic(completion: @escaping @Sendable (String?) -> Void)
}
