import Foundation
import SSTPKit

guard getuid() == 0 else {
    fputs("sstpd must run as root (utun + routes). Install it with scripts/install-daemon.sh\n", stderr)
    exit(1)
}

// set by install-daemon.sh to the app's designated requirement: only that app may drive the helper
let args = CommandLine.arguments
let requirement = args.firstIndex(of: "--client-requirement").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
let server = Server(clientRequirement: requirement)
server.run()
dispatchMain()
