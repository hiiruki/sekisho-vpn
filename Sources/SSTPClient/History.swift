import SSTPKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var vpn: VPNModel

    var body: some View {
        VStack(alignment: .leading) {
            Table(vpn.sessions) {
                TableColumn("Started") { s in Text(Date(timeIntervalSince1970: s.start).formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("Profile", value: \.profile)
                TableColumn("Duration") { s in Text(duration(s.end - s.start)).monospacedDigit() }
                TableColumn("Down") { s in Text(bytes(Double(s.rx))).monospacedDigit() }
                TableColumn("Up") { s in Text(bytes(Double(s.tx))).monospacedDigit() }
                TableColumn("Ended") { s in ending(s).help(s.reason) }
            }
            HStack {
                let drops = vpn.sessions.filter(\.dropped).count
                Text("\(vpn.sessions.count) sessions, \(drops) dropped, ↓ \(bytes(Double(vpn.sessions.map(\.rx).reduce(0, +)))) ↑ \(bytes(Double(vpn.sessions.map(\.tx).reduce(0, +))))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…") { vpn.exportHistory() }.disabled(vpn.sessions.isEmpty)
                Button("Clear History") { vpn.clearHistory() }.disabled(vpn.sessions.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 300)
    }

    private func ending(_ s: Session) -> Text {
        if s.dropped { return Text("Dropped: \(s.reason)") }
        return s.reason.isEmpty ? Text("Disconnected") : Text(s.reason)
    }
}
