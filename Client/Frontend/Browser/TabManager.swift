/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Storage
import Shared
import XCGLogger
import Data
import CoreData

private let log = Logger.browserLogger

protocol TabManagerDelegate: class {
    func tabManager(_ tabManager: TabManager, didSelectedTabChange selected: Tab?, previous: Tab?)
    func tabManager(_ tabManager: TabManager, willAddTab tab: Tab)
    func tabManager(_ tabManager: TabManager, didAddTab tab: Tab)
    func tabManager(_ tabManager: TabManager, willRemoveTab tab: Tab)
    func tabManager(_ tabManager: TabManager, didRemoveTab tab: Tab)

    func tabManagerDidRestoreTabs(_ tabManager: TabManager)
    func tabManagerDidAddTabs(_ tabManager: TabManager)
    func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?)
}

protocol TabManagerStateDelegate: class {
    func tabManagerWillStoreTabs(_ tabs: [Tab])
}

// We can't use a WeakList here because this is a protocol.
class WeakTabManagerDelegate {
    weak var value: TabManagerDelegate?

    init (value: TabManagerDelegate) {
        self.value = value
    }

    func get() -> TabManagerDelegate? {
        return value
    }
}

// TabManager must extend NSObjectProtocol in order to implement WKNavigationDelegate
class TabManager: NSObject {
    fileprivate var delegates = [WeakTabManagerDelegate]()
    fileprivate let tabEventHandlers: [TabEventHandler]
    weak var stateDelegate: TabManagerStateDelegate?

    func addDelegate(_ delegate: TabManagerDelegate) {
        assert(Thread.isMainThread)
        delegates.append(WeakTabManagerDelegate(value: delegate))
    }

    func removeDelegate(_ delegate: TabManagerDelegate) {
        assert(Thread.isMainThread)
        for i in 0 ..< delegates.count {
            let del = delegates[i]
            if delegate === del.get() || del.get() == nil {
                delegates.remove(at: i)
                return
            }
        }
    }

    fileprivate(set) var tabs = [Tab]()
    fileprivate var _selectedIndex = -1
    fileprivate let navDelegate: TabManagerNavDelegate
    fileprivate(set) var isRestoring = false

