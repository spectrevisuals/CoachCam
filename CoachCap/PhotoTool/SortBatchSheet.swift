import SwiftUI
import AppKit

/// "Sort before / after" — for the awkward case where a client misses a week and sends their
/// before AND after photos (often mixed in with sleep screenshots, food pics, etc.) in one
/// batch on one date. The two-panel "one date = one side" model can't split that, so this
/// sheet lets the coach tag each photo in the batch as **before** or **after** — and leave the
/// irrelevant ones untagged so they never show up in the comparison. "compare" hands the
/// tagged photos back as the before (left) and after (right) sequences.
struct SortBatchSheet: View {
    let contact: String?
    var initialDateKey: String? = nil
    /// Ordered (before, after) items when the coach commits. Empty lists are allowed.
    let onCompare: ([WhatsAppMediaItem], [WhatsAppMediaItem]) -> Void
    let onCancel: () -> Void

    enum Slot { case before, after }

    @StateObject private var loader = DateCompareLoader()
    @State private var dateKey: String? = nil
    @State private var tags: [UUID: Slot] = [:]

    private var photos: [WhatsAppMediaItem] { loader.leftPhotos }
    private var beforeItems: [WhatsAppMediaItem] { photos.filter { tags[$0.id] == .before } }
    private var afterItems:  [WhatsAppMediaItem] { photos.filter { tags[$0.id] == .after } }

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Brand.border)
            content
            Divider().overlay(Brand.border)
            footer
        }
        .frame(width: 740, height: 580)
        .background(Brand.bg)
        .brandTheme()
        .onAppear {
            dateKey = initialDateKey
            guard let c = contact else { return }
            Task {
                await loader.loadDates(for: c)
                if let k = dateKey { await loader.loadSide(.left, contact: c, dateKey: k) }
            }
        }
        .onChange(of: dateKey) { _, key in
            tags = [:]
            if let key, let c = contact { Task { await loader.loadSide(.left, contact: c, dateKey: key) } }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("sort before / after").font(Brand.font(17, .bold)).foregroundStyle(Brand.text)
                Text("tag each photo — leave sleep / food / other shots untagged to skip them")
                    .font(Brand.font(12)).foregroundStyle(Brand.muted)
            }
            Spacer()
            if !loader.dates.isEmpty {
                Picker("Date", selection: $dateKey) {
                    Text("pick the batch date…").tag(String?.none)
                    ForEach(loader.dates) { d in Text(d.displayString).tag(Optional(d.key)) }
                }
                .labelsHidden().frame(width: 300).colorScheme(.dark)
            }
        }
        .padding(16)
    }

    // MARK: grid

    @ViewBuilder
    private var content: some View {
        if contact == nil {
            filler(icon: "person.crop.circle", title: "no client selected",
                   subtitle: "pick a client on the compare screen first")
        } else if loader.isLoadingLeft {
            ProgressView("loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if dateKey == nil {
            filler(icon: "calendar", title: "pick the batch date",
                   subtitle: "choose the day the before + after photos came in")
        } else if photos.isEmpty {
            filler(icon: "photo.on.rectangle", title: "no photos", subtitle: "nothing on this date")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(photos) { item in thumb(item) }
                }
                .padding(16)
            }
        }
    }

    private func thumb(_ item: WhatsAppMediaItem) -> some View {
        let tag = tags[item.id]
        let ring: Color = tag == .before ? .blue : (tag == .after ? .green : Brand.border)
        return VStack(spacing: 5) {
            // Color.black sets the cell box; the photo is an overlay that fills and is then
            // hard-clipped to that box, so a wide photo can never spill over its neighbour
            // (which was covering the next cell's before/after buttons).
            Color.black
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .overlay {
                    if let t = item.thumb {
                        Image(nsImage: t).resizable().scaledToFill()
                    } else {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                // `.clipped()` clips the fill-overflow for BOTH drawing and HIT-TESTING — without
                // it the invisible overflow of a scaled-to-fill photo swallows clicks meant for
                // the before/after buttons below (and the neighbour's). clipShape only rounds.
                .clipped()
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ring, lineWidth: tag == nil ? 1 : 2.5))

            HStack(spacing: 5) {
                tagBtn("before", slot: .before, color: .blue, item: item, current: tag)
                tagBtn("after",  slot: .after,  color: .green, item: item, current: tag)
            }
        }
    }

    private func tagBtn(_ label: String, slot: Slot, color: Color,
                        item: WhatsAppMediaItem, current: Slot?) -> some View {
        let active = current == slot
        return Button {
            if tags[item.id] == slot { tags[item.id] = nil } else { tags[item.id] = slot }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(active ? .white : color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? color.opacity(0.9) : color.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func filler(icon: String, title: String, subtitle: String) -> some View {
        BrandEmptyState(icon: icon, title: title, subtitle: subtitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 14) {
            Label("\(beforeItems.count) before", systemImage: "circle.fill").foregroundStyle(.blue)
                .font(Brand.font(12))
            Label("\(afterItems.count) after", systemImage: "circle.fill").foregroundStyle(.green)
                .font(Brand.font(12))
            Text("\(photos.count - beforeItems.count - afterItems.count) skipped")
                .font(Brand.font(12)).foregroundStyle(Brand.muted)
            Spacer()
            Button("cancel") { onCancel() }.buttonStyle(OutlineButtonStyle())
            Button("compare") { onCompare(beforeItems, afterItems) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(beforeItems.isEmpty && afterItems.isEmpty)
        }
        .padding(16)
    }
}
