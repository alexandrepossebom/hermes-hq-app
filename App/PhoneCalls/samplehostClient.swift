// Phone Calls (Beta): the app talks to samplehost itself with the owner's own API key. No gateway, add-on or runtime is
// involved. Every request and field below is taken from samplehost's v2 reference (developers.samplehost.com); the doc for
// each is named beside it. The key lives only in this device's Keychain (PhoneKeyStore) and in the Authorization
// header of requests to api.samplehost.com. It is never logged, put in a URL, a crash report, UserDefaults or the gateway.

import CryptoKit
import Foundation
import Security

// MARK: - Where requests go

nonisolated enum samplehostEndpoint {
    /// Release builds only ever use this.
    static let production = URL(string: "https://api.samplehost.com/v2")!

    /// The API base. DEBUG builds (UI tests) may point it at a loopback fake with the launch environment
    /// `HQ_SAMPLEHOST_BASE_URL=https://127.0.0.1:<port>/v2`; anything else is ignored. Release compiles the override out.
    static func base(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if DEBUG
        if let raw = environment["HQ_SAMPLEHOST_BASE_URL"], let url = loopback(raw) { return url }
        #endif
        return production
    }

    /// An HTTPS URL on 127.0.0.1 with no credentials or query, else nil.
    static func loopback(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.host == "127.0.0.1",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        return url
    }

    /// True only for HTTPS requests to the configured base's own host and port.
    static func allowed(_ url: URL, base: URL) -> Bool {
        url.scheme == "https" && url.host == base.host && url.port == base.port && url.user == nil && url.password == nil
    }
}

// MARK: - Errors

nonisolated enum samplehostError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 401/403: samplehost refused the key.
    case badKey
    /// samplehost's own readable words (`errors[].detail`), with the key removed if it was ever echoed.
    case provider(String)
    /// Call Control error 90018 "Call has already ended" (hangup-call reference).
    case callEnded
    case network
    case unexpected(Int)
    /// A URL that is not HTTPS to the samplehost host; never sent.
    case refusedURL

    var description: String { phoneMessage(self) }
}

/// What the screen shows for a failure. Never a raw body and never the key.
nonisolated func phoneMessage(_ error: Error) -> String {
    switch error as? samplehostError {
    case .badKey: return "samplehost didn't accept this API key. Check it in the samplehost portal and try again."
    case .provider(let detail): return "samplehost: \(detail)"
    case .callEnded: return "This call has already ended."
    case .network: return "Couldn't reach samplehost. Check your connection and try again."
    case .unexpected(let status): return "samplehost answered with an unexpected error (\(status)). Try again."
    case .refusedURL: return "Phone Calls only talks to api.samplehost.com over HTTPS."
    case nil: return "The phone request couldn't be completed. Try again."
    }
}

// MARK: - Responses (only the fields the app reads)

/// list-phone-numbers: `data[]` of PhoneNumberDetailed (`id`, `phone_number`, `status`, `connection_id`, `connection_name`).
nonisolated struct samplehostNumber: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let phone_number: String
    var status: String? = nil
    var connection_id: String? = nil
    var connection_name: String? = nil
}

/// list-assistants: `data[]` of Assistant (`id`, `name`).
nonisolated struct samplehostAssistant: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
}

/// get-conversation-messages: ConversationMessage (`role`, `text`, `tool_calls[]`, `created_at`, `sent_at`).
nonisolated struct samplehostMessage: Decodable, Sendable, Equatable {
    nonisolated struct ToolCall: Decodable, Sendable, Equatable {
        nonisolated struct Function: Decodable, Sendable, Equatable {
            let name: String
            var arguments: String? = nil
        }
        let id: String
        var type: String? = nil
        let function: Function
    }
    let role: String
    var text: String? = nil
    var tool_calls: [ToolCall]? = nil
    var created_at: String? = nil
    var sent_at: String? = nil
}

private nonisolated struct DataList<T: Decodable>: Decodable { let data: [T] }
private nonisolated struct DataOne<T: Decodable>: Decodable { let data: T }
private nonisolated struct DialResult: Decodable { let call_control_id: String }
private nonisolated struct CallStatus: Decodable { let is_alive: Bool }
private nonisolated struct ConversationRow: Decodable { let id: String }

// MARK: - The dial request

/// What the owner approved on the confirm sheet, plus the saved setup.
nonisolated struct PhoneDialRequest: Sendable, Equatable {
    let to: String
    let from: String
    let connectionID: String
    let assistantID: String
    let purpose: String
    /// dial `command_id`: samplehost ignores another Dial with the same one, so a retry never places a second call.
    let commandID: String
}

