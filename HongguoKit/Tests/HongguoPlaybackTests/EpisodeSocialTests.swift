import XCTest
@testable import HongguoCore

/// The fixtures have the shape of the official app's replies (series detail, book_pack_fields on
/// inner_feed_detail, the comment list with the review page's values), cut down to the fields the
/// parsers read. Every id, name and text in them is made up.
final class EpisodeSocialTests: XCTestCase {
    static let sid = "7000000000000000001"

    static let officialDetail = #"""
    {"code":0,"data":{"video_detail_data":{"7000000000000000001":{"video_data":{
      "series_id_str":"7000000000000000001","series_title":"示例剧","series_intro":"示例简介","episode_cnt":2,
      "followed_cnt":24009,"record_info":{"record_number":"App备案号"},
      "celebrities":[{"nickname":"示例演员","sub_title":"饰 主角","role_name":"主角","avatar":"http://example.com/p.jpg","celebrity_id":"9001","intro":" 示例演员简介 ","schema":"sslocal://guest_profile?uid=1000000000000001"},
                     {"nickname":"示例配角","sub_title":"","role_name":"配角","celebrity_id":9002},
                     {"nickname":"示例演员","sub_title":"饰 主角","celebrity_id":"9001"},
                     {"nickname":"","sub_title":"无名"}],
      "category_schema":"[{\"name\":\"都市\",\"schema\":\"sslocal://x\"},{\"name\":\"逆袭\"},{\"name\":\"都市\"},{\"name\":\" \"}]",
      "video_list":[{"vid":"7000000000000000011","vid_index":1,"digged_count":4705},
                    {"vid":"7000000000000000012","vid_index":2}]}}}}}
    """#

    static let packReply = #"""
    {"code":0,"message":"","data":{"7000000000000000001":{
      "action_info":{"digg_cnt":"88000","followed_cnt":24010},
      "base_info":{"publish_time":1786809814},
      "stat_info":{"hot_score_data":{"Score":52630687,"Text":"5263万热度"}}}}}
    """#

    static let reviewReply = #"""
    {"code":0,"message":"success","data":{
      "extra":{"credibility_score":"9.0","credibility_score_count":23973},
      "common_list_info":{"total":786,"cursor":"10","has_more":true},
      "data_list":[
        {"comment":{"comment_id":"8001","expand":{"score":"10"},"stat":{"digg_count":246,"reply_count":14},
          "common":{"create_timestamp":1794000000,"content":{"text":"很好看"},
            "user_info":{"base_info":{"user_name":"示例用户甲","user_avatar":"http://example.com/a.jpg"}}}}},
        {"comment":{"comment_id":"8002","expand":{"score":"0"},
          "common":{"create_timestamp":1794000100000,"content":{"text":"一般"},
            "user_info":{"base_info":{"user_name":"示例用户乙","expand_user_avatar":"https://example.com/b.jpg"}}}}},
        {"comment":{"comment_id":"8001","expand":{"score":"10"},
          "common":{"content":{"text":"很好看"},"user_info":{"base_info":{"user_name":"示例用户甲"}}}}},
        {"comment":{"comment_id":"8003","common":{"content":{"text":"   "}}}}]}}
    """#

    func testReviewListGivesScoreCountsAndScoredReviews() throws {
        let reviews = try OfficialSeriesReviews.parse(try JSONValue.parse(Self.reviewReply))
        XCTAssertEqual(reviews.rating, 9.0)
        XCTAssertEqual(reviews.ratingCount, 23_973)
        XCTAssertEqual(reviews.page.total, 786)
        XCTAssertEqual(reviews.page.cursor, "10")
        XCTAssertTrue(reviews.page.hasMore)
        let list = reviews.page.comments
        XCTAssertEqual(list.map(\.content), ["很好看", "一般"], "duplicates and blank reviews are dropped")
        XCTAssertEqual(list.map(\.rating), [10, nil], "a score outside 1...10 is treated as no score")
        XCTAssertEqual(list[0].likes, 246)
        XCTAssertEqual(list[0].replyCount, 14)
        XCTAssertEqual(list[1].replyCount, 0)
        XCTAssertEqual(list[0].avatar, "https://example.com/a.jpg", "http pictures are requested over https")
        XCTAssertEqual(list[1].avatar, "https://example.com/b.jpg")
        XCTAssertEqual(list[0].createdAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(list[1].createdAt, Date(timeIntervalSince1970: 1_794_000_100), "millisecond times are accepted")

        let rejected = try JSONValue.parse(#"{"code":103001,"message":"参数错误"}"#)
        XCTAssertThrowsError(try OfficialSeriesReviews.parse(rejected))
        let unrated = try OfficialSeriesReviews.parse(try JSONValue.parse(#"{"code":0,"data":{"extra":{"credibility_score":-1,"credibility_score_count":-1},"data_list":[]}}"#))
        XCTAssertNil(unrated.rating, "-1 means not rated yet")
        XCTAssertNil(unrated.ratingCount)
        XCTAssertFalse(unrated.page.hasMore)
    }

    func testPackReadGivesHeatAndFirstShown() throws {
        let stats = try OfficialSeriesStats.parse(try JSONValue.parse(Self.packReply), seriesId: Self.sid)
        XCTAssertEqual(stats.heatText, "5263万热度", "the heat keys are capitalised")
        XCTAssertEqual(stats.heatScore, 52_630_687)
        XCTAssertEqual(stats.publishedAt, Date(timeIntervalSince1970: 1_786_809_814))

        XCTAssertThrowsError(try OfficialSeriesStats.parse(try JSONValue.parse(Self.packReply), seriesId: "7000000000000000002"),
                             "no entry for the asked series")
        let unpacked = try JSONValue.parse(#"{"code":200001,"message":"有字段不支持pack secondary_infos"}"#)
        XCTAssertThrowsError(try OfficialSeriesStats.parse(unpacked, seriesId: Self.sid))
    }

    func testDetailGivesCastAndTags() throws {
        let detail = try OfficialSeriesDetail.parse(try JSONValue.parse(Self.officialDetail), seriesId: Self.sid)
        XCTAssertEqual(detail.cast.map(\.name), ["示例演员", "示例配角"], "nameless and repeated entries are dropped")
        XCTAssertEqual(detail.cast.map(\.role), ["饰 主角", "配角"], "the role name stands in for an empty subtitle")
        XCTAssertEqual(detail.cast.map(\.id), ["9001", "9002"])
        XCTAssertEqual(detail.cast.first?.avatar, "https://example.com/p.jpg")
        XCTAssertEqual(detail.cast.map(\.intro), ["示例演员简介", ""])
        XCTAssertEqual(detail.cast.map(\.profileUserId), ["1000000000000001", ""], "the home page account comes from the schema")
        XCTAssertEqual(EpisodeSocialService.profileUserId("sslocal://guest_profile?uid=12345678&enter_from_type=0"), "12345678")
        XCTAssertEqual(EpisodeSocialService.profileUserId("sslocal://profile?uid=12345678"), "")
        XCTAssertEqual(EpisodeSocialService.profileUserId("sslocal://guest_profile?uid=abc"), "")
        XCTAssertEqual(detail.tags, ["都市", "逆袭"], "the JSON string is read, repeats and blanks dropped")
        XCTAssertEqual(OfficialSeriesDetail.tags(try JSONValue.parse(#"["悬疑",{"category_name":"复仇"}]"#)), ["悬疑", "复仇"])
    }

    func testEpisodePanelAndReviewsTakeEverythingFromTheApp() throws {
        let detail = try OfficialSeriesDetail.parse(try JSONValue.parse(Self.officialDetail), seriesId: Self.sid)
        let stats = try OfficialSeriesStats.parse(try JSONValue.parse(Self.packReply), seriesId: Self.sid)
        let page = EpisodeSocialService.CommentPage(comments: [], total: 31, cursor: "20", hasMore: true)
        let social = EpisodeSocialService.social(seriesId: Self.sid, vid: "7000000000000000011", detail: detail, stats: stats, comments: page)
        XCTAssertEqual(social.title, "示例剧")
        XCTAssertEqual(social.intro, "示例简介")
        XCTAssertEqual(social.episodeCount, 2)
        XCTAssertEqual(social.episodeLikes, 4_705)
        XCTAssertEqual(social.favoriteCount, 24_009)
        XCTAssertEqual(social.commentTotal, 31, "the comment count is the App comment API's")
        XCTAssertEqual(social.cast.map(\.name), ["示例演员", "示例配角"])
        XCTAssertEqual(social.tags, ["都市", "逆袭"])
        XCTAssertEqual(social.firstShown, Date(timeIntervalSince1970: 1_786_809_814))
        XCTAssertTrue(social.hasMoreComments)

        let second = EpisodeSocialService.social(seriesId: Self.sid, vid: "7000000000000000012", detail: detail, stats: nil, comments: nil)
        XCTAssertNil(second.episodeLikes, "an episode the detail gives no count for has none")
        XCTAssertNil(second.firstShown)
        XCTAssertEqual(second.favoriteCount, 24_009)

        let list = try OfficialSeriesReviews.parse(try JSONValue.parse(Self.reviewReply))
        let reviews = EpisodeSocialService.reviews(from: list, detail: detail, stats: stats)
        XCTAssertEqual(reviews.rating, 9.0)
        XCTAssertEqual(reviews.ratingCount, 23_973)
        XCTAssertEqual(reviews.reviewTotal, 786)
        XCTAssertEqual(reviews.heatText, "5263万热度")
        XCTAssertEqual(reviews.favoriteCount, 24_009, "the collect count is the detail's")
        XCTAssertEqual(reviews.recordNumber, "App备案号")
        XCTAssertEqual(reviews.cast.count, 2)
        XCTAssertEqual(reviews.nextCursor, "10")
        XCTAssertTrue(reviews.hasMoreReviews)

        let bare = EpisodeSocialService.reviews(from: list, detail: nil, stats: nil)
        XCTAssertEqual(bare.heatText, "")
        XCTAssertNil(bare.favoriteCount)
        XCTAssertEqual(bare.recordNumber, "")
        XCTAssertEqual(bare.rating, 9.0, "the score stands on its own")
    }

    func testReplyPageParsesCapitalCommonAndReplyToTarget() throws {
        let json = try JSONValue.parse(#"""
        {
          "comment_list_info": {"total": 222, "cursor": "5", "has_more": true},
          "reply_list": [
            {
              "reply_id": "9001",
              "reply_to_reply_id": "0",
              "reply_to_user_info": {"base_info": {"user_name": "楼主甲"}},
              "stat": {"digg_count": 12},
              "Common": {
                "create_timestamp": 1794000000,
                "content": {"text": "同感[捂脸]"},
                "user_info": {"base_info": {"user_name": "示例回复甲", "user_avatar": "http://example.com/r1.jpg"}}
              }
            },
            {
              "reply_id": "9002",
              "reply_to_reply_id": "9001",
              "reply_to_user_info": {"base_info": {"user_name": " 示例回复甲 "}},
              "stat": {"digg_count": "3"},
              "Common": {
                "create_timestamp": 1794000100000,
                "content": {"text": "不上了[笑哭]"},
                "user_info": {"base_info": {"user_name": "示例回复乙", "expand_user_avatar": "https://example.com/r2.jpg"}}
              }
            },
            {
              "reply_id": "9001",
              "Common": {
                "content": {"text": "重复"},
                "user_info": {"base_info": {"user_name": "示例回复甲"}}
              }
            },
            {
              "reply_id": "9003",
              "Common": {
                "content": {"text": "   "},
                "user_info": {"base_info": {"user_name": "空白回复"}}
              }
            }
          ]
        }
        """#)
        let page = EpisodeSocialService.replyPage(from: json)
        XCTAssertEqual(page.total, 222)
        XCTAssertEqual(page.cursor, "5")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.replies.map(\.id), ["9001", "9002"])
        XCTAssertEqual(page.replies[0].author, "示例回复甲")
        XCTAssertEqual(page.replies[0].avatar, "https://example.com/r1.jpg")
        XCTAssertEqual(page.replies[0].content, "同感[捂脸]")
        XCTAssertEqual(page.replies[0].likes, 12)
        XCTAssertEqual(page.replies[0].replyToAuthor, "", "direct reply to root comment must not show reply-to prefix")
        XCTAssertEqual(page.replies[0].createdAt, Date(timeIntervalSince1970: 1_794_000_000))

        XCTAssertEqual(page.replies[1].author, "示例回复乙")
        XCTAssertEqual(page.replies[1].avatar, "https://example.com/r2.jpg")
        XCTAssertEqual(page.replies[1].content, "不上了[笑哭]")
        XCTAssertEqual(page.replies[1].likes, 3)
        XCTAssertEqual(page.replies[1].replyToAuthor, "示例回复甲")
        XCTAssertEqual(page.replies[1].createdAt, Date(timeIntervalSince1970: 1_794_000_100))

        let empty = EpisodeSocialService.replyPage(from: try JSONValue.parse(#"{"comment_list_info":{"total":0,"cursor":"0","has_more":true},"reply_list":[]}"#))
        XCTAssertTrue(empty.replies.isEmpty)
        XCTAssertFalse(empty.hasMore, "empty reply_list stops pagination even if has_more is true")
    }

    func testPostCommentBodyMatchesOfficialSchema() {
        let body = EpisodeSocialService.postCommentBody(
            seriesId: Self.sid,
            vid: "7000000000000000011",
            text: "太爽了[微笑][笑哭]",
            offsetMs: 12_500
        )
        XCTAssertEqual(body["aid"] as? Int, 8662)
        XCTAssertEqual(body["commit_source"] as? Int, 10)
        XCTAssertEqual(body["group_id"] as? String, "7000000000000000011")
        XCTAssertEqual(body["group_type"] as? Int, 30)
        XCTAssertEqual(body["data_type"] as? Int, 4)
        XCTAssertEqual(body["comment_type"] as? Int, 0)
        XCTAssertEqual(body["text"] as? String, "太爽了[微笑][笑哭]")
        let biz = body["business_param"] as? [String: Any]
        XCTAssertEqual(biz?["book_id"] as? String, Self.sid)
        XCTAssertEqual(biz?["offset"] as? Int64, 12_500)

        let clamped = EpisodeSocialService.postCommentBody(seriesId: Self.sid, vid: "7000000000000000011", text: "ok", offsetMs: -50)
        XCTAssertEqual((clamped["business_param"] as? [String: Any])?["offset"] as? Int64, 0)
    }

    func testPostReplyBodyMatchesOfficialSchema() {
        let body = EpisodeSocialService.postReplyBody(
            seriesId: Self.sid, vid: "7000000000000000011", commentId: "88001", text: "同感", offsetMs: 3_000
        )
        XCTAssertEqual(body["aid"] as? Int, 8662)
        XCTAssertEqual(body["commit_source"] as? Int, 10)
        XCTAssertEqual(body["group_id"] as? String, "7000000000000000011")
        XCTAssertEqual(body["group_type"] as? Int, 30)
        XCTAssertEqual(body["reply_to_comment_id"] as? String, "88001")
        XCTAssertEqual(body["text"] as? String, "同感")
        XCTAssertNil(body["reply_to_replyid"])
        XCTAssertNil(body["parent_reply_id"])
        XCTAssertEqual((body["business_param"] as? [String: Any])?["book_id"] as? String, Self.sid)

        let nested = EpisodeSocialService.postReplyBody(
            seriesId: Self.sid, vid: "7000000000000000011", commentId: "88001", text: "对",
            replyToReplyId: "77002", replyToUserId: "123456"
        )
        XCTAssertEqual(nested["reply_to_replyid"] as? String, "77002")
        XCTAssertEqual(nested["parent_reply_id"] as? String, "77002")
        XCTAssertEqual(nested["reply_to_userid"] as? String, "123456")
    }

    func testParsePostedReplyFullMinimalAndErrors() throws {
        let full = try JSONValue.parse(#"""
        {"code":0,"data":{"reply":{"reply_id":"66001","stat":{"digg_count":0},
          "Common":{"create_timestamp":1794000500,"content":{"text":"说得对"},
            "user_info":{"base_info":{"user_name":"示例作者","user_avatar":"http://example.com/u.jpg"}}}}}}
        """#)
        let parsed = try EpisodeSocialService.parsePostedReply(full, fallbackText: "说得对", fallbackAuthor: "本地名")
        XCTAssertEqual(parsed.id, "66001")
        XCTAssertEqual(parsed.author, "示例作者")
        XCTAssertEqual(parsed.avatar, "https://example.com/u.jpg")

        let now = Date(timeIntervalSince1970: 1_794_000_600)
        let minimal = try JSONValue.parse(#"{"code":0,"data":{"reply":{"reply_id":"66002"}}}"#)
        let fallback = try EpisodeSocialService.parsePostedReply(minimal, fallbackText: "冲", fallbackAuthor: "本地用户", now: now)
        XCTAssertEqual(fallback.id, "66002")
        XCTAssertEqual(fallback.author, "本地用户")
        XCTAssertEqual(fallback.content, "冲")
        XCTAssertEqual(fallback.createdAt, now)

        var expired = false
        XCTAssertThrowsError(try EpisodeSocialService.parsePostedReply(
            try JSONValue.parse(#"{"code":103006}"#), fallbackText: "x", fallbackAuthor: "", onAuthExpired: { expired = true }))
        XCTAssertTrue(expired)
        XCTAssertThrowsError(try EpisodeSocialService.parsePostedReply(
            try JSONValue.parse(#"{"code":103099,"message":"内容包含敏感词"}"#), fallbackText: "x", fallbackAuthor: "")) { error in
            XCTAssertEqual((error as? HongguoError)?.message, "内容包含敏感词")
        }
    }

    func testParsePostedCommentFullMinimalAndErrors() throws {
        let full = try JSONValue.parse(#"""
        {
          "code": 0,
          "message": "success",
          "data": {
            "comment_info": {
              "comment_id": "99001",
              "stat": {"digg_count": 0, "reply_count": 0},
              "common": {
                "create_timestamp": 1794000500,
                "content": {"text": "好看[微笑]"},
                "user_info": {"base_info": {"user_name": "示例作者", "user_avatar": "http://example.com/u.jpg"}}
              }
            }
          }
        }
        """#)
        let parsed = try EpisodeSocialService.parsePostedComment(
            full, fallbackText: "好看[微笑]", fallbackAuthor: "本地名", fallbackAvatar: ""
        )
        XCTAssertEqual(parsed.id, "99001")
        XCTAssertEqual(parsed.author, "示例作者")
        XCTAssertEqual(parsed.avatar, "https://example.com/u.jpg")
        XCTAssertEqual(parsed.content, "好看[微笑]")
        XCTAssertEqual(parsed.createdAt, Date(timeIntervalSince1970: 1_794_000_500))

        let minimal = try JSONValue.parse(#"{"code":0,"data":{"comment_info":{"comment_id":"99002"}}}"#)
        let now = Date(timeIntervalSince1970: 1_794_000_600)
        let fallback = try EpisodeSocialService.parsePostedComment(
            minimal, fallbackText: "冲[赞]", fallbackAuthor: "本地用户", fallbackAvatar: "http://example.com/me.jpg", now: now
        )
        XCTAssertEqual(fallback.id, "99002")
        XCTAssertEqual(fallback.author, "本地用户")
        XCTAssertEqual(fallback.avatar, "https://example.com/me.jpg")
        XCTAssertEqual(fallback.content, "冲[赞]")
        XCTAssertEqual(fallback.createdAt, now)

        var expiredCalled = false
        let authExpired = try JSONValue.parse(#"{"code":103006,"message":"用户未登录"}"#)
        XCTAssertThrowsError(try EpisodeSocialService.parsePostedComment(
            authExpired, fallbackText: "x", fallbackAuthor: "", fallbackAvatar: "", onAuthExpired: { expiredCalled = true }
        ))
        XCTAssertTrue(expiredCalled)

        let failed = try JSONValue.parse(#"{"code":103099,"message":"内容包含敏感词"}"#)
        XCTAssertThrowsError(try EpisodeSocialService.parsePostedComment(
            failed, fallbackText: "x", fallbackAuthor: "", fallbackAvatar: ""
        )) { error in
            XCTAssertEqual((error as? HongguoError)?.message, "内容包含敏感词")
        }
    }

    func testPostCommentRejectsBlankAndInvalidInputs() async {
        do {
            _ = try await EpisodeSocialService.postComment(seriesId: "abc", vid: "7000000000000000011", text: "你好")
            XCTFail("expected invalid series id error")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .input)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        do {
            _ = try await EpisodeSocialService.postComment(seriesId: Self.sid, vid: "7000000000000000011", text: "   \n ")
            XCTFail("expected blank text error")
        } catch let error as HongguoError {
            XCTAssertEqual(error.kind, .input)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCommentImagesParsingUploadAndPostBody() throws {
        let img = EpisodeSocial.CommentImage(
            url: "https://p0-reading-private.snssdk.com/tos-cn-i-1yzifmftcy/demo.jpeg",
            width: 800,
            height: 600,
            format: "jpeg"
        )
        let body = EpisodeSocialService.postCommentBody(
            seriesId: Self.sid,
            vid: "7000000000000000011",
            text: "",
            images: [img],
            offsetMs: 4200
        )
        let imageData = body["image_data"] as? [[String: Any]]
        XCTAssertEqual(imageData?.count, 1)
        XCTAssertEqual(imageData?.first?["web_uri"] as? String, img.url)
        XCTAssertEqual(imageData?.first?["width"] as? Int, 800)
        XCTAssertEqual(imageData?.first?["height"] as? Int, 600)
        XCTAssertEqual(imageData?.first?["format"] as? String, "jpeg")

        let multipart = EpisodeSocialService.buildMultipartPictureBody(jpegData: Data([0xFF, 0xD8, 0xFF]), boundary: "TESTBOUNDARY")
        let multipartText = String(decoding: multipart, as: UTF8.self)
        XCTAssertTrue(multipartText.contains("name=\"picture\"; filename=\"temp.jpeg\""))
        XCTAssertTrue(multipartText.contains("Content-Type: image/jpeg"))

        let uploadJSON = try JSONValue.parse(#"{"code":0,"message":"SUCCESS","data":"http://p0-reading-private.snssdk.com/tos/img.jpeg"}"#)
        let uploaded = try EpisodeSocialService.parseUploadedImage(uploadJSON, width: 640, height: 480)
        XCTAssertEqual(uploaded.url, "https://p0-reading-private.snssdk.com/tos/img.jpeg")
        XCTAssertEqual(uploaded.width, 640)
        XCTAssertEqual(uploaded.height, 480)

        let imageOnlyComment = try JSONValue.parse(#"""
        {
          "comment_id": "99010",
          "common": {
            "content": {
              "text": "",
              "image_data_list": {
                "image_data": [{
                  "web_url": "http://img.example.com/full.jpeg",
                  "thumb_nails": [{"web_url": "http://img.example.com/thumb.jpeg"}],
                  "width": 1080,
                  "height": 1440,
                  "format": "jpeg"
                }]
              }
            },
            "create_timestamp": 1763600000,
            "user_info": {"base_info": {"user_name": "图评用户"}}
          },
          "stat": {"digg_count": 3, "reply_count": 0}
        }
        """#)
        let parsed = try XCTUnwrap(EpisodeSocialService.parseComment(imageOnlyComment))
        XCTAssertEqual(parsed.id, "99010")
        XCTAssertEqual(parsed.content, "")
        XCTAssertEqual(parsed.images.count, 1)
        XCTAssertEqual(parsed.images.first?.url, "https://img.example.com/full.jpeg")
        XCTAssertEqual(parsed.images.first?.thumbnailUrl, "https://img.example.com/thumb.jpeg")
        XCTAssertEqual(parsed.images.first?.width, 1080)
        XCTAssertEqual(parsed.images.first?.height, 1440)

        let identity = PlaybackIdentity(deviceId: "1234567890123456789", iid: "2234567890123456789", cdid: "cdid-1")
        let uploadURL = try XCTUnwrap(EpisodeSocialService.commentImageUploadURL(identity: identity))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(uploadURL.absoluteString.hasPrefix("https://reading.snssdk.com/reading/reader/upload/picture/?"))
        XCTAssertEqual(items["aid"], "8662")
        XCTAssertEqual(items["app_name"], "dragon_app")
        XCTAssertEqual(items["version_code"], "74532")
        XCTAssertEqual(items["device_id"], "1234567890123456789")
        XCTAssertEqual(items["iid"], "2234567890123456789")

        let fallbackURL = try XCTUnwrap(EpisodeSocialService.commentImageUploadURL(identity: nil))
        let fallbackItems = Dictionary(uniqueKeysWithValues: (URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fallbackItems["aid"], "8662")
        XCTAssertNil(fallbackItems["device_id"])
    }
}
