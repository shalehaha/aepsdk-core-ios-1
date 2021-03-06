/*
 Copyright 2020 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import AEPServices
import Foundation

public typealias EventListener = (Event) -> Void
public typealias EventResponseListener = (Event?) -> Void
public typealias SharedStateResolver = ([String: Any]?) -> Void
public typealias EventHandlerMapping = (event: Event, handler: (Event) -> (Bool))
public typealias EventPreprocessor = (Event) -> Event

/// Responsible for delivering events to listeners and maintaining registered extension's lifecycle.
final class EventHub {
    private let LOG_TAG = "EventHub"
    private let eventHubQueue = DispatchQueue(label: "com.adobe.eventhub.queue")
    private var registeredExtensions = ThreadSafeDictionary<String, ExtensionContainer>(identifier: "com.adobe.eventhub.registeredExtensions.queue")
    private let eventNumberMap = ThreadSafeDictionary<UUID, Int>(identifier: "com.adobe.eventhub.eventNumber.queue")
    private let responseEventListeners = ThreadSafeArray<EventListenerContainer>(identifier: "com.adobe.eventhub.response.queue")
    private var eventNumberCounter = AtomicCounter()
    private let eventQueue = OperationOrderer<Event>("EventHub")
    private var preprocessors = ThreadSafeArray<EventPreprocessor>(identifier: "com.adobe.eventhub.preprocessors.queue")

    #if DEBUG
        public internal(set) static var shared = EventHub()
    #else
        internal static let shared = EventHub()
    #endif

    // MARK: Internal API

    init() {
        // setup a fake extension container for `EventHub` so we can shared and retrieve state
        registerExtension(EventHubPlaceholderExtension.self, completion: { _ in })

        // Setup eventQueue handler for the main OperationOrderer
        eventQueue.setHandler { (event) -> Bool in

            let processedEvent = self.preprocessors.shallowCopy.reduce(event) { event, preprocessor in
                preprocessor(event)
            }

            // Handle response event listeners first
            if let responseID = processedEvent.responseID {
                _ = self.responseEventListeners.filterRemove { (eventListenerContainer: EventListenerContainer) -> Bool in
                    guard eventListenerContainer.triggerEventId == responseID else { return false }
                    eventListenerContainer.timeoutTask?.cancel()
                    eventListenerContainer.listener(processedEvent)
                    return true
                }
            }

            // Send event to each ExtensionContainer
            self.registeredExtensions.shallowCopy.values.forEach {
                $0.eventOrderer.add(processedEvent)
            }

            return true
        }
    }

    /// When this API is invoked the `EventHub` will begin processing `Event`s
    func start() {
        eventHubQueue.async {
            self.eventQueue.start()
            self.shareEventHubSharedState() // share state of all registered extensions
            Log.debug(label: "\(self.LOG_TAG):\(#function)", "Event Hub successfully started")
        }
    }

    /// Dispatches a new `Event` to the `EventHub`. This `Event` is sent to all listeners who have registered for the `EventType`and `EventSource`
    /// - Parameter event: An `Event` to be dispatched to listeners
    func dispatch(event: Event) {
        // Set an event number for the event
        eventNumberMap[event.id] = eventNumberCounter.incrementAndGet()
        eventQueue.add(event)
        Log.debug(label: "\(LOG_TAG):\(#function)", "Event #\(String(describing: eventNumberMap[event.id] ?? 0)), \(event) is dispatched.")
    }

    /// Registers a new `Extension` to the `EventHub`. This `Extension` must implement `Extension`
    /// - Parameters:
    ///   - type: The type of extension to register
    ///   - completion: Invoked when the extension has been registered or failed to register
    func registerExtension(_ type: Extension.Type, completion: @escaping (_ error: EventHubError?) -> Void) {
        eventHubQueue.async {
            guard !type.typeName.isEmpty else {
                Log.error(label: "\(self.LOG_TAG):\(#function)", "Extension name must not be empty.")
                completion(.invalidExtensionName)
                return
            }
            guard self.registeredExtensions[type.typeName] == nil else {
                Log.error(label: "\(self.LOG_TAG):\(#function)", "Cannot register an extension multiple times.")
                completion(.duplicateExtensionName)
                return
            }

            // Init the extension on a dedicated queue
            let extensionQueue = DispatchQueue(label: "com.adobe.eventhub.extension.\(type.typeName)")
            let extensionContainer = ExtensionContainer(type, extensionQueue, completion: completion)
            self.registeredExtensions[type.typeName] = extensionContainer
            Log.debug(label: "\(self.LOG_TAG):\(#function)", "\(type.typeName) successfully registered.")
        }
    }

    /// Unregisters the extension from the `EventHub` if registered
    /// - Parameters:
    ///   - type: The extension to be unregistered
    ///   - completion: A closure invoked when the extension has been unregistered
    func unregisterExtension(_ type: Extension.Type, completion: @escaping (_ error: EventHubError?) -> Void) {
        eventHubQueue.async {
            guard self.registeredExtensions[type.typeName] != nil else {
                Log.error(label: "\(self.LOG_TAG):\(#function)", "Cannot unregister an extension that is not registered.")
                completion(.extensionNotRegistered)
                return
            }

            let extensionContainer = self.registeredExtensions.removeValue(forKey: type.typeName) // remove the corresponding extension container
            extensionContainer?.exten?.onUnregistered() // invoke the onUnregistered delegate function
            self.shareEventHubSharedState()
            completion(nil)
        }
    }

    /// Registers an `EventListener` which will be invoked when the response `Event` to `triggerEvent` is dispatched
    /// - Parameters:
    ///   - triggerEvent: An `Event` which will trigger a response `Event`
    ///   - timeout A timeout in seconds, if the response listener is not invoked within the timeout, then the `EventHub` invokes the response listener with a nil `Event`
    ///   - listener: Function or closure which will be invoked whenever the `EventHub` receives the response `Event` for `triggerEvent`
    func registerResponseListener(triggerEvent: Event, timeout: TimeInterval, listener: @escaping EventResponseListener) {
        var responseListenerContainer: EventListenerContainer? // initialized here so we can use in timeout block
        responseListenerContainer = EventListenerContainer(listener: listener, triggerEventId: triggerEvent.id, timeout: DispatchWorkItem {
            listener(nil)
            _ = self.responseEventListeners.filterRemove { $0 == responseListenerContainer }
        })
        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + timeout, execute: responseListenerContainer!.timeoutTask!)
        responseEventListeners.append(responseListenerContainer!)
    }

    /// Creates a new `SharedState` for the extension with provided data, versioned at `event` if not nil otherwise versioned at latest
    /// - Parameters:
    ///   - extensionName: Extension whose `SharedState` is to be updated
    ///   - data: Data for the `SharedState`
    ///   - event: If not nil, the `SharedState` will be versioned at `event`, if nil the shared state is versioned zero
    func createSharedState(extensionName: String, data: [String: Any]?, event: Event?) {
        guard let (sharedState, version) = versionSharedState(extensionName: extensionName, event: event) else {
            Log.error(label: "\(LOG_TAG):\(#function)", "Error in creating shared state.")
            return
        }

        sharedState.set(version: version, data: data)
        dispatch(event: createSharedStateEvent(extensionName: extensionName))
        Log.debug(label: "\(LOG_TAG):\(#function)", "Shared state is created for \(extensionName) with data \(String(describing: data)) and version \(version)")
    }

    /// Sets the `SharedState` for the extension to pending at `event`'s version and returns a `SharedStateResolver` which is to be invoked with data for the `SharedState` once available.
    /// - Parameters:
    ///   - extensionName: Extension whose `SharedState` is to be updated
    ///   - event: Event which has the `SharedState` should be versioned for, if nil the shared state is versioned zero
    /// - Returns: A `SharedStateResolver` which is invoked to set pending the `SharedState` versioned at `event`
    func createPendingSharedState(extensionName: String, event: Event?) -> SharedStateResolver {
        var pendingVersion: Int?

        if let (sharedState, version) = versionSharedState(extensionName: extensionName, event: event) {
            pendingVersion = version
            sharedState.addPending(version: version)
            Log.debug(label: "\(LOG_TAG):\(#function)", "Pending shared state is created for \(extensionName) with version \(version)")
        }

        return { [weak self] data in
            self?.resolvePendingSharedState(extensionName: extensionName, version: pendingVersion, data: data)
            Log.debug(label: "\(self?.LOG_TAG ?? "EventHub"):\(#function)", "Pending shared state is resolved for \(extensionName) with data \(String(describing: data)) and version \(String(describing: pendingVersion))")
        }
    }

    /// Retrieves the `SharedState` for a specific extension
    /// - Parameters:
    ///   - extensionName: An extension name whose `SharedState` will be returned
    ///   - event: If not nil, will retrieve the `SharedState` that corresponds with this event's version, if nil will return the latest `SharedState`
    ///   - barrier: If true, the `EventHub` will only return `.set` if `extensionName` has moved past `event`
    /// - Returns: The `SharedState` data and status for the extension with `extensionName`
    func getSharedState(extensionName: String, event: Event?, barrier: Bool = true) -> SharedStateResult? {
        guard let container = registeredExtensions.first(where: { $1.sharedStateName == extensionName })?.value, let sharedState = container.sharedState else {
            Log.error(label: "\(LOG_TAG):\(#function)", "Extension not registered")
            return nil
        }

        var version = 0 // default to version 0 if event nil
        if let unwrappedEvent = event {
            version = eventNumberMap[unwrappedEvent.id] ?? 0
        }

        let result = sharedState.resolve(version: version)

        let stateProviderLastVersion = eventNumberFor(event: container.lastProcessedEvent)
        // shared state is still considered pending if barrier is used and the state provider has not processed past the previous event
        if barrier && stateProviderLastVersion < version - 1 && result.status == .set {
            return SharedStateResult(status: .pending, value: result.value)
        }

        return SharedStateResult(status: result.status, value: result.value)
    }

    /// Retrieves the `ExtensionContainer` wrapper for the given extension type
    /// - Parameter type: The `Extension` class to find the `ExtensionContainer` for
    /// - Returns: The `ExtensionContainer` instance if the `Extension` type was found, nil otherwise
    func getExtensionContainer(_ type: Extension.Type) -> ExtensionContainer? {
        return registeredExtensions[type.typeName]
    }

    /// Register a event preprocessor
    /// - Parameter preprocessor: The `EventPreprocessor`
    func registerPreprocessor(_ preprocessor: @escaping EventPreprocessor) {
        preprocessors.append(preprocessor)
    }

    // MARK: Internal
    /// Shares a shared state for the `EventHub` with data containing all the registered extensions
    func shareEventHubSharedState() {
        var extensionsInfo = [String: [String: Any]]()
        for (_, val) in registeredExtensions.shallowCopy
            where val.sharedStateName != EventHubConstants.NAME {
            if let exten = val.exten {
                let version = type(of: exten).extensionVersion
                extensionsInfo[exten.friendlyName] = [EventHubConstants.EventDataKeys.VERSION: version]
                if let metadata = exten.metadata, !metadata.isEmpty {
                    extensionsInfo[exten.friendlyName] = [EventHubConstants.EventDataKeys.VERSION: version,
                                                          EventHubConstants.EventDataKeys.METADATA: metadata]
                }
            }
        }

        // TODO: Determine which version of Core to use in the top level version field
        let data: [String: Any] = [EventHubConstants.EventDataKeys.VERSION: ConfigurationConstants.EXTENSION_VERSION,
                                   EventHubConstants.EventDataKeys.EXTENSIONS: extensionsInfo]

        guard let sharedState = registeredExtensions.first(where: { $1.sharedStateName == EventHubConstants.NAME })?.value.sharedState else {
            Log.error(label: "\(LOG_TAG):\(#function)", "Extension not registered with EventHub")
            return
        }

        let version = sharedState.resolve(version: 0).value == nil ? 0 : eventNumberCounter.incrementAndGet()
        sharedState.set(version: version, data: data)
        dispatch(event: createSharedStateEvent(extensionName: EventHubConstants.NAME))
        Log.debug(label: "\(LOG_TAG):\(#function)", "Shared state is created for \(EventHubConstants.NAME) with data \(String(describing: data)) and version \(version)")
    }

    // MARK: Private

    private func versionSharedState(extensionName: String, event: Event?) -> (SharedState, Int)? {
        guard let extensionContainer = registeredExtensions.first(where: { $1.sharedStateName == extensionName })?.value else {
            Log.error(label: "\(LOG_TAG):\(#function)", "Extension \(extensionName) not registered with EventHub")
            return nil
        }

        var version = 0 // default to version 0
        // attempt to version at the event
        if let unwrappedEvent = event, let eventNumber = eventNumberMap[unwrappedEvent.id] {
            version = eventNumber
        }

        guard let sharedState = extensionContainer.sharedState else { return nil }
        return (sharedState, version)
    }

    private func resolvePendingSharedState(extensionName: String, version: Int?, data: [String: Any]?) {
        guard let pendingVersion = version, let sharedState = registeredExtensions.first(where: { $1.sharedStateName == extensionName })?.value.sharedState else { return }

        sharedState.updatePending(version: pendingVersion, data: data)
        dispatch(event: createSharedStateEvent(extensionName: extensionName))
    }

    private func createSharedStateEvent(extensionName: String) -> Event {
        return Event(name: EventHubConstants.STATE_CHANGE, type: EventType.hub, source: EventSource.sharedState,
                     data: [EventHubConstants.EventDataKeys.Configuration.EVENT_STATE_OWNER: extensionName])
    }

    /// Returns the event number for the event
    /// - Parameter event: The `Event` to be looked up
    /// - Returns: The `Event` number if found, otherwise 0
    private func eventNumberFor(event: Event?) -> Int {
        if let event = event {
            return eventNumberMap[event.id] ?? 0
        }

        return 0
    }
}

private extension Extension {
    /// Returns the name of the class for the Extension
    static var typeName: String {
        return String(describing: self)
    }
}
