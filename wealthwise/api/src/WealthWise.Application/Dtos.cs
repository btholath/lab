using WealthWise.Domain;

namespace WealthWise.Application;

public sealed record SecurityDto(string Symbol, string Name, AssetClass AssetClass, decimal BasePrice);

public sealed record PortfolioSummary(
    Guid Id, string Name, string ClientName, RiskProfile RiskProfile,
    decimal TotalValue, decimal UnrealizedGain, decimal MaxDrift);

public sealed record PortfolioDetail(
    Guid Id, string Name, string ClientName, RiskProfile RiskProfile, PortfolioValuation Valuation);

public sealed record RebalancePlan(
    string Strategy, decimal TotalValue, IReadOnlyList<ProposedTrade> Trades,
    decimal CashAfter, IReadOnlyList<AllocationLine> ProjectedAllocation);

public sealed record TradeRequest(string Symbol, TradeSide Side, decimal Quantity);

public sealed record TradeDto(Guid Id, string Symbol, TradeSide Side, decimal Quantity, decimal Price, decimal Notional, DateTimeOffset ExecutedAt)
{
    public static TradeDto From(Trade t) => new(t.Id, t.Symbol, t.Side, t.Quantity, t.Price, t.Notional, t.ExecutedAt);
}