nonisolated enum PhoneLimits {
    /// dial `time_limit_secs`: the hard cap on the answered leg (owner, beta: 60 seconds).
    static let callSeconds = 60
    /// dial `timeout_secs`: how long it may ring before samplehost gives up (default 30).
    static let ringSeconds = 30
    /// Never resolves (RFC 2606 `.invalid`), so the ask_owner webhook sends nothing anywhere. See PhoneAskOwner.
    static let askOwnerURL = "https://ask-owner.invalid/hermes-hq"
}

/// The ask_owner tool and the per-call instructions.
///
/// samplehost has no tool type that works on a phone call without a server: client-side tools are WebRTC only
/// ("They are not available for SIP/phone-call-based conversations", docs/inference/ai-assistants/client-side-tools),
/// and dial's per-call `assistant.tools` accepts only book_appointment, check_availability, webhook, hangup, transfer
/// and retrieval (dial reference, CallAssistantRequest.tools). So ask_owner is a `webhook` tool aimed at an address
/// that never resolves: the assistant's call is still recorded in the conversation (get-conversation-messages,
/// `tool_calls[].id/function.name/arguments`), the app reads it from there, and the owner's answer goes back with
/// ai_assistant_add_messages. The instructions tell the assistant that the tool's own result is not the answer.
nonisolated enum PhoneAskOwner {
    static let name = "ask_owner"
    static let answerPrefix = "The owner answered"
    /// The assistant the app makes for an account that has none (Settings > Phone Calls > Create Assistant).
    static let assistantName = "Hermes HQ Caller"
    /// Its stored instructions; every call replaces them with `instructions(purpose:)`.
    static let baseInstructions = "You are a polite voice assistant placing short phone calls on behalf of the owner of this "
        + "account. Each call gives you its purpose. Be honest that you are an AI assistant if asked."

    static func instructions(purpose: String) -> String {
        """
        You are a voice assistant placing a phone call on behalf of the owner of this account. \
        The purpose of this call, in the owner's words: \(purpose)

        Keep the call short: it ends automatically after \(PhoneLimits.callSeconds) seconds. \
        Be honest that you are an AI assistant calling for the owner if asked. \
        When you need a decision or a fact only the owner has, call the \(name) tool with one short question and, \
        when there are clear options, up to four short choices. Then tell the person you are checking with the owner \
        and keep the conversation going politely. The tool's immediate result never contains the answer and may say \
        it failed; ignore that result. The owner's answer arrives later as a message that starts with \
        "\(answerPrefix)". Never guess or invent the owner's answer. When the conversation is finished, say goodbye \
        and hang up.
        """
    }

    /// dial reference: WebhookTool (`type`, `timeout_ms`, `webhook`) with CallControlWebhookToolParams (`name`,
    /// `description`, `url`, `method`, `body_parameters`), and HangupTool (`type`, `hangup.description`).
    static var tools: [[String: Any]] {
        [
            ["type": "webhook",
             "timeout_ms": 2000,
             "webhook": [
                "name": name,
                "description": "Ask the owner a question during the call. Returns no answer itself: the owner's "
                    + "answer arrives later as a message starting with \"\(answerPrefix)\".",
                "url": PhoneLimits.askOwnerURL,
                "method": "POST",
                "body_parameters": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string", "description": "One short question for the owner."],
                        "choices": ["type": "array", "items": ["type": "string"],
                                    "description": "Up to four short answers the owner can tap. Optional."],
                    ],
                    "required": ["question"],
                ] as [String: Any],
             ] as [String: Any]],
            ["type": "hangup",
             "hangup": ["description": "Hang up when the conversation is finished."]],
        ]
    }

    /// The tool message's text: carries the tool call id so a reopened sheet knows the question was answered.
    static func toolAnswer(_ answer: String, toolCallID: String) -> String {
        "\(answerPrefix) (ref \(toolCallID)): \(answer)"
    }
}

// MARK: - The client

