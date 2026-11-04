using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using WealthWise.Domain;

namespace WealthWise.Infrastructure.Persistence;

public static class DbInitializer
{
    /// <summary>Creates the schema (with retries while Postgres boots) and seeds demo data once.</summary>
    public static async Task InitializeAsync(IServiceProvider services, CancellationToken ct = default)
    {
        using var scope = services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<WealthWiseDbContext>();
        var log = scope.ServiceProvider.GetRequiredService<ILoggerFactory>().CreateLogger("DbInitializer");

        for (var attempt = 1; ; attempt++)
        {
            try { await db.Database.EnsureCreatedAsync(ct); break; }
            catch (Exception ex) when (attempt < 30)
            {
                log.LogWarning("Database not ready (attempt {Attempt}): {Message}", attempt, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(2), ct);
            }
        }

        if (await db.Securities.AnyAsync(ct)) return;
        Seed(db, scope.ServiceProvider.GetRequiredService<TimeProvider>().GetUtcNow());
        await db.SaveChangesAsync(ct);
    }

    // Illustrative ETFs and prices only. Not market data and not investment advice.
    private static void Seed(WealthWiseDbContext db, DateTimeOffset now)
    {
        var sec = new[]
        {
            new Security("VTI", "US Total Stock Market ETF", AssetClass.Equity, 285.40m),
            new Security("VXUS", "International Stock ETF", AssetClass.Equity, 66.15m),
            new Security("BND", "US Aggregate Bond ETF", AssetClass.FixedIncome, 72.80m),
            new Security("VTIP", "Short-Term Inflation-Protected ETF", AssetClass.FixedIncome, 48.90m),
            new Security("VNQ", "Real Estate ETF", AssetClass.Alternatives, 91.30m),
            new Security("GLD", "Gold Trust", AssetClass.Alternatives, 262.10m),
            new Security("SGOV", "0-3 Month Treasury ETF", AssetClass.Cash, 100.45m),
        };
        db.Securities.AddRange(sec);
        Security S(string sym) => sec.First(s => s.Symbol == sym);

        Portfolio Build(string name, string client, RiskProfile risk, decimal cash,
            (AssetClass, decimal)[] targets, (string Sym, decimal Qty)[] buys)
        {
            var p = new Portfolio(name, client, risk, cash);
            p.SetTargets(targets);
            for (var i = 0; i < buys.Length; i++)
            {
                var (sym, qty) = buys[i];
                // Oldest first, a week apart, so trade history reads naturally.
                p.ApplyTrade(S(sym), TradeSide.Buy, qty, S(sym).BasePrice, now.AddDays(-7 * (buys.Length - i)));
            }
            return p;
        }

        db.Portfolios.AddRange(
            Build("Harlow Family Trust", "Harlow family", RiskProfile.Balanced, 600_000m,
                [(AssetClass.Equity, .50m), (AssetClass.FixedIncome, .35m), (AssetClass.Cash, .05m), (AssetClass.Alternatives, .10m)],
                [("VTI", 900), ("VXUS", 1500), ("BND", 1800), ("VNQ", 300), ("GLD", 100)]),
            Build("Okafor Retirement IRA", "Adaeze Okafor", RiskProfile.Conservative, 250_000m,
                [(AssetClass.Equity, .30m), (AssetClass.FixedIncome, .55m), (AssetClass.Cash, .10m), (AssetClass.Alternatives, .05m)],
                [("VTI", 250), ("BND", 900), ("VTIP", 400), ("SGOV", 300)]),
            Build("Lindqvist Growth Account", "Erik Lindqvist", RiskProfile.Growth, 400_000m,
                [(AssetClass.Equity, .75m), (AssetClass.FixedIncome, .10m), (AssetClass.Cash, .03m), (AssetClass.Alternatives, .12m)],
                [("VTI", 700), ("VXUS", 1200), ("BND", 150), ("GLD", 250), ("VNQ", 100)]));
    }
}
