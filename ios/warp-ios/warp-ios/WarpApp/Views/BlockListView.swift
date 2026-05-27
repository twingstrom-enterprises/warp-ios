import SwiftUI
import UIKit

struct BlockListView: View {
    let blockStore: TerminalBlockStore
    let onCopyBlock: (UInt64) -> Void
    @Binding var jumpRequest: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(blockStore.blocks) { block in
                        BlockRowView(block: block) {
                            onCopyBlock(block.id)
                        }
                        .id(block.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: jumpRequest) { _, _ in
                guard let lastID = blockStore.blocks.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: blockStore.blocks.count) { _, _ in
                guard let lastID = blockStore.blocks.last?.id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: blockStore.scrollTick) { _, _ in
                let targetID = blockStore.activeBlockID ?? blockStore.blocks.last?.id
                guard let targetID else { return }
                withAnimation(.linear(duration: 0.06)) {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            }
        }
    }
}
