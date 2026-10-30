using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>EPUB import (Swift: <c>EPUBImportTests</c>, same two books): an
/// AO3 download (calibre-style EPUB 2, deflated, an NCX whose chapters share a
/// file) and a plain EPUB 3 book (stored, a nav document, a cover page).</summary>
public sealed class EpubImportTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fanficly_epub_{Guid.NewGuid()}");

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void Ao3BookKeepsItsWorkIdTagsAndChapters()
    {
        var payload = EpubImport.Parse(Convert.FromBase64String(Ao3Epub));
        var s = payload.Summary;
        Assert.Equal(12345, s.Id);
        Assert.Equal("The Long Way Home", s.Title);
        Assert.Equal("Quill Writer", s.Author);
        Assert.Equal("quill", s.AuthorUsername);
        Assert.Equal("General Audiences", s.Rating);
        Assert.Equal(["No Archive Warnings Apply"], s.Warnings);
        Assert.Equal(["Original Work", "Some Fandom"], s.Fandoms);
        Assert.Equal(["A/B"], s.Relationships);
        Assert.Equal(["A", "B"], s.Characters);
        Assert.Equal(["Fluff", "Road Trips"], s.Freeforms);
        Assert.Equal("English", s.Language);
        Assert.Equal(1234, s.WordCount);
        Assert.Equal(3, s.TotalChapters);
        Assert.False(s.IsComplete);
        Assert.Equal(new DateTimeOffset(2024, 3, 4, 0, 0, 0, TimeSpan.Zero), s.UpdatedAt);
        Assert.Contains("Two friends drive home.", s.Summary);

        // The preface is the Library entry, not a chapter; the afterword's end
        // notes close the last chapter.
        Assert.Equal(2, payload.Chapters.Count);
        Assert.Equal(2, s.ChapterCount);
        var one = payload.Chapters[0];
        Assert.Equal((1, "Chapter 1: Hello", 678), (one.Index, one.Title, one.AoId));
        Assert.Contains("It was a dark and stormy night.", one.BodyHtml);
        Assert.Contains("They left at dawn.", one.BodyHtml);
        Assert.DoesNotContain("<img", one.BodyHtml);
        Assert.DoesNotContain("car broke down", one.BodyHtml);
        var two = payload.Chapters[1];
        Assert.Equal((2, "Chapter 2"), (two.Index, two.Title));
        // The self-closed anchor didn't swallow the rest of the sentence into a link.
        Assert.Contains("somewhere in Ohio.</p>", two.BodyHtml);
        Assert.DoesNotContain(">Chapter 2</h2>", two.BodyHtml);
        Assert.Contains("End notes: thanks for reading!", two.BodyHtml);
    }

    [Fact]
    public void PlainBookGetsAStableLocalIdAndOneChapterPerTocEntry()
    {
        var payload = EpubImport.Parse(Convert.FromBase64String(PlainEpub));
        var s = payload.Summary;
        Assert.True(s.Id < 0);
        Assert.True(EpubImport.IsLocalWork(s.Id));
        // The same id the Apple app gives it, so a library shared through one
        // sync folder keeps one entry per book.
        Assert.Equal(-1596378688, s.Id);
        Assert.Equal("A Plain Book", s.Title);
        Assert.Equal("Jane Doe", s.Author);
        Assert.Equal("fr", s.Language);
        Assert.Equal(["Essays"], s.Freeforms);
        Assert.Equal("<p>A short book.</p><p>In two parts.</p>", s.Summary);
        Assert.True(s.IsComplete);

        // The cover page comes before the first contents entry, so it's left out.
        Assert.Equal(["Part One", "Part Two"], payload.Chapters.Select(c => c.Title));
        Assert.Contains("First words here.", payload.Chapters[0].BodyHtml);
        Assert.DoesNotContain("x()", payload.Chapters[0].BodyHtml);
        Assert.Contains("Second &amp; last.", payload.Chapters[1].BodyHtml);
        Assert.All(payload.Chapters, c => Assert.Null(c.AoId));
        Assert.Equal(10, s.WordCount);
    }

    [Fact]
    public void NotAnEpubIsRefused()
    {
        var e = Assert.Throws<EpubImportException>(() => EpubImport.Parse("not a zip"u8.ToArray()));
        Assert.Equal("This file isn't an EPUB e-book.", e.Message);
    }

    [Fact]
    public void SelfClosingTagsAreSpelledOutExceptVoidOnes()
    {
        Assert.Equal("<title></title><br/><p>a<a id=\"x\"></a>b</p><img src=\"y\" />",
            EpubImport.ExpandSelfClosingTags("<title/><br/><p>a<a id=\"x\"/>b</p><img src=\"y\" />"));
    }

    [Fact]
    public void SavingAddsANewWorkWithItsFileAndKeepsAnExistingWorksDetails()
    {
        var oldFolder = WorkPersistence.LibraryFolder;
        WorkPersistence.LibraryFolder = Path.Combine(_dir, "library");
        try
        {
            using var store = LibraryStore.Open(Path.Combine(_dir, "library.sqlite"));
            var bytes = Convert.FromBase64String(Ao3Epub);
            var payload = EpubImport.Parse(bytes);

            var work = EpubImport.Save(payload, bytes, store);
            Assert.Equal(12345, work.Ao3Id);
            Assert.Equal(2, work.Chapters.Count);
            Assert.NotNull(WorkPersistence.EpubPath(12345));
            Assert.Empty(RestoreDownloadCenter.RedownloadCandidates(store));

            // Already in the Library with AO3's details: those stay, the text is replaced.
            work.Kudos = 99;
            work.Title = "Renamed On AO3";
            var again = EpubImport.Save(payload, bytes, store);
            Assert.Same(work, again);
            Assert.Equal((99, "Renamed On AO3"), (again.Kudos, again.Title));
            Assert.Equal(2, again.Chapters.Count);

            // A book that isn't on AO3 is never offered for download.
            var plainBytes = Convert.FromBase64String(PlainEpub);
            var plain = EpubImport.Save(EpubImport.Parse(plainBytes), plainBytes, store);
            File.Delete(WorkPersistence.EpubTargetPath(plain.Ao3Id));
            Assert.Empty(RestoreDownloadCenter.RedownloadCandidates(store));
            Assert.Empty(RestoreDownloadCenter.FolderDownloadCandidates([plain]));
        }
        finally
        {
            WorkPersistence.LibraryFolder = oldFolder;
        }
    }

    private const string Ao3Epub =
        "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" +
        "AAA=";

    private const string PlainEpub =
        "UEsDBBQAAAAAAAAAIQBvYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAAAAChtF5dHgvX" +
        "yd0AAADdAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWw8P3htbCB2ZXJzaW9uPSIxLjAiPz48Y29udGFpbmVyIHZlcnNpb249" +
        "IjEuMCIgeG1sbnM9InVybjpvYXNpczpuYW1lczp0YzpvcGVuZG9jdW1lbnQ6eG1sbnM6Y29udGFpbmVyIj48cm9vdGZpbGVzPjxy" +
        "b290ZmlsZSBmdWxsLXBhdGg9Ik9FQlBTL2NvbnRlbnQub3BmIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi9vZWJwcy1wYWNrYWdl" +
        "K3htbCIvPjwvcm9vdGZpbGVzPjwvY29udGFpbmVyPlBLAwQUAAAAAAChtF5d24NrymgDAABoAwAAEQAAAE9FQlBTL2NvbnRlbnQu" +
        "b3BmPD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHBhY2thZ2UgeG1sbnM9Imh0dHA6Ly93d3cuaWRwZi5v" +
        "cmcvMjAwNy9vcGYiIHZlcnNpb249IjMuMCIgdW5pcXVlLWlkZW50aWZpZXI9ImJvb2tpZCI+CjxtZXRhZGF0YSB4bWxuczpkYz0i" +
        "aHR0cDovL3B1cmwub3JnL2RjL2VsZW1lbnRzLzEuMS8iPjxkYzppZGVudGlmaWVyIGlkPSJib29raWQiPnVybjppc2JuOjk3ODAw" +
        "MDAwMDAwMDE8L2RjOmlkZW50aWZpZXI+CjxkYzp0aXRsZT5BIFBsYWluIEJvb2s8L2RjOnRpdGxlPjxkYzpjcmVhdG9yPkphbmUg" +
        "RG9lPC9kYzpjcmVhdG9yPjxkYzpsYW5ndWFnZT5mcjwvZGM6bGFuZ3VhZ2U+CjxkYzpkZXNjcmlwdGlvbj5BIHNob3J0IGJvb2su" +
        "CkluIHR3byBwYXJ0cy48L2RjOmRlc2NyaXB0aW9uPjxkYzpzdWJqZWN0PkVzc2F5czwvZGM6c3ViamVjdD48L21ldGFkYXRhPgo8" +
        "bWFuaWZlc3Q+PGl0ZW0gaWQ9Im5hdiIgaHJlZj0ibmF2LnhodG1sIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi94aHRtbCt4bWwi" +
        "IHByb3BlcnRpZXM9Im5hdiIvPgo8aXRlbSBpZD0iY292ZXIiIGhyZWY9InRleHQvY292ZXIueGh0bWwiIG1lZGlhLXR5cGU9ImFw" +
        "cGxpY2F0aW9uL3hodG1sK3htbCIvPgo8aXRlbSBpZD0iYzEiIGhyZWY9InRleHQvb25lJTIwYS54aHRtbCIgbWVkaWEtdHlwZT0i" +
        "YXBwbGljYXRpb24veGh0bWwreG1sIi8+CjxpdGVtIGlkPSJjMiIgaHJlZj0idGV4dC90d28ueGh0bWwiIG1lZGlhLXR5cGU9ImFw" +
        "cGxpY2F0aW9uL3hodG1sK3htbCIvPjwvbWFuaWZlc3Q+CjxzcGluZT48aXRlbXJlZiBpZHJlZj0iY292ZXIiLz48aXRlbXJlZiBp" +
        "ZHJlZj0iYzEiLz48aXRlbXJlZiBpZHJlZj0iYzIiLz48L3NwaW5lPjwvcGFja2FnZT5QSwMEFAAAAAAAobReXTyFfgyQAQAAkAEA" +
        "AA8AAABPRUJQUy9uYXYueGh0bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCI/PjxodG1sIHhtbG5zPSJodHRw" +
        "Oi8vd3d3LnczLm9yZy8xOTk5L3hodG1sIiB4bWxuczplcHViPSJodHRwOi8vd3d3LmlkcGYub3JnLzIwMDcvb3BzIj48aGVhZD48" +
        "dGl0bGU+Q29udGVudHM8L3RpdGxlPjwvaGVhZD48Ym9keT4KPG5hdiBlcHViOnR5cGU9ImxhbmRtYXJrcyI+PG9sPjxsaT48YSBo" +
        "cmVmPSJ0ZXh0L2NvdmVyLnhodG1sIj5Db3ZlcjwvYT48L2xpPjwvb2w+PC9uYXY+CjxuYXYgZXB1Yjp0eXBlPSJ0b2MiPjxvbD48" +
        "bGk+PGEgaHJlZj0idGV4dC9vbmUlMjBhLnhodG1sIj5QYXJ0IE9uZTwvYT48L2xpPjxsaT48YSBocmVmPSJ0ZXh0L3R3by54aHRt" +
        "bCI+UGFydCBUd288L2E+PC9saT48L29sPjwvbmF2PjwvYm9keT48L2h0bWw+UEsDBBQAAAAAAKG0Xl3tvMorgAAAAIAAAAAWAAAA" +
        "T0VCUFMvdGV4dC9jb3Zlci54aHRtbDxodG1sIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5L3hodG1sIj48aGVhZD48dGl0" +
        "bGU+Q292ZXI8L3RpdGxlPjwvaGVhZD48Ym9keT48aW1nIHNyYz0iLi4vaW1hZ2VzL2NvdmVyLnBuZyIvPjwvYm9keT48L2h0bWw+" +
        "UEsDBBQAAAAAAKG0Xl0QV33lrQAAAK0AAAAWAAAAT0VCUFMvdGV4dC9vbmUgYS54aHRtbDxodG1sIHhtbG5zPSJodHRwOi8vd3d3" +
        "LnczLm9yZy8xOTk5L3hodG1sIj48aGVhZD48dGl0bGU+T25lPC90aXRsZT48c3R5bGU+cHt9PC9zdHlsZT48L2hlYWQ+PGJvZHk+" +
        "PGgxPlBhcnQgT25lPC9oMT48cD5GaXJzdCB3b3JkcyBoZXJlLjwvcD48c2NyaXB0PngoKTwvc2NyaXB0PjwvYm9keT48L2h0bWw+" +
        "UEsDBBQAAAAAAKG0Xl3D0t95mwAAAJsAAAAUAAAAT0VCUFMvdGV4dC90d28ueGh0bWw8aHRtbCB4bWxucz0iaHR0cDovL3d3dy53" +
        "My5vcmcvMTk5OS94aHRtbCI+PGhlYWQ+PHRpdGxlPlR3bzwvdGl0bGU+PC9oZWFkPjxib2R5PjxzZWN0aW9uPjxoMT5QYXJ0IFR3" +
        "bzwvaDE+PHA+U2Vjb25kICZhbXA7IGxhc3QuPC9wPjwvc2VjdGlvbj48L2JvZHk+PC9odG1sPlBLAQIUAxQAAAAAAAAAIQBvYass" +
        "FAAAABQAAAAIAAAAAAAAAAAAAACAAQAAAABtaW1ldHlwZVBLAQIUAxQAAAAAAKG0Xl0eC9fJ3QAAAN0AAAAWAAAAAAAAAAAAAACA" +
        "AToAAABNRVRBLUlORi9jb250YWluZXIueG1sUEsBAhQDFAAAAAAAobReXduDa8poAwAAaAMAABEAAAAAAAAAAAAAAIABSwEAAE9F" +
        "QlBTL2NvbnRlbnQub3BmUEsBAhQDFAAAAAAAobReXTyFfgyQAQAAkAEAAA8AAAAAAAAAAAAAAIAB4gQAAE9FQlBTL25hdi54aHRt" +
        "bFBLAQIUAxQAAAAAAKG0Xl3tvMorgAAAAIAAAAAWAAAAAAAAAAAAAACAAZ8GAABPRUJQUy90ZXh0L2NvdmVyLnhodG1sUEsBAhQD" +
        "FAAAAAAAobReXRBXfeWtAAAArQAAABYAAAAAAAAAAAAAAIABUwcAAE9FQlBTL3RleHQvb25lIGEueGh0bWxQSwECFAMUAAAAAACh" +
        "tF5dw9LfeZsAAACbAAAAFAAAAAAAAAAAAAAAgAE0CAAAT0VCUFMvdGV4dC90d28ueGh0bWxQSwUGAAAAAAcABwDAAQAAAQkAAAAA";
}
