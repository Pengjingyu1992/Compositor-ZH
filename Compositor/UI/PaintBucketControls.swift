import SwiftUI

struct PaintBucketControls: View {
    @Bindable var session: EditorSession
    var body: some View {
        ToolControlsScroll {
            ToolControlsRow(spacing: 8) {
                Text("Paint Bucket").font(ToolHeaderStyle.titleFont)
                Text("Tolerance")
                TextField("Tolerance", value: Binding(get: { session.bucketSettings.tolerance },
                    set: { session.bucketSettings.tolerance = min(255, max(0, $0)) }), format: .number)
                    .frame(width: 54).textFieldStyle(ToolNumberFieldStyle(height: 22)).accessibilityIdentifier("bucketTolerance")
                Picker("Sample Size", selection: $session.bucketSettings.sampleSize) {
                    ForEach(WandSampleSize.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                }.frame(width: 170)
                Toggle("Contiguous", isOn: $session.bucketSettings.contiguous)
                Toggle("Sample All Layers", isOn: $session.bucketSettings.sampleAllLayers)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.document == nil || session.showsBusy)
    }
}