    // A WKWebViewConfiguration used for normal tabs
    lazy fileprivate var configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !(self.prefs.boolForKey("blockPopups") ?? true)
        return configuration
    }()

    // A WKWebViewConfiguration used for private mode tabs
    lazy fileprivate var privateConfiguration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !(self.prefs.boolForKey("blockPopups") ?? true)
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        return configuration
    }()

    fileprivate let imageStore: DiskImageStore?

    fileprivate let prefs: Prefs
    var selectedIndex: Int { return _selectedIndex }
    var tempTabs: [Tab]?

    var normalTabs: [Tab] {
        assert(Thread.isMainThread)

        return tabs.filter { !$0.isPrivate }
    }

    var privateTabs: [Tab] {
        assert(Thread.isMainThread)
        return tabs.filter { $0.isPrivate }
    }

    init(prefs: Prefs, imageStore: DiskImageStore?) {
        assert(Thread.isMainThread)

        self.prefs = prefs
        self.navDelegate = TabManagerNavDelegate()
        self.imageStore = imageStore
        self.tabEventHandlers = TabEventHandlers.create(with: prefs)
        super.init()

        addNavigationDelegate(self)

        NotificationCenter.default.addObserver(self, selector: #selector(prefsDidChange), name: UserDefaults.didChangeNotification, object: nil)
    }

    func addNavigationDelegate(_ delegate: WKNavigationDelegate) {
        assert(Thread.isMainThread)

        self.navDelegate.insert(delegate)
    }

    var count: Int {
        assert(Thread.isMainThread)

        return tabs.count
    }

    var selectedTab: Tab? {
        assert(Thread.isMainThread)
        if !(0..<count ~= _selectedIndex) {
            return nil
        }

        return tabs[_selectedIndex]
    }

    subscript(index: Int) -> Tab? {
        assert(Thread.isMainThread)

        if index >= tabs.count {
            return nil
        }
        return tabs[index]
    }

    subscript(webView: WKWebView) -> Tab? {
        assert(Thread.isMainThread)

        for tab in tabs where tab.webView === webView {
            return tab
        }

        return nil
    }
    
    var currentDisplayedIndex: Int? {
        assert(Thread.isMainThread)
        
        guard let selectedTab = self.selectedTab else {
            return nil
        }
        
        return displayedTabsForCurrentPrivateMode.index(of: selectedTab)
    }
    
    // What the users sees displayed based on current private browsing mode
    var displayedTabsForCurrentPrivateMode: [Tab] {
        return UIApplication.isInPrivateMode ? privateTabs : normalTabs
    }

    func getTabFor(_ url: URL) -> Tab? {
        assert(Thread.isMainThread)

        for tab in tabs {
            if tab.webView?.url == url {
                return tab
            }

            // Also look for tabs that haven't been restored yet.
            if let sessionData = tab.sessionData,
                0..<sessionData.urls.count ~= sessionData.currentPage,
                sessionData.urls[sessionData.currentPage] == url {
                return tab
            }
        }

        return nil
    }

    func selectTab(_ tab: Tab?, previous: Tab? = nil) {
        assert(Thread.isMainThread)
        let previous = previous ?? selectedTab

        if previous === tab {
            return
        }

        // Make sure to wipe the private tabs if the user has the pref turned on
        if shouldClearPrivateTabs(), !(tab?.isPrivate ?? false) {
            removeAllPrivateTabs()
        }

        if let tab = tab {
            _selectedIndex = tabs.index(of: tab) ?? -1
        } else {
            _selectedIndex = -1
        }

        preserveScreenshots()
        
        if let t = selectedTab, t.webView == nil {
            selectedTab?.createWebview()
            restoreTab(t)
        }

        assert(tab === selectedTab, "Expected tab is selected")
        selectedTab?.createWebview()
        selectedTab?.lastExecutedTime = Date.now()

        delegates.forEach { $0.get()?.tabManager(self, didSelectedTabChange: tab, previous: previous) }
        if let tab = previous {
            TabEvent.post(.didLoseFocus, for: tab)
        }
        if let tab = selectedTab {
            TabEvent.post(.didGainFocus, for: tab)
            UITextField.appearance().keyboardAppearance = tab.isPrivate ? .dark : .light
        }
    }

    func shouldClearPrivateTabs() -> Bool {
        return prefs.boolForKey("settings.closePrivateTabs") ?? false
    }

    //Called by other classes to signal that they are entering/exiting private mode
    //This is called by TabTrayVC when the private mode button is pressed and BEFORE we've switched to the new mode
    //we only want to remove all private tabs when leaving PBM and not when entering.
    func willSwitchTabMode(leavingPBM: Bool) {
        if shouldClearPrivateTabs() && leavingPBM {
            removeAllPrivateTabs()
        }
    }

    func expireSnackbars() {
        assert(Thread.isMainThread)

        for tab in tabs {
            tab.expireSnackbars()
        }
    }

    func addPopupForParentTab(_ parentTab: Tab, configuration: WKWebViewConfiguration) -> Tab {
        let popup = Tab(configuration: configuration, isPrivate: parentTab.isPrivate)
        configureTab(popup, request: nil, afterTab: parentTab, flushToDisk: true, zombie: false, isPopup: true)

        // Wait momentarily before selecting the new tab, otherwise the parent tab
        // may be unable to set `window.location` on the popup immediately after
        // calling `window.open("")`.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.selectTab(popup)
        }

        return popup
    }
    
    @discardableResult func addTab(_ request: URLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil, isPrivate: Bool) -> Tab {
        return self.addTab(request, configuration: configuration, afterTab: afterTab, flushToDisk: true, zombie: false, isPrivate: isPrivate)
    }

    @discardableResult func addTabAndSelect(_ request: URLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil, isPrivate: Bool) -> Tab {
        let tab = addTab(request, configuration: configuration, afterTab: afterTab, isPrivate: isPrivate)
        selectTab(tab)
        return tab
    }

    @discardableResult func addTabAndSelect(_ request: URLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil) -> Tab {
        let tab = addTab(request, configuration: configuration, afterTab: afterTab)
        selectTab(tab)
        return tab
    }

    // This method is duplicated to hide the flushToDisk option from consumers.
    @discardableResult func addTab(_ request: URLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil) -> Tab {
        return self.addTab(request, configuration: configuration, afterTab: afterTab, flushToDisk: true, zombie: false)
    }

    func addTabsForURLs(_ urls: [URL], zombie: Bool, isPrivate: Bool = false) {
        assert(Thread.isMainThread)

        if urls.isEmpty {
            return
        }
        // When bulk adding tabs don't notify delegates until we are done
        self.isRestoring = true
        var tab: Tab!
        for url in urls {
            tab = self.addTab(URLRequest(url: url), flushToDisk: false, zombie: zombie, isPrivate: isPrivate)
        }
        // Select the most recent.
        self.selectTab(tab)
        self.isRestoring = false
        // Okay now notify that we bulk-loaded so we can adjust counts and animate changes.
        delegates.forEach { $0.get()?.tabManagerDidAddTabs(self) }
    }

    fileprivate func addTab(_ request: URLRequest? = nil, configuration: WKWebViewConfiguration? = nil, afterTab: Tab? = nil, flushToDisk: Bool, zombie: Bool, id: String? = nil, isPrivate: Bool) -> Tab {
        assert(Thread.isMainThread)

        // Take the given configuration. Or if it was nil, take our default configuration for the current browsing mode.
        let configuration: WKWebViewConfiguration = configuration ?? (isPrivate ? privateConfiguration : self.configuration)

        let tab = Tab(configuration: configuration, isPrivate: isPrivate)
        if !isPrivate {
            tab.id = id ?? TabMO.create().syncUUID
        }
        configureTab(tab, request: request, afterTab: afterTab, flushToDisk: flushToDisk, zombie: zombie, isPrivate: isPrivate)
        return tab
    }

    fileprivate func addTab(_ request: URLRequest? = nil, configuration: WKWebViewConfiguration? = nil, afterTab: Tab? = nil, flushToDisk: Bool, zombie: Bool) -> Tab {
        assert(Thread.isMainThread)

        let tab = Tab(configuration: configuration ?? self.configuration)
        tab.id = TabMO.create().syncUUID
        
        configureTab(tab, request: request, afterTab: afterTab, flushToDisk: flushToDisk, zombie: zombie)
        return tab
    }
    
    func moveTab(isPrivate privateMode: Bool, fromIndex visibleFromIndex: Int, toIndex visibleToIndex: Int) {
        assert(Thread.isMainThread)

        let currentTabs = privateMode ? privateTabs : normalTabs

        guard visibleFromIndex < currentTabs.count, visibleToIndex < currentTabs.count else {
            return
        }

        let previouslySelectedTab = selectedTab

        tabs.insert(tabs.remove(at: visibleFromIndex), at: visibleToIndex)

        if let previouslySelectedTab = previouslySelectedTab, let previousSelectedIndex = tabs.index(of: previouslySelectedTab) {
            _selectedIndex = previousSelectedIndex
        }

        saveTabOrder()
    }
    
    private func saveTabOrder() {
        let context = DataController.shared.workerContext
        context.perform {
            for (i, tab) in self.tabs.enumerated() {
                guard let managedObject = TabMO.get(fromId: tab.id, context: context) else { 
                    log.error("Error: Tab missing managed object")
                    continue
                }
                managedObject.order = Int16(i)
            }
            
            DataController.saveContext(context: context)
        }
    }

    func configureTab(_ tab: Tab, request: URLRequest?, afterTab parent: Tab? = nil, flushToDisk: Bool, zombie: Bool, isPopup: Bool = false, isPrivate: Bool = false) {
        assert(Thread.isMainThread)

        delegates.forEach { $0.get()?.tabManager(self, willAddTab: tab) }

        if parent == nil || parent?.isPrivate != tab.isPrivate {
            tabs.append(tab)
        } else if let parent = parent, var insertIndex = tabs.index(of: parent) {
            insertIndex += 1
            while insertIndex < tabs.count && tabs[insertIndex].isDescendentOf(parent) {
                insertIndex += 1
            }
            tab.parent = parent
            tabs.insert(tab, at: insertIndex)
        }

        delegates.forEach { $0.get()?.tabManager(self, didAddTab: tab) }

        if !zombie {
            tab.createWebview()
        }
        tab.navigationDelegate = self.navDelegate

        if let request = request {
            tab.loadRequest(request)
        } else if !isPopup {
            let newTabChoice = NewTabAccessors.getNewTabPage(prefs)
            switch newTabChoice {
            case .homePage:
                // We definitely have a homepage if we've got here
                // (so we can safely dereference it).
                let url = HomePageAccessors.getHomePage(prefs)!
                tab.loadRequest(URLRequest(url: url))
            case .blankPage:
                // Do nothing: we're already seeing a blank page.
                break
            default:
                // The common case, where the NewTabPage enum defines
                // one of the about:home pages.
                if let url = newTabChoice.url {
                    tab.loadRequest(PrivilegedRequest(url: url) as URLRequest)
                    tab.url = url
                }
            }
        }
        
        // Ignore on restore.
        if flushToDisk && !zombie && !isPrivate {
            saveTab(tab, saveOrder: true)
        }

    }
    
    func indexOfWebView(_ webView: WKWebView) -> UInt? {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        
        var count = UInt(0)
        for tab in tabs {
            if tab.webView === webView {
                return count
            }
            count = count + 1
        }
        
        return nil
    }
    
    func saveTab(_ tab: Tab, saveOrder: Bool = false) {
        guard let data = savedTabData(tab: tab) else { return }
        
        TabMO.preserve(savedTab: data)
        if saveOrder {
            saveTabOrder()
        }
    }
    
    func savedTabData(tab: Tab) -> SavedTab? {
        
        guard let webView = tab.webView, let order = indexOfWebView(webView) else { return nil }
        
        let context = DataController.shared.mainThreadContext
        
        // Ignore session restore data.
        guard let urlString = tab.url?.absoluteString, !urlString.contains("localhost") else { return nil }
        
        var urls = [String]()
        var currentPage = 0
        
        if let currentItem = webView.backForwardList.currentItem {
            // Freshly created web views won't have any history entries at all.
            let backList = webView.backForwardList.backList
            let forwardList = webView.backForwardList.forwardList
            let backListMap = backList.map { $0.url.absoluteString }
            let forwardListMap = forwardList.map { $0.url.absoluteString }
            let currentItemString = currentItem.url.absoluteString
            
            log.debug("backList: \(backListMap)")
            log.debug("forwardList: \(forwardListMap)")
            log.debug("currentItem: \(currentItemString)")
            
            // Business as usual.
            urls = backListMap + [currentItemString] + forwardListMap
            currentPage = -forwardList.count
            
            log.debug("---stack: \(urls)")
        }
        if let id = TabMO.get(fromId: tab.id, context: context)?.syncUUID {
            let displayTitle = tab.displayTitle
            let title = displayTitle != "" ? displayTitle : ""
            
            let isSelected = selectedTab === tab
            
            let data = SavedTab(id: id, title: title, url: urlString, isSelected: isSelected, order: Int16(order), 
                                screenshot: nil, history: urls, historyIndex: Int16(currentPage))
            return data
        }
        
        return nil
    }

    func removeTab(_ tab: Tab) {
        assert(Thread.isMainThread)
        
        hideNetworkActivitySpinner()

        guard let removalIndex = tabs.index(where: { $0 === tab }) else {
            log.debug("Could not find index of tab to remove")
            return
        }

        if tab.isPrivate {
            removeAllBrowsingDataForTab(tab)
        }

        let oldSelectedTab = selectedTab

        delegates.forEach { $0.get()?.tabManager(self, willRemoveTab: tab) }

        // The index of the tab in its respective tab grouping. Used to figure out which tab is next
        var tabIndex: Int = -1
        if let oldTab = oldSelectedTab {
            tabIndex = (tab.isPrivate ? privateTabs.index(of: oldTab) : normalTabs.index(of: oldTab)) ?? -1
        }

        let prevCount = count
        tabs.remove(at: removalIndex)
        
        let context = DataController.shared.mainThreadContext
        if let tab = TabMO.get(fromId: tab.id, context: context) {
            DataController.remove(object: tab, context: context)
        }

        let viableTabs: [Tab] = tab.isPrivate ? privateTabs : normalTabs

        // Let's select the tab to be selected next.
        if let oldTab = oldSelectedTab, tab !== oldTab {
            // If it wasn't the selected tab we removed, then keep it like that.
            // It might have changed index, so we look it up again.
            _selectedIndex = tabs.index(of: oldTab) ?? -1
        } else if let parentTab = tab.parent,
            let newTab = viableTabs.reduce(viableTabs.first, { currentBestTab, tab2 in
            if let tab1 = currentBestTab, let time1 = tab1.lastExecutedTime {
                if let time2 = tab2.lastExecutedTime {
                    return time1 <= time2 ? tab2 : tab1
                }
                return tab1
            } else {
                return tab2
            }
        }), parentTab == newTab, tab !== newTab, newTab.lastExecutedTime != nil {
            // We select the most recently visited tab, only if it is also the parent tab of the closed tab.
            _selectedIndex = tabs.index(of: newTab) ?? -1
        } else {
            // By now, we've just removed the selected one, and no previously loaded
            // tabs. So let's load the final one in the tab tray.
            if tabIndex == viableTabs.count {
                tabIndex -= 1
            }

            if let currentTab = viableTabs[safe: tabIndex] {
                _selectedIndex = tabs.index(of: currentTab) ?? -1
            } else {
                _selectedIndex = -1
            }
        }

        assert(count == prevCount - 1, "Make sure the tab count was actually removed")

        // There's still some time between this and the webView being destroyed. We don't want to pick up any stray events.
        tab.webView?.navigationDelegate = nil

        delegates.forEach { $0.get()?.tabManager(self, didRemoveTab: tab) }
        TabEvent.post(.didClose, for: tab)

        if !tab.isPrivate && viableTabs.isEmpty {
            addTab()
        }

        // If the removed tab was selected, find the new tab to select.
        if selectedTab != nil {
            selectTab(selectedTab, previous: oldSelectedTab)
        } else {
            selectTab(tabs.last, previous: oldSelectedTab)
        }
    }

    /// Removes all private tabs from the manager without notifying delegates.
    private func removeAllPrivateTabs() {
        // reset the selectedTabIndex if we are on a private tab because we will be removing it.
        if selectedTab?.isPrivate ?? false {
            _selectedIndex = -1
        }
        tabs.forEach { tab in
            if tab.isPrivate {
                tab.webView?.removeFromSuperview()
                removeAllBrowsingDataForTab(tab)
            }
        }

        tabs = tabs.filter { !$0.isPrivate }
    }

    func removeAllBrowsingDataForTab(_ tab: Tab, completionHandler: @escaping () -> Void = {}) {
        let dataTypes = Set([WKWebsiteDataTypeCookies,
                             WKWebsiteDataTypeLocalStorage,
                             WKWebsiteDataTypeSessionStorage,
                             WKWebsiteDataTypeWebSQLDatabases,
                             WKWebsiteDataTypeIndexedDBDatabases])
        tab.webView?.configuration.websiteDataStore.removeData(ofTypes: dataTypes,
                                                               modifiedSince: Date.distantPast,
                                                               completionHandler: completionHandler)
    }

    func removeTabsWithUndoToast(_ tabs: [Tab]) {
        tempTabs = tabs
        var tabsCopy = tabs
        
        // Remove the current tab last to prevent switching tabs while removing tabs
        if let selectedTab = selectedTab {
            if let selectedIndex = tabsCopy.index(of: selectedTab) {
                let removed = tabsCopy.remove(at: selectedIndex)
                removeTabs(tabsCopy)
                removeTab(removed)
            } else {
                removeTabs(tabsCopy)
            }
        }
        for tab in tabs {
            tab.hideContent()
        }
        var toast: ButtonToast?
        if let numberOfTabs = tempTabs?.count, numberOfTabs > 0 {
            toast = ButtonToast(labelText: String.localizedStringWithFormat(Strings.TabsDeleteAllUndoTitle, numberOfTabs), buttonText: Strings.TabsDeleteAllUndoAction, completion: { buttonPressed in
                if buttonPressed {
                    self.undoCloseTabs()
                    for delegate in self.delegates {
                        delegate.get()?.tabManagerDidAddTabs(self)
                    }
                }
                self.eraseUndoCache()
            })
        }

        delegates.forEach { $0.get()?.tabManagerDidRemoveAllTabs(self, toast: toast) }
    }
    
    func undoCloseTabs() {
        guard let tempTabs = self.tempTabs, tempTabs.count > 0 else {
            return
        }
        let tabsCopy = normalTabs
        restoreTabs(tempTabs)
        self.isRestoring = true
        for tab in tempTabs {
            tab.showContent(true)
        }
        if !tempTabs[0].isPrivate {
            removeTabs(tabsCopy)
        }
        selectTab(tempTabs.first)
        self.isRestoring = false
        delegates.forEach { $0.get()?.tabManagerDidRestoreTabs(self) }
        self.tempTabs?.removeAll()
        tabs.first?.createWebview()
    }
    
    func eraseUndoCache() {
        tempTabs?.removeAll()
    }

    func removeTabs(_ tabs: [Tab]) {
        for tab in tabs {
            self.removeTab(tab)
        }
    }
    
    func removeAll() {
        removeTabs(self.tabs)
    }

    func getIndex(_ tab: Tab) -> Int? {
        assert(Thread.isMainThread)

        for i in 0..<count where tabs[i] === tab {
            return i
        }

        assertionFailure("Tab not in tabs list")
        return nil
    }

    func getTabForURL(_ url: URL) -> Tab? {
        assert(Thread.isMainThread)

        return tabs.filter { $0.webView?.url == url } .first
    }

    @objc func prefsDidChange() {
        DispatchQueue.main.async {
            let allowPopups = !(self.prefs.boolForKey("blockPopups") ?? true)
            // Each tab may have its own configuration, so we should tell each of them in turn.
            for tab in self.tabs {
                tab.webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            }
            // The default tab configurations also need to change.
            self.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            self.privateConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
        }
    }

    func resetProcessPool() {
        assert(Thread.isMainThread)

        configuration.processPool = WKProcessPool()
    }
}

