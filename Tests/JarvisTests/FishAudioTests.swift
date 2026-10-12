import XCTest
@testable import Jarvis

final class FishAudioTests: XCTestCase {
    private let voiceID = "104c93410aa94f7fa679dab02a0153cd"

    func testLinksAndIDsResolveToSameVoice() throws {
        for input in [
            voiceID.uppercased(),
            " https://fish.audio/m/\(voiceID)/?source=share \n",
            "fish.audio/app/m/\(voiceID)",
            "https://www.fish.audio/app/text-to-speech/?modelId=\(voiceID)&language=it"
        ] {
            XCTAssertEqual(try FishAudio.voiceInput(input), .reference(voiceID), input)
        }
        XCTAssertEqual(try FishAudio.voiceInput("  Goku Paolo Torrisi  "), .search("Goku Paolo Torrisi"))
        XCTAssertEqual(try FishAudio.voiceInput(" "), .search(""))
    }

    func testInvalidLinksNeverBecomeSearchesOrRequestsToPastedHost() {
        for input in [
            "https://fish.audio.evil.example/m/\(voiceID)",
            "https://evil.example/m/\(voiceID)",
            "http://fish.audio/m/\(voiceID)",
            "https://user:pass@fish.audio/m/\(voiceID)",
            "https://fish.audio:8443/m/\(voiceID)",
            "https://fish.audio/m/not-an-id",
            "https://fish.audio/app/text-to-speech/",
            "https://fish.audio/app/text-to-speech/?modelId=\(voiceID)&modelId=\(voiceID)",
            "https://fish.audio/other/\(voiceID)"
        ] {
            XCTAssertThrowsError(try FishAudio.voiceInput(input), input)
        }
    }

    func testSearchSupportsAllLanguagesAndPaginationWithoutChangingDictation() throws {
        let all = FishAudio.voiceSearchRequest(apiKey: "test", query: " Goku Paolo Torrisi ", language: nil, page: 2)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(all.url), resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.host, "api.fish.audio")
        XCTAssertEqual(components.path, "/model")
        XCTAssertEqual(items["title"], "Goku Paolo Torrisi")
        XCTAssertEqual(items["page_number"], "2")
        XCTAssertEqual(items["page_size"], "50")
        XCTAssertNil(items["language"])
        let italian = FishAudio.voiceSearchRequest(apiKey: "test", query: "", language: "it", page: 1)
        XCTAssertTrue(italian.url!.query!.contains("language=it"))
        XCTAssertFalse(italian.url!.query!.contains("title="))
    }

    func testVoiceLookupAndSearchExcludeUnusableModelsAndPreserveAuthor() throws {
        let object: [String: Any] = ["_id": voiceID, "title": "Goku Paolo Torrisi", "type": "tts", "state": "trained",
                                   "tags": ["male", "narration"], "languages": ["it"],
                                   "author": ["nickname": "Francesco Striano"]]
        let voice = try FishAudio.decodeVoice(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(voice.id, voiceID)
        XCTAssertEqual(voice.author, "Francesco Striano")
        XCTAssertEqual(voice.languages, ["it"])
        var unusable = object; unusable["state"] = "training"
        var conversion = object; conversion["type"] = "svc"
        var removed = object; removed["dmca_taken_down"] = true
        for invalid in [unusable, conversion, removed] {
            XCTAssertThrowsError(try FishAudio.decodeVoice(JSONSerialization.data(withJSONObject: invalid)))
        }
        let data = try JSONSerialization.data(withJSONObject: ["items": [object, unusable, conversion, removed], "has_more": true])
        let page = try FishAudio.decodeVoicePage(data, page: 1)
        XCTAssertEqual(page.voices, [voice])
        XCTAssertTrue(page.hasMore)
        let end = try FishAudio.decodeVoicePage(Data(#"{"items":[],"has_more":true}"#.utf8), page: 2)
        XCTAssertFalse(end.hasMore)
        XCTAssertThrowsError(try FishAudio.decodeVoicePage(Data(#"{"error":"bad response"}"#.utf8), page: 1))
    }

    func testLookupErrorsExplainAccountOrMissingVoice() {
        XCTAssertTrue(FishAudio.voiceErrorMessage(FishAudio.APIError(status: 403, body: "private")).contains("chiave API"))
        XCTAssertTrue(FishAudio.voiceErrorMessage(FishAudio.APIError(status: 404, body: "missing")).contains("non trovata"))
    }
}
