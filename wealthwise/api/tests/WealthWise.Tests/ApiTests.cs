using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;

namespace WealthWise.Tests;

public sealed class ApiFactory : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(Microsoft.AspNetCore.Hosting.IWebHostBuilder builder)
    {
        builder.UseSetting("Database:Provider", "InMemory");
        builder.UseSetting("Database:Name", $"tests-{Guid.NewGuid():N}");
        builder.UseSetting("Sqs:QueueUrl", "");
    }
}

public class ApiTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private readonly HttpClient _http = factory.CreateClient();

    private async Task<JsonElement> GetJson(string url)
    {
        var res = await _http.GetAsync(url);
        res.EnsureSuccessStatusCode();
        return await res.Content.ReadFromJsonAsync<JsonElement>();
    }

    private async Task<Guid> FirstPortfolioId()
    {
        var list = await GetJson("/api/portfolios");
        return list[0].GetProperty("id").GetGuid();
    }

    [Fact]
    public async Task Lists_seeded_portfolios_with_drift()
    {
        var list = await GetJson("/api/portfolios");
        Assert.Equal(3, list.GetArrayLength());
        Assert.All(list.EnumerateArray(), p => Assert.True(p.GetProperty("totalValue").GetDecimal() > 0));
    }

    [Fact]
    public async Task Unknown_portfolio_is_404_problem_details()
    {
        var res = await _http.GetAsync($"/api/portfolios/{Guid.NewGuid()}");
        Assert.Equal(HttpStatusCode.NotFound, res.StatusCode);
    }

    [Fact]
    public async Task Buying_more_than_cash_allows_is_422()
    {
        var id = await FirstPortfolioId();
        var res = await _http.PostAsJsonAsync($"/api/portfolios/{id}/trades", new { symbol = "VTI", side = "Buy", quantity = 1_000_000 });
        Assert.Equal(HttpStatusCode.UnprocessableEntity, res.StatusCode);
    }

    [Fact]
    public async Task Executing_a_trade_moves_cash_and_records_history()
    {
        var id = await FirstPortfolioId();
        var before = (await GetJson($"/api/portfolios/{id}")).GetProperty("valuation").GetProperty("cash").GetDecimal();

        var res = await _http.PostAsJsonAsync($"/api/portfolios/{id}/trades", new { symbol = "SGOV", side = "Buy", quantity = 10 });
        Assert.Equal(HttpStatusCode.Created, res.StatusCode);

        var after = (await GetJson($"/api/portfolios/{id}")).GetProperty("valuation").GetProperty("cash").GetDecimal();
        Assert.True(after < before);
        Assert.True((await GetJson($"/api/portfolios/{id}/trades")).GetArrayLength() >= 1);
    }

    [Fact]
    public async Task Rebalance_endpoint_returns_a_plan_and_rejects_bad_strategy()
    {
        var id = await FirstPortfolioId();
        var plan = await GetJson($"/api/portfolios/{id}/rebalance?strategy=full");
        Assert.Equal("full", plan.GetProperty("strategy").GetString());

        var bad = await _http.GetAsync($"/api/portfolios/{id}/rebalance?strategy=nope");
        Assert.Equal(HttpStatusCode.UnprocessableEntity, bad.StatusCode);
    }
}
