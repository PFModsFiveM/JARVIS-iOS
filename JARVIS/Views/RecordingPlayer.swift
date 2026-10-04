import AVKit
import SwiftUI

/// Something there is a video file for, and what to call it on screen.
///
/// One type for both kinds of recording - the ones fetched from the PC and the ones read from the
/// shared store with the PC off - because the player must not care which it is, and two near-
/// identical player screens is how one of them ends up with the Close button and the other does
/// not.
struct RecordingPlayable: Identifiable, Equatable {
    let url: URL
    let title: String

    /// The file path, which is unique per fetched recording and is what the sheet keys on.
    var id: String { url.path }

    init(url: URL, title: String = "Recording") {
        self.url = url
        self.title = title
    }
}

/// Owns the player for one recording: created once, stopped and released on the way out.
///
/// **The defect this exists to fix.** Both player sheets built `AVPlayer(url:)` inline in the
/// view builder, so a new player was constructed on every re-render of the sheet, none of them
/// was ever paused, and none was released - which on a phone means audio continuing after the
/// screen has gone and several decoders alive at once. SwiftUI gives no hook to clean that up
/// from an expression inside a `ViewBuilder`; it needs an object with a lifetime, which is this.
///
/// It is also the testable half of the fix: the view cannot be unit-tested, and the part that was
/// actually wrong can be.
@MainActor
final class RecordingPlaybackSession: ObservableObject {
    /// What is open, or nil when nothing is.
    @Published private(set) var showing: RecordingPlayable?

    /// The player for it. Nil whenever `showing` is nil, and never a second one for the same file.
    private(set) var player: AVPlayer?

    /// How many players this session has built, so a test can prove one per recording.
    private(set) var built = 0

    /// Opens a recording, reusing the player when it is the one already open.
    ///
    /// Reusing matters because SwiftUI will evaluate the sheet's body more than once for one
    /// presentation, and rebuilding the player each time is what the old code did.
    func open(_ item: RecordingPlayable) {
        if showing == item, player != nil { return }

        // A different recording replaces this one, and the old player must go first rather than
        // being left running behind the new one.
        release()

        showing = item
        player = AVPlayer(url: item.url)
        built += 1
    }

    /// Closes whatever is open: playback stops, the player goes, the sheet's binding clears.
    ///
    /// Safe to call twice - the dismiss path and `onDisappear` both call it, on purpose, because
    /// either one can be the one that actually happens depending on how the sheet went away.
    func close() {
        release()
        showing = nil
    }

    /// Whether anything is playing, for the tests and for a diagnostic.
    var isPlaying: Bool { player?.timeControlStatus == .playing }

    private func release() {
        player?.pause()

        // Detaching the item is what actually lets the decoder go; pausing alone leaves it held.
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

/// One recording, playable, with a way out that always works.
///
/// **Why this is not just `VideoPlayer` in a sheet.** `RecordingsView` is itself presented as a
/// sheet from Security, so the player is a sheet on a sheet; `AVPlayerViewController` consumes
/// drag gestures, so swipe-to-dismiss does not reach the sheet; and the old code put
/// `.ignoresSafeArea()` on the whole player, which covered the one remaining affordance at the
/// top edge. The result was a screen with no way back, and closing the app was the only exit.
///
/// So the way out is explicit and is drawn above the video rather than under it:
///
/// - a Close button in the top trailing corner, inside the safe area, always hit-testable;
/// - the drag indicator shown, so the sheet looks dismissable and is;
/// - `interactiveDismissDisabled(false)` stated rather than assumed;
/// - playback stopped and the player released on the way out, by whichever path is taken.
///
/// Only the video surface ignores the safe area. The chrome never does.
struct RecordingPlayerView: View {
    let item: RecordingPlayable
    let onClose: () -> Void

    @StateObject private var session = RecordingPlaybackSession()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The backdrop ignores the safe area so the bars are black in landscape; the player
            // sits inside it and the chrome sits above it.
            HUD.background.ignoresSafeArea()

            if let player = session.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView().tint(HUD.accent)
            }

            closeButton
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .task { session.open(item) }
        .onDisappear { session.close() }
    }

    /// Deliberately large and deliberately opaque enough to see against any frame.
    ///
    /// 44 points is the smallest thing a thumb reliably hits, and this is the control somebody
    /// reaches for when they are already slightly annoyed.
    private var closeButton: some View {
        Button {
            session.close()
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(HUD.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().stroke(HUD.accent.opacity(0.5), lineWidth: 1))
        }
        .padding(.top, 12)
        .padding(.trailing, 16)
        .accessibilityLabel("Close recording")
    }
}

extension View {
    /// Presents a recording, with the chrome that makes it closable.
    ///
    /// One line at both call sites so the PC-provided list and the shared-store list cannot drift
    /// into having different exits - which is exactly how the bug survived in one of them.
    func recordingPlayer(_ item: Binding<RecordingPlayable?>) -> some View {
        sheet(item: item) { playable in
            RecordingPlayerView(item: playable) { item.wrappedValue = nil }
        }
    }
}
