using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using WealthWise.Application;
using WealthWise.Domain;

namespace WealthWise.Infrastructure.Persistence;

internal sealed class EfPortfolioRepository(WealthWiseDbContext db) : IPortfolioRepository
{
    public async Task<IReadOnlyList<Portfolio>> ListAsync(CancellationToken ct) =>
        await db.Portfolios.AsNoTracking().AsSplitQuery()
            .Include(p => p.Holdings).Include(p => p.Targets)
            .OrderBy(p => p.Name).ToListAsync(ct);

    public Task<Portfolio?> GetAsync(Guid id, CancellationToken ct) =>
        db.Portfolios.AsSplitQuery()
            .Include(p => p.Holdings).Include(p => p.Targets)
            .FirstOrDefaultAsync(p => p.Id == id, ct);

    public async Task<IReadOnlyList<Trade>> GetTradesAsync(Guid portfolioId, int take, CancellationToken ct) =>
        await db.Trades.AsNoTracking().Where(t => t.PortfolioId == portfolioId)
            .OrderByDescending(t => t.ExecutedAt).Take(take).ToListAsync(ct);

    public async Task<IReadOnlyList<Security>> GetSecuritiesAsync(CancellationToken ct) =>
        await db.Securities.AsNoTracking().OrderBy(s => s.Symbol).ToListAsync(ct);

    public Task<Security?> GetSecurityAsync(string symbol, CancellationToken ct) =>
        db.Securities.AsNoTracking().FirstOrDefaultAsync(s => s.Symbol == symbol, ct);

    public Task SaveChangesAsync(CancellationToken ct) => db.SaveChangesAsync(ct);
}

internal sealed class EfAuditLog(WealthWiseDbContext db) : IAuditLog
{
    public async Task<bool> AppendAsync(Guid eventId, string type, DateTimeOffset at, string payloadJson, CancellationToken ct)
    {
        if (await db.AuditEntries.AnyAsync(e => e.EventId == eventId, ct)) return false;
        db.AuditEntries.Add(new AuditEntry { EventId = eventId, Type = type, At = at.ToUniversalTime(), PayloadJson = payloadJson });
        try { await db.SaveChangesAsync(ct); return true; }
        catch (DbUpdateException) { return false; } // lost a race with a duplicate delivery
    }

    public async Task<IReadOnlyList<AuditEntryDto>> RecentAsync(int take, CancellationToken ct)
    {
        var rows = await db.AuditEntries.AsNoTracking().OrderByDescending(e => e.At).Take(Math.Clamp(take, 1, 200)).ToListAsync(ct);
        return rows.Select(r => new AuditEntryDto(r.EventId, r.Type, r.At, JsonDocument.Parse(r.PayloadJson).RootElement.Clone())).ToList();
    }
}
