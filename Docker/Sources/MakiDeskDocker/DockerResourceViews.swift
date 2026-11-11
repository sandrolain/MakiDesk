import SwiftUI
import MakiDockerCore

struct DockerImagesView: View {
    @Bindable var store: DockerStore
    @State private var sortOrder = [KeyPathComparator<DockerImage>(\.primaryTag)]

    var body: some View {
        VStack(spacing: 0) {
            DockerSectionHeader(
                title: "Images",
                subtitle: "\(store.images.count) total · \(store.images.filter(\.isDangling).count) dangling",
                store: store
            )
            HStack {
                Spacer()
                Menu("Image actions") {
                    Button("Pull image…") { store.pullImage() }
                    Button("Build image…") { store.buildImage() }
                }
                .menuStyle(.borderlessButton)
                .padding(.trailing, 12)
            }
            .frame(height: 30)
            Divider().overlay(store.theme.border)
            if store.filteredImages.isEmpty {
                DockerEmptyView(icon: "square.stack.3d.up",
                                title: store.images.isEmpty ? "No images" : "No matching images",
                                detail: store.images.isEmpty
                                    ? "Images appear here after a pull, a build or a Compose start."
                                    : "Try another search or clear the filter.")
            } else {
                VStack(spacing: 0) {
                    Table(sortedImages, selection: $store.selectedImageID,
                          sortOrder: $sortOrder) {
                    TableColumn("Repository:Tag", value: \.primaryTag) { image in
                        HStack(spacing: 5) {
                            Text(image.primaryTag)
                                .lineLimit(1)
                            if image.isDangling {
                                DockerBadge(text: "dangling", tone: .warning, theme: store.theme)
                            }
                        }
                    }
                    .width(min: 150, ideal: 190, max: 260)
                    TableColumn("ID", value: \.shortID) { image in
                        Text(image.shortID).font(.callout.monospaced())
                    }
                    .width(min: 82, ideal: 92, max: 110)
                    TableColumn("Size", value: \.sizeBytes) { image in
                        Text(DockerFormatting.spacedSize(image.size)).font(.callout.monospacedDigit())
                    }
                    .width(min: 58, ideal: 70, max: 90)
                    TableColumn("Containers", value: \.containers) { image in
                        Text("\(image.containers)").font(.callout.monospacedDigit())
                    }
                    .width(min: 72, ideal: 82, max: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .tableColumnHeaders(.visible)
                .scrollContentBackground(.hidden)
                .background(store.theme.background)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let image = store.images.first(where: { $0.id == id }) {
                        Button("Tag image…") { store.tagImage(image) }
                        Button("Push image…") { store.pushImage(image) }
                            .disabled(image.isDangling)
                        Button("Save image archive…") { store.saveImage(image) }
                        Divider()
                        Button("Remove image", role: .destructive) { store.removeImage(image) }
                        Button("Copy image ID") { store.copyToPasteboard(image.id) }
                    }
                } primaryAction: { _ in }
                }
            }
        }
        .background(store.theme.background)
    }

    private var sortedImages: [DockerImage] {
        store.filteredImages.sorted(using: sortOrder)
    }
}

struct DockerVolumesView: View {
    @Bindable var store: DockerStore
    @State private var sortOrder = [KeyPathComparator<DockerVolume>(\.name)]

