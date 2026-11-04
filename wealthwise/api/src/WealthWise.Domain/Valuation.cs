namespace WealthWise.Domain;

public sealed record HoldingValuation(
    string Symbol, string Name, AssetClass AssetClass, decimal Quantity, decimal Price,
    decimal MarketValue, decimal CostBasis, decimal UnrealizedGain);

public sealed record AllocationLine(AssetClass AssetClass, decimal Value, decimal Actual, decimal Target, decimal Drift);

public sealed record PortfolioValuation(
    decimal TotalValue, decimal Cash, decimal TotalCost, decimal UnrealizedGain,
    IReadOnlyList<HoldingValuation> Holdings, IReadOnlyList<AllocationLine> Allocation);

/// <summary>Pure function: no I/O, trivially unit-testable.</summary>
public static class Valuator
{
    public static PortfolioValuation Calculate(
        Portfolio portfolio,
        IReadOnlyDictionary<string, Security> securities,
        IReadOnlyDictionary<string, decimal> prices)
    {
        var lines = portfolio.Holdings
            .Select(h =>
            {
                var s = securities[h.Symbol];
                var price = prices[h.Symbol];
                var marketValue = Math.Round(h.Quantity * price, 2);
                var cost = Math.Round(h.CostBasis, 2);
                return new HoldingValuation(h.Symbol, s.Name, s.AssetClass, h.Quantity, price, marketValue, cost, marketValue - cost);
            })
            .OrderByDescending(l => l.MarketValue)
            .ToList();

        var cash = portfolio.CashBalance;
        var total = lines.Sum(l => l.MarketValue) + cash;

        var allocation = Enum.GetValues<AssetClass>()
            .Select(ac =>
            {
                var value = lines.Where(l => l.AssetClass == ac).Sum(l => l.MarketValue) + (ac == AssetClass.Cash ? cash : 0m);
                var actual = total == 0 ? 0m : value / total;
                var target = portfolio.Targets.FirstOrDefault(t => t.AssetClass == ac)?.Weight ?? 0m;
                return new AllocationLine(ac, value, actual, target, actual - target);
            })
            .ToList();

        return new PortfolioValuation(total, cash, lines.Sum(l => l.CostBasis), lines.Sum(l => l.UnrealizedGain), lines, allocation);
    }
}