extension TabManager {

    static fileprivate func tabsStateArchivePath() -> String {
        guard let profilePath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier)?.appendingPathComponent("profile.profile").path else {
            let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
            return URL(fileURLWithPath: documentsPath).appendingPathComponent("tabsState.archive").path
        }

        return URL(fileURLWithPath: profilePath).appendingPathComponent("tabsState.archive").path
    }

    static fileprivate func migrateTabsStateArchive() {
        guard let oldPath = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("tabsState.archive").path, FileManager.default.fileExists(atPath: oldPath) else {
            return
        }

        log.info("Migrating tabsState.archive from ~/Documents to shared container")

        guard let profilePath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier)?.appendingPathComponent("profile.profile").path else {
            log.error("Unable to get profile path in shared container to move tabsState.archive")
            return
        }

        let newPath = URL(fileURLWithPath: profilePath).appendingPathComponent("tabsState.archive").path

        do {
            try FileManager.default.createDirectory(atPath: profilePath, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)

            log.info("Migrated tabsState.archive to shared container successfully")
        } catch let error as NSError {
            log.error("Unable to move tabsState.archive to shared container: \(error.localizedDescription)")
        }
    }

    static func tabArchiveData() -> Data? {
        migrateTabsStateArchive()

        let tabStateArchivePath = tabsStateArchivePath()
        if FileManager.default.fileExists(atPath: tabStateArchivePath) {
            return (try? Data(contentsOf: URL(fileURLWithPath: tabStateArchivePath)))
        } else {
            return nil
        }
    }
    
    private func preserveScreenshots() {
        assert(Thread.isMainThread)
        if isRestoring { return }
        
        var savedUUIDs = Set<String>()
        
        for tab in tabs { 
            guard let screenshot = tab.screenshot, let screenshotUUID = tab.screenshotUUID  else { continue }
            savedUUIDs.insert(screenshotUUID.uuidString)
            imageStore?.put(screenshotUUID.uuidString, image: screenshot)
        }
        
        // Clean up any screenshots that are no longer associated with a tab.
        imageStore?.clearExcluding(savedUUIDs)
    }

    fileprivate func restoreTabsInternal() {
        let savedTabs = TabMO.getAll()
        if savedTabs.isEmpty { return }

        var tabToSelect: Tab?
        for savedTab in savedTabs {
            if savedTab.url == nil {
                DataController.remove(object: savedTab)
                continue
            }
            
            // Provide an empty request to prevent a new tab from loading the home screen
            let tab = self.addTab(nil, configuration: nil, afterTab: nil, flushToDisk: false, zombie: true, 
                                  id: savedTab.syncUUID, isPrivate: false)

            // Since this is a restored tab, reset the URL to be loaded as that will be handled by the SessionRestoreHandler
            tab.url = nil

            // BRAVE TODO: restore favicon
            /*
            if let faviconURL = savedTab.favicon.url {
                let icon = Favicon(url: faviconURL, date: Date())
                icon.width = 1
                tab.favicons.append(icon)
            }
             */

            
            // Set the UUID for the tab, asynchronously fetch the UIImage, then store
            // the screenshot in the tab as long as long as a newer one hasn't been taken.
            if let screenshotUUID = savedTab.screenshotUUID,
               let imageStore = self.imageStore {
                tab.screenshotUUID = screenshotUUID
                imageStore.get(screenshotUUID.uuidString) >>== { screenshot in
                    if tab.screenshotUUID == screenshotUUID {
                        tab.setScreenshot(screenshot, revUUID: false)
                    }
                }
            }

            if savedTab.isSelected {
                tabToSelect = tab
            }

            tab.lastTitle = savedTab.title
        }

        if tabToSelect == nil {
            tabToSelect = tabs.first
        }

        // Only tell our delegates that we restored tabs if we actually restored a tab(s)
        if savedTabs.count > 0 {
            for delegate in delegates {
                delegate.get()?.tabManagerDidRestoreTabs(self)
            }
        }

        if let tab = tabToSelect {
            // TODO: only selected tab has webView attached
            selectTab(tab)
            restoreTab(tab)
            tab.createWebview()
        }
    }
    
    func restoreTab(_ tab: Tab) {
        // Tab was created with no active webview or session data. Restore tab data from CD and configure.
        guard let savedTab = TabMO.get(fromId: tab.id, context: DataController.shared.mainThreadContext) else { return }
        
        if let history = savedTab.urlHistorySnapshot as? [String], let tabUUID = savedTab.syncUUID, let url = savedTab.url {
            let data = SavedTab(id: tabUUID, title: savedTab.title, url: url, isSelected: savedTab.isSelected, order: savedTab.order, screenshot: nil, history: history, historyIndex: savedTab.urlHistoryCurrentIndex)
            if let webView = tab.webView {
                tab.navigationDelegate = navDelegate
                tab.restore(webView, restorationData: data)
            }
        }
    }

    func restoreTabs() {
        isRestoring = true

        if count == 0 && !AppConstants.IsRunningTest && !DebugSettingsBundleOptions.skipSessionRestore {
            // This is wrapped in an Objective-C @try/@catch handler because NSKeyedUnarchiver may throw exceptions which Swift cannot handle
            _ = Try(
                withTry: { () -> Void in
                    self.restoreTabsInternal()
                },
                catch: { exception in
                    log.error("Failed to restore tabs: \(String(describing: exception))")
                }
            )
        }
        isRestoring = false

        // Always make sure there is a single normal tab.
        if normalTabs.isEmpty {
            let tab = addTab()
            if selectedTab == nil {
                selectTab(tab)
            }
        }
    }
    
    func restoreTabs(_ savedTabs: [Tab]) {
        isRestoring = true
        for tab in savedTabs {
            tabs.append(tab)
            tab.navigationDelegate = self.navDelegate
            for delegate in delegates {
                delegate.get()?.tabManager(self, didAddTab: tab)
            }
        }
        isRestoring = false
    }
}

