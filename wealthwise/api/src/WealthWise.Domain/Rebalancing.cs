namespace WealthWise.Domain;

/// <param name="Amount">Dollar amount to trade at asset-class level (always positive).</param>
public sealed record ProposedTrade(AssetClass AssetClass, TradeSide Side, decimal Amount, string Reason);

/// <summary>Strategy pattern: new rebalancing policies plug in without touching callers.</summary>
public interface IRebalanceStrategy
{
    string Name { get; }
    IReadOnlyList<ProposedTrade> Propose(PortfolioValuation valuation);
}

/// <summary>Trade every non-cash asset class back to its target. Cash is the funding leg.</summary>
public sealed class FullRebalanceStrategy : IRebalanceStrategy
{
    private const decimal MinimumTrade = 50m;
    public string Name => "full";

    public IReadOnlyList<ProposedTrade> Propose(PortfolioValuation v) =>
        v.Allocation
            .Where(a => a.AssetClass != AssetClass.Cash)
            .Select(a => (Line: a, Delta: Math.Round(-a.Drift * v.TotalValue, 2)))
            .Where(x => Math.Abs(x.Delta) >= MinimumTrade)
            .Select(x => new ProposedTrade(
                x.Line.AssetClass,
                x.Delta > 0 ? TradeSide.Buy : TradeSide.Sell,
                Math.Abs(x.Delta),
                $"Return {x.Line.AssetClass} to its {x.Line.Target:P0} target."))
            .ToList();
}

/// <summary>Only trade asset classes whose drift exceeds a tolerance band; cheaper in fees and taxes.</summary>
public sealed class ThresholdRebalanceStrategy(decimal band) : IRebalanceStrategy
{
    private readonly FullRebalanceStrategy _full = new();
    public string Name => "threshold";

    public IReadOnlyList<ProposedTrade> Propose(PortfolioValuation v)
    {
        var breaching = v.Allocation.Where(a => Math.Abs(a.Drift) > band).Select(a => a.AssetClass).ToHashSet();
        return _full.Propose(v)
            .Where(t => breaching.Contains(t.AssetClass))
            .Select(t => t with { Reason = $"Drift outside the ±{band:P0} band." })
            .ToList();
    }
}

public static class RebalanceStrategyFactory
{
    public static IRebalanceStrategy Create(string? name, decimal? band = null) =>
        (name ?? "threshold").Trim().ToLowerInvariant() switch
        {
            "threshold" => new ThresholdRebalanceStrategy(band is > 0 and < 1 ? band.Value : 0.05m),
            "full" => new FullRebalanceStrategy(),
            _ => throw new DomainException($"Unknown rebalance strategy '{name}'. Use 'threshold' or 'full'.")
        };
}
