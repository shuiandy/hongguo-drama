import Foundation

/// Raw access to the two App catalogue endpoints the core's signer allows
/// (`AppLegacySigner.metadataPaths`): the category landing page and the ranking cell.
/// The core only exposes them wrapped as "new releases"; the iOS feed needs other filters
/// and its own paging, so this file (compiled into the HongguoCore module) passes the request
/// through unchanged. It adds no endpoint: any other path is still refused by the signer.
/// Both calls are read-only lists made with the persistent device.
public enum AppCatalogueAccess {
    /// POST /reading/distribution/category/landpage/v/ with a JSON body.
    public static func landpage(body: Data, timeout: TimeInterval = 8) async throws -> JSONValue {
        try await request(path: AppLegacySigner.metadataPaths[0], values: [], payload: Array(body), timeout: timeout)
    }

    /// GET /reading/bookapi/bookmall/cell/change/v with query values.
    public static func cellChange(values: [(String, String)], timeout: TimeInterval = 8) async throws -> JSONValue {
        try await request(path: AppLegacySigner.metadataPaths[1], values: values, payload: nil, timeout: timeout)
    }

    private static func request(path: String, values: [(String, String)], payload: [UInt8]?, timeout: TimeInterval) async throws -> JSONValue {
        let transport = AppTransport(http: .shared)
        do {
            let device = try await PersistentAppDevice.dataIdentity(transport: transport)
            let signed = try AppLegacySigner.shared.metadata(path: path, values: values, payload: payload,
                                                             identity: device.identity, dToken: device.dToken,
                                                             nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
            return try await transport.requestJSON(signed.url, method: payload == nil ? "GET" : "POST",
                                                   headers: signed.headers, body: payload,
                                                   deadline: Date().addingTimeInterval(timeout))
        } catch let error as AppSourceError {
            throw error.hongguoError
        }
    }
}