extension TabManager: WKNavigationDelegate {

    // Note the main frame JSContext (i.e. document, window) is not available yet.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        UIApplication.shared.isNetworkActivityIndicatorVisible = true

        if #available(iOS 11, *), let tab = self[webView], let blocker = tab.contentBlocker as? ContentBlockerHelper {
            blocker.clearPageStats()
        }
    }

    // The main frame JSContext is available, and DOM parsing has begun.
    // Do not excute JS at this point that requires running prior to DOM parsing.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = self[webView] else { return }
        let isNightMode = NightModeAccessors.isNightMode(self.prefs)
        tab.setNightMode(isNightMode)

        if #available(iOS 11, *) {
            let isNoImageMode = self.prefs.boolForKey(PrefsKeys.KeyNoImageModeStatus) ?? false
            tab.noImageMode = isNoImageMode

            if let tpHelper = tab.contentBlocker as? ContentBlockerHelper, !tpHelper.isEnabled {
                webView.evaluateJavaScript("window.__firefox__.TrackingProtectionStats.setEnabled(false, \(UserScriptManager.securityToken))", completionHandler: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideNetworkActivitySpinner()
        // only store changes if this is not an error page
        // as we current handle tab restore as error page redirects then this ensures that we don't
        // call storeChanges unnecessarily on startup
        
        if let tab = tabForWebView(webView), !tab.isPrivate, let url = webView.url, !url.absoluteString.contains("localhost") {
            saveTab(tab)
        }
    }
    
    func tabForWebView(_ webView: WKWebView) -> Tab? {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        
        for tab in tabs {
            if tab.webView === webView {
                return tab
            }
        }
        
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hideNetworkActivitySpinner()
    }

    func hideNetworkActivitySpinner() {
        for tab in tabs {
            if let tabWebView = tab.webView {
                // If we find one tab loading, we don't hide the spinner
                if tabWebView.isLoading {
                    return
                }
            }
        }
        UIApplication.shared.isNetworkActivityIndicatorVisible = false
    }

    /// Called when the WKWebView's content process has gone away. If this happens for the currently selected tab
    /// then we immediately reload it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let tab = selectedTab, tab.webView == webView {
            webView.reload()
        }
    }
}

