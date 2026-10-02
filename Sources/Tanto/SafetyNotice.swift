import SwiftUI

/// The notice Tantō shows at launch until it is confirmed, before it looks for the amp: turn MASTER down, what MASTER
/// does not limit, and Panic (design spec, section 5.6).
struct SafetyNotice: View {
    /// Called by the notice's only button.
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before you connect")
                .font(.headline)
            Text(
                "Tantō changes your amp's settings, its volumes included. Turn the amp's MASTER knob to minimum before connecting, and raise it while you play."
            )
            Text(
                "MASTER limits the speaker and the PHONES jack, but not LINE OUT or USB audio. If you use those, turn on the volume ceiling in Settings."
            )
            Text("Panic (Esc) sets the amp's VOLUME to 0.")
            HStack {
                Spacer()
                Button("I've turned MASTER down", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 440)
        // The button is the only way past the notice, so Tantō never looks for the amp before it was read.
        .interactiveDismissDisabled()
    }
}
