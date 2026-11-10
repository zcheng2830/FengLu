import AppKit
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openURLsHandler: (([URL]) -> Void)?
    private var addToPlaylistHandler: (([URL]) -> Void)?
    private var willTerminateHandler: (() -> Void)?
    private var pendingOpenURLs: [URL] = []
    private var pendingPlaylistURLs: [URL] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appleEventManagerWillProcessFirstEvent(_:)),
            name: .NSAppleEventManagerWillProcessFirstEvent,
            object: nil
        )
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installOpenDocumentsAppleEventHandler()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        DebugLog.log("Registered Finder service provider")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.log("Application will terminate; stopping playback")
        willTerminateHandler?()
        NotificationCenter.default.removeObserver(self)
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc
    private func appleEventManagerWillProcessFirstEvent(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: .NSAppleEventManagerWillProcessFirstEvent,
            object: nil
        )
        installOpenDocumentsAppleEventHandler()
    }

    private func installOpenDocumentsAppleEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        DebugLog.log("Installed batched open-documents Apple event handler")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("Application did finish launching")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.log("Activation policy set to regular; app activated")
    }

    func configureOpenURLsHandler(_ handler: @escaping ([URL]) -> Void) {
        openURLsHandler = handler
        guard !pendingOpenURLs.isEmpty else {
            return
        }

        let urls = pendingOpenURLs
        pendingOpenURLs = []
        handleOpenURLs(urls)
    }

    func configureAddToPlaylistHandler(_ handler: @escaping ([URL]) -> Void) {
        addToPlaylistHandler = handler
        guard !pendingPlaylistURLs.isEmpty else {
            return
        }

        let urls = pendingPlaylistURLs
        pendingPlaylistURLs = []
        handleAddToPlaylist(urls)
    }

    func configureWillTerminateHandler(_ handler: @escaping () -> Void) {
        willTerminateHandler = handler
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc(addToPlaylist:userData:error:)
    func addToPlaylist(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        guard !urls.isEmpty else {
            error.pointee = "No files were provided to Fenglu Player." as NSString
            DebugLog.log("Add-to-playlist service received no file URLs")
            return
        }

        DebugLog.log("Add-to-playlist service received \(urls.count) URL(s)")
        handleAddToPlaylist(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        DebugLog.log("AppDelegate received one openFiles batch with \(filenames.count) path(s)")
        handleOpenURLs(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    @objc
    private func handleOpenDocumentsAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let directObject = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            DebugLog.log("Open-documents Apple event had no direct object")
            return
        }

        let urls = fileURLs(from: directObject)
        DebugLog.log("AppDelegate received one Apple event with \(urls.count) document(s)")
        handleOpenURLs(urls)
    }

    private func handleOpenURLs(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else {
            return
        }

        DebugLog.log("AppDelegate received \(fileURLs.count) file-open URL(s)")
        guard let openURLsHandler else {
            pendingOpenURLs.append(contentsOf: fileURLs)
            DebugLog.log("Queued file-open URL(s) until main window is ready")
            return
        }

        openURLsHandler(fileURLs)
    }

    private func handleAddToPlaylist(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !fileURLs.isEmpty else {
            return
        }

        guard let addToPlaylistHandler else {
            pendingPlaylistURLs.append(contentsOf: fileURLs)
            DebugLog.log("Queued add-to-playlist URL(s) until main window is ready")
            return
        }

        addToPlaylistHandler(fileURLs)
    }

    private func fileURLs(from descriptor: NSAppleEventDescriptor) -> [URL] {
        guard descriptor.descriptorType == DescType(typeAEList) else {
            return fileURL(from: descriptor).map { [$0] } ?? []
        }

        let itemCount = descriptor.numberOfItems
        guard itemCount > 0 else {
            return []
        }

        return (1...itemCount).compactMap { index in
            descriptor.atIndex(index).flatMap(fileURL(from:))
        }
    }

    private func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        if let url = descriptor.fileURLValue, url.isFileURL {
            return url.standardizedFileURL
        }

        if descriptor.descriptorType == DescType(typeBookmarkData) {
            let bookmarkData = descriptor.data
            var isStale = false
            return try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }

        return nil
    }
}
