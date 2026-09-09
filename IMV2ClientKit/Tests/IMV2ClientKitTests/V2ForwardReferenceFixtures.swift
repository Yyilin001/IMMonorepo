import IMV2Core

func testForwardReference(_ messageID: MessageID) throws -> V2ForwardMessageReference {
    .init(roomID: try .init("00000000-0000-0000-0000-00000000ff00"), messageID: messageID, revision: try .init(1))
}