// WKNavigationDelegates must implement NSObjectProtocol
class TabManagerNavDelegate: NSObject, WKNavigationDelegate {
    fileprivate var delegates = WeakList<WKNavigationDelegate>()

    func insert(_ delegate: WKNavigationDelegate) {
        delegates.insert(delegate)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didCommit: navigation)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        for delegate in delegates {
            delegate.webView?(webView, didFail: navigation, withError: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            for delegate in delegates {
                delegate.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
            }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didFinish: navigation)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        for delegate in delegates {
            delegate.webViewWebContentProcessDidTerminate?(webView)
        }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let authenticatingDelegates = delegates.filter { wv in
                return wv.responds(to: #selector(webView(_:didReceive:completionHandler:)))
            }

            guard let firstAuthenticatingDelegate = authenticatingDelegates.first else {
                return completionHandler(.performDefaultHandling, nil)
            }

            firstAuthenticatingDelegate.webView?(webView, didReceive: challenge) { (disposition, credential) in
                completionHandler(disposition, credential)
            }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didStartProvisionalNavigation: navigation)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            var res = WKNavigationActionPolicy.allow
            for delegate in delegates {
                delegate.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: { policy in
                    if policy == .cancel {
                        res = policy
                    }
                })
            }

            decisionHandler(res)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        var res = WKNavigationResponsePolicy.allow
        for delegate in delegates {
            delegate.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: { policy in
                if policy == .cancel {
                    res = policy
                }
            })
        }

        if res == .allow, let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            let tab = appDelegate.browserViewController.tabManager[webView]
            tab?.mimeType = navigationResponse.response.mimeType
        }

        decisionHandler(res)
    }
}

// MARK: - TabManagerDelegate optional methods.
extension TabManagerDelegate {
    func tabManager(_ tabManager: TabManager, willAddTab tab: Tab) {}
    func tabManager(_ tabManager: TabManager, willRemoveTab tab: Tab) {}
    func tabManagerDidAddTabs(_ tabManager: TabManager) {}
    func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?) {}
}
