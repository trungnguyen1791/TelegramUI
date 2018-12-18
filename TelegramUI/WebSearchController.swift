import Foundation
import Postbox
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import LegacyComponents

private func requestContextResults(account: Account, botId: PeerId, query: String, peerId: PeerId, offset: String = "", existingResults: ChatContextResultCollection? = nil, limit: Int = 60) -> Signal<ChatContextResultCollection?, NoError> {
    return requestChatContextResults(account: account, botId: botId, peerId: peerId, query: query, offset: offset)
    |> mapToSignal { results -> Signal<ChatContextResultCollection?, NoError> in
        var collection = existingResults
        if let existingResults = existingResults, let results = results {
            var newResults: [ChatContextResult] = []
            var existingIds = Set<String>()
            for result in existingResults.results {
                newResults.append(result)
                existingIds.insert(result.id)
            }
            for result in results.results {
                if !existingIds.contains(result.id) {
                    newResults.append(result)
                    existingIds.insert(result.id)
                }
            }
            collection = ChatContextResultCollection(botId: existingResults.botId, peerId: existingResults.peerId, query: existingResults.query, geoPoint: existingResults.geoPoint, queryId: results.queryId, nextOffset: results.nextOffset, presentation: existingResults.presentation, switchPeer: existingResults.switchPeer, results: newResults, cacheTimeout: existingResults.cacheTimeout)
        } else {
            collection = results
        }
        if let collection = collection, collection.results.count < limit, let nextOffset = collection.nextOffset {
            let nextResults = requestContextResults(account: account, botId: botId, query: query, peerId: peerId, offset: nextOffset, existingResults: collection)
            if collection.results.count > 10 {
                return .single(collection)
                |> then(nextResults)
            } else {
                return nextResults
            }
        } else {
            return .single(collection)
        }
    }
}

enum WebSearchMode {
    case media
    case avatar
}

enum WebSearchControllerMode {
    case media(completion: (TGMediaSelectionContext, TGMediaEditingContext) -> Void)
    case avatar(completion: (UIImage) -> Void)
    
    var mode: WebSearchMode {
        switch self {
            case .media:
                return .media
            case .avatar:
                return .avatar
        }
    }
}

final class WebSearchControllerInteraction {
    let openResult: (ChatContextResult) -> Void
    let setSearchQuery: (String) -> Void
    let deleteRecentQuery: (String) -> Void
    let toggleSelection: (ChatContextResult, Bool) -> Void
    let sendSelected: (ChatContextResult?) -> Void
    let avatarCompleted: (UIImage) -> Void
    let selectionState: TGMediaSelectionContext?
    let editingState: TGMediaEditingContext
    var hiddenMediaId: String?
    
    init(openResult: @escaping (ChatContextResult) -> Void, setSearchQuery: @escaping (String) -> Void, deleteRecentQuery: @escaping (String) -> Void, toggleSelection: @escaping (ChatContextResult, Bool) -> Void, sendSelected: @escaping (ChatContextResult?) -> Void, avatarCompleted: @escaping (UIImage) -> Void, selectionState: TGMediaSelectionContext?, editingState: TGMediaEditingContext) {
        self.openResult = openResult
        self.setSearchQuery = setSearchQuery
        self.deleteRecentQuery = deleteRecentQuery
        self.toggleSelection = toggleSelection
        self.sendSelected = sendSelected
        self.avatarCompleted = avatarCompleted
        self.selectionState = selectionState
        self.editingState = editingState
    }
}

private func selectionChangedSignal(selectionState: TGMediaSelectionContext) -> Signal<Void, NoError> {
    return Signal { subscriber in
        let disposable = selectionState.selectionChangedSignal()?.start(next: { next in
            subscriber.putNext(Void())
        }, completed: {})
        return ActionDisposable {
            disposable?.dispose()
        }
    }
}

final class WebSearchController: ViewController {
    private var validLayout: ContainerViewLayout?
    
