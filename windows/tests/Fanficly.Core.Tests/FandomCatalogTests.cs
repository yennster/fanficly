using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class FandomCatalogTests
{
    [Fact]
    public void ExactCatalogMatchUsesCategorySymbol()
    {
        // "Harry Potter - J. K. Rowling" is in the Books category (book.closed).
        Assert.Equal("book.closed", FandomCatalog.Symbol("Harry Potter - J. K. Rowling"));
        // Genshin is in Video Games (gamecontroller).
        Assert.Equal("gamecontroller", FandomCatalog.Symbol("Genshin Impact (Video Game)"));
    }

    [Fact]
    public void SuffixHeuristics()
    {
        Assert.Equal("gamecontroller", FandomCatalog.Symbol("Some New Game (Video Game)"));
        Assert.Equal("tv", FandomCatalog.Symbol("Random Show (TV 2024)"));
        Assert.Equal("film", FandomCatalog.Symbol("Big Hit (Movies)"));
        Assert.Equal("film", FandomCatalog.Symbol("Marvel Cinematic Universe"));
        Assert.Equal("headphones", FandomCatalog.Symbol("Some Audio Drama (Podcast)"));
        Assert.Equal("sparkles", FandomCatalog.Symbol("Naruto (Anime & Manga)"));
        Assert.Equal("person.fill", FandomCatalog.Symbol("Formula 1 RPF"));
        Assert.Equal("theatermasks", FandomCatalog.Symbol("Hadestown - Mitchell (Musical)"));
    }

    [Fact]
    public void UnknownFallsBackToBook()
    {
        Assert.Equal("book.closed", FandomCatalog.Symbol("Something Obscure With No Suffix"));
    }
}
