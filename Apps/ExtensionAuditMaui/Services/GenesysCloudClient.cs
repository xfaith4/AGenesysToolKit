using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ExtensionAuditMaui.Models;

namespace ExtensionAuditMaui.Services;

public sealed record RateLimitSnapshot(
    int? Limit,
    int? Remaining,
    DateTimeOffset? ResetAtUtc,
    DateTimeOffset CapturedAtUtc
);

public sealed class GenesysCloudClient
{
    private readonly HttpClient _http;
    private readonly LogService _log;

    private RateLimitSnapshot? _lastRateLimit;

    public GenesysCloudClient(HttpClient http, LogService log)
    {
        _http = http;
        _log = log;
    }

    public RateLimitSnapshot? LastRateLimit => _lastRateLimit;

    public async Task<GenesysPagedResponse<GenesysUser>?> GetUsersPageAsync(
        AuditConfig cfg,
        int pageSize,
        int pageNumber,
        CancellationToken ct)
    {
        var state = cfg.IncludeInactive ? "" : "&state=active";
        var path = $"/api/v2/users?pageSize={pageSize}&pageNumber={pageNumber}{state}";
        return await SendAsync<GenesysPagedResponse<GenesysUser>>(cfg, HttpMethod.Get, path, null, ct).ConfigureAwait(false);
    }

    public async Task<GenesysPagedResponse<GenesysExtension>?> GetExtensionsPageAsync(
        AuditConfig cfg,
        int pageSize,
        int pageNumber,
        CancellationToken ct)
    {
        var path = $"/api/v2/telephony/providers/edges/extensions?pageSize={pageSize}&pageNumber={pageNumber}";
        return await SendAsync<GenesysPagedResponse<GenesysExtension>>(cfg, HttpMethod.Get, path, null, ct).ConfigureAwait(false);
    }

    public async Task<GenesysPagedResponse<GenesysExtension>?> GetExtensionsByNumberAsync(
        AuditConfig cfg,
        string number,
        CancellationToken ct)
    {
        var escaped = Uri.EscapeDataString(number);
        var path = $"/api/v2/telephony/providers/edges/extensions?number={escaped}";
        return await SendAsync<GenesysPagedResponse<GenesysExtension>>(cfg, HttpMethod.Get, path, null, ct).ConfigureAwait(false);
    }

    public async Task<GenesysUser?> GetUserAsync(AuditConfig cfg, string userId, CancellationToken ct)
    {
        var path = $"/api/v2/users/{Uri.EscapeDataString(userId)}";
        return await SendAsync<GenesysUser>(cfg, HttpMethod.Get, path, null, ct).ConfigureAwait(false);
    }

    public async Task<JsonDocument?> PatchUserAsync(AuditConfig cfg, string userId, object body, CancellationToken ct)
    {
        var path = $"/api/v2/users/{Uri.EscapeDataString(userId)}";
        return await SendAsync<JsonDocument>(cfg, HttpMethod.Patch, path, body, ct).ConfigureAwait(false);
    }

    private async Task PreThrottleIfNeededAsync(CancellationToken ct)
    {
        var snap = _lastRateLimit;
        if (snap is null) return;
        if (snap.Remaining is null) return;
        if (snap.Remaining > 2) return;
        if (snap.ResetAtUtc is null) return;

        var delay = snap.ResetAtUtc.Value - DateTimeOffset.UtcNow + TimeSpan.FromMilliseconds(250);
        if (delay <= TimeSpan.Zero) return;
        if (delay > TimeSpan.FromSeconds(60)) delay = TimeSpan.FromSeconds(60);

        _log.Warn("Rate limit low; throttling", new { snap.Remaining, snap.Limit, ResetUtc = snap.ResetAtUtc, DelayMs = (int)delay.TotalMilliseconds });
        await Task.Delay(delay, ct).ConfigureAwait(false);
    }

