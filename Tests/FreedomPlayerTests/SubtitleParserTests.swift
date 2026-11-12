import Testing
@testable import FreedomPlayer

struct SubtitleParserTests {

    @Test func srtParse() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        Hello, world!

        2
        00:00:03,000 --> 00:00:04,000
        Second cue
        wrapped on two lines
        """
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 2)
        #expect(abs(cues[0].start - 1.0) < 0.001)
        #expect(abs(cues[0].end - 2.5) < 0.001)
        #expect(cues[0].text == "Hello, world!")
        #expect(cues[1].text == "Second cue\nwrapped on two lines")
    }

    @Test func vttParse() {
        let vtt = """
        WEBVTT

        00:01.000 --> 00:03.000
        Hi

        01:05.500 --> 01:10.000
        Bye
        """
        let cues = SubtitleParser.parse(vtt)
        #expect(cues.count == 2)
        #expect(abs(cues[0].start - 1.0) < 0.001)
        #expect(abs(cues[1].start - 65.5) < 0.001)
        #expect(abs(cues[1].end - 70.0) < 0.001)
    }

    @Test func cuesSortedByStart() {
        let srt = """
        1
        00:00:10,000 --> 00:00:11,000
        late

        2
        00:00:02,000 --> 00:00:03,000
        early
        """
        let cues = SubtitleParser.parse(srt)
        #expect(cues.map(\.text) == ["early", "late"])
    }

    @Test func emptyAndMalformedInput() {
        #expect(SubtitleParser.parse("").isEmpty)
        #expect(SubtitleParser.parse("not a subtitle file").isEmpty)
        // 有时间轴但无文本的块应被跳过
        #expect(SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000").isEmpty)
    }

    @Test func crlfLineEndings() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nWorld\r\n"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 2)
        #expect(cues[1].text == "World")
    }
}
