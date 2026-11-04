using Microsoft.Extensions.Logging;
using WealthWise.Domain;

namespace WealthWise.Application;

public sealed class TradeService(
    IPortfolioRepository repo, IPriceProvider prices, IEventPublisher events,
    TimeProvider time, ILogger<TradeService> log)
{
    public async Task<TradeDto> ExecuteAsync(Guid portfolioId, TradeRequest request, CancellationToken ct)
    {
        var portfolio = await repo.GetAsync(portfolioId, ct)
            ?? throw new NotFoundException($"Portfolio {portfolioId} was not found.");

        var symbol = (request.Symbol ?? "").Trim().ToUpperInvariant();
        var security = await repo.GetSecurityAsync(symbol, ct)
            ?? throw new DomainException($"Unknown security '{symbol}'.");

        var quotes = await prices.GetPricesAsync([security], ct);
        var trade = portfolio.ApplyTrade(security, request.Side, request.Quantity, quotes[symbol], time.GetUtcNow());
        await repo.SaveChangesAsync(ct);

        var dto = TradeDto.From(trade);

        // Published after commit (at-least-once). A transactional outbox would close the gap
        // where the process dies between commit and publish; see docs/confluence/ADR-0002.
        try { await events.PublishAsync("trade.executed", new { portfolioId, trade = dto }, ct); }
        catch (Exception ex) { log.LogWarning(ex, "Trade {TradeId} committed but event publish failed", dto.Id); }

        return dto;
    }
}
