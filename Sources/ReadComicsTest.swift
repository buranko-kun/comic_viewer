import Foundation

/// Headless test: `ComicViewer --readcomicstest` exercises the ReadComicsOnline connector's pure
/// parsers against embedded HTML fixtures (no network), plus the shared search ranking and A–Z
/// index. Prints each check and exits non-zero if any fail — these parsers have historically been
/// the connector's most fragile part (entity decoding, lettered "TPB" chapters, hashed cover files),
/// so they're worth locking down deterministically.
enum ReadComicsTest {
    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--readcomicstest") else { return }
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "✓" : "✗ FAIL") \(name)")
            if !cond { failures += 1 }
        }

        // MARK: entity decoding
        check("decode &#039; → '", ReadComicsParser.decodeEntities("Zorro&#039;s Legacy") == "Zorro's Legacy")
        check("decode &amp;", ReadComicsParser.decodeEntities("Hack &amp; Slash") == "Hack & Slash")
        check("decode hex &#x27;", ReadComicsParser.decodeEntities("It&#x27;s") == "It's")
        check("decode leaves plain text", ReadComicsParser.decodeEntities("Spawn (1992)") == "Spawn (1992)")

        // MARK: search ranking (separator-insensitive)
        let nq = SearchRank.normalize("avengers armageddon")
        check("normalize collapses punctuation",
              SearchRank.normalize("Avengers: Armageddon") == nq)
        check("matches across ':' separator",
              SearchRank.matches("Avengers: Armageddon", normalizedQuery: nq))
        check("matches across ' - ' separator",
              SearchRank.matches("Avengers - Armageddon", normalizedQuery: nq))
        // "thor" should rank a whole-word title above a mere substring ("Authority").
        let thor = SearchRank.normalize("thor")
        check("exact/word title outranks substring",
              SearchRank.score("Thor", normalizedQuery: thor)
              > SearchRank.score("The Authority", normalizedQuery: thor))
        check("non-match scores as no-hit path",
              !SearchRank.matches("Batman", normalizedQuery: thor))

        // MARK: A–Z bucketing / index ("#" for non-letters, in list order)
        check("bucket letter", AZLetter.bucket("Spawn") == "S")
        check("bucket digit → #", AZLetter.bucket("100 Bullets") == "#")
        struct Row: Identifiable { let id: String; let title: String }
        let rows = [Row(id: "a", title: "100 Bullets"), Row(id: "b", title: "Aquaman"),
                    Row(id: "c", title: "Azrael"), Row(id: "d", title: "Batman")]
        let idx = AZLetter.index(rows, id: \.id, title: \.title)
        check("index buckets in list order (# first)",
              idx.map(\.letter) == ["#", "A", "B"])
        check("index points at first item per bucket",
              idx.first?.id == "a" && idx.first(where: { $0.letter == "B" })?.id == "d")

        // MARK: parseSeries — numeric chapters, excludes Read First/Last buttons
        let seriesURL = URL(string: "https://readcomicsonline.ru/comic/spawn-1992")!
        let seriesHTML = """
        <meta property="og:title" content="Spawn (1992) — Read Comics Online"/>
        <meta property="og:image" content="https://cdn.readcomicsonline.ru/uploads/manga/spawn-1992/cover/cover.jpg"/>
        <a href="https://readcomicsonline.ru/comic/spawn-1992/1">Read First</a>
        <a href="https://readcomicsonline.ru/comic/spawn-1992/3">Read Last</a>
        <a href="https://readcomicsonline.ru/comic/spawn-1992/1">Spawn (1992) #1</a>
        <a href="https://readcomicsonline.ru/comic/spawn-1992/2">Spawn (1992) #2</a>
        <a href="https://readcomicsonline.ru/comic/spawn-1992/3">Spawn (1992) #3</a>
        """
        let series = ReadComicsParser.parseSeries(seriesHTML, pageURL: seriesURL)
        check("series title strips suffix", series.title == "Spawn (1992)")
        check("series cover parsed", series.coverURL != nil)
        check("series has 3 chapters (buttons deduped, not extra)", series.chapters.count == 3)
        check("chapters numeric-ordered 1..3", series.chapters.map(\.segment) == ["1", "2", "3"])
        check("chapter label is #N", series.chapters.first?.label == "#1")

        // MARK: parseSeries — collected edition, lettered "TPB" segment
        let tpbURL = URL(string: "https://readcomicsonline.ru/comic/spiderman-the-complete-frank-miller-2002")!
        let tpbHTML = """
        <meta property="og:title" content="Spider-Man: The Complete Frank Miller (2002) — Read Comics Online"/>
        <meta property="og:image" content="https://cdn.readcomicsonline.ru/uploads/manga/spiderman-the-complete-frank-miller-2002/cover/cover.jpg"/>
        <a href="https://readcomicsonline.ru/comic/spiderman-the-complete-frank-miller-2002/TPB">Read First</a>
        <a href="https://readcomicsonline.ru/comic/spiderman-the-complete-frank-miller-2002/TPB">Spider-Man: The Complete Frank Miller (2002) #TPB</a>
        """
        let tpb = ReadComicsParser.parseSeries(tpbHTML, pageURL: tpbURL)
        check("TPB series found 1 chapter", tpb.chapters.count == 1)
        check("TPB segment is lettered", tpb.chapters.first?.segment == "TPB")
        check("TPB has no numeric value", tpb.chapters.first?.number == nil)
        check("TPB label is the segment", tpb.chapters.first?.label == "TPB")

        // MARK: parseSeries — fallback when no row carries "#"
        let oneShotURL = URL(string: "https://readcomicsonline.ru/comic/some-one-shot-2020")!
        let oneShotHTML = """
        <meta property="og:title" content="Some One-Shot (2020)"/>
        <a href="https://readcomicsonline.ru/comic/some-one-shot-2020/1">Read Now</a>
        """
        let oneShot = ReadComicsParser.parseSeries(oneShotHTML, pageURL: oneShotURL)
        check("no-# fallback still finds the chapter", oneShot.chapters.count == 1)

        // MARK: parseChapterPages — dedup + natural sort of CDN image URLs
        let chapterHTML = """
        <img src="https://cdn.readcomicsonline.ru/uploads/manga/spawn-1992/chapters/1/02.jpg">
        <img src="https://cdn.readcomicsonline.ru/uploads/manga/spawn-1992/chapters/1/01.jpg">
        <img src="https://cdn.readcomicsonline.ru/uploads/manga/spawn-1992/chapters/1/10.jpg">
        <img src="https://cdn.readcomicsonline.ru/uploads/manga/spawn-1992/chapters/1/02.jpg">
        """
        let pages = ReadComicsParser.parseChapterPages(chapterHTML)
        check("chapter pages deduped to 3", pages.count == 3)
        check("chapter pages natural-sorted (01,02,10)",
              pages.map { $0.lastPathComponent } == ["01.jpg", "02.jpg", "10.jpg"])

        // MARK: parseCatalog — cards (cover+slug+title) + pagination max
        let catalogHTML = """
        <div class="card">
          <img src="https://cdn.readcomicsonline.ru/uploads/manga/10-years-to-death-2021/cover/c.jpg" alt="10 Years to Death"/>
          <a href="https://readcomicsonline.ru/comic/10-years-to-death-2021" class="line-clamp-2 block">10 Years to Death (2021)</a>
        </div>
        <div class="card">
          <img src="https://cdn.readcomicsonline.ru/uploads/manga/zorro-2019/cover/c.jpg" alt="Zorro"/>
          <a href="https://readcomicsonline.ru/comic/zorro-2019" class="line-clamp-2 block">Zorro&#039;s Legacy (2019)</a>
        </div>
        <a href="https://readcomicsonline.ru/comic-list?page=2">2</a>
        <a href="https://readcomicsonline.ru/comic-list?page=159">Last</a>
        """
        let (entries, pageCount) = ReadComicsParser.parseCatalog(catalogHTML)
        check("catalog parsed 2 cards", entries.count == 2)
        check("catalog card slug + title", entries.first?.slug == "10-years-to-death-2021"
              && entries.first?.title == "10 Years to Death (2021)")
        check("catalog card cover parsed", entries.first?.coverURL != nil)
        check("catalog decodes entity in title", entries.last?.title == "Zorro's Legacy (2019)")
        check("catalog pagination max = 159", pageCount == 159)

        if failures == 0 {
            print("\nALL PASSED")
            return
        }
        print("\n\(failures) FAILED")
        exit(1)
    }
}
