import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The remote-notification route, kept out of `Server.swift`'s main body
/// alongside `ServerDeepLinkRoutes` — that file's router-builder
/// inference grinds once too many closures share one function.
extension Server {

    /// `POST /simulators/:udid/notify[?bundleId=<id>]`  body: the payload
    ///
    /// Browser-facing, behind the browser-trust check. The body is the
    /// payload exactly as the app should receive it; `bundleId` may be
    /// left off when the payload carries `Simulator Target Bundle`.
    func registerNotifyRoutes(
        on router: some RouterMethods<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let simulators = self.simulators

        router.post("/simulators/:udid/notify") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            // Above the 4096-byte APNs limit on purpose, so an oversized
            // payload is told its size instead of arriving truncated.
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let payload = buffer.map { Data(buffer: $0) } ?? Data()
            let app = r.uri.queryParameters.get("bundleId").map { String($0) }
            switch await Self.notify(
                udid: Self.udidParam(r), app: app, payload: payload, simulators: simulators
            ) {
            case .delivered(let notification):
                return Self.jsonResponse(notification.deliveredJSON)
            case .badPayload(let reason):
                return Self.pluginError(reason.description, status: .badRequest)
            case .unknownDevice:
                return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .notAllowed(let message):
                return Self.pluginError(message, status: .conflict)
            case .deliverFailed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }
    }

    /// Outcome of the notify route.
    enum NotifyOutcome: Equatable {
        case delivered(RemoteNotification)
        case badPayload(RemoteNotificationError)
        case unknownDevice
        /// The app's notification permission, not a server fault.
        case notAllowed(String)
        case deliverFailed(String)
    }

    /// Read the payload, look up the device, deliver. Split out from the
    /// route closure so unit tests drive every branch without Hummingbird.
    /// The payload is judged first: it's wrong on every device alike.
    static func notify(
        udid: String,
        app: String?,
        payload: Data,
        simulators: any Simulators
    ) async -> NotifyOutcome {
        let notification: RemoteNotification
        do {
            notification = try RemoteNotification.from(json: payload, addressedTo: app)
        } catch let reason as RemoteNotificationError {
            return .badPayload(reason)
        } catch {
            return .badPayload(.notJSON)
        }
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            try await notification.deliver(to: sim.apps())
        } catch let refusal as AppsError {
            if case .notificationsNotAllowed = refusal { return .notAllowed(refusal.description) }
            return .deliverFailed(refusal.description)
        } catch {
            return .deliverFailed(String(describing: error))
        }
        return .delivered(notification)
    }
}
