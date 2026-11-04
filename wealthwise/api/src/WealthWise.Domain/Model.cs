namespace WealthWise.Domain;

public enum AssetClass { Equity = 0, FixedIncome = 1, Cash = 2, Alternatives = 3 }
public enum TradeSide { Buy = 0, Sell = 1 }
public enum RiskProfile { Conservative = 0, Balanced = 1, Growth = 2 }

/// <summary>A business rule was violated (maps to HTTP 422).</summary>
public class DomainException(string message) : Exception(message);

public sealed class Security
{
    public string Symbol { get; private set; } = "";
    public string Name { get; private set; } = "";
    public AssetClass AssetClass { get; private set; }
    public decimal BasePrice { get; private set; }

    private Security() { }

    public Security(string symbol, string name, AssetClass assetClass, decimal basePrice)
    {
        if (string.IsNullOrWhiteSpace(symbol)) throw new DomainException("Symbol is required.");
        if (basePrice <= 0) throw new DomainException("Base price must be positive.");
        Symbol = symbol.Trim().ToUpperInvariant();
        Name = name;
        AssetClass = assetClass;
        BasePrice = basePrice;
    }
}

public sealed class Holding
{
    public Guid Id { get; private set; } = Guid.NewGuid();
    public Guid PortfolioId { get; private set; }
    public string Symbol { get; private set; } = "";
    public decimal Quantity { get; private set; }
    public decimal CostBasis { get; private set; }

    private Holding() { }
    internal Holding(Guid portfolioId, string symbol) { PortfolioId = portfolioId; Symbol = symbol; }

    internal void Increase(decimal quantity, decimal cost) { Quantity += quantity; CostBasis += cost; }

    internal void Decrease(decimal quantity)
    {
        // Average-cost method: cost basis leaves in proportion to the shares sold.
        var released = Math.Round(CostBasis * (quantity / Quantity), 4);
        CostBasis -= released;
        Quantity -= quantity;
        if (Quantity == 0) CostBasis = 0;
    }
}

public sealed class Trade
{
    public Guid Id { get; private set; } = Guid.NewGuid();
    public Guid PortfolioId { get; private set; }
    public string Symbol { get; private set; } = "";
    public TradeSide Side { get; private set; }
    public decimal Quantity { get; private set; }
    public decimal Price { get; private set; }
    public DateTimeOffset ExecutedAt { get; private set; }
    public decimal Notional => Math.Round(Quantity * Price, 2);

    private Trade() { }
    internal Trade(Guid portfolioId, string symbol, TradeSide side, decimal quantity, decimal price, DateTimeOffset at)
    {
        PortfolioId = portfolioId; Symbol = symbol; Side = side; Quantity = quantity; Price = price; ExecutedAt = at;
    }
}

public sealed class TargetAllocation
{
    public Guid Id { get; private set; } = Guid.NewGuid();
    public Guid PortfolioId { get; private set; }
    public AssetClass AssetClass { get; private set; }
    /// <summary>Fraction of portfolio value, 0..1.</summary>
    public decimal Weight { get; private set; }

    private TargetAllocation() { }
    internal TargetAllocation(Guid portfolioId, AssetClass assetClass, decimal weight)
    {
        PortfolioId = portfolioId; AssetClass = assetClass; Weight = weight;
    }
}

/// <summary>Aggregate root. All changes to holdings and cash go through <see cref="ApplyTrade"/>.</summary>
public sealed class Portfolio
{
    private readonly List<Holding> _holdings = [];
    private readonly List<TargetAllocation> _targets = [];
    private readonly List<Trade> _trades = [];

    public Guid Id { get; private set; } = Guid.NewGuid();
    public string Name { get; private set; } = "";
    public string ClientName { get; private set; } = "";
    public RiskProfile RiskProfile { get; private set; }
    public decimal CashBalance { get; private set; }
    /// <summary>Optimistic-concurrency token, bumped on every trade.</summary>
    public int Version { get; private set; }

    public IReadOnlyCollection<Holding> Holdings => _holdings;
    public IReadOnlyCollection<TargetAllocation> Targets => _targets;
    public IReadOnlyCollection<Trade> Trades => _trades;

    private Portfolio() { }

    public Portfolio(string name, string clientName, RiskProfile riskProfile, decimal openingCash)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new DomainException("Portfolio name is required.");
        if (openingCash < 0) throw new DomainException("Opening cash cannot be negative.");
        Name = name; ClientName = clientName; RiskProfile = riskProfile; CashBalance = openingCash;
    }

    public void SetTargets(IEnumerable<(AssetClass AssetClass, decimal Weight)> weights)
    {
        var list = weights.ToList();
        if (Math.Abs(list.Sum(w => w.Weight) - 1m) > 0.0001m)
            throw new DomainException("Target weights must sum to 100%.");
        _targets.Clear();
        _targets.AddRange(list.Select(w => new TargetAllocation(Id, w.AssetClass, w.Weight)));
    }

    public Trade ApplyTrade(Security security, TradeSide side, decimal quantity, decimal price, DateTimeOffset at)
    {
        if (quantity <= 0) throw new DomainException("Quantity must be positive.");
        if (price <= 0) throw new DomainException("Price must be positive.");

        var notional = Math.Round(quantity * price, 2);
        var holding = _holdings.FirstOrDefault(h => h.Symbol == security.Symbol);

        if (side == TradeSide.Buy)
        {
            if (notional > CashBalance)
                throw new DomainException($"Insufficient cash: order needs {notional:N2}, available {CashBalance:N2}.");
            CashBalance -= notional;
            if (holding is null)
            {
                holding = new Holding(Id, security.Symbol);
                _holdings.Add(holding);
            }
            holding.Increase(quantity, notional);
        }
        else
        {
            if (holding is null || holding.Quantity < quantity)
                throw new DomainException($"Cannot sell {quantity:N4} {security.Symbol}: position is {holding?.Quantity ?? 0:N4}.");
            CashBalance += notional;
            holding.Decrease(quantity);
            if (holding.Quantity == 0) _holdings.Remove(holding);
        }

        Version++;
        var trade = new Trade(Id, security.Symbol, side, quantity, price, at);
        _trades.Add(trade);
        return trade;
    }
}
