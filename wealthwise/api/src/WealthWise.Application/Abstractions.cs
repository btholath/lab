using System.Text.Json;
using WealthWise.Domain;

namespace WealthWise.Application;

public class NotFoundException(string message) : Exception(message);

public interface IPortfolioRepository
{
    Task<IReadOnlyList<Portfolio>> ListAsync(CancellationToken ct);
    /// <summary>Tracked aggregate with holdings and targets loaded.</summary>
    Task<Portfolio?> GetAsync(Guid id, CancellationToken ct);
    Task<IReadOnlyList<Trade>> GetTradesAsync(Guid portfolioId, int take, CancellationToken ct);
    Task<IReadOnlyList<Security>> GetSecuritiesAsync(CancellationToken ct);
    Task<Security?> GetSecurityAsync(string symbol, CancellationToken ct);
    Task SaveChangesAsync(CancellationToken ct);
}

public interface IPriceProvider
{
    Task<IReadOnlyDictionary<string, decimal>> GetPricesAsync(IEnumerable<Security> securities, CancellationToken ct);
}

public interface IEventPublisher
{
    Task PublishAsync(string type, object payload, CancellationToken ct);
}

public interface IAuditLog
{
    /// <summary>Idempotent: returns false if the event id was already recorded.</summary>
    Task<bool> AppendAsync(Guid eventId, string type, DateTimeOffset at, string payloadJson, CancellationToken ct);
    Task<IReadOnlyList<AuditEntryDto>> RecentAsync(int take, CancellationToken ct);
}

public sealed record AuditEntryDto(Guid EventId, string Type, DateTimeOffset At, JsonElement Payload);
