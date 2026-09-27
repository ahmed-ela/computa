import Darwin
import Foundation

/// Opt-in signing test only. Links the production IPC source but never creates
/// a socket, reads Chrome state, touches pairing, or requests OS permissions.
@main
struct ChromeBridgeSigningProbe {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case "hold" where arguments.count == 1:
                FileHandle.standardOutput.write(Data("READY \(getpid())\n".utf8))
                while readLine() != nil { }
            case "own-team" where arguments.count == 2:
                let team = try ChromeBridgeIPC.ownAppleSigningTeam(forPeerIdentifier: arguments[1])
                print("TEAM \(team)")
            case "validate" where arguments.count == 3 || arguments.count == 4:
                guard let pid = Int32(arguments[1]), pid > 0 else { exit(64) }
                try ChromeBridgeIPC.validateCode(
                    pid: pid, identifier: arguments[2], team: arguments.count == 4 ? arguments[3] : nil
                )
                print("ACCEPTED")
            default:
                exit(64)
            }
        } catch let failure as ChromeBridgeIPC.Failure {
            print("REJECTED \(failure)")
            exit(23)
        } catch {
            print("REJECTED unexpected")
            exit(24)
        }
    }
}