    var body: some View {
        VStack(spacing: 0) {
            DockerSectionHeader(
                title: "Volumes",
                subtitle: "\(store.volumes.count) total · \(store.volumes.filter { $0.isUsed == false }.count) unused",
                store: store
            )
            HStack {
                Spacer()
                Button("Create volume…") { store.createVolume() }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 12)
            }
            .frame(height: 30)
            Divider().overlay(store.theme.border)
            if store.filteredVolumes.isEmpty {
                DockerEmptyView(icon: "externaldrive",
                                title: store.volumes.isEmpty ? "No volumes" : "No matching volumes",
                                detail: store.volumes.isEmpty
                                    ? "Named and anonymous volumes appear here."
                                    : "Try another search or clear the filter.")
            } else {
                VStack(spacing: 0) {
                    Table(sortedVolumes, selection: $store.selectedVolumeID,
                          sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { volume in
                        HStack(spacing: 5) {
                            Text(volume.name).lineLimit(1)
                            if volume.isAnonymous {
                                DockerBadge(text: "anonymous", tone: .neutral, theme: store.theme)
                            }
                        }
                    }
                    .width(min: 140, ideal: 180, max: 260)
                    TableColumn("Driver", value: \.driver) { Text($0.driver).font(.callout) }
                        .width(min: 60, ideal: 70, max: 90)
                    TableColumn("Size", value: \.sizeBytes) {
                        Text(DockerFormatting.spacedSize($0.size ?? "—"))
                            .font(.callout.monospacedDigit())
                    }
                        .width(min: 60, ideal: 70, max: 90)
                    TableColumn("In use", value: \.usageSortOrder) { volume in
                        Text(volume.isUsed ? "yes" : "no")
                            .font(.callout)
                            .foregroundStyle(volume.isUsed ? store.theme.subtext : .orange)
                    }
                    .width(min: 50, ideal: 60, max: 80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .tableColumnHeaders(.visible)
                .scrollContentBackground(.hidden)
                .background(store.theme.background)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let volume = store.volumes.first(where: { $0.name == id }) {
                        Button("Remove volume", role: .destructive) { store.removeVolume(volume) }
                            .disabled(volume.isUsed)
                        Button("Copy name") { store.copyToPasteboard(volume.name) }
                    }
                } primaryAction: { _ in }
                }
            }
        }
        .background(store.theme.background)
    }

    private var sortedVolumes: [DockerVolume] {
        store.filteredVolumes.sorted(using: sortOrder)
    }
}

struct DockerNetworksView: View {
    @Bindable var store: DockerStore
    @State private var sortOrder = [KeyPathComparator<DockerNetwork>(\.name)]

    var body: some View {
        VStack(spacing: 0) {
            DockerSectionHeader(
                title: "Networks",
                subtitle: "\(store.networks.count) total · \(store.networks.filter { $0.isUsed == false && $0.isBuiltIn == false }.count) unused",
                store: store
            )
            HStack {
                Spacer()
                Button("Create network…") { store.createNetwork() }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 12)
            }
            .frame(height: 30)
            Divider().overlay(store.theme.border)
            if store.filteredNetworks.isEmpty {
                DockerEmptyView(icon: "network",
                                title: store.networks.isEmpty ? "No networks" : "No matching networks",
                                detail: store.networks.isEmpty
                                    ? "Bridge, host and project networks appear here."
                                    : "Try another search or clear the filter.")
            } else {
                VStack(spacing: 0) {
                    Table(sortedNetworks, selection: $store.selectedNetworkID,
                          sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { network in
                        HStack(spacing: 5) {
                            Text(network.name).lineLimit(1)
                            if network.isBuiltIn {
                                DockerBadge(text: "built-in", tone: .neutral, theme: store.theme)
                            }
                        }
                    }
                    .width(min: 140, ideal: 180, max: 260)
                    TableColumn("Driver", value: \.driver) { Text($0.driver).font(.callout) }
                        .width(min: 60, ideal: 70, max: 90)
                    TableColumn("Scope", value: \.scope) { Text($0.scope).font(.callout) }
                        .width(min: 50, ideal: 60, max: 80)
                    TableColumn("Containers", value: \.containerCount) {
                        Text("\($0.containers.count)").font(.callout.monospacedDigit())
                    }
                    .width(min: 60, ideal: 70, max: 90)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .tableColumnHeaders(.visible)
                .scrollContentBackground(.hidden)
                .background(store.theme.background)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let network = store.networks.first(where: { $0.id == id }) {
                        Button("Remove network", role: .destructive) { store.removeNetwork(network) }
                            .disabled(network.isUsed || network.isBuiltIn)
                        Button("Connect container…") { store.connectContainer(to: network) }
                            .disabled(network.name == "host" || network.name == "none")
                        Button("Copy network ID") { store.copyToPasteboard(network.id) }
                    }
                } primaryAction: { _ in }
                }
            }
        }
        .background(store.theme.background)
    }

    private var sortedNetworks: [DockerNetwork] {
        store.filteredNetworks.sorted(using: sortOrder)
    }
}

