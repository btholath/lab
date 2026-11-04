using System.Text.Json;
using System.Text.Json.Serialization;
using Amazon.SQS;
using Amazon.SQS.Model;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using WealthWise.Application;

namespace WealthWise.Infrastructure.Messaging;

public sealed class SqsOptions
{
    /// <summary>Empty means "real AWS" (default endpoint + default credential chain).</summary>
    public string ServiceUrl { get; set; } = "";
    public string QueueUrl { get; set; } = "";
    public string Region { get; set; } = "us-east-1";
    public bool Enabled => !string.IsNullOrWhiteSpace(QueueUrl);
}

public sealed record EventEnvelope(Guid Id, string Type, DateTimeOffset At, object Payload);

internal static class EventJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter() }
    };
}

internal sealed class SqsEventPublisher(IAmazonSQS sqs, IOptions<SqsOptions> options) : IEventPublisher
{
    public async Task PublishAsync(string type, object payload, CancellationToken ct)
    {
        var body = JsonSerializer.Serialize(new EventEnvelope(Guid.NewGuid(), type, DateTimeOffset.UtcNow, payload), EventJson.Options);
        await sqs.SendMessageAsync(new SendMessageRequest { QueueUrl = options.Value.QueueUrl, MessageBody = body }, ct);
    }
}

internal sealed class NullEventPublisher : IEventPublisher
{
    public Task PublishAsync(string type, object payload, CancellationToken ct) => Task.CompletedTask;
}

/// <summary>
/// Long-polls the queue and writes an audit trail. Stand-in for what would be a Lambda behind an SQS
/// event source mapping on AWS; the handler body is the same.
/// </summary>
internal sealed class TradeEventConsumer(
    IAmazonSQS sqs, IOptions<SqsOptions> options, IServiceScopeFactory scopes, ILogger<TradeEventConsumer> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var queue = options.Value.QueueUrl;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var response = await sqs.ReceiveMessageAsync(
                    new ReceiveMessageRequest { QueueUrl = queue, MaxNumberOfMessages = 10, WaitTimeSeconds = 5 }, ct);

                foreach (var message in response.Messages ?? [])
                {
                    using var doc = JsonDocument.Parse(message.Body);
                    var root = doc.RootElement;
                    using var scope = scopes.CreateScope();
                    var audit = scope.ServiceProvider.GetRequiredService<IAuditLog>();

                    var recorded = await audit.AppendAsync(
                        root.GetProperty("id").GetGuid(),
                        root.GetProperty("type").GetString() ?? "unknown",
                        root.GetProperty("at").GetDateTimeOffset(),
                        root.GetProperty("payload").GetRawText(), ct);

                    log.LogInformation("Event {Type} {Status}", root.GetProperty("type").GetString(), recorded ? "recorded" : "duplicate ignored");
                    await sqs.DeleteMessageAsync(queue, message.ReceiptHandle, ct);
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
            catch (Exception ex)
            {
                log.LogWarning(ex, "Queue poll failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), ct).ContinueWith(_ => { });
            }
        }
    }
}
