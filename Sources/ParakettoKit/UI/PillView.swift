import SwiftUI

struct PillView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PillStyle.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .frame(width: Overlay.pillSize.width, height: Overlay.pillSize.height)
            .background(PillBackground())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
            .frame(width: Overlay.panelSize.width, height: Overlay.panelSize.height)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .recording, .transcribing:
            SpectrumMeter(meter: controller.meter)
                .opacity(controller.state == .recording ? 1 : 0.4)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(PillStyle.error)
        case .notice(let message):
            Label(message, systemImage: "doc.on.clipboard")
        case .idle, .downloadingModel, .loadingModel, .optimizingModel:
            Text(controller.state.label)
        }
    }

}

enum PillStyle {
    static let fill = Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82)
    static let text = Color.white.opacity(0.95)
    static let bar = Color.white.opacity(0.92)
    static let error = Color(red: 1.0, green: 0.42, blue: 0.42)
}

/// Dark capsule with a hairline border.
private struct PillBackground: View {
    var body: some View {
        Capsule()
            .fill(PillStyle.fill)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// Thin white bars. Each new level pushes the history left,
/// so the meter scrolls like a waveform rather than bouncing in place.
private struct SpectrumMeter: View {
    @ObservedObject var meter: RecordingMeter

    private static let barCount = 36
    private static let barWidth: CGFloat = 2
    private static let spacing: CGFloat = 1.5
    private static let silenceFraction: CGFloat = 0.14
    private static let peakFraction: CGFloat = 0.86

    @State private var history: [CGFloat] = []

    var body: some View {
        Canvas { context, size in
            let padded = Array(repeating: CGFloat(0), count: max(0, Self.barCount - history.count)) + history
            for (index, value) in padded.suffix(Self.barCount).enumerated() {
                let barHeight = size.height * (Self.silenceFraction + Self.peakFraction * value)
                let rect = CGRect(
                    x: CGFloat(index) * (Self.barWidth + Self.spacing),
                    y: (size.height - barHeight) / 2,
                    width: Self.barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                    with: .color(PillStyle.bar)
                )
            }
        }
        .frame(
            width: CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.spacing,
            height: 24
        )
        .onChange(of: meter.elapsed) { _, _ in
            history.append(CGFloat(min(max(meter.level, 0), 1)))
            if history.count > Self.barCount { history.removeFirst(history.count - Self.barCount) }
        }
    }
}

#if DEBUG
#Preview("Recording") { PillPreview(.recording) }
#Preview("Transcribing") { PillPreview(.transcribing) }
#Preview("Copied") { PillPreview(.notice("Copied")) }
#Preview("Kept in history") { PillPreview(.notice("Kept in history")) }
#Preview("Error") { PillPreview(.failed("No mic access")) }
#Preview("All messages") { PillMessagesPreview() }
#endif
