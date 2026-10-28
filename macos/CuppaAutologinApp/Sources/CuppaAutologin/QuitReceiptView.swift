import SwiftUI

struct QuitReceiptView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)

            VStack(spacing: 8) {
                receipt
                    .environment(\.colorScheme, .light)

                Button {
                    model.confirmQuit()
                } label: {
                    HStack(spacing: 7) {
                        if model.isQuitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            model.isQuitting
                                ? "Stopping Monitoring…"
                                : "Settle Up & Quit"
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.caramelPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isQuitting)

                Button("Cancel") {
                    model.dismissQuitReceipt()
                }
                .buttonStyle(.coffeeSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isQuitting)
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .frame(width: 252)
            .background(CoffeeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(CoffeeTheme.surfaceBorder)
            }
            .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quit Cuppa Wi-Fi")
    }

    private var receipt: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                Text(model.receiptVenueTitle)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("— Cuppa Wi-Fi —")
                    .foregroundStyle(.secondary)

                dashedRule

                ReceiptLine(
                    label: "time online",
                    value: model.timeConnected(at: context.date)
                )
                dashedRule

                ReceiptLine(
                    label: "TOTAL",
                    value: "on the house",
                    isBold: true
                )

                Text("thanks for steaming with us")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background {
                TornReceiptShape()
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                TornReceiptShape()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
    }

    private var dashedRule: some View {
        Line()
            .stroke(
                Color.secondary.opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

private struct ReceiptLine: View {
    let label: String
    let value: String
    var isBold = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .fontWeight(isBold ? .bold : .regular)
    }
}

private struct TornReceiptShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let toothWidth: CGFloat = 10
        let toothDepth: CGFloat = 6
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(
            to: CGPoint(x: rect.maxX, y: rect.maxY - toothDepth)
        )

        var x = rect.maxX
        var down = true
        while x > rect.minX {
            x = max(rect.minX, x - toothWidth / 2)
            path.addLine(
                to: CGPoint(
                    x: x,
                    y: down ? rect.maxY : rect.maxY - toothDepth
                )
            )
            down.toggle()
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct ReceiptIcon: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 11
            let sy = size.height / 13
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * sx, y: y * sy)
            }

            var outline = Path()
            outline.move(to: p(1, 1))
            outline.addLine(to: p(10, 1))
            outline.addLine(to: p(10, 11))
            outline.addLine(to: p(8.5, 10))
            outline.addLine(to: p(7, 11))
            outline.addLine(to: p(5.5, 10))
            outline.addLine(to: p(4, 11))
            outline.addLine(to: p(2.5, 10))
            outline.addLine(to: p(1, 11))
            outline.closeSubpath()

            var rules = Path()
            rules.move(to: p(3, 4))
            rules.addLine(to: p(8, 4))
            rules.move(to: p(3, 6.5))
            rules.addLine(to: p(8, 6.5))

            let style = StrokeStyle(
                lineWidth: min(sx, sy),
                lineJoin: .round
            )
            context.stroke(outline, with: .foreground, style: style)
            context.stroke(rules, with: .foreground, style: style)
        }
        .accessibilityHidden(true)
    }
}
