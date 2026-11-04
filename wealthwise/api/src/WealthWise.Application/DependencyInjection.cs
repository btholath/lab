using Microsoft.Extensions.DependencyInjection;

namespace WealthWise.Application;

public static class DependencyInjection
{
    public static IServiceCollection AddApplication(this IServiceCollection services)
    {
        services.AddScoped<PortfolioService>();
        services.AddScoped<TradeService>();
        return services;
    }
}
