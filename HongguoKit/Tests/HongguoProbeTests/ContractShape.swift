// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoCore

/// Value-free JSON shape extractor and drift checker for upstream protocol contracts.
/// Only paths and JSON types are recorded, never URLs, identifiers, tokens, or key material.
///
/// Path conventions:
/// - `.` descends into object keys (e.g. `data.video_list`)
/// - `[]` descends into array elements
/// - `{}` descends into an embedded JSON object string (such as `video_model` or `lynx_data`)
enum ContractShape {
    struct Field: Hashable, Comparable, Sendable {
        let path: String
        let type: String

        static func < (lhs: Field, rhs: Field) -> Bool {
            lhs.path != rhs.path ? lhs.path < rhs.path : lhs.type < rhs.type
        }
    }

    struct Drift: Equatable, CustomStringConvertible, Sendable {
        let path: String
        let expected: String
        let actual: [String]

        var description: String {
            actual.isEmpty
                ? "\(path): missing (expected \(expected))"
                : "\(path): got \(actual.joined(separator: "|")), expected \(expected)"
        }
    }

    static func extract(from value: JSONValue) -> [Field] {
        var seen = Set<Field>()
        walk(path: "", value: value, into: &seen)
        return seen.sorted()
    }

    private static func walk(path: String, value: JSONValue, into seen: inout Set<Field>) {
        switch value {
        case .object(let dict):
            if dict.isEmpty {
                seen.insert(Field(path: path, type: "object"))
                return
            }
            for (key, child) in dict {
                let next = path.isEmpty ? key : "\(path).\(key)"
                walk(path: next, value: child, into: &seen)
            }
        case .array(let list):
            if list.isEmpty {
                seen.insert(Field(path: path, type: "array"))
                return
            }
            for child in list {
                walk(path: "\(path)[]", value: child, into: &seen)
            }
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let inner = try? JSONValue.parse(trimmed),
               inner.object != nil {
                walk(path: "\(path){}", value: inner, into: &seen)
            } else {
                seen.insert(Field(path: path, type: "string"))
            }
        case .int, .double:
            seen.insert(Field(path: path, type: "number"))
        case .bool:
            seen.insert(Field(path: path, type: "bool"))
        case .null:
            seen.insert(Field(path: path, type: "null"))
        }
    }

    /// Compares required contract fields against a live response shape.
    /// Extra live fields are ignored; `null` satisfies scalar types; non-empty subtrees satisfy
    /// `"object"` or `"array"` expectations.
    static func compare(required: [Field], live: [Field]) -> [Drift] {
        var byPath: [String: Set<String>] = [:]
        for field in live {
            byPath[field.path, default: []].insert(field.type)
        }
        var drifts: [Drift] = []
        for req in required {
            let got = byPath[req.path] ?? []
            if got.contains(req.type) { continue }
            if ["string", "number", "bool"].contains(req.type), got.contains("null") { continue }
            if (req.type == "object" || req.type == "array"),
               live.contains(where: {
                   $0.path.hasPrefix(req.path + ".")
                   || $0.path.hasPrefix(req.path + "[]")
                   || $0.path.hasPrefix(req.path + "{}")
               }) {
                continue
            }
            drifts.append(Drift(path: req.path, expected: req.type, actual: got.sorted()))
        }
        return drifts
    }
}

final class ContractShapeTests: XCTestCase {
    func testExtractsNestedAndEmbeddedJSONShapesWithoutValues() throws {
        let sample = try JSONValue.parse("""
        {
          "code": 0,
          "data": {
            "video_model": "{\\"video_id\\":\\"secret\\",\\"video_list\\":[{\\"main_url\\":\\"https://a.invalid/1.mp4\\",\\"vwidth\\":1080}]}"
          }
        }
        """)
        let shape = ContractShape.extract(from: sample)
        let required: [ContractShape.Field] = [
            .init(path: "code", type: "number"),
            .init(path: "data.video_model{}.video_id", type: "string"),
            .init(path: "data.video_model{}.video_list[].main_url", type: "string"),
            .init(path: "data.video_model{}.video_list[].vwidth", type: "number"),
        ]
        XCTAssertEqual(ContractShape.compare(required: required, live: shape), [])
    }

