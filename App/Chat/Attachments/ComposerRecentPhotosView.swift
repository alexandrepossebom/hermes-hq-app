import SwiftUI
@preconcurrency import PhotosUI

/// An out-of-process, single-row Photos picker. Only selected item providers leave the picker;
/// embedding it does not require Photos library authorization.
struct ComposerRecentPhotosView: UIViewControllerRepresentable {
    let onSelect: (NSItemProvider) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // Specifying the library supplies identifiers for tracking selection changes, without
        // requesting library access or fetching assets ourselves.
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.mode = .compact
        configuration.selection = .continuousAndOrdered
        configuration.selectionLimit = 0
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        configuration.edgesWithoutContentMargins = .all
        configuration.disabledCapabilities = [.search, .collectionNavigation, .stagingArea, .selectionActions]
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.onSelect = onSelect
    }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onSelect: (NSItemProvider) -> Void
        private var selectedIdentifiers: Set<String> = []

        init(onSelect: @escaping (NSItemProvider) -> Void) {
            self.onSelect = onSelect
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Continuous callbacks contain the whole selection, not just the latest tap.
            // Remember identifiers so unchanged items are not imported again; removing and
            // reselecting an item is a new selection.
            let previous = selectedIdentifiers
            selectedIdentifiers = Set(results.compactMap(\.assetIdentifier))
            for result in results {
                guard let identifier = result.assetIdentifier, !previous.contains(identifier) else { continue }
                onSelect(result.itemProvider)
            }
        }
    }
}