struct DockerCleanupView: View {
    @Bindable var store: DockerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                          spacing: 12) {
                    DockerCleanupCard(store: store, mode: .containers,
                                      category: store.diskUsage.containers)
                    DockerCleanupCard(store: store, mode: .images,
                                      category: store.diskUsage.images)
                    DockerCleanupCard(store: store, mode: .volumes,
                                      category: store.diskUsage.volumes)
                    DockerCleanupCard(store: store, mode: .networks,
                                      category: networkCategory)
                    DockerCleanupCard(store: store, mode: .buildCache,
                                      category: store.diskUsage.buildCache)
                }
                DockerCleanupSummaryActions(store: store)
            }
            .padding(16)
        }
        .background(store.theme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cleanup")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(store.theme.text)
                Text("Reclaimable \(DockerFormatting.size(store.diskUsage.reclaimableBytes)) of \(DockerFormatting.size(store.diskUsage.totalBytes))")
                    .font(.callout)
                    .foregroundStyle(store.theme.subtext)
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Button("Refresh") { store.refreshNow() }
        }
    }

    private var networkCategory: DockerDiskUsageCategory {
        let unused = store.networks.filter { $0.isUsed == false && $0.isBuiltIn == false }.count
        return DockerDiskUsageCategory(
            title: "Networks",
            total: store.networks.count,
            active: store.networks.count - unused,
            size: "—",
            bytes: 0,
            reclaimable: unused == 0 ? "0" : "\(unused)",
            reclaimableBytes: 0
        )
    }

}

private struct DockerPrunePreviewGroup: Identifiable {
    let title: String
    let items: [String]
    var note: String? = nil

    var id: String { title }
}

struct DockerCleanupSummaryActions: View {
    @Bindable var store: DockerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup summary")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(store.theme.text)
            DockerKeyValue(items: [
                ("Images", store.diskUsage.images.size),
                ("Containers", store.diskUsage.containers.size),
                ("Volumes", store.diskUsage.volumes.size),
                ("Build cache", store.diskUsage.buildCache.size),
                ("Estimated reclaimable", store.prunePlan.estimatedSize),
            ], store: store)
            HStack {
                Button("Prune") { store.prune(.basic) }
                    .buttonStyle(.borderedProminent)
                Button("Prune all", role: .destructive) { store.prune(.all) }
            }
        }
        .padding(12)
        .background(store.theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(store.theme.border.opacity(0.5))
        }
    }
}

