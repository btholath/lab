using WealthWise.Domain;

namespace WealthWise.Application;

public sealed class PortfolioService(IPortfolioRepository repo, IPriceProvider prices)
{
    public async Task<IReadOnlyList<PortfolioSummary>> ListAsync(CancellationToken ct)
    {
        var portfolios = await repo.ListAsync(ct);
        var (securities, quotes) = await LoadMarketAsync(ct);

        return portfolios.Select(p =>
        {
            var v = Valuator.Calculate(p, securities, quotes);
            return new PortfolioSummary(p.Id, p.Name, p.ClientName, p.RiskProfile,
                v.TotalValue, v.UnrealizedGain, v.Allocation.Max(a => Math.Abs(a.Drift)));
        }).ToList();
    }

    public async Task<PortfolioDetail> GetAsync(Guid id, CancellationToken ct)
    {
        var p = await repo.GetAsync(id, ct) ?? throw new NotFoundException($"Portfolio {id} was not found.");
        var (securities, quotes) = await LoadMarketAsync(ct);
        return new PortfolioDetail(p.Id, p.Name, p.ClientName, p.RiskProfile, Valuator.Calculate(p, securities, quotes));
    }

    public async Task<RebalancePlan> ProposeRebalanceAsync(Guid id, string? strategyName, decimal? band, CancellationToken ct)
    {
        var strategy = RebalanceStrategyFactory.Create(strategyName, band);
        var detail = await GetAsync(id, ct);
        var v = detail.Valuation;

        var trades = strategy.Propose(v);
        decimal Signed(ProposedTrade t) => t.Side == TradeSide.Buy ? t.Amount : -t.Amount;
        var cashEffect = -trades.Sum(Signed);

        var projected = v.Allocation.Select(a =>
        {
            var delta = a.AssetClass == AssetClass.Cash ? cashEffect : trades.Where(t => t.AssetClass == a.AssetClass).Sum(Signed);
            var value = a.Value + delta;
            var actual = v.TotalValue == 0 ? 0 : value / v.TotalValue;
            return new AllocationLine(a.AssetClass, value, actual, a.Target, actual - a.Target);
        }).ToList();

        return new RebalancePlan(strategy.Name, v.TotalValue, trades, v.Cash + cashEffect, projected);
    }

    public async Task<IReadOnlyList<TradeDto>> TradesAsync(Guid id, int take, CancellationToken ct)
    {
        _ = await repo.GetAsync(id, ct) ?? throw new NotFoundException($"Portfolio {id} was not found.");
        return (await repo.GetTradesAsync(id, Math.Clamp(take, 1, 200), ct)).Select(TradeDto.From).ToList();
    }

    private async Task<(Dictionary<string, Security>, IReadOnlyDictionary<string, decimal>)> LoadMarketAsync(CancellationToken ct)
    {
        var securities = (await repo.GetSecuritiesAsync(ct)).ToDictionary(s => s.Symbol);
        return (securities, await prices.GetPricesAsync(securities.Values, ct));
    }
}
