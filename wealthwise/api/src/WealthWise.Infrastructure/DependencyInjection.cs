using Amazon;
using Amazon.Runtime;
using Amazon.SQS;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using WealthWise.Application;
using WealthWise.Infrastructure.Messaging;
using WealthWise.Infrastructure.Persistence;
using WealthWise.Infrastructure.Pricing;

namespace WealthWise.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddInfrastructure(this IServiceCollection services, IConfiguration config)
    {
        services.AddSingleton(TimeProvider.System);

        services.AddDbContext<WealthWiseDbContext>(o =>
        {
            if (string.Equals(config["Database:Provider"], "InMemory", StringComparison.OrdinalIgnoreCase))
                o.UseInMemoryDatabase(config["Database:Name"] ?? "wealthwise");
            else
                o.UseNpgsql(config.GetConnectionString("Postgres")
                    ?? throw new InvalidOperationException("ConnectionStrings:Postgres is not configured."));
        });
        services.AddScoped<IPortfolioRepository, EfPortfolioRepository>();
        services.AddScoped<IAuditLog, EfAuditLog>();

        services.AddMemoryCache();
        services.AddSingleton<SimulatedPriceProvider>();
        services.AddSingleton<IPriceProvider>(sp => new CachingPriceProvider(
            sp.GetRequiredService<SimulatedPriceProvider>(), sp.GetRequiredService<IMemoryCache>()));

        var sqs = config.GetSection("Sqs").Get<SqsOptions>() ?? new SqsOptions();
        services.Configure<SqsOptions>(config.GetSection("Sqs"));
        if (sqs.Enabled)
        {
            services.AddSingleton<IAmazonSQS>(_ => string.IsNullOrWhiteSpace(sqs.ServiceUrl)
                ? new AmazonSQSClient(RegionEndpoint.GetBySystemName(sqs.Region))
                : new AmazonSQSClient(new BasicAWSCredentials("local", "local"),
                    new AmazonSQSConfig { ServiceURL = sqs.ServiceUrl, AuthenticationRegion = sqs.Region }));
            services.AddSingleton<IEventPublisher, SqsEventPublisher>();
            services.AddHostedService<TradeEventConsumer>();
        }
        else
        {
            services.AddSingleton<IEventPublisher, NullEventPublisher>();
        }
        return services;
    }
}
