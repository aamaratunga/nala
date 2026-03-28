import SwiftUI

protocol ProgressStep: RawRepresentable, CaseIterable, Hashable where RawValue == String {}

enum StepStatus: Equatable {
    case pending
    case inProgress
    case completed
    case skipped
    case failed(String)
}

struct StepProgressList<Step: ProgressStep>: View {
    let statuses: [Step: StepStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Step.allCases), id: \.self) { step in
                stepRow(step, status: statuses[step] ?? .pending)
            }
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func stepRow(_ step: Step, status: StepStatus) -> some View {
        HStack(spacing: 10) {
            stepIcon(status)
                .frame(width: 20, height: 20)

            Text(step.rawValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(stepTextColor(status))

            Spacer()

            if case .failed(let message) = status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.white.opacity(0.3))
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.gray)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func stepTextColor(_ status: StepStatus) -> Color {
        switch status {
        case .pending: .white.opacity(0.4)
        case .inProgress: .white
        case .completed: .green.opacity(0.8)
        case .skipped: .gray
        case .failed: .red
        }
    }
}
