using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore;
using WealthWise.Application;
using WealthWise.Domain;
using WealthWise.Infrastructure;
using WealthWise.Infrastructure.Persistence;

var builder = WebApplication.CreateBuilder(args);

builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));
builder.Services.AddOpenApi();
builder.Services.AddApplication();
builder.Services.AddInfrastructure(builder.Configuration);

var app = builder.Build();

// Outer layer: only genuine bugs reach this handler, and the framework logs them at error level.
app.UseExceptionHandler(handler => handler.Run(async ctx =>
{
    ctx.Response.StatusCode = StatusCodes.Status500InternalServerError;
    await Results.Problem(title: "Unexpected error", statusCode: StatusCodes.Status500InternalServerError).ExecuteAsync(ctx);
}));

// Inner layer: expected failures (business rules, unknown ids, stale writes) become problem responses
// and are logged at Information/Warning, so a rejected trade is not mistaken for an application error.
app.Use(async (ctx, next) =>
{
    try { await next(ctx); }
    catch (Exception ex) when (ex is NotFoundException or DomainException or DbUpdateConcurrencyException)
    {
        var (status, title, level) = ex switch
        {
            NotFoundException => (StatusCodes.Status404NotFound, "Not found", LogLevel.Information),
            DomainException => (StatusCodes.Status422UnprocessableEntity, "Business rule violated", LogLevel.Information),
            _ => (StatusCodes.Status409Conflict, "The portfolio changed; reload and retry", LogLevel.Warning)
        };
        ctx.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("Problems")
            .Log(level, "{Status} {Title}: {Detail} ({Method} {Path})", status, title, ex.Message, ctx.Request.Method, ctx.Request.Path);

        ctx.Response.Clear();
        ctx.Response.StatusCode = status;
        await Results.Problem(title: title, detail: ex.Message, statusCode: status).ExecuteAsync(ctx);
    }
});

await DbInitializer.InitializeAsync(app.Services);

app.MapOpenApi();
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

var api = app.MapGroup("/api");
api.MapGet("/health", () => Results.Ok(new { status = "ok", time = DateTimeOffset.UtcNow }));

api.MapGet("/securities", async (IPortfolioRepository repo, CancellationToken ct) =>
    (await repo.GetSecuritiesAsync(ct)).Select(s => new SecurityDto(s.Symbol, s.Name, s.AssetClass, s.BasePrice)));

api.MapGet("/portfolios", (PortfolioService svc, CancellationToken ct) => svc.ListAsync(ct));

api.MapGet("/portfolios/{id:guid}", (Guid id, PortfolioService svc, CancellationToken ct) => svc.GetAsync(id, ct));

api.MapGet("/portfolios/{id:guid}/rebalance",
    (Guid id, string? strategy, decimal? band, PortfolioService svc, CancellationToken ct) =>
        svc.ProposeRebalanceAsync(id, strategy, band, ct));

api.MapGet("/portfolios/{id:guid}/trades",
    (Guid id, int? take, PortfolioService svc, CancellationToken ct) => svc.TradesAsync(id, take ?? 25, ct));

api.MapPost("/portfolios/{id:guid}/trades", async (Guid id, TradeRequest request, TradeService svc, CancellationToken ct) =>
{
    var trade = await svc.ExecuteAsync(id, request, ct);
    return Results.Created($"/api/portfolios/{id}/trades/{trade.Id}", trade);
});

api.MapGet("/audit", async (IAuditLog audit, int? take, CancellationToken ct) => await audit.RecentAsync(take ?? 25, ct));

app.Run();

public partial class Program; // for WebApplicationFactory<Program>
