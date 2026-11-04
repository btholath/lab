using Microsoft.Extensions.Caching.Memory;
using WealthWise.Application;
using WealthWise.Domain;

namespace WealthWise.Infrastructure.Pricing;

/// <summary>Deterministic fake market: base price plus slow sine waves. Swap for a real feed behind IPriceProvider.</summary>
public sealed class SimulatedPriceProvider(TimeProvider time) : IPriceProvider
{
    public Task<IReadOnlyDictionary<string, decimal>> GetPricesAsync(IEnumerable<Security> securities, CancellationToken ct)
    {
        var t = time.GetUtcNow().ToUnixTimeSeconds();
        IReadOnlyDictionary<string, decimal> result = securities.ToDictionary(s => s.Symbol, s => Quote(s, t));
        return Task.FromResult(result);
    }

    private static decimal Quote(Security s, long t)
    {
        var volatility = s.AssetClass switch
        {
            AssetClass.Cash => 0.0004,
            AssetClass.FixedIncome => 0.012,
            AssetClass.Alternatives => 0.035,
            _ => 0.03
        };
        var phase = s.Symbol.Sum(c => c);
        var wave = Math.Sin(t / 900.0 + phase) * volatility + Math.Sin(t / 137.0 + phase * 2) * volatility / 6;
        return Math.Round(s.BasePrice * (decimal)(1 + wave), 2);
    }
}

/// <summary>Decorator: keeps quotes stable for a few seconds so valuation and trade execution agree.</summary>
public sealed class CachingPriceProvider(IPriceProvider inner, IMemoryCache cache) : IPriceProvider
{
    private static readonly TimeSpan Ttl = TimeSpan.FromSeconds(5);

    public async Task<IReadOnlyDictionary<string, decimal>> GetPricesAsync(IEnumerable<Security> securities, CancellationToken ct)
    {
        var result = new Dictionary<string, decimal>();
        var missing = new List<Security>();
        foreach (var s in securities)
        {
            if (cache.TryGetValue($"price:{s.Symbol}", out decimal cached)) result[s.Symbol] = cached;
            else missing.Add(s);
        }
        if (missing.Count > 0)
        {
            foreach (var (symbol, price) in await inner.GetPricesAsync(missing, ct))
            {
                cache.Set($"price:{symbol}", price, Ttl);
                result[symbol] = price;
            }
        }
        return result;
    }
}
