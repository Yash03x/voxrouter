import SwiftUI
import VoxRouterKit

/// Past conversations for the working directory.
///
/// Reads the same store the dispatcher writes to, so what's listed here is
/// exactly what a follow-up command could refer back to.
struct HistoryWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.history, selection: $model.selectedConversation) { conversation in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(conversation.startedAt,
                             format: .dateTime.month().day().hour().minute())
                        Text("·")
                        Text("\(conversation.turns.count) turn\(conversation.turns.count == 1 ? "" : "s")")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(conversation.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if model.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No conversations yet")
                            .font(.system(size: 12, weight: .medium))
                        Text("Hold \(model.hotkey.label) and say what you want done.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
        } detail: {
            if let conversation = model.history.first(where: { $0.id == model.selectedConversation }) {
                ConversationDetail(conversation: conversation)
            } else {
                Text("Select a conversation")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await model.refresh() }
    }
}

private struct ConversationDetail: View {
    let conversation: ConversationStore.Conversation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(conversation.turns.enumerated()), id: \.offset) { _, turn in
                    TurnView(turn: turn)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TurnView: View {
    let turn: ConversationStore.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.wave.2")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(turn.task)
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: turn.succeeded ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(turn.succeeded ? .green : .red)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.summary ?? (turn.succeeded ? "Done." : "Did not complete."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label(turn.engineId, systemImage: "cpu")
                        Text(turn.at, format: .dateTime.hour().minute().second())
                        // The run id links back to the on-disk journal, which
                        // holds the full transcript.
                        Text(turn.runId).textSelection(.enabled)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
