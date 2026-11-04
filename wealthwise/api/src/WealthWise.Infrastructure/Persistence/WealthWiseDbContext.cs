using Microsoft.EntityFrameworkCore;
using WealthWise.Domain;

namespace WealthWise.Infrastructure.Persistence;

public sealed class AuditEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid EventId { get; set; }
    public string Type { get; set; } = "";
    public DateTimeOffset At { get; set; }
    public string PayloadJson { get; set; } = "{}";
}

public sealed class WealthWiseDbContext(DbContextOptions<WealthWiseDbContext> options) : DbContext(options)
{
    public DbSet<Security> Securities => Set<Security>();
    public DbSet<Portfolio> Portfolios => Set<Portfolio>();
    public DbSet<Trade> Trades => Set<Trade>();
    public DbSet<AuditEntry> AuditEntries => Set<AuditEntry>();

    protected override void OnModelCreating(ModelBuilder m)
    {
        m.Entity<Security>(b =>
        {
            b.HasKey(x => x.Symbol);
            b.Property(x => x.Symbol).HasMaxLength(16);
            b.Property(x => x.Name).HasMaxLength(120);
            b.Property(x => x.AssetClass).HasConversion<string>().HasMaxLength(20);
            b.Property(x => x.BasePrice).HasPrecision(18, 4);
        });

        m.Entity<Portfolio>(b =>
        {
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).ValueGeneratedNever();
            b.Property(x => x.Name).HasMaxLength(120);
            b.Property(x => x.ClientName).HasMaxLength(120);
            b.Property(x => x.RiskProfile).HasConversion<string>().HasMaxLength(20);
            b.Property(x => x.CashBalance).HasPrecision(18, 2);
            b.Property(x => x.Version).IsConcurrencyToken();

            b.HasMany(x => x.Holdings).WithOne().HasForeignKey(h => h.PortfolioId).OnDelete(DeleteBehavior.Cascade);
            b.HasMany(x => x.Targets).WithOne().HasForeignKey(t => t.PortfolioId).OnDelete(DeleteBehavior.Cascade);
            b.HasMany(x => x.Trades).WithOne().HasForeignKey(t => t.PortfolioId).OnDelete(DeleteBehavior.Cascade);
            b.Navigation(x => x.Holdings).UsePropertyAccessMode(PropertyAccessMode.Field);
            b.Navigation(x => x.Targets).UsePropertyAccessMode(PropertyAccessMode.Field);
            b.Navigation(x => x.Trades).UsePropertyAccessMode(PropertyAccessMode.Field);
        });

        m.Entity<Holding>(b =>
        {
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).ValueGeneratedNever();
            b.Property(x => x.Symbol).HasMaxLength(16);
            b.Property(x => x.Quantity).HasPrecision(18, 6);
            b.Property(x => x.CostBasis).HasPrecision(18, 4);
            b.HasIndex(x => new { x.PortfolioId, x.Symbol }).IsUnique();
            b.HasOne<Security>().WithMany().HasForeignKey(x => x.Symbol);
        });

        m.Entity<TargetAllocation>(b =>
        {
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).ValueGeneratedNever();
            b.Property(x => x.AssetClass).HasConversion<string>().HasMaxLength(20);
            b.Property(x => x.Weight).HasPrecision(6, 4);
        });

        m.Entity<Trade>(b =>
        {
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).ValueGeneratedNever();
            b.Property(x => x.Symbol).HasMaxLength(16);
            b.Property(x => x.Side).HasConversion<string>().HasMaxLength(8);
            b.Property(x => x.Quantity).HasPrecision(18, 6);
            b.Property(x => x.Price).HasPrecision(18, 4);
            b.HasIndex(x => new { x.PortfolioId, x.ExecutedAt });
            b.HasOne<Security>().WithMany().HasForeignKey(x => x.Symbol);
        });

        m.Entity<AuditEntry>(b =>
        {
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).ValueGeneratedNever();
            b.Property(x => x.Type).HasMaxLength(60);
            b.HasIndex(x => x.EventId).IsUnique(); // idempotent consumer
            b.HasIndex(x => x.At);
        });
    }
}
