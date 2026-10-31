#if SWIFT_PACKAGE
import AppleCamCore
#endif
import SwiftUI

/// Shows a newly taken background picture so it can be checked before the mask uses it.
struct BackgroundPictureReview: View {
    let model: CameraModel
    let pending: PendingPlate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Background Picture").font(.title3.bold())
            Text("Use it only if nobody and nothing that moves is in the picture. Everything that looks like this picture will be removed from your webcam layers.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Image(decorative: pending.capture.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 400).clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("New background picture")
            Text("\(String(pending.capture.width)) × \(String(pending.capture.height)), averaged from \(PlateAverager.defaultFrames) camera frames.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Retake") { model.discardBackgroundPicture(); model.takeBackgroundPicture() }
                Spacer()
                Button("Cancel", role: .cancel) { model.discardBackgroundPicture() }.keyboardShortcut(.cancelAction)
                Button("Use Picture") { model.acceptBackgroundPicture() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640)
    }
}

/// Large countdown over the canvas while the background picture is being prepared.
struct PlateCountdownOverlay: View {
    let model: CameraModel
    var body: some View {
        if let seconds = model.plateCountdown {
            VStack(spacing: 8) {
                Text("\(seconds)").font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text("Step out of view").font(.headline)
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Background picture in \(seconds) seconds. Step out of view.")
        } else if model.capturingPlate {
            Label("Taking background picture…", systemImage: "camera")
                .font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
    }
}