struct DockerCleanupPreviewView: View {
    @Bindable var store: DockerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader(title: "Removal preview",
                             subtitle: "Resources eligible for each prune scope",
                             icon: "trash")
                Text("Docker may refine the build-cache selection when pruning.")
                    .font(.callout)
                    .foregroundStyle(store.theme.subtext)
                pruneScope(title: "Prune",
                           estimate: store.prunePlan.estimatedSize(for: .basic),
                           accent: store.theme.accent,
                           resources: standardPruneResources)
                pruneScope(title: "Prune all",
                           estimate: store.prunePlan.estimatedSize(for: .all),
                           accent: .orange,
                           resources: allPruneResources)
            }
            .padding(16)
        }
        .background(store.theme.background)
    }

    private var standardPruneResources: [DockerPrunePreviewGroup] {
        let plan = store.prunePlan
        return [
            DockerPrunePreviewGroup(title: "Containers",
                                    items: plan.stoppedContainers.map { "\($0.name) · \($0.state.label)" }),
            DockerPrunePreviewGroup(title: "Images · dangling",
                                    items: plan.danglingImages.map { "\($0.primaryTag) · \(DockerFormatting.spacedSize($0.size))" }),
            DockerPrunePreviewGroup(title: "Volumes · anonymous",
                                    items: plan.unusedVolumes.filter(\.isAnonymous).map(\.name)),
            DockerPrunePreviewGroup(title: "Networks",
                                    items: plan.unusedNetworks.map(\.name),
                                    note: "Same eligible networks as Prune all."),
            DockerPrunePreviewGroup(title: "Build cache · dangling",
                                    items: [],
                                    note: "Docker selects dangling cache records at execution; this inventory cannot identify that exact subset.")
        ]
    }

    private var allPruneResources: [DockerPrunePreviewGroup] {
        let plan = store.prunePlan
        let cacheItems = plan.buildCache.items.filter { $0.inUse == false }
        return [
            DockerPrunePreviewGroup(title: "Containers",
                                    items: plan.stoppedContainers.map { "\($0.name) · \($0.state.label)" },
                                    note: "Same stopped containers as Prune."),
            DockerPrunePreviewGroup(title: "Images · unused",
                                    items: plan.unusedImages.map { "\($0.primaryTag) · \(DockerFormatting.spacedSize($0.size))" }),
            DockerPrunePreviewGroup(title: "Volumes · unused",
                                    items: plan.unusedVolumes.map { volume in
                                        "\(volume.name) · \(volume.isAnonymous ? "anonymous" : "named")"
                                    }),
            DockerPrunePreviewGroup(title: "Networks",
                                    items: plan.unusedNetworks.map(\.name),
                                    note: "Same eligible networks as Prune."),
            DockerPrunePreviewGroup(title: "Build cache · unused",
                                    items: cacheItems.map { "\($0.name) · \(DockerFormatting.spacedSize($0.size))" })
        ]
    }

    private func pruneScope(title: String,
                            estimate: String,
                            accent: Color,
                            resources: [DockerPrunePreviewGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer(minLength: 6)
                Text(estimate)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(store.theme.subtext)
            }
            ForEach(resources) { resource in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(resource.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(store.theme.text)
                        Spacer()
                        Text("\(resource.items.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(accent)
                    }
                    if let note = resource.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(store.theme.subtext)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if resource.items.isEmpty {
                        if resource.note == nil {
                            Text("None").font(.caption).foregroundStyle(store.theme.subtext)
                        }
                    } else {
                        ForEach(resource.items, id: \.self) { item in
                            Text(item)
                                .font(.caption.monospaced())
                                .foregroundStyle(store.theme.subtext)
                                .lineLimit(1)
                                .help(item)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(store.theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.3))
                }
            }
        }
        .padding(12)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.22))
        }
    }
}

struct DockerCleanupCard: View {
    @Bindable var store: DockerStore
    let mode: DockerPruneMode
    let category: DockerDiskUsageCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: mode.icon)
                    .foregroundStyle(store.theme.accent)
                Text(category.title.isEmpty ? mode.title : category.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Text("\(category.total) items · \(category.active) in use")
                .font(.callout)
                .foregroundStyle(store.theme.subtext)
            HStack {
                Text(category.size)
                    .font(.title2.monospacedDigit())
                Spacer()
                Text("reclaim \(category.reclaimable)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Button("Prune") { store.prune(mode, all: false) }
                    .buttonStyle(.bordered)
                Button("Prune all", role: .destructive) {
                    store.prune(mode, all: true)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(store.theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(store.theme.border.opacity(0.5))
        }
    }
}

private extension DockerPruneMode {
    var icon: String {
        switch self {
        case .basic, .all: return "trash"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .buildCache: return "hammer"
        }
    }
}

struct DockerDetailPane: View {
    @Bindable var store: DockerStore

    var body: some View {
        Group {
            switch store.section {
            case .containers:
                if let container = store.selectedContainer {
                    DockerContainerDetailView(store: store, container: container)
                } else {
                    placeholder("Select a container", icon: "shippingbox")
                }
            case .images:
                if let image = store.selectedImage {
                    DockerImageDetailView(store: store, image: image)
                } else {
                    placeholder("Select an image", icon: "square.stack.3d.up")
                }
            case .volumes:
                if let volume = store.selectedVolume {
                    DockerVolumeDetailView(store: store, volume: volume)
                } else {
                    placeholder("Select a volume", icon: "externaldrive")
                }
            case .networks:
                if let network = store.selectedNetwork {
                    DockerNetworkDetailView(store: store, network: network)
                } else {
                    placeholder("Select a network", icon: "network")
                }
            case .cleanup:
                DockerCleanupDetailView(store: store)
            }
        }
        .background(store.theme.background)
    }

    private func placeholder(_ title: String, icon: String) -> some View {
        DockerEmptyView(icon: icon, title: title,
                        detail: "Choose an item in the list to see its details.")
    }
}

struct DockerImageDetailView: View {
    @Bindable var store: DockerStore
    let image: DockerImage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader(title: image.primaryTag,
                             subtitle: image.shortID,
                             icon: "square.stack.3d.up")
                DockerKeyValue(items: [
                    ("Repository", image.primaryTag),
                    ("Image ID", image.id),
                    ("Size", DockerFormatting.spacedSize(image.size)),
                    ("Unique size", DockerFormatting.spacedSize(image.uniqueSize ?? "—")),
                    ("Created", image.createdAt),
                    ("Containers", "\(image.containers)"),
                    ("Dangling", image.isDangling ? "yes" : "no"),
                ], store: store)
                if image.repoTags.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags").font(.callout).foregroundStyle(store.theme.subtext)
                        ForEach(image.repoTags, id: \.self) { tag in
                            Text(tag).font(.callout.monospaced())
                        }
                    }
                }
                HStack {
                    Button("Remove image", role: .destructive) { store.removeImage(image) }
                    Button("Copy ID") { store.copyToPasteboard(image.id) }
                }
            }
            .padding(16)
        }
    }
}

