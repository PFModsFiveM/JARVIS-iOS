import SwiftUI

/// Which nodes of JARVIS are here - priority §3A and §11.
///
/// **The complaint this answers.** With the PC asleep the screen said CONNECTING, which reads as
/// "JARVIS is not here yet" - and JARVIS was there, on the phone, able to work the lights, say
/// where the owner was and answer a general question. One word for a connection had been standing
/// in for the state of the whole assistant.
///
/// So two facts, separately. JARVIS is online, because the node being asked is running by
/// definition. And PC-Prime is whatever PC-Prime is, on its own line, in the same word the panel
/// below uses - passed in rather than worked out twice.
///
/// Two nodes and no others. There is no Home Node, no glasses and no headset yet, and a strip with
/// placeholders for them would be a claim about things that do not exist.
struct NodeStateStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HUDLabel(text: MobileStatus.headline(), color: HUD.accent)

            HStack(spacing: 14) {
                ForEach(MobileStatus.nodes(model.nodeState, pcWord: model.device.headline)) { node in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(colour(node.tone))
                            .frame(width: 6, height: 6)
                        Text("\(node.title) \(node.word)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(HUD.dim)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(node.title) \(node.word)\(node.detail.map { ". \($0)" } ?? "")")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func colour(_ tone: MobileStatus.Tone) -> Color {
        switch tone {
        case .alive: return HUD.accent
        case .waiting: return HUD.dim
        case .down: return HUD.amber
        }
    }
}
