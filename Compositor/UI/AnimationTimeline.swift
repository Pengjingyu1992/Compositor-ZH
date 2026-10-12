import SwiftUI

struct AnimationTimeline: View {
    let session: EditorSession
    @State private var playback: Task<Void, Never>?
    private var track: AnimationTrack? { session.document?.animation }
    private var current: UUID? { session.document?.currentAnimationFrameID }
    private var editable: Bool { session.canEditLayers && !session.history.hasPendingEdit }

    var body: some View {
        if session.document != nil {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    if let track {
                        Text("Animation").font(.caption.bold())
                        Button { if session.animationPlaying { session.stopAnimation(); playback?.cancel() } else { playback = Task { await session.playAnimation() } } }
                            label: { Image(systemName: session.animationPlaying ? "pause.fill" : "play.fill") }
                            .help(L10n.text(session.animationPlaying ? "Pause Animation" : "Play Animation"))
                            .disabled(!editable && !session.animationPlaying)
                        Button { session.addAnimationFrame(duplicate: false) } label: { Image(systemName: "plus") }.help("New Animation Frame").disabled(!editable)
                        Button { session.addAnimationFrame(duplicate: true) } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate Animation Frame").disabled(!editable)
                        Button { session.removeAnimationFrame() } label: { Image(systemName: "trash") }.help("Delete Animation Frame").disabled(!editable || track.frames.count < 2)
                        Button { session.moveAnimationFrame(-1) } label: { Image(systemName: "arrow.left") }.help("Move Frame Earlier").disabled(!editable || current == track.frames.first?.groupID)
                        Button { session.moveAnimationFrame(1) } label: { Image(systemName: "arrow.right") }.help("Move Frame Later").disabled(!editable || current == track.frames.last?.groupID)
                        Text("Duration (ms)").font(.caption)
                        TextField("Duration (ms)", value: Binding(get: { track.frames.first(where: { $0.groupID == current })?.durationMS ?? 100 }, set: { session.changeAnimationTiming(duration: $0) }), format: .number.grouping(.never))
                            .frame(width: 65).disabled(!editable)
                        Text("Repeats (−1 once, 0 forever)").font(.caption)
                        TextField("Repeats (−1 once, 0 forever)", value: Binding(get: { track.loopCount }, set: { session.changeAnimationTiming(loops: $0) }), format: .number.grouping(.never))
                            .frame(width: 55).disabled(!editable)
                        Spacer()
                        Text(L10n.format("%lld frames", track.frames.count)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Create Animation") { session.startAnimation() }.disabled(!editable)
                        Text("Turn this canvas into editable GIF frames").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                if let track {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(track.frames.enumerated()), id: \.element.id) { index, frame in
                                Button { session.selectAnimationFrame(frame.groupID) } label: {
                                    VStack(spacing: 2) {
                                        Text(L10n.format("Frame %lld", index + 1))
                                        Text("\(frame.durationMS) ms").font(.caption2).foregroundStyle(.secondary)
                                    }.padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(current == frame.groupID ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).disabled(!editable).accessibilityIdentifier("animationFrame-\(index)")
                            }
                        }
                    }.frame(height: 43)
                }
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .onDisappear { playback?.cancel(); session.stopAnimation() }
                .onChange(of: session.document?.id) { _, _ in playback?.cancel(); session.stopAnimation() }
            Divider()
        }
    }
}
