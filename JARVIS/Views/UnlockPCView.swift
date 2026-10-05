import SwiftUI

/// Signing into the PC from here.
///
/// One view with one rule: it shows an action only when the machine has said an unlock could
/// work. Everything else it shows is an explanation of why there is no action, because a card
/// that goes blank is a card that sends somebody to check their Wi-Fi when the real answer is
/// that nothing is enrolled.
///
/// It never claims Windows signed in. The stages come from `MachineLink.stage`, which only moves
/// when the machine says something, and the last two - signing in, starting - exist precisely so
/// that the gap between "authorized" and "actually signed in" is visible rather than smoothed
/// over with a spinner.
struct UnlockPCCard: View {
    @ObservedObject var machine: MachineLink

    var body: some View {
        let standing = machine.standing

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(standing.headline)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HUD.text)

                Spacer()

                if machine.stage.busy { ProgressView().tint(HUD.accent).scaleEffect(0.8) }
            }

            if let obstacle = standing.obstacle {
                Text(obstacle).font(.footnote).foregroundStyle(HUD.amber)

                // The only thing that fixes either of these is at the PC, so say where rather
                // than leaving somebody pressing a button that will not come back.
                Text("Run Jarvis.SystemService.exe --enrol on the PC, from an elevated prompt.")
                    .font(.caption)
                    .foregroundStyle(HUD.dim)
            }

            switch machine.stage {
            case .idle:
                EmptyView()

            case .asking, .faceID, .authorizing, .signingIn, .desktopStarting:
                Text(machine.stage.sentence).font(.footnote).foregroundStyle(HUD.accent)

            case .online:
                Text("PC-PRIME online").font(.footnote).foregroundStyle(HUD.good)

            case .stopped(let stop):
                Text(stop.sentence)
                    .font(.footnote)
                    .foregroundStyle(stop.isCancellation ? HUD.dim : HUD.amber)
            }

            if standing.offersUnlock {
                Button(machine.stage.busy ? machine.stage.sentence : "Unlock PC") {
                    Task { await machine.unlock() }
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(machine.stage.busy)
            }
        }
    }
}
