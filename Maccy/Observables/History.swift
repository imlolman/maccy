import AppKit.NSRunningApplication
import Defaults
import Foundation
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History { // swiftlint:disable:this type_body_length
  static let shared = History()

  // Pagination constants
  @ObservationIgnored @Default(.pageSize) private var pageSize
  private var currentOffset = 0
  var hasMoreItems = true
  private var allItemsCount = 0
  private var pinnedCount = 0

  // Track the min/max dates of loaded items to ensure we load different items each time
  private var oldestLoadedDate: Date?
  private var newestLoadedDate: Date?

  var items: [HistoryItemDecorator] = []
  var selectedItem: HistoryItemDecorator? {
    willSet {
      print("[History.selectedItem.willSet] Old: \(selectedItem?.id.uuidString ?? "nil"), New: \(newValue?.id.uuidString ?? "nil")")
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      print("[History.searchQuery.didSet] Search query changed to: '\(searchQuery)'")
      throttler.throttle { [self] in
        print("[History.searchQuery.didSet.throttle] Throttled search update starting")
        updateItems(search.search(string: searchQuery, within: all))

        if searchQuery.isEmpty {
          print("[History.searchQuery.didSet.throttle] Search query empty, selecting first unpinned item")
          AppState.shared.selection = unpinnedItems.first?.id
        } else {
          print("[History.searchQuery.didSet.throttle] Search query not empty, highlighting first item")
          AppState.shared.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
        print("[History.searchQuery.didSet.throttle] Throttled search update finished, set needsResize=true")
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items that are currently loaded in memory
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init() {
    print("[History] Entering init()")
    Task {
      print("[History.init.Task.pasteByDefault] Observing Defaults.updates(.pasteByDefault)")
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        print("[History.init.Task.pasteByDefault] pasteByDefault changed, updating shortcuts")
        updateShortcuts()
      }
    }

    Task {
      print("[History.init.Task.sortBy] Observing Defaults.updates(.sortBy)")
      for await _ in Defaults.updates(.sortBy, initial: false) {
        print("[History.init.Task.sortBy] sortBy changed, reloading history")
        try? await load()
      }
    }

    Task {
      print("[History.init.Task.pinTo] Observing Defaults.updates(.pinTo)")
      for await _ in Defaults.updates(.pinTo, initial: false) {
        print("[History.init.Task.pinTo] pinTo changed, reloading history")
        try? await load()
      }
    }
    
    Task {
      print("[History.init.Task.pageSize] Observing Defaults.updates(.pageSize)")
      for await newSize in Defaults.updates(.pageSize, initial: false) {
        print("[History.init.Task.pageSize] pageSize changed to \(newSize), reloading history")
        try? await load()
      }
    }

    Task {
      print("[History.init.Task.showSpecialSymbols] Observing Defaults.updates(.showSpecialSymbols)")
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        print("[History.init.Task.showSpecialSymbols] showSpecialSymbols changed, updating item titles")
        items.forEach { item in
          let title = item.item.generateTitle()
          item.title = title
          item.item.title = title
        }
        print("[History.init.Task.showSpecialSymbols] Finished updating item titles")
      }
    }

    Task {
      print("[History.init.Task.imageMaxHeight] Observing Defaults.updates(.imageMaxHeight)")
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        print("[History.init.Task.imageMaxHeight] imageMaxHeight changed, resizing images")
        for item in items {
          item.sizeImages()
        }
        print("[History.init.Task.imageMaxHeight] Finished resizing images")
      }
    }
    print("[History] Exiting init()")
  }

  @MainActor
  func load() async throws {
    print("[History] Entering load()")
    // Access pageSize directly from Defaults
    print("[History.load] Using pageSize from Defaults: \(Defaults[.pageSize])")

    // Count total items
    let countDescriptor = FetchDescriptor<HistoryItem>()
    allItemsCount = try Storage.shared.context.fetchCount(countDescriptor)
    print("[History.load] Found total items: \(allItemsCount)")
    
    // Count pinned items
    let pinnedDescriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin != nil })
    pinnedCount = try Storage.shared.context.fetchCount(pinnedDescriptor)
    print("[History.load] Found pinned items: \(pinnedCount)")
    
    hasMoreItems = true
    currentOffset = 0
    oldestLoadedDate = nil
    newestLoadedDate = nil
    print("[History.load] Reset pagination state: hasMoreItems=true, currentOffset=0, dates=nil")
    
    // First, fetch all pinned items
    print("[History.load] Fetching pinned items")
    let pinnedResults = try Storage.shared.context.fetch(pinnedDescriptor)
    print("[History.load] Fetched \(pinnedResults.count) pinned items")
    
    // Then fetch the most recent unpinned items
    print("[History.load] Fetching initial page of unpinned items (limit: \(Defaults[.pageSize]))")
    var unpinnedDescriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
    unpinnedDescriptor.sortBy = [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    unpinnedDescriptor.fetchLimit = Defaults[.pageSize]
    
    let unpinnedResults = try Storage.shared.context.fetch(unpinnedDescriptor)
    currentOffset = unpinnedResults.count
    print("[History.load] Fetched \(unpinnedResults.count) unpinned items, new offset: \(currentOffset)")
    
    // Track the date range of loaded items
    if let newest = unpinnedResults.first?.lastCopiedAt,
       let oldest = unpinnedResults.last?.lastCopiedAt {
        newestLoadedDate = newest
        oldestLoadedDate = oldest
        print("[History.load] Initial date range: newest=\(newest), oldest=\(oldest)")
    } else {
        print("[History.load] Could not determine initial date range (no unpinned items?)")
    }
    
    // Combine and sort all results
    let combinedResults = pinnedResults + unpinnedResults
    print("[History.load] Combined \(pinnedResults.count) pinned and \(unpinnedResults.count) unpinned. Total: \(combinedResults.count)")
    print("[History.load] Sorting combined results")
    all = sorter.sort(combinedResults).map { HistoryItemDecorator($0) }
    items = all
    print("[History.load] Sorted and updated 'all' and 'items' (\(all.count) items)")
    
    hasMoreItems = currentOffset < allItemsCount - pinnedCount
    print("[History.load] Updated hasMoreItems: \(hasMoreItems) (offset=\(currentOffset), unpinnedTotal=\(allItemsCount - pinnedCount))")
    
    print("[History.load] Updating shortcuts")
    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      print("[History.load.Task] Setting needsResize = true")
      AppState.shared.popup.needsResize = true
    }
    print("[History] Exiting load()")
  }
  
  @MainActor
  func loadMore() async throws {
    print("[History] Entering loadMore()")
    // Access pageSize directly from Defaults
    print("[History.loadMore] Using pageSize from Defaults: \(Defaults[.pageSize])")

    guard hasMoreItems && searchQuery.isEmpty else { 
      print("[History.loadMore] Guard failed: hasMoreItems=\(hasMoreItems), searchQuery=\(searchQuery.isEmpty ? "empty" : "not empty")")
      return 
    }
    
    print("[History.loadMore] Proceeding to load more: offset=\(currentOffset), allItemsCount=\(allItemsCount), pinnedCount=\(pinnedCount)")
    
    // Ensure we don't have too many items already loaded
    pruneOldItemsIfNeeded()
    
    // Fetch next page of unpinned items - try date-based filtering first
    var nextPageDescriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
    
    // Try date-based filtering if we have different dates in our data
    if let oldestDate = oldestLoadedDate {
        print("[History.loadMore] Using date-based filtering: lastCopiedAt < \(oldestDate)")
        nextPageDescriptor.predicate = #Predicate<HistoryItem> { 
            $0.pin == nil && $0.lastCopiedAt < oldestDate 
        }
    } else {
        print("[History.loadMore] No oldestLoadedDate, using basic pin==nil predicate")
    }
    
    nextPageDescriptor.sortBy = [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    nextPageDescriptor.fetchLimit = Defaults[.pageSize]
    
    print("[History.loadMore] Fetching next page (limit: \(Defaults[.pageSize])) using date filter (if applicable)")
    var nextPageResults = try Storage.shared.context.fetch(nextPageDescriptor)
    
    print("[History.loadMore] Date-based fetch returned \(nextPageResults.count) items")
    
    // If date-based filtering didn't work (returned 0 items), fall back to offset-based
    if nextPageResults.isEmpty && currentOffset < allItemsCount - pinnedCount {
        print("[History.loadMore] Date filtering returned 0. Falling back to offset-based pagination (offset: \(currentOffset))")
        var offsetDescriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
        offsetDescriptor.sortBy = [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        offsetDescriptor.fetchLimit = Defaults[.pageSize]
        offsetDescriptor.fetchOffset = currentOffset
        
        print("[History.loadMore] Fetching next page using offset filter")
        nextPageResults = try Storage.shared.context.fetch(offsetDescriptor)
        print("[History.loadMore] Offset-based fetch returned \(nextPageResults.count) items")
    }
    
    guard !nextPageResults.isEmpty else {
      hasMoreItems = false
      print("[History.loadMore] Guard failed: No more items found after fetching. Setting hasMoreItems=false")
      return
    }
    
    // Update current offset
    currentOffset += nextPageResults.count
    print("[History.loadMore] Updated offset to \(currentOffset)")
    
    // Update the oldest loaded date if we have different dates
    if let newOldest = nextPageResults.last?.lastCopiedAt {
        if oldestLoadedDate == nil || newOldest < oldestLoadedDate! {
             oldestLoadedDate = newOldest
             print("[History.loadMore] Updated oldest loaded date to \(newOldest)")
        } else {
             print("[History.loadMore] New oldest date (\(newOldest)) is not older than current oldest (\(oldestLoadedDate!))")
        }
    } else {
         print("[History.loadMore] Could not determine new oldest date from results")
    }
    
    // If we've loaded all unpinned items, set hasMoreItems to false
    if currentOffset >= allItemsCount - pinnedCount {
      hasMoreItems = false
      print("[History.loadMore] Reached the end (offset \(currentOffset) >= unpinned count \(allItemsCount - pinnedCount)). Setting hasMoreItems=false")
    } else {
       print("[History.loadMore] Still more items potentially available (offset \(currentOffset) < unpinned count \(allItemsCount - pinnedCount)). hasMoreItems=\(hasMoreItems)")
    }
    
    print("[History.loadMore] Successfully fetched \(nextPageResults.count) more items, new offset=\(currentOffset)")
    
    // Add new items to in-memory collection
    let newDecorators = nextPageResults.map { HistoryItemDecorator($0) }
    print("[History.loadMore] Appending \(newDecorators.count) new decorators to 'all' collection")
    all.append(contentsOf: newDecorators)
    
    // Re-sort all items
    print("[History.loadMore] Re-sorting 'all' collection based on pinTo setting ('\(Defaults[.pinTo])')")
    let pinnedItems = all.filter(\.isPinned)
    let unpinnedItems = all.filter(\.isUnpinned)
      .sorted(by: { $0.item.lastCopiedAt > $1.item.lastCopiedAt })
    
    // Combine based on pin position settings
    if Defaults[.pinTo] == .top {
      all = pinnedItems + unpinnedItems
    } else {
      all = unpinnedItems + pinnedItems
    }
    
    items = all
    print("[History.loadMore] Updated 'items' collection (\(items.count) total items)")
    print("[History.loadMore] Updating unpinned shortcuts")
    updateUnpinnedShortcuts()
    
    print("[History.loadMore] Finished adding \(nextPageResults.count) new entries. Total items: \(items.count)")
    
    Task {
      print("[History.loadMore.Task] Setting needsResize = true")
      AppState.shared.popup.needsResize = true
    }
    print("[History] Exiting loadMore()")
  }
  
  // Separate function to prune old items if we have too many loaded
  private func pruneOldItemsIfNeeded() {
    print("[History] Entering pruneOldItemsIfNeeded()")
    // IMPORTANT: We're disabling the pruning of older items during pagination
    // This was causing pagination to appear not to work because items were being removed
    // as new ones were loaded.
    // When a better memory management solution is needed, it should be implemented differently.
    
    // Original pruning code is commented out below:
    // /* // Remove this line to uncomment
    let currentUnpinnedItems = all.filter(\.isUnpinned)
    
    // Only prune if we have more than 2x pageSize items
    // Read pageSize directly from Defaults for this check
    let currentMaxAllowed = Defaults[.pageSize] * 2 
    print("[History.pruneOldItemsIfNeeded] Checking if \(currentUnpinnedItems.count) exceeds max allowed (\(currentMaxAllowed))")
    if currentUnpinnedItems.count > currentMaxAllowed {
      let extraItemsCount = currentUnpinnedItems.count - currentMaxAllowed
      
      if extraItemsCount > 0 {
        // Find oldest items to remove based on lastCopiedAt
        print("[History.pruneOldItemsIfNeeded] Need to prune \(extraItemsCount) items.")
        let oldestItems = currentUnpinnedItems
          .sorted(by: { $0.item.lastCopiedAt < $1.item.lastCopiedAt })
          .prefix(extraItemsCount)
        
        print("[History.pruneOldItemsIfNeeded] Pruning \(oldestItems.count) oldest items to maintain memory usage")
        
        // Remove these items from our in-memory collection
        let idsToRemove = Set(oldestItems.map { $0.id })
        all.removeAll(where: { item in
            idsToRemove.contains(item.id) && item.isUnpinned // Ensure we only remove unpinned items identified
        })
        print("[History.pruneOldItemsIfNeeded] Pruning complete. New 'all' count: \(all.count)")
      }
    }
    // */ // Remove this line to uncomment
    
    // Log how many items we have loaded
    let finalUnpinnedCount = all.filter(\.isUnpinned).count
    // print("[History.pruneOldItemsIfNeeded] Currently have \(finalUnpinnedCount) unpinned items loaded (Pruning disabled)") // Remove this line
    print("[History.pruneOldItemsIfNeeded] Currently have \(finalUnpinnedCount) unpinned items loaded.") // Keep this log
    print("[History] Exiting pruneOldItemsIfNeeded()")
  }
  
  @MainActor
  func resetView() async throws {
    print("[History] Entering resetView()")
    // Only reset if we're not in search mode
    if searchQuery.isEmpty {
      print("[History.resetView] Search query is empty, calling load()")
      try await load()
    } else {
       print("[History.resetView] Search query is not empty ('\(searchQuery)'), skipping load()")
    }
    print("[History] Exiting resetView()")
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    print("[History] Entering add() for item with content starting: \(item.title.prefix(50))...")
    print("[History.add] Current unpinned count: \(all.filter(\.isUnpinned).count), Max size: \(Defaults[.size])")
    while all.filter(\.isUnpinned).count >= Defaults[.size] {
      print("[History.add] Max size reached, attempting to delete oldest unpinned item")
      delete(all.last(where: \.isUnpinned))
    }

    var removedItemIndex: Int?
    print("[History.add] Searching for similar existing item")
    if let existingHistoryItem = findSimilarItem(item) {
      print("[History.add] Found similar item: \(existingHistoryItem.id)")
      if isModified(item) == nil {
         print("[History.add] Item is not a modification, preserving existing contents")
        item.contents = existingHistoryItem.contents
      } else {
         print("[History.add] Item is a modification, keeping new contents")
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        print("[History.add] Item not from Maccy, preserving existing application: \(existingHistoryItem.application ?? "nil")")
        item.application = existingHistoryItem.application
      }
      print("[History.add] Deleting existing item: \(existingHistoryItem.id)")
      Storage.shared.context.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        print("[History.add] Removing existing item from 'all' at index \(removedItemIndex)")
        all.remove(at: removedItemIndex)
      } else {
         print("[History.add] Existing item not found in 'all' collection (unexpected)")
      }
    } else {
      print("[History.add] No similar item found, adding as new")
      Task {
        print("[History.add.Task] Sending notification for new item")
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    print("[History.add] Adding item to session log with change count: \(Clipboard.shared.changeCount)")
    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      print("[History.add] Item is pinned ('\(pin)'), creating decorator with shortcut")
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      // Keep pins in the same place.
      if let removedItemIndex {
        print("[History.add] Inserting pinned item back at original index \(removedItemIndex)")
        all.insert(itemDecorator, at: removedItemIndex)
      } else {
         // If it wasn't a duplicate, it might need adding based on sort order if not found
         print("[History.add] Inserting new pinned item (logic might need review for exact position)")
         // Simple append for now, might need refinement based on desired pinned item sorting
         all.append(itemDecorator)
      }
    } else {
      print("[History.add] Item is unpinned, creating decorator")
      itemDecorator = HistoryItemDecorator(item)

      print("[History.add] Sorting 'all' + new item to find insertion index")
      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        print("[History.add] Inserting unpinned item at index \(index)")
        all.insert(itemDecorator, at: index)
      } else {
         print("[History.add] Could not find index for new unpinned item after sort (unexpected), appending")
         all.append(itemDecorator) // Fallback
      }

      print("[History.add] Updating 'items' and unpinned shortcuts")
      items = all
      updateUnpinnedShortcuts()
      print("[History.add.Task] Setting needsResize = true")
      AppState.shared.popup.needsResize = true
    }
    print("[History] Exiting add() -> Decorator ID: \(itemDecorator.id)")
    return itemDecorator
  }

  @MainActor
  func clear() {
    print("[History] Entering clear()")
    let unpinnedCount = all.filter(\.isUnpinned).count
    print("[History.clear] Removing all \(unpinnedCount) unpinned items from 'all' collection")
    all.removeAll(where: \.isUnpinned)
    items = all
    print("[History.clear] Deleting unpinned items from storage")
    try? Storage.shared.context.delete(
      model: HistoryItem.self,
      where: #Predicate { $0.pin == nil }
    )
    print("[History.clear] Clearing clipboard and closing popup")
    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      print("[History.clear.Task] Setting needsResize = true")
      AppState.shared.popup.needsResize = true
    }
    print("[History] Exiting clear()")
  }

  @MainActor
  func clearAll() {
    print("[History] Entering clearAll()")
    let totalCount = all.count
    print("[History.clearAll] Removing all \(totalCount) items from 'all' collection")
    all.removeAll()
    items = all
    print("[History.clearAll] Deleting all items from storage")
    try? Storage.shared.context.delete(model: HistoryItem.self)
    print("[History.clearAll] Clearing clipboard and closing popup")
    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      print("[History.clearAll.Task] Setting needsResize = true")
      AppState.shared.popup.needsResize = true
    }
    print("[History] Exiting clearAll()")
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    print("[History] Entering delete() for item ID: \(item?.id.uuidString ?? "nil")")
    guard let item else { 
        print("[History.delete] Guard failed: item is nil")
        return 
    }

    print("[History.delete] Deleting item from storage: \(item.id)")
    Storage.shared.context.delete(item.item)
    let allCountBefore = all.count
    let itemsCountBefore = items.count
    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    print("[History.delete] Removed item from 'all' (count \(allCountBefore) -> \(all.count)) and 'items' (count \(itemsCountBefore) -> \(items.count))")

    print("[History.delete] Updating unpinned shortcuts")
    updateUnpinnedShortcuts()
    Task {
      print("[History.delete.Task] Setting needsResize = true")
      AppState.shared.popup.needsResize = true
    }
    print("[History] Exiting delete()")
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    print("[History] Entering select() for item ID: \(item?.id.uuidString ?? "nil")")
    guard let item else {
      print("[History.select] Guard failed: item is nil")
      return
    }

    let modifierFlags = NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
    print("[History.select] Modifier flags: \(modifierFlags)")

    if modifierFlags.isEmpty {
      print("[History.select] No modifiers. Closing popup, copying (removeFormatting=\(!Defaults[.removeFormattingByDefault])), maybe pasting (pasteByDefault=\(Defaults[.pasteByDefault]))")
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        print("[History.select] Pasting by default")
        Clipboard.shared.paste()
      }
    } else {
      let action = HistoryItemAction(modifierFlags)
      print("[History.select] Modifiers present. Action: \(action)")
      switch action {
      case .copy:
        print("[History.select] Action: Copy. Closing popup, copying item")
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        print("[History.select] Action: Paste. Closing popup, copying, pasting")
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        print("[History.select] Action: Paste Without Formatting. Closing popup, copying (removeFormatting=true), pasting")
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        print("[History.select] Action: Unknown. Doing nothing.")
        return
      }
    }

    Task {
      print("[History.select.Task] Resetting search query")
      searchQuery = ""
    }
     print("[History] Exiting select()")
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
     print("[History] Entering togglePin() for item ID: \(item?.id.uuidString ?? "nil")")
    guard let item else { 
       print("[History.togglePin] Guard failed: item is nil")
       return 
    }

    let wasPinned = item.isPinned
    print("[History.togglePin] Calling item.togglePin() (wasPinned=\(wasPinned))")
    item.togglePin()
    print("[History.togglePin] Item pin toggled (isPinned=\(item.isPinned))")

    print("[History.togglePin] Sorting all items to find new index")
    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      print("[History.togglePin] Found indices: current=\(currentIndex), new=\(newIndex). Reordering item in 'all' collection")
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    } else {
       print("[History.togglePin] Could not find current or new index after sorting (unexpected)")
    }

    print("[History.togglePin] Updating 'items' collection")
    items = all

    print("[History.togglePin] Resetting search query and updating unpinned shortcuts")
    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      print("[History.togglePin] Item is now unpinned, setting scroll target to \(item.id)")
      AppState.shared.scrollTarget = item.id
    }
    print("[History] Exiting togglePin()")
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    print("[History] Entering findSimilarItem() for item ID: \(item.id)")
    let descriptor = FetchDescriptor<HistoryItem>()
    do {
        print("[History.findSimilarItem] Fetching all items from storage")
        let allItems = try Storage.shared.context.fetch(descriptor)
        print("[History.findSimilarItem] Fetched \(allItems.count) items. Filtering for duplicates/supersedes...")
        let duplicates = allItems.filter({ $0 == item || $0.supersedes(item) })
        print("[History.findSimilarItem] Found \(duplicates.count) duplicates/supersedes")
        if duplicates.count > 1 {
            let firstDuplicate = duplicates.first(where: { $0 != item })
            print("[History.findSimilarItem] Found > 1 duplicate, returning first non-self match: \(firstDuplicate?.id.debugDescription ?? "nil")")
            return firstDuplicate
        } else {
            print("[History.findSimilarItem] Found 0 or 1 duplicate, checking if item is modified")
            let modifiedItem = isModified(item)
            print("[History.findSimilarItem] isModified returned: \(modifiedItem?.id.debugDescription ?? "nil")")
            return modifiedItem
        }
    } catch {
        print("[History.findSimilarItem] Error fetching items: \(error)")
        // If fetch fails, maybe return the original item? Or nil? Returning item for now.
        print("[History.findSimilarItem] Returning original item due to fetch error")
        return item 
    }
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    print("[History] Entering isModified() for item ID: \(item.id)")
    if let modified = item.modified {
        print("[History.isModified] Item has modified field: \(modified). Checking session log.")
        if sessionLog.keys.contains(modified) {
            let loggedItem = sessionLog[modified]
            print("[History.isModified] Found modified item in session log: \(loggedItem?.id.debugDescription ?? "nil")")
            return loggedItem
        } else {
            print("[History.isModified] Modified key \(modified) not found in session log keys: \(sessionLog.keys)")
        }
    } else {
        print("[History.isModified] Item has no modified field")
    }

    print("[History.isModified] Returning nil")
    return nil
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    print("[History] Entering updateItems() with \(newItems.count) search results")
    
    // Efficiently create a map for quick lookup if needed, but direct map might be fine
    // let allMap = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }

    items = newItems.map { result in
      // Find the corresponding decorator from the 'all' list
      // This assumes the SearchResult.object is one of the HistoryItemDecorator instances already in 'all'
      // If SearchResult contains raw HistoryItems, we'd need to find the decorator first.
      // Assuming result.object IS the decorator:
      let itemDecorator = result.object // Assuming result.object is HistoryItemDecorator
      // print("[History.updateItems] Highlighting item \(itemDecorator.id) with query '\(searchQuery)' and ranges \(result.ranges)") // Too noisy
      itemDecorator.highlight(searchQuery, result.ranges)
      return itemDecorator
    }
    print("[History.updateItems] Updated 'items' collection to \(items.count) filtered/highlighted items")

    print("[History.updateItems] Updating unpinned shortcuts")
    updateUnpinnedShortcuts()
    print("[History] Exiting updateItems()")
  }

  private func updateShortcuts() {
    print("[History] Entering updateShortcuts()")
    print("[History.updateShortcuts] Updating shortcuts for \(pinnedItems.count) pinned items")
    for item in pinnedItems {
      if let pin = item.item.pin {
        // print("[History.updateShortcuts] Assigning shortcut '\(pin)' to pinned item \(item.id)") // Too noisy
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    print("[History.updateShortcuts] Updating unpinned shortcuts")
    updateUnpinnedShortcuts()
    print("[History] Exiting updateShortcuts()")
  }

  private func updateUnpinnedShortcuts() {
    print("[History] Entering updateUnpinnedShortcuts()")
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    print("[History.updateUnpinnedShortcuts] Found \(visibleUnpinnedItems.count) visible unpinned items")
    print("[History.updateUnpinnedShortcuts] Clearing existing shortcuts for visible unpinned items")
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    print("[History.updateUnpinnedShortcuts] Assigning numeric shortcuts (1-10) to first \(min(visibleUnpinnedItems.count, 10)) visible unpinned items")
    for item in visibleUnpinnedItems.prefix(10) {
      // print("[History.updateUnpinnedShortcuts] Assigning shortcut '\(index)' to item \(item.id)") // Too noisy
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
    print("[History] Exiting updateUnpinnedShortcuts()")
  }
}