/// One owner's samplehost key. `description`, `debugDescription` and the mirror never show it.
nonisolated struct samplehostAPI: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let key: String
    let base: URL
    private let session: URLSession

    init(key: String, base: URL = samplehostEndpoint.base(), session: URLSession = samplehostAPI.session) {
        self.key = key; self.base = base; self.session = session
    }

    var description: String { "samplehostAPI(\(base.host ?? "?"))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["base": base]) }

    /// Ephemeral: no cache, cookies or credential store; redirects are refused so the header never follows one.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: samplehostNoRedirects(), delegateQueue: nil)
    }()

    // MARK: Requests

    /// list-phone-numbers: `GET /v2/phone_numbers?page[size]=250` (read-only; samplehost's own suggested key check).
    func phoneNumbers() async throws -> [samplehostNumber] {
        let data = try await send("GET", ["phone_numbers"], query: [("page[size]", "250")])
        let list = try decode(DataList<samplehostNumber>.self, data).data
        return list.filter { $0.status == nil || $0.status == "active" }
    }

    /// list-assistants: `GET /v2/ai/assistants`.
    func assistants() async throws -> [samplehostAssistant] {
        try decode(DataList<samplehostAssistant>.self, try await send("GET", ["ai", "assistants"])).data
    }

    /// create-an-assistant: `POST /v2/ai/assistants` with the two required fields (`name`, `instructions`; samplehost picks
    /// the default model) and an `Idempotency-Key`, so a retried tap never makes a second one. Answers the Assistant.
    func createAssistant(idempotencyKey: String) async throws -> samplehostAssistant {
        let body: [String: Any] = ["name": PhoneAskOwner.assistantName, "instructions": PhoneAskOwner.baseInstructions]
        let data = try await send("POST", ["ai", "assistants"], body: try JSONSerialization.data(withJSONObject: body),
                                  headers: ["Idempotency-Key": idempotencyKey])
        if let wrapped = try? JSONDecoder().decode(DataOne<samplehostAssistant>.self, from: data) { return wrapped.data }
        return try decode(samplehostAssistant.self, data)
    }

    /// dial: `POST /v2/calls` with `connection_id`, `from`, `to`, `timeout_secs`, `time_limit_secs`, `command_id` and
    /// `assistant` (CallAssistantRequest: `id`, `instructions`, `tools`). Answers `data.call_control_id`.
    func dial(_ request: PhoneDialRequest) async throws -> String {
        let body: [String: Any] = [
            "connection_id": request.connectionID,
            "from": request.from,
            "to": request.to,
            "timeout_secs": PhoneLimits.ringSeconds,
            "time_limit_secs": PhoneLimits.callSeconds,
            "command_id": request.commandID,
            "assistant": [
                "id": request.assistantID,
                "instructions": PhoneAskOwner.instructions(purpose: request.purpose),
                "tools": PhoneAskOwner.tools,
            ] as [String: Any],
        ]
        let data = try await send("POST", ["calls"], body: try JSONSerialization.data(withJSONObject: body))
        return try decode(DataOne<DialResult>.self, data).data.call_control_id
    }

    /// list-conversations: `GET /v2/ai/conversations?metadata->call_control_id=eq.<id>&limit=1`. nil until samplehost has
    /// made the call's conversation (after pickup).
    func conversationID(callControlID: String) async throws -> String? {
        let data = try await send("GET", ["ai", "conversations"],
                                  query: [("metadata->call_control_id", "eq." + callControlID), ("limit", "1")])
        return try decode(DataList<ConversationRow>.self, data).data.first?.id
    }

    /// get-conversation-messages: `GET /v2/ai/conversations/{id}/messages?page[size]=100`.
    func messages(conversationID: String) async throws -> [samplehostMessage] {
        let data = try await send("GET", ["ai", "conversations", conversationID, "messages"], query: [("page[size]", "100")])
        return try decode(DataList<samplehostMessage>.self, data).data
    }

    /// add-messages-to-ai-assistant: `POST /v2/calls/{id}/actions/ai_assistant_add_messages` with a `tool` message
    /// (`tool_call_id`, `content`) and a `system` message, `trigger_response: true` and `command_id`. The system
    /// message is there because GPT Live assistants never receive injected `tool` records (same reference).
    func deliverAnswer(callControlID: String, toolCallID: String, question: String, answer: String, commandID: String) async throws {
        let body: [String: Any] = [
            "messages": [
                ["role": "tool", "tool_call_id": toolCallID,
                 "content": PhoneAskOwner.toolAnswer(answer, toolCallID: toolCallID)],
                ["role": "system",
                 "content": "\(PhoneAskOwner.answerPrefix) your question \"\(question)\": \(answer). Tell the person now, then continue."],
            ],
            "trigger_response": true,
            "command_id": commandID,
        ]
        _ = try await send("POST", ["calls", callControlID, "actions", "ai_assistant_add_messages"],
                           body: try JSONSerialization.data(withJSONObject: body))
    }

    /// hangup-call: `POST /v2/calls/{id}/actions/hangup` with `command_id` (samplehost ignores a repeat). An already
    /// ended call (error 90018) counts as done.
    func hangup(callControlID: String, commandID: String) async throws {
        do {
            _ = try await send("POST", ["calls", callControlID, "actions", "hangup"],
                               body: try JSONSerialization.data(withJSONObject: ["command_id": commandID]))
        } catch samplehostError.callEnded { }
    }

    /// retrieve-a-call-status: `GET /v2/calls/{id}` → `data.is_alive`. nil when samplehost no longer knows the call (404).
    func isAlive(callControlID: String) async throws -> Bool? {
        do {
            return try decode(DataOne<CallStatus>.self, try await send("GET", ["calls", callControlID])).data.is_alive
        } catch samplehostError.unexpected(404) { return nil }
    }

    // MARK: Transport

    /// Builds `base/segments…?query` with every segment and query part strictly percent-encoded.
    func url(_ segments: [String], query: [(String, String)] = []) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.percentEncodedPath.hasSuffix("/") ? String(parts.percentEncodedPath.dropLast()) : parts.percentEncodedPath
        parts.percentEncodedPath = path + "/" + segments.map(Self.escape).joined(separator: "/")
        parts.percentEncodedQuery = query.isEmpty ? nil : query.map { Self.escape($0.0) + "=" + Self.escape($0.1) }.joined(separator: "&")
        return parts.url
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    private func send(_ method: String, _ segments: [String], query: [(String, String)] = [], body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> Data {
        guard let url = url(segments, query: query), samplehostEndpoint.allowed(url, base: base) else { throw samplehostError.refusedURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw samplehostError.network }
        guard let http = response as? HTTPURLResponse else { throw samplehostError.network }
        if (200..<300).contains(http.statusCode) { return data }
        throw failure(status: http.statusCode, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw samplehostError.unexpected(200) }
    }

    /// samplehost's error body: `{"errors":[{"code","title","detail"}]}` (Call Control, Numbers) or FastAPI's
    /// `{"detail":[{"msg"}]}` / `{"detail":"…"}` (AI endpoints, HTTPValidationError).
    func failure(status: Int, _ data: Data) -> samplehostError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errors = object?["errors"] as? [[String: Any]] ?? []
        if errors.contains(where: { "\($0["code"] ?? "")" == "90018" }) { return .callEnded }
        if status == 401 || status == 403 { return .badKey }
        var words = errors.compactMap { ($0["detail"] as? String) ?? ($0["title"] as? String) }
        if words.isEmpty, let detail = object?["detail"] as? String { words = [detail] }
        if words.isEmpty, let details = object?["detail"] as? [[String: Any]] { words = details.compactMap { $0["msg"] as? String } }
        let text = redact(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "))
        if status == 404, text.isEmpty { return .unexpected(404) }
        guard !text.isEmpty else { return .unexpected(status) }
        return .provider(String(text.prefix(300)))
    }

    /// Removes the key from text samplehost sent back, should it ever be echoed.
    func redact(_ text: String) -> String {
        key.count >= 4 ? text.replacingOccurrences(of: key, with: "•••") : text
    }
}

