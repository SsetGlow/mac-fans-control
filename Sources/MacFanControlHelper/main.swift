import Foundation

@main
enum MacFanControlHelperMain {
    static func main() {
        let helper = SMCHelperDaemon()
        helper.run()
    }
}

final class SMCHelperDaemon: NSObject, NSXPCListenerDelegate, SMCHelperProtocol {
    private let listener = NSXPCListener(machServiceName: fanControlHelperIdentifier)
    private let queue = DispatchQueue(label: "local.mac-fan-control.smc-helper.queue")

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SMCHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setFanTarget(id: Int, rpm: Double, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                let smc = try SMCClient()
                try smc.setFan(index: id, rpm: rpm)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    func restoreAutomatic(completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                let smc = try SMCClient()
                try smc.restoreAutomaticFanControl()
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}