    func testDetectsMissingAndTypeChangedFields() throws {
        let live = ContractShape.extract(from: try JSONValue.parse("""
        {"code": "0", "data": {"items": []}}
        """))
        let required: [ContractShape.Field] = [
            .init(path: "code", type: "number"),
            .init(path: "data.items", type: "array"),
            .init(path: "data.next_cursor", type: "string"),
        ]
        let drifts = ContractShape.compare(required: required, live: live)
        XCTAssertEqual(drifts.count, 2)
        XCTAssertEqual(drifts[0].path, "code")
        XCTAssertEqual(drifts[0].actual, ["string"])
        XCTAssertEqual(drifts[1].path, "data.next_cursor")
        XCTAssertEqual(drifts[1].actual, [])
    }
}

/// Opt-in live contract drift check (`HONGGUO_LIVE=1 swift test --filter ContractDriftLiveTests`).
/// Verifies key field paths and JSON types across core upstream endpoints without printing values.
final class ContractDriftLiveTests: XCTestCase {
    func testCoreEndpointContractsLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_LIVE"] == "1", "set HONGGUO_LIVE=1 to run")
        let transport = AppTransport(http: .shared)
        let identity = try await PersistentAppDevice.shared.get(transport: transport)
        let dToken = await PersistentAppDevice.shared.dTokenHeaders()

        var allDrifts: [String] = []
        func assertContract(_ name: String, payload: JSONValue, required: [(String, String)]) {
            let live = ContractShape.extract(from: payload)
            let req = required.map { ContractShape.Field(path: $0.0, type: $0.1) }
            let drifts = ContractShape.compare(required: req, live: live)
            if !drifts.isEmpty {
                allDrifts.append("\(name): " + drifts.map(\.description).joined(separator: "; "))
            }
        }

        // 1. Search cues
        let cuePayload = try await AppBookMallAccess.tab(
            values: [("cue_type", "1"), ("limit", "5"), ("search_source", "1"), ("tab_name", "feed")],
            host: DiscoveryAccess.defaultHost,
            path: "/reading/bookapi/search/cue/v1/",
            timeout: 8
        )
        assertContract("search/cue/v1", payload: cuePayload, required: [
            ("code", "number"),
            ("data_v1[].text", "string"),
        ])

        // 2. Search -> Detail -> Playback V5 (device_level=1)
        let searchPage = try await AppSearchService().search("家里家外")
        let sid = try XCTUnwrap(searchPage.results.first?.seriesId, "search returned no series")
        let detail = try await OfficialSeriesDetail.load(sid, force: true)
        let vid = try XCTUnwrap(detail.episodes.first?.vid, "detail returned no episode")

        let playReq = try AppSource.modelRequest(
            base: AppSource.playerAPI,
            payload: try AppSource.modelPayload(vids: [vid]),
            identity: identity
        )
        let playPayload = try await transport.requestJSON(
            playReq.url, method: "POST", headers: playReq.headers + dToken, body: playReq.body,
            deadline: Date().addingTimeInterval(10)
        )
        let videoEntry = playPayload["data"]["1004"][vid].isNull ? playPayload["data"][vid] : playPayload["data"]["1004"][vid]
        assertContract("multi_video_model/v1", payload: videoEntry, required: [
            ("video_model{}.video_id", "string"),
            ("video_model{}.video_duration", "number"),
            ("video_model{}.video_list", "object"),
        ])

        // 3. Series recommendations (plan/v)
        let recPayload = try await AppBookMallAccess.tab(
            values: [("scene", "10"), ("from", "select_panel_recommend"), ("book_id", sid), ("session_uuid", AppCrypto.uuid())],
            host: DiscoveryAccess.defaultHost,
            path: "/reading/bookapi/plan/v/",
            timeout: 8
        )
        assertContract("plan/v(select_panel_recommend)", payload: recPayload, required: [
            ("code", "number"),
            ("data[].show_type", "number"),
        ])

        XCTAssertEqual(allDrifts, [], "Contract drift detected:\n" + allDrifts.joined(separator: "\n"))
    }
}
