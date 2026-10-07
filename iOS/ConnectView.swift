import SwiftUI

/// First screen: pick a discovered server (Bonjour) or type an address + pairing code, then connect.
struct ConnectView: View {
    @Environment(ServerConnection.self) private var connection
    @State private var browser = BonjourBrowser()
    @State private var connecting = false

    var body: some View {
        @Bindable var conn = connection
        NavigationStack {
            Form {
                if !browser.servers.isEmpty {
                    Section("Found on your network") {
                        ForEach(browser.servers) { s in
                            Button {
                                conn.host = s.host; conn.port = s.port
                            } label: {
                                HStack {
                                    Label(s.name, systemImage: "desktopcomputer")
                                    Spacer()
                                    Text("\(s.host):\(s.port)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Server") {
                    TextField("Address (e.g. 192.168.1.8)", text: $conn.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Port", value: $conn.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Pairing code", text: $conn.code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.numberPad)
                }

                if let err = connection.lastError {
                    Section { Text(err).foregroundStyle(.red).font(.callout) }
                }

                Section {
                    Button {
                        connecting = true
                        Task { await connection.connect(); connecting = false }
                    } label: {
                        HStack { Spacer()
                            if connecting { ProgressView() } else { Text("Connect").bold() }
                            Spacer() }
                    }
                    .disabled(connecting || conn.host.isEmpty || conn.code.isEmpty)
                }
            }
            .navigationTitle("Connect")
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }
}