struct DockerVolumeDetailView: View {
    @Bindable var store: DockerStore
    let volume: DockerVolume

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader(title: volume.name,
                             subtitle: volume.driver,
                             icon: "externaldrive")
                DockerKeyValue(items: [
                    ("Name", volume.name),
                    ("Driver", volume.driver),
                    ("Scope", volume.scope),
                    ("Size", DockerFormatting.spacedSize(volume.size ?? "—")),
                    ("In use", volume.isUsed ? "yes" : "no"),
                    ("Compose project", volume.composeProject ?? "—"),
                    ("Mountpoint", volume.mountpoint),
                ], store: store)
                HStack {
                    Button("Remove volume", role: .destructive) { store.removeVolume(volume) }
                        .disabled(volume.isUsed)
                    Button("Copy name") { store.copyToPasteboard(volume.name) }
                }
            }
            .padding(16)
        }
    }
}

struct DockerNetworkDetailView: View {
    @Bindable var store: DockerStore
    let network: DockerNetwork

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader(title: network.name,
                             subtitle: network.driver,
                             icon: "network")
                DockerKeyValue(items: [
                    ("Name", network.name),
                    ("ID", network.id),
                    ("Driver", network.driver),
                    ("Scope", network.scope),
                    ("Subnet", network.subnet ?? "—"),
                    ("Gateway", network.gateway ?? "—"),
                    ("Internal", network.internalNetwork ? "yes" : "no"),
                    ("Compose project", network.composeProject ?? "—"),
                    ("Containers", "\(network.containers.count)"),
                ], store: store)
                if network.containers.isEmpty == false {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Connected containers")
                            .font(.callout)
                            .foregroundStyle(store.theme.subtext)
                        ForEach(network.containers) { container in
                            HStack {
                                Text(container.name).font(.callout)
                                Spacer()
                                Text(container.ipv4 ?? "—")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(store.theme.subtext)
                                Button("Disconnect") {
                                    store.disconnectContainer(container, from: network)
                                }
                                .buttonStyle(.borderless)
                                .disabled(network.name == "host" || network.name == "none")
                            }
                        }
                    }
                }
                HStack {
                    Button("Remove network", role: .destructive) { store.removeNetwork(network) }
                        .disabled(network.isUsed || network.isBuiltIn)
                    Button("Copy ID") { store.copyToPasteboard(network.id) }
                }
            }
            .padding(16)
        }
    }
}

struct DockerCleanupDetailView: View {
    @Bindable var store: DockerStore

    var body: some View {
        DockerCleanupPreviewView(store: store)
    }
}

@ViewBuilder
func detailHeader(title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .font(.title)
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct DockerKeyValue: View {
    let items: [(String, String)]
    let store: DockerStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Text(entry.element.0)
                        .font(.callout)
                        .foregroundStyle(store.theme.subtext)
                        .frame(width: 132, alignment: .leading)
                    Text(entry.element.1)
                        .font(.callout)
                        .foregroundStyle(store.theme.text)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                Divider().overlay(store.theme.border.opacity(0.4))
            }
        }
    }
}