    private void CaptureRateLimit(HttpResponseMessage resp)
    {
        int? ParseInt(string? s)
        {
            if (string.IsNullOrWhiteSpace(s)) return null;
            if (int.TryParse(s, out var i)) return i;
            if (double.TryParse(s, out var d)) return (int)d;
            return null;
        }

        string? GetHeader(string name)
        {
            if (resp.Headers.TryGetValues(name, out var values)) return values.FirstOrDefault();
            if (resp.Content?.Headers.TryGetValues(name, out var v2) == true) return v2.FirstOrDefault();
            return null;
        }

        var limit = ParseInt(GetHeader("X-RateLimit-Limit"));
        var remaining = ParseInt(GetHeader("X-RateLimit-Remaining"));
        var resetRaw = GetHeader("X-RateLimit-Reset");

        DateTimeOffset? resetUtc = null;
        if (!string.IsNullOrWhiteSpace(resetRaw) && double.TryParse(resetRaw, out var resetNum))
        {
            try
            {
                if (resetNum > 1000000000000)
                    resetUtc = DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Floor(resetNum));
                else if (resetNum > 1000000000)
                    resetUtc = DateTimeOffset.FromUnixTimeSeconds((long)Math.Floor(resetNum));
                else
                    resetUtc = DateTimeOffset.UtcNow.AddSeconds(Math.Max(0, resetNum));
            }
            catch { resetUtc = null; }
        }

        if (limit is null && remaining is null && resetUtc is null) return;
        _lastRateLimit = new RateLimitSnapshot(limit, remaining, resetUtc, DateTimeOffset.UtcNow);
    }

    private static TimeSpan? GetRetryAfter(HttpResponseMessage resp)
    {
        if (resp.Headers.RetryAfter?.Delta is TimeSpan delta) return delta;
        if (resp.Headers.RetryAfter?.Date is DateTimeOffset dt)
        {
            var d = dt - DateTimeOffset.UtcNow;
            return d > TimeSpan.Zero ? d : TimeSpan.Zero;
        }
        return null;
    }

    private async Task<T?> SendAsync<T>(
        AuditConfig cfg,
        HttpMethod method,
        string pathAndQuery,
        object? body,
        CancellationToken ct,
        int maxRetries = 5)
        where T : class
    {
        if (cfg.ApiBaseUri.EndsWith("/")) cfg = cfg with { ApiBaseUri = cfg.ApiBaseUri.TrimEnd('/') };
        var uri = new Uri(cfg.ApiBaseUri + (pathAndQuery.StartsWith("/") ? pathAndQuery : "/" + pathAndQuery));

        var attempt = 0;
        var backoff = TimeSpan.FromMilliseconds(500);
        var jsonOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        };

        while (true)
        {
            ct.ThrowIfCancellationRequested();
            attempt++;

            await PreThrottleIfNeededAsync(ct).ConfigureAwait(false);

            using var req = new HttpRequestMessage(method, uri);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", cfg.AccessToken);
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

            if (body is not null)
            {
                var json = JsonSerializer.Serialize(body, jsonOptions);
                req.Content = new StringContent(json, Encoding.UTF8, "application/json");
            }

            try
            {
                var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
                CaptureRateLimit(resp);

                if (resp.IsSuccessStatusCode)
                {
                    if (typeof(T) == typeof(JsonDocument))
                    {
                        var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false), cancellationToken: ct).ConfigureAwait(false);
                        return (T)(object)doc;
                    }

                    if (resp.Content is null) return null;
                    await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
                    if (stream is null) return null;
                    return await JsonSerializer.DeserializeAsync<T>(stream, jsonOptions, ct).ConfigureAwait(false);
                }

                var status = (int)resp.StatusCode;
                var retryable = resp.StatusCode == (HttpStatusCode)429 || (status >= 500 && status <= 599);

                var payload = "";
                try { payload = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false); } catch { }

                _log.Warn("API request failed", new { Attempt = attempt, Method = method.Method, Url = uri.ToString(), Status = status, Retryable = retryable });

                if (!retryable || attempt >= maxRetries)
                {
                    throw new HttpRequestException($"Genesys API call failed: {method} {pathAndQuery} (HTTP {status}). {payload}");
                }

                var retryAfter = GetRetryAfter(resp);
                var delay = retryAfter ?? backoff;
                if (delay < backoff) delay = backoff;
                if (delay > TimeSpan.FromSeconds(60)) delay = TimeSpan.FromSeconds(60);

                var jitter = TimeSpan.FromMilliseconds(Random.Shared.Next(0, 200));
                await Task.Delay(delay + jitter, ct).ConfigureAwait(false);

                backoff = TimeSpan.FromMilliseconds(Math.Min(8000, backoff.TotalMilliseconds * 1.8));
            }
            catch (OperationCanceledException) { throw; }
        }
    }
}

