using WealthWise.Domain;

namespace WealthWise.Tests;

public class DomainTests
{
    private static readonly Security Vti = new("VTI", "Total Market", AssetClass.Equity, 100m);
    private static readonly Security Bnd = new("BND", "Bonds", AssetClass.FixedIncome, 50m);
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static Portfolio NewPortfolio(decimal cash = 10_000m)
    {
        var p = new Portfolio("Test", "Client", RiskProfile.Balanced, cash);
        p.SetTargets([(AssetClass.Equity, .6m), (AssetClass.FixedIncome, .4m), (AssetClass.Cash, 0m), (AssetClass.Alternatives, 0m)]);
        return p;
    }

    private static PortfolioValuation Value(Portfolio p, decimal vtiPrice = 100m, decimal bndPrice = 50m) =>
        Valuator.Calculate(p,
            new Dictionary<string, Security> { ["VTI"] = Vti, ["BND"] = Bnd },
            new Dictionary<string, decimal> { ["VTI"] = vtiPrice, ["BND"] = bndPrice });

    [Fact]
    public void Buy_reduces_cash_and_creates_holding()
    {
        var p = NewPortfolio();
        var trade = p.ApplyTrade(Vti, TradeSide.Buy, 10, 100m, Now);

        Assert.Equal(9_000m, p.CashBalance);
        Assert.Equal(1_000m, trade.Notional);
        var h = Assert.Single(p.Holdings);
        Assert.Equal(10, h.Quantity);
        Assert.Equal(1_000m, h.CostBasis);
    }

    [Fact]
    public void Buy_with_insufficient_cash_is_rejected()
    {
        var p = NewPortfolio(500m);
        var ex = Assert.Throws<DomainException>(() => p.ApplyTrade(Vti, TradeSide.Buy, 10, 100m, Now));
        Assert.Contains("Insufficient cash", ex.Message);
        Assert.Empty(p.Holdings);
        Assert.Equal(500m, p.CashBalance);
    }

    [Fact]
    public void Sell_more_than_held_is_rejected()
    {
        var p = NewPortfolio();
        p.ApplyTrade(Vti, TradeSide.Buy, 5, 100m, Now);
        Assert.Throws<DomainException>(() => p.ApplyTrade(Vti, TradeSide.Sell, 6, 100m, Now));
    }

    [Fact]
    public void Partial_sell_releases_cost_basis_proportionally()
    {
        var p = NewPortfolio();
        p.ApplyTrade(Vti, TradeSide.Buy, 10, 100m, Now);
        p.ApplyTrade(Vti, TradeSide.Sell, 4, 120m, Now);

        var h = Assert.Single(p.Holdings);
        Assert.Equal(6, h.Quantity);
        Assert.Equal(600m, h.CostBasis);
        Assert.Equal(9_480m, p.CashBalance); // 10,000 - 1,000 + 480
    }

    [Fact]
    public void Selling_everything_removes_the_holding_and_bumps_version()
    {
        var p = NewPortfolio();
        p.ApplyTrade(Vti, TradeSide.Buy, 5, 100m, Now);
        p.ApplyTrade(Vti, TradeSide.Sell, 5, 100m, Now);
        Assert.Empty(p.Holdings);
        Assert.Equal(2, p.Version);
    }

    [Fact]
    public void Targets_must_sum_to_one()
    {
        var p = new Portfolio("T", "C", RiskProfile.Growth, 0);
        Assert.Throws<DomainException>(() => p.SetTargets([(AssetClass.Equity, .5m), (AssetClass.Cash, .4m)]));
    }

    [Fact]
    public void Valuation_allocation_sums_to_one_and_reports_gain()
    {
        var p = NewPortfolio();
        p.ApplyTrade(Vti, TradeSide.Buy, 50, 100m, Now);
        p.ApplyTrade(Bnd, TradeSide.Buy, 60, 50m, Now);

        var v = Value(p, vtiPrice: 110m);
        Assert.Equal(1m, v.Allocation.Sum(a => a.Actual), 6);
        Assert.Equal(500m, v.UnrealizedGain);
        Assert.Equal(v.Holdings.Sum(h => h.MarketValue) + v.Cash, v.TotalValue);
    }

    [Fact]
    public void Full_rebalance_funds_the_shortfall_from_cash_and_trims_the_overweight()
    {
        var p = NewPortfolio();
        p.ApplyTrade(Vti, TradeSide.Buy, 90, 100m, Now);  // 9,000 equity, 1,000 cash, target cash is 0%
        var v = Value(p);

        var trades = new FullRebalanceStrategy().Propose(v);
        var netBuys = trades.Sum(t => t.Side == TradeSide.Buy ? t.Amount : -t.Amount);

        Assert.Equal(1_000m, netBuys, 2); // exactly the cash that must be deployed
        Assert.Contains(trades, t => t.AssetClass == AssetClass.Equity && t.Side == TradeSide.Sell && t.Amount == 3_000m);
        Assert.Contains(trades, t => t.AssetClass == AssetClass.FixedIncome && t.Side == TradeSide.Buy && t.Amount == 4_000m);
    }

    [Fact]
    public void Threshold_strategy_ignores_drift_inside_the_band()
    {
        var p = NewPortfolio();
        p.ApplyTrade(Vti, TradeSide.Buy, 59, 100m, Now);
        p.ApplyTrade(Bnd, TradeSide.Buy, 82, 50m, Now); // ~5.9k equity / ~4.1k bonds, well within a 20% band

        Assert.Empty(new ThresholdRebalanceStrategy(0.20m).Propose(Value(p)));
        Assert.NotEmpty(new ThresholdRebalanceStrategy(0.001m).Propose(Value(p)));
    }

    [Fact]
    public void Factory_rejects_unknown_strategy()
    {
        Assert.Throws<DomainException>(() => RebalanceStrategyFactory.Create("yolo"));
        Assert.IsType<FullRebalanceStrategy>(RebalanceStrategyFactory.Create("FULL"));
    }
}