private nonisolated final class samplehostNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Keychain

/// The owner's samplehost setup for one signed-in HQ account.
nonisolated struct PhoneSetup: Codable, Equatable, Sendable {
    var apiKey: String
    var fromNumber: String? = nil
    var connectionID: String? = nil
    var assistantID: String? = nil
    var assistantName: String? = nil

    var ready: Bool {
        [fromNumber, connectionID, assistantID].allSatisfy { !($0 ?? "").isEmpty }
    }
}

/// One Keychain item per HQ account (`kSecClassGenericPassword`, `AfterFirstUnlockThisDeviceOnly`, never synced).
/// The item's account is a hash of the HQ account's id, so another sign-in never reads this one's key.
nonisolated struct PhoneKeyStore: Sendable {
    let service: String
    static let app = PhoneKeyStore(service: AppIdentity.current.keychainService + ".samplehost")

    func itemAccount(_ hqAccountID: String) -> String {
        "samplehost-" + SHA256.hash(data: Data(hqAccountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func query(_ hqAccountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: itemAccount(hqAccountID), kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func load(for hqAccountID: String) -> PhoneSetup? {
        var q = query(hqAccountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let setup = try? JSONDecoder().decode(PhoneSetup.self, from: data), !setup.apiKey.isEmpty else { return nil }
        return setup
    }

    func save(_ setup: PhoneSetup, for hqAccountID: String) throws {
        let data = try JSONEncoder().encode(setup)
        SecItemDelete(query(hqAccountID) as CFDictionary)
        var add = query(hqAccountID)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PhoneKeyStoreError.keychain(status) }
    }

    func delete(for hqAccountID: String) {
        SecItemDelete(query(hqAccountID) as CFDictionary)
    }

    /// Every account's item (DEBUG `-HQDebugResetAccounts`, tests).
    func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

nonisolated enum PhoneKeyStoreError: Error, Equatable { case keychain(OSStatus) }
