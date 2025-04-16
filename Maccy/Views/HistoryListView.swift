import Defaults
import SwiftUI
import Combine

struct HistoryListView: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.scenePhase) private var scenePhase
  @Environment(History.self) private var history
  
  @State private var isLoading = false
  @State private var isLoadingNewer = false
  @State private var anchorItemId: UUID? = nil
  @State private var isAtTop = false
  @State private var isAtBottom = false
  @State private var lastLoadAttemptTime = Date()
  @State private var hasTriedLoadingMore = false
  @State private var loadingTimerTask: Task<Void, Never>? = nil
  @State private var scrollViewProxy: ScrollViewProxy?
  @State private var initialLoadComplete = false
  
  @Default(.pinTo) private var pinTo
  @Default(.previewDelay) private var previewDelay

  private var pinnedItems: [HistoryItemDecorator] {
    let filtered = appState.history.pinnedItems.filter(\.isVisible)
    // print("[HistoryListView.pinnedItems] Filtering pinned items, count: \(filtered.count)") // Too noisy
    return filtered
  }
  private var unpinnedItems: [HistoryItemDecorator] {
    let filtered = appState.history.unpinnedItems.filter(\.isVisible)
    // print("[HistoryListView.unpinnedItems] Filtering unpinned items, count: \(filtered.count)") // Too noisy
    return filtered
  }
  private var showPinsSeparator: Bool {
    let shouldShow = !pinnedItems.isEmpty && !unpinnedItems.isEmpty && appState.history.searchQuery.isEmpty
    // print("[HistoryListView.showPinsSeparator] Check: pinned=\(!pinnedItems.isEmpty), unpinned=\(!unpinnedItems.isEmpty), search=\(appState.history.searchQuery.isEmpty ? "empty" : "not empty") -> \(shouldShow)") // Existing, kept commented
    return shouldShow
  }
  private var isActive: Bool {
    // print("[HistoryListView.isActive] Checking scenePhase: \(scenePhase)") // Too noisy
    return scenePhase == .active
  }

  // Handle stopping the refresh timer when the view disappears
  var refreshTimer: AnyCancellable? = nil

  var body: some View {
    // print("[HistoryListView] Entering body") // Too noisy for SwiftUI body
    ZStack {
      // Main content
      scrollViewContent
        .onChange(of: history.items) { _, _ in
          print("[HistoryListView.onChange(of: history.items)] Items changed, count: \(history.items.count)")
          if !history.items.isEmpty && !initialLoadComplete {
            print("[HistoryListView.onChange(of: history.items)] Initial load detected, setting initialLoadComplete = true") // Enhanced existing print
            initialLoadComplete = true
          }
        }
        .onChange(of: unpinnedItems.count) { _, newCount in
          print("[HistoryListView.onChange(of: unpinnedItems.count)] Count changed to \(newCount)") // Enhanced existing print
          // Reset loading state when new items are loaded
          isLoading = false
          print("[HistoryListView.onChange(of: unpinnedItems.count)] Reset isLoading to false")
        }
      
      // Show a refresh indicator at the top when loading newer items
      if isLoadingNewer {
        // print("[HistoryListView.body] isLoadingNewer is true, showing ProgressView") // Too noisy
        VStack {
          ProgressView()
            .padding(5)
            .background(Color(.windowBackgroundColor).opacity(0.8))
            .cornerRadius(8)
            .frame(width: 30, height: 30)
          Spacer()
        }
        .padding(.top, 10)
      }
    }
    .onAppear {
      print("[HistoryListView] Entering onAppear") // Enhanced existing print
      if isActive {
        print("[HistoryListView.onAppear] Scene is active, attempting to load newer items")
        attemptLoadNewer()
      } else {
        print("[HistoryListView.onAppear] Scene is not active, skipping load newer")
      }
      print("[HistoryListView] Exiting onAppear")
    }
    .onDisappear {
      print("[HistoryListView] Entering onDisappear") // Enhanced existing print
      print("[HistoryListView.onDisappear] Cancelling loading timer")
      cancelLoadingTimer()
      print("[HistoryListView] Exiting onDisappear")
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      print("[HistoryListView] Entering onChange(of: scenePhase) - Old: \(oldPhase), New: \(newPhase)")
      if newPhase == .active {
        print("[HistoryListView.onChange(of: scenePhase)] Scene became active - resetting states") // Enhanced existing print
        searchFocused = true
        HistoryItemDecorator.previewThrottler.minimumDelay = Double(previewDelay) / 1000
        HistoryItemDecorator.previewThrottler.cancel()
        appState.isKeyboardNavigating = true
        appState.selection = appState.history.unpinnedItems.first?.id ?? appState.history.pinnedItems.first?.id
        print("[HistoryListView.onChange(of: scenePhase)] Set selection to \(appState.selection?.uuidString ?? "nil")")
        
        // Reset loading states when becoming active
        print("[HistoryListView.onChange(of: scenePhase)] Resetting loading states")
        resetLoadingStates()
      } else if newPhase == .background || newPhase == .inactive {
        print("[HistoryListView.onChange(of: scenePhase)] Scene became inactive/background - resetting view state") // Enhanced existing print
        // Reset state when window is minimized or inactive
        modifierFlags.flags = []
        appState.isKeyboardNavigating = true
        
        // Clear in-memory history items AND reload the initial page to free memory but keep basics ready
        // print("[HistoryListView.onChange(of: scenePhase)] Calling history.clearInMemoryItems()") // REMOVE this line
        // history.clearInMemoryItems() // REMOVE this line
        Task {
            print("[HistoryListView.onChange(of: scenePhase).Task] Calling history.load() to reset/reload initial items on backgrounding.")
            do {
                try await history.load() 
                print("[HistoryListView.onChange(of: scenePhase).Task] history.load() completed.")
            } catch {
                print("[HistoryListView.onChange(of: scenePhase).Task] Error calling history.load() on backgrounding: \(error)")
            }
        }
        
        // Reset scroll position flags
        print("[HistoryListView.onChange(of: scenePhase)] Resetting scroll flags")
        isAtTop = false
        isAtBottom = false
      }
      print("[HistoryListView] Exiting onChange(of: scenePhase)")
    }

    if pinTo == .bottom {
      // print("[HistoryListView.body] pinTo is bottom, showing pinned items at bottom") // Too noisy
      LazyVStack(spacing: 0) {
        if showPinsSeparator {
          Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }

        ForEach(pinnedItems) { item in
          HistoryItemView(item: item)
        }
      }
      .background {
        GeometryReader { geo in
          Color.clear
            .task(id: geo.size.height) {
              print("[HistoryListView.body.pinnedItems.task] Pinned items height changed: \(geo.size.height)")
              appState.popup.pinnedItemsHeight = geo.size.height
            }
        }
      }
    }
  }
  
  // Reset all loading states
  private func resetLoadingStates() {
    print("[HistoryListView] Entering resetLoadingStates") // Enhanced existing print
    isLoading = false
    isLoadingNewer = false
    hasTriedLoadingMore = false
    cancelLoadingTimer()
    print("[HistoryListView] Exiting resetLoadingStates")
  }
  
  // Attempt to load newer items
  private func attemptLoadNewer() {
    print("[HistoryListView] Entering attemptLoadNewer") // Enhanced existing print
    guard !isLoadingNewer && appState.history.searchQuery.isEmpty else {
      print("[HistoryListView.attemptLoadNewer] Guard failed: isLoadingNewer=\(isLoadingNewer), searchQuery=\(appState.history.searchQuery.isEmpty ? "empty" : "not empty")") // Enhanced existing print
      return
    }
    
    isLoadingNewer = true
    print("[HistoryListView.attemptLoadNewer] Starting to load newer items, set isLoadingNewer=true") // Enhanced existing print
    
    Task {
      print("[HistoryListView.attemptLoadNewer.Task] Entering task")
      do {
        let itemsCountBefore = appState.history.unpinnedItems.count
        print("[HistoryListView.attemptLoadNewer.Task] Calling history.resetView()")
        try await appState.history.resetView()
        let itemsCountAfter = appState.history.unpinnedItems.count
        
        await MainActor.run {
          print("[HistoryListView.attemptLoadNewer.Task] Load newer finished: before=\(itemsCountBefore), after=\(itemsCountAfter)") // Enhanced existing print
          if itemsCountBefore == itemsCountAfter {
            print("[HistoryListView.attemptLoadNewer.Task] No new items found") // Enhanced existing print
          }
          isLoadingNewer = false
          print("[HistoryListView.attemptLoadNewer.Task] Set isLoadingNewer=false, starting loading timer")
          startLoadingTimer()
        }
      } catch {
        await MainActor.run {
          print("[HistoryListView.attemptLoadNewer.Task] Error loading newer items: \(error)") // Enhanced existing print
          isLoadingNewer = false
          print("[HistoryListView.attemptLoadNewer.Task] Set isLoadingNewer=false on error, starting loading timer")
          startLoadingTimer()
        }
      }
      print("[HistoryListView.attemptLoadNewer.Task] Exiting task")
    }
    print("[HistoryListView] Exiting attemptLoadNewer")
  }
  
  // Start a timer to check for newer items periodically
  private func startLoadingTimer() {
    print("[HistoryListView] Entering startLoadingTimer") // Enhanced existing print
    cancelLoadingTimer()
    
    print("[HistoryListView.startLoadingTimer] Starting new 30s timer task")
    loadingTimerTask = Task {
      do {
         try await Task.sleep(for: .seconds(30))
         guard !Task.isCancelled else { 
           print("[HistoryListView.startLoadingTimer.Task] Timer task cancelled")
           return 
         }
         
         print("[HistoryListView.startLoadingTimer.Task] Timer fired after 30s") // Enhanced existing print
         await MainActor.run { // Ensure UI updates are on the main thread
             attemptLoadNewer()
         }
      } catch {
          print("[HistoryListView.startLoadingTimer.Task] Timer task sleep cancelled: \(error)")
      }
    }
    print("[HistoryListView] Exiting startLoadingTimer")
  }
  
  // Cancel the loading timer
  private func cancelLoadingTimer() {
    print("[HistoryListView] Entering cancelLoadingTimer")
    if loadingTimerTask != nil {
      loadingTimerTask?.cancel()
      loadingTimerTask = nil
      print("[HistoryListView.cancelLoadingTimer] Cancelled existing timer task")
    } else {
      print("[HistoryListView.cancelLoadingTimer] No active timer task to cancel")
    }
    print("[HistoryListView] Exiting cancelLoadingTimer")
  }
  
  private var scrollViewContent: some View {
    // print("[HistoryListView.scrollViewContent] Entering scrollViewContent") // Too noisy
    ScrollViewReader { proxy in
      ScrollView {
        // print("[HistoryListView.scrollViewContent] Entering ScrollView") // Too noisy
        LazyVStack(spacing: 0) {
          if pinTo == .top {   
            // print("[HistoryListView.scrollViewContent] pinTo is top, adding pinned items") // Too noisy         
            ForEach(pinnedItems) { item in
              HistoryItemView(item: item)
            }
            if initialLoadComplete && showPinsSeparator {
              // print("[HistoryListView.scrollViewContent] Showing pins separator") // Too noisy
              Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
          }
          
          // print("[HistoryListView.scrollViewContent] Adding unpinned items") // Too noisy
          ForEach(unpinnedItems) { item in
            HistoryItemView(item: item)
          }
          
          // Always show the load more trigger when not searching
          // It will display appropriate state based on hasMoreItems
          if !unpinnedItems.isEmpty && searchQuery.isEmpty {
            // print("[HistoryListView.scrollViewContent] Adding LoadMoreTrigger") // Too noisy
            LoadMoreTrigger(isLoading: isLoading, hasMoreItems: history.hasMoreItems, onLoadMore: loadMoreItems)
          } else {
            // print("[HistoryListView.scrollViewContent] Skipping LoadMoreTrigger (unpinned empty or search active)") // Too noisy
          }
        }
      }
      .task(id: appState.scrollTarget) {
        print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Entering task, target: \(appState.scrollTarget?.uuidString ?? "nil")")
        guard let targetId = appState.scrollTarget else { 
           print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Guard failed: scrollTarget is nil")
           return 
        }

        do {
          try await Task.sleep(for: .milliseconds(10))
          guard !Task.isCancelled else { 
            print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Task cancelled after sleep")
            return 
          }
        } catch {
            print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Sleep cancelled: \(error)")
            return
        }


        print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Scrolling to \(targetId)")
        proxy.scrollTo(targetId)
        appState.scrollTarget = nil
        print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Reset scrollTarget to nil")
        print("[HistoryListView.scrollViewContent.task(id: scrollTarget)] Exiting task")
      }
      // Calculate the total height inside a scroll view.
      .background {
        GeometryReader { geo in
          Color.clear
            .task(id: appState.popup.needsResize) {
              print("[HistoryListView.scrollViewContent.background.task(id: needsResize)] Entering task, needsResize: \(appState.popup.needsResize)")
              // Increase delay to allow layout calculations to finish
              do {
                 try await Task.sleep(for: .milliseconds(150))
                 guard !Task.isCancelled else { 
                     print("[HistoryListView.scrollViewContent.background.task(id: needsResize)] Task cancelled after sleep")
                     return 
                 }
              } catch {
                  print("[HistoryListView.scrollViewContent.background.task(id: needsResize)] Sleep cancelled: \(error)")
                  return
              }

              if appState.popup.needsResize {
                print("[HistoryListView.scrollViewContent.background.task(id: needsResize)] Needs resize is true, calling resize with height: \(geo.size.height)") // Enhanced existing print
                appState.popup.resize(height: geo.size.height)
              } else {
                print("[HistoryListView.scrollViewContent.background.task(id: needsResize)] Needs resize is false, skipping resize") // Enhanced existing print
              }
               print("[HistoryListView.scrollViewContent.background.task(id: needsResize)] Exiting task")
            }
        }
      }
      .contentMargins(.leading, 10, for: .scrollIndicators)
    }
  }
  
  // The loading trigger view at the bottom of the list
  private struct LoadMoreTrigger: View {
    var isLoading: Bool
    var hasMoreItems: Bool
    var onLoadMore: () -> Void
    
    var body: some View {
      // print("[LoadMoreTrigger] Entering body, isLoading: \(isLoading), hasMoreItems: \(hasMoreItems)") // Too noisy
      VStack {
        if isLoading {
          // print("[LoadMoreTrigger.body] Showing loading state") // Too noisy
          VStack(spacing: 8) {
            ProgressView()
              .padding(.vertical, 4)
            Text("Loading more items...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(height: 60)
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
        } else if hasMoreItems {
          // print("[LoadMoreTrigger.body] Showing 'load more' button state") // Too noisy
          Button(action: {
              print("[LoadMoreTrigger.body] Load more button tapped")
              onLoadMore()
          }) {
            VStack(spacing: 8) {
              Image(systemName: "arrow.down.circle")
                .font(.system(size: 16))
              Text("Tap to load more items")
                .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .frame(height: 60)
        } else {
          // print("[LoadMoreTrigger.body] Showing 'no more items' state") // Too noisy
          VStack(spacing: 8) {
            Text("No more items")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(height: 40)
          .frame(maxWidth: .infinity)
        }
      }
      .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
      .onAppear {
        print("[LoadMoreTrigger] Entering onAppear - hasMoreItems: \(hasMoreItems), isLoading: \(isLoading)") // Enhanced existing print
        // Only automatically load more if there are more items and not already loading
        if hasMoreItems && !isLoading {
          print("[LoadMoreTrigger.onAppear] Conditions met, scheduling onLoadMore()")
          // Delay slightly to prevent multiple rapid calls
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("[LoadMoreTrigger.onAppear] Dispatch executing onLoadMore()")
            onLoadMore()
          }
        } else {
           print("[LoadMoreTrigger.onAppear] Conditions not met, skipping automatic load")
        }
        print("[LoadMoreTrigger] Exiting onAppear")
      }
    }
  }
  
  // Load more items when scrolled to bottom
  private func loadMoreItems() {
    print("[HistoryListView] Entering loadMoreItems - isLoading=\(isLoading), hasMoreItems=\(history.hasMoreItems), searchQuery=\(searchQuery.isEmpty ? "empty" : searchQuery)") // Enhanced existing print
    
    // Skip if already loading, search is active, or no more items
    guard !isLoading, searchQuery.isEmpty, history.hasMoreItems else {
      if isLoading {
        print("[HistoryListView.loadMoreItems] Guard failed: Skipping load - already loading") // Enhanced existing print
      } else if !searchQuery.isEmpty {
        print("[HistoryListView.loadMoreItems] Guard failed: Skipping load - search is active") // Enhanced existing print
      } else if !history.hasMoreItems {
        print("[HistoryListView.loadMoreItems] Guard failed: Skipping load - no more items available") // Enhanced existing print
      }
      return
    }
    
    // Set loading state
    isLoading = true
    hasTriedLoadingMore = true
    print("[HistoryListView.loadMoreItems] Set isLoading=true, hasTriedLoadingMore=true")
    
    // Log time before loading
    let startTime = Date()
    
    // Create a task to load more items
    Task {
      print("[HistoryListView.loadMoreItems.Task] Entering task")
      do {
        print("[HistoryListView.loadMoreItems.Task] Calling history.loadMore()") // Enhanced existing print
        try await history.loadMore()
        
        // Log time after loading
        let duration = Date().timeIntervalSince(startTime)
        print("[HistoryListView.loadMoreItems.Task] Loaded more items in \(String(format: "%.3f", duration)) seconds") // Enhanced existing print
      } catch {
        print("[HistoryListView.loadMoreItems.Task] Error loading more items: \(error)") // Enhanced existing print
      }
      
      // Reset loading state regardless of success/failure
      await MainActor.run {
        print("[HistoryListView.loadMoreItems.Task] Resetting loading states (isLoading=false, hasTriedLoadingMore=false)")
        isLoading = false
        // Only reset hasTriedLoadingMore when the task is complete
        // This prevents rapid repeated loading attempts
        hasTriedLoadingMore = false
      }
      print("[HistoryListView.loadMoreItems.Task] Exiting task")
    }
    print("[HistoryListView] Exiting loadMoreItems (task started)")
  }
  
  // Try to load older items if conditions allow
  private func attemptLoadOlder() {
    print("[HistoryListView] Entering attemptLoadOlder - isLoading=\(isLoading), isLoadingNewer=\(isLoadingNewer), hasMore=\(history.hasMoreItems), searchActive=\(history.searchQuery.isEmpty ? "no" : "yes")") // Enhanced existing print
    
    // Skip if already loading, no more items, or if search is active
    guard !isLoadingNewer && !isLoading && history.hasMoreItems && history.searchQuery.isEmpty else {
      print("[HistoryListView.attemptLoadOlder] Guard failed, skipping")
      return
    }
    
    // Rate limiting
    let now = Date()
    let timeSinceLastAttempt = now.timeIntervalSince(lastLoadAttemptTime)
    if timeSinceLastAttempt < 0.5 {
      print("[HistoryListView.attemptLoadOlder] Rate limited, time since last attempt: \(String(format: "%.3f", timeSinceLastAttempt))s")
      return
    }
    lastLoadAttemptTime = now
    print("[HistoryListView.attemptLoadOlder] Rate limit passed, proceeding")
    
    // Set loading state and start loading
    isLoading = true
    print("[HistoryListView.attemptLoadOlder] Set isLoading=true, starting loading timer")
    // It seems odd to call startLoadingTimer here, as this loads *older* items. 
    // Keeping original logic but commenting. Should perhaps call loadMoreItems directly?
    // startLoadingTimer() // Original code had this, seems like it might call attemptLoadNewer instead of loadMore
    
    Task {
      print("[HistoryListView.attemptLoadOlder.Task] Entering task")
      do {
        print("[HistoryListView.attemptLoadOlder.Task] Calling history.loadMore()")
        // Directly call loadMore as intended for older items
        try await history.loadMore() 
      } catch {
        print("[HistoryListView.attemptLoadOlder.Task] Error loading older items: \(error)") // Enhanced existing print
      }
      // Reset loading state after do-catch completes
      await MainActor.run {
         print("[HistoryListView.attemptLoadOlder.Task] Resetting isLoading=false")
         isLoading = false // Ensure loading state is reset
      }
      print("[HistoryListView.attemptLoadOlder.Task] Exiting task")
    }
    print("[HistoryListView] Exiting attemptLoadOlder (task started)")
  }
}

// Top loading view that appears when scrolled to top
struct TopLoadingView: View {
  var isLoading: Bool
  
  var body: some View {
    // print("[TopLoadingView] Entering body, isLoading: \(isLoading)") // Too noisy
    HStack {
      Spacer()
      ProgressView()
        .scaleEffect(0.7)
        .padding(.trailing, 5)
      Text("Checking for new items...")
        .font(.caption)
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(height: 30)
    .background(Color(NSColor.controlBackgroundColor))
  }
}

// Bottom loading view that changes based on whether more items are available
struct BottomLoadingView: View {
  var isLoading: Bool
  var hasMore: Bool
  
  var body: some View {
     // print("[BottomLoadingView] Entering body, isLoading: \(isLoading), hasMore: \(hasMore)") // Too noisy
    VStack(spacing: 4) {
      if isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .scaleEffect(0.7)
          .padding(.vertical, 4)
        
        Text("Loading more items...")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if hasMore {
        Text("Scroll to load more...")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        Color.clear
          .frame(height: 2)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 8)
  }
}

// Scroll sensor for auto-loading content
enum SensorPosition {
  case top, bottom
}

struct ScrollSensor: View {
  var isLoading: Bool
  var position: SensorPosition
  var loadAction: () -> Void
  
  var body: some View {
    // print("[ScrollSensor] Entering body, isLoading: \(isLoading), position: \(position)") // Too noisy
    Group {
      if isLoading {
        ProgressView()
          .scaleEffect(0.7)
          .padding(.vertical, 8)
      } else {
        // Make the sensor more noticeable with light styling
        Color.gray.opacity(0.05)
          .frame(height: 20)
          .overlay {
            Text(position == .top ? "⬆️ Pull for more" : "⬇️ More items below")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .opacity(0.5)
          }
      }
    }
    .frame(maxWidth: .infinity)
    .onAppear {
      print("[ScrollSensor] Entering onAppear, position: \(position), isLoading: \(isLoading)")
      // Small delay to prevent triggering during fast scrolls
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        print("[ScrollSensor.onAppear] Dispatch executing loadAction for position \(position)")
        loadAction()
      }
       print("[ScrollSensor] Exiting onAppear")
    }
  }
}