    private let account: Account
    private let mode: WebSearchControllerMode
    private let peer: Peer?
    private let configuration: SearchBotsConfiguration
    
    private var controllerNode: WebSearchControllerNode {
        return self.displayNode as! WebSearchControllerNode
    }
    
    private var _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private var didPlayPresentationAnimation = false
    
    private var controllerInteraction: WebSearchControllerInteraction?
    private var interfaceState: WebSearchInterfaceState
    private let interfaceStatePromise = ValuePromise<WebSearchInterfaceState>()
    
    private var disposable: Disposable?
    private let resultsDisposable = MetaDisposable()
    private var selectionDisposable: Disposable?
    
    private var navigationContentNode: WebSearchNavigationContentNode?
    
    init(account: Account, peer: Peer?, configuration: SearchBotsConfiguration, mode: WebSearchControllerMode) {
        self.account = account
        self.mode = mode
        self.peer = peer
        self.configuration = configuration
        
        let presentationData = account.telegramApplicationContext.currentPresentationData.with { $0 }
        self.interfaceState = WebSearchInterfaceState(presentationData: presentationData)
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: presentationData.theme).withUpdatedSeparatorColor(presentationData.theme.rootController.navigationBar.backgroundColor), strings: NavigationBarStrings(presentationStrings: presentationData.strings)))
        self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBar.style.style
        
        let settings = self.account.postbox.preferencesView(keys: [ApplicationSpecificPreferencesKeys.webSearchSettings])
        |> take(1)
        |> map { view -> WebSearchSettings in
            if let current = view.values[ApplicationSpecificPreferencesKeys.webSearchSettings] as? WebSearchSettings {
                return current
            } else {
                return WebSearchSettings.defaultSettings
            }
        }

        self.disposable = ((combineLatest(settings, account.telegramApplicationContext.presentationData))
        |> deliverOnMainQueue).start(next: { [weak self] settings, presentationData in
            guard let strongSelf = self else {
                return
            }
            strongSelf.updateInterfaceState { current -> WebSearchInterfaceState in
                var updated = current
                if case .media = mode, current.state?.scope != settings.scope {
                    updated = updated.withUpdatedScope(settings.scope)
                }
                if current.presentationData !== presentationData {
                    updated = updated.withUpdatedPresentationData(presentationData)
                }
                return updated
            }
        })
        
        let navigationContentNode = WebSearchNavigationContentNode(theme: presentationData.theme, strings: presentationData.strings)
        self.navigationContentNode = navigationContentNode
        navigationContentNode.setQueryUpdated { [weak self] query in
            guard let strongSelf = self, strongSelf.isNodeLoaded else {
                return
            }
            strongSelf.updateSearchQuery(query)
        }
        self.navigationBar?.setContentNode(navigationContentNode, animated: false)
        
        let selectionState: TGMediaSelectionContext?
        switch self.mode {
            case .media:
                selectionState = TGMediaSelectionContext()
            case .avatar:
                selectionState = nil
        }
        let editingState = TGMediaEditingContext()
        self.controllerInteraction = WebSearchControllerInteraction(openResult: { [weak self] result in
            if let strongSelf = self {
                strongSelf.controllerNode.openResult(currentResult: result, present: { [weak self] viewController, arguments in
                    if let strongSelf = self {
                        strongSelf.present(viewController, in: .window(.root), with: arguments, blockInteraction: true)
                    }
                })
            }
        }, setSearchQuery: { [weak self] query in
            if let strongSelf = self {
                strongSelf.navigationContentNode?.setQuery(query)
                strongSelf.updateSearchQuery(query)
                strongSelf.navigationContentNode?.deactivate()
            }
        }, deleteRecentQuery: { [weak self] query in
            if let strongSelf = self {
                _ = removeRecentWebSearchQuery(postbox: strongSelf.account.postbox, string: query).start()
            }
        }, toggleSelection: { [weak self] result, value in
            if let strongSelf = self {
                let item = LegacyWebSearchItem(result: result)
                strongSelf.controllerInteraction?.selectionState?.setItem(item, selected: value)
            }
        }, sendSelected: { current in
            if let selectionState = selectionState {
                if let current = current {
                    let currentItem = LegacyWebSearchItem(result: current)
                    selectionState.setItem(currentItem, selected: true)
                }
                if case let .media(sendSelected) = mode {
                    sendSelected(selectionState, editingState)
                }
            }
        }, avatarCompleted: { result in
            if case let .avatar(avatarCompleted) = mode {
                avatarCompleted(result)
            }
        }, selectionState: selectionState, editingState: editingState)
        
        if let selectionState = selectionState {
            self.selectionDisposable = (selectionChangedSignal(selectionState: selectionState)
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                if let strongSelf = self {
                    strongSelf.controllerNode.updateSelectionState(animated: true)
                }
            })
        }
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.disposable?.dispose()
        self.resultsDisposable.dispose()
        self.selectionDisposable?.dispose()
    }
    
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if let presentationArguments = self.presentationArguments as? ViewControllerPresentationArguments, !self.didPlayPresentationAnimation {
            self.didPlayPresentationAnimation = true
            if case .modalSheet = presentationArguments.presentationAnimation {
                self.controllerNode.animateIn()
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.navigationContentNode?.activate()
    }
    
    override public func loadDisplayNode() {
        self.displayNode = WebSearchControllerNode(account: self.account, theme: self.interfaceState.presentationData.theme, strings: interfaceState.presentationData.strings, controllerInteraction: self.controllerInteraction!, peer: self.peer, mode: self.mode.mode)
        self.controllerNode.requestUpdateInterfaceState = { [weak self] animated, f in
            if let strongSelf = self {
                strongSelf.updateInterfaceState(f)
            }
        }
        self.controllerNode.cancel = { [weak self] in
            if let strongSelf = self {
                strongSelf.dismiss()
            }
        }
        self.controllerNode.dismissInput = { [weak self] in
            if let strongSelf = self {
                strongSelf.navigationContentNode?.deactivate()
            }
        }
        self.controllerNode.updateInterfaceState(self.interfaceState, animated: false)
        
        self._ready.set(.single(true))
        self.displayNodeDidLoad()
    }
    
    func updateInterfaceState(animated: Bool = true, _ f: (WebSearchInterfaceState) -> WebSearchInterfaceState) {
        let previousInterfaceState = self.interfaceState
        let previousTheme = self.interfaceState.presentationData.theme
        let previousStrings = self.interfaceState.presentationData.theme
        
        let updatedInterfaceState = f(self.interfaceState)
        self.interfaceState = updatedInterfaceState
        self.interfaceStatePromise.set(updatedInterfaceState)
        
        if self.isNodeLoaded {
            if previousTheme !== updatedInterfaceState.presentationData.theme || previousStrings !== updatedInterfaceState.presentationData.strings {
                self.controllerNode.updatePresentationData(theme: updatedInterfaceState.presentationData.theme, strings: updatedInterfaceState.presentationData.strings)
            }
            if previousInterfaceState != self.interfaceState {
                self.controllerNode.updateInterfaceState(self.interfaceState, animated: animated)
            }
        }
    }
    
    private func updateSearchQuery(_ query: String) {
        if !query.isEmpty {
            let _ = addRecentWebSearchQuery(postbox: self.account.postbox, string: query).start()
        }
        
        let scope: Signal<WebSearchScope?, NoError>
        switch self.mode {
            case .media:
                scope = self.interfaceStatePromise.get()
                |> map { state -> WebSearchScope? in
                    return state.state?.scope
                }
                |> distinctUntilChanged
            case .avatar:
                scope = .single(.images)
        }
        
        self.updateInterfaceState { $0.withUpdatedQuery(query) }
        
        let scopes: [WebSearchScope: Promise<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?>] = [.images: Promise(initializeOnFirstAccess: self.signalForQuery(query, scope: .images)), .gifs: Promise(initializeOnFirstAccess: self.signalForQuery(query, scope: .gifs))]
        
        var results = scope
        |> mapToSignal { scope -> (Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, NoError>) in
            if let scope = scope, let scopeResults = scopes[scope] {
                return scopeResults.get()
            } else {
                return .complete()
            }
        }
        
        if query.isEmpty {
            results = .single({ _ in return nil})
            self.navigationContentNode?.setActivity(false)
        }
        
        self.resultsDisposable.set((results
        |> deliverOnMainQueue).start(next: { [weak self] result in
            if let strongSelf = self {
                if let result = result(nil), case let .contextRequestResult(_, results) = result {
                    if let results = results {
                        strongSelf.controllerNode.updateResults(results)
                    }
                } else {
                    strongSelf.controllerNode.updateResults(nil)
                }
            }
        }))
    }
    
    private func signalForQuery(_ query: String, scope: WebSearchScope) -> Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, NoError> {
        var delayRequest = true
        var signal: Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, NoError> = .single({ _ in return .contextRequestResult(nil, nil) })
        
        guard let peerId = self.peer?.id else {
            return .single({ _ in return .contextRequestResult(nil, nil) })
        }
        
        let botName: String?
        switch scope {
            case .images:
                botName = self.configuration.imageBotUsername
            case .gifs:
                botName = self.configuration.gifBotUsername
        }
        guard let name = botName else {
            return .single({ _ in return .contextRequestResult(nil, nil) })
        }
        
        let account = self.account
        let contextBot = resolvePeerByName(account: account, name: name)
        |> mapToSignal { peerId -> Signal<Peer?, NoError> in
            if let peerId = peerId {
                return account.postbox.loadedPeerWithId(peerId)
                |> map { peer -> Peer? in
                    return peer
                }
                |> take(1)
            } else {
                return .single(nil)
            }
        }
        |> mapToSignal { peer -> Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, NoError> in
            if let user = peer as? TelegramUser, let botInfo = user.botInfo, let _ = botInfo.inlinePlaceholder {
                let results = requestContextResults(account: account, botId: user.id, query: query, peerId: peerId, limit: 64)
                |> map { results -> (ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult? in
                    return { _ in
                        return .contextRequestResult(user, results)
                    }
                }
            
                let botResult: Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, NoError> = .single({ previousResult in
                    var passthroughPreviousResult: ChatContextResultCollection?
                    if let previousResult = previousResult {
                        if case let .contextRequestResult(previousUser, previousResults) = previousResult {
                            if previousUser?.id == user.id {
                                passthroughPreviousResult = previousResults
                            }
                        }
                    }
                    return .contextRequestResult(nil, passthroughPreviousResult)
                })
                
                let maybeDelayedContextResults: Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, NoError>
                if delayRequest {
                    maybeDelayedContextResults = results |> delay(0.4, queue: Queue.concurrentDefaultQueue())
                } else {
                    maybeDelayedContextResults = results
                }
                
                return botResult |> then(maybeDelayedContextResults)
            } else {
                return .single({ _ in return nil })
            }
        }
        return (signal |> then(contextBot))
        |> deliverOnMainQueue
        |> beforeStarted { [weak self] in
            if let strongSelf = self {
                strongSelf.navigationContentNode?.setActivity(true)
            }
        }
        |> afterCompleted { [weak self] in
            if let strongSelf = self {
                strongSelf.navigationContentNode?.setActivity(false)
            }
        }
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.validLayout = layout
        
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationHeight, transition: transition)
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        self.navigationContentNode?.deactivate()
        self.controllerNode.animateOut(completion: { [weak self] in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
            completion?()
        })
    }
}