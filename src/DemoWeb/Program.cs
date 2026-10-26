using System.Diagnostics;
using System.Net;
using System.Text;
using Azure.Monitor.OpenTelemetry.AspNetCore;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(options =>
{
    options.UseUtcTimestamp = true;
    options.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
});
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);

var telemetryEnabled = !string.IsNullOrWhiteSpace(
    builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]);
if (telemetryEnabled)
{
    builder.Services.AddOpenTelemetry().UseAzureMonitor(options => options.SamplingRatio = 1.0F);
}

var app = builder.Build();
if (!telemetryEnabled)
{
    app.Logger.LogWarning("Application Insights is disabled: APPLICATIONINSIGHTS_CONNECTION_STRING is not set. This is intended only for local testing.");
}

var modeFile = builder.Configuration["FAILURE_MODE_FILE"];
var localMode = builder.Configuration["FailureMode"] ?? "healthy";
var pod = Environment.GetEnvironmentVariable("HOSTNAME") ?? Environment.MachineName;

DemoStatus ReadStatus(HttpContext context)
{
    context.Response.Headers.CacheControl = "no-store";
    var mode = localMode;
    var message = "All systems operational. Requests are succeeding.";
    var statusCode = StatusCodes.Status200OK;

    try
    {
        if (!string.IsNullOrWhiteSpace(modeFile))
        {
            mode = File.ReadAllText(modeFile).Trim();
        }

        switch (mode)
        {
            case "healthy":
                break;
            case "http500":
                statusCode = StatusCodes.Status500InternalServerError;
                message = "The application is returning HTTP 500 because its failure-mode setting is http500.";
                break;
            default:
                statusCode = StatusCodes.Status500InternalServerError;
                message = "Invalid application configuration. failure-mode must be healthy or http500.";
                app.Logger.LogError("Invalid failure-mode value {FailureMode} in {ConfigFile}", mode, modeFile);
                mode = "configuration-error";
                break;
        }
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
    {
        statusCode = StatusCodes.Status500InternalServerError;
        mode = "configuration-error";
        message = "The application cannot read its failure-mode configuration. Inspect the application logs.";
        app.Logger.LogError(exception, "Cannot read failure-mode configuration from {ConfigFile}", modeFile);
    }

    var traceId = Activity.Current?.TraceId.ToString() ?? context.TraceIdentifier;
    Activity.Current?.SetTag("demo.failure_mode", mode);
    if (statusCode == StatusCodes.Status500InternalServerError)
    {
        app.Logger.LogError(
            "Demo request failed: HTTP {StatusCode}; failure-mode={FailureMode}; pod={Pod}; traceId={TraceId}",
            statusCode, mode, pod, traceId);
    }
    else
    {
        app.Logger.LogInformation("Demo request succeeded: failure-mode={FailureMode}; pod={Pod}", mode, pod);
    }

    return new DemoStatus(statusCode, mode, message, pod, DateTimeOffset.UtcNow, traceId);
}

app.MapGet("/health/live", () => Results.Ok(new { status = "alive" }));
app.MapGet("/health/ready", () => Results.Ok(new { status = "ready" }));
app.MapGet("/api/status", (HttpContext context) =>
{
    var status = ReadStatus(context);
    return Results.Json(status, statusCode: status.StatusCode);
});
app.MapGet("/", (HttpContext context) =>
{
    var status = ReadStatus(context);
    var healthy = status.StatusCode == StatusCodes.Status200OK;
    var title = healthy ? "All systems operational" : "Application incident";
    var color = healthy ? "#34d399" : "#fb7185";
    var page = $$"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>AKS Operations Demo - HTTP {{status.StatusCode}}</title>
          <style>
            :root { color-scheme: dark; font-family: system-ui, sans-serif; }
            body { margin: 0; background: #0b1220; color: #e2e8f0; }
            main { max-width: 880px; margin: 7vh auto; padding: 32px; }
            .eyebrow { color: #94a3b8; letter-spacing: .15em; text-transform: uppercase; }
            h1 { font-size: clamp(2rem, 5vw, 3.5rem); margin-bottom: 16px; }
            .badge { display: inline-block; padding: 10px 18px; border: 1px solid {{color}};
                     border-radius: 30px; color: {{color}}; font-weight: 700; }
            .card { margin-top: 30px; padding: 24px; background: #162033; border-radius: 16px; }
            dl { display: grid; grid-template-columns: 130px 1fr; gap: 14px; }
            dt { color: #94a3b8; } dd { margin: 0; overflow-wrap: anywhere; }
            code { color: {{color}}; } a { color: #7dd3fc; }
            .note { color: #94a3b8; line-height: 1.7; }
          </style>
        </head>
        <body><main>
          <p class="eyebrow">Azure Kubernetes Service / SRE Operations Demo</p>
          <span class="badge">HTTP {{status.StatusCode}} / {{(healthy ? "HEALTHY" : "FAILED")}}</span>
          <h1>{{title}}</h1>
          <p>{{WebUtility.HtmlEncode(status.Message)}}</p>
          <section class="card" aria-label="Request details">
            <dl>
              <dt>Failure mode</dt><dd><code>{{WebUtility.HtmlEncode(status.Mode)}}</code></dd>
              <dt>Pod</dt><dd>{{WebUtility.HtmlEncode(status.Pod)}}</dd>
              <dt>UTC time</dt><dd>{{status.Timestamp:O}}</dd>
              <dt>Trace ID</dt><dd>{{WebUtility.HtmlEncode(status.TraceId)}}</dd>
            </dl>
          </section>
          <p class="note">The Kubernetes ConfigMap <code>demo-settings</code> controls the
            <code>failure-mode</code> setting. Kubernetes probes stay healthy during an injected incident.
            Application Insights records these requests and Azure Monitor evaluates HTTP 5XX failures.</p>
          <p><a href="/">Refresh page</a> &nbsp; / &nbsp; <a href="/api/status">View JSON status</a></p>
        </main></body>
        </html>
        """;
    return Results.Content(page, "text/html", Encoding.UTF8, status.StatusCode);
});

app.Run();

internal sealed record DemoStatus(
    int StatusCode, string Mode, string Message, string Pod, DateTimeOffset Timestamp, string TraceId);
