using System.Collections.Concurrent;
using System.Text.Json;

namespace ExtensionAuditMaui.Services;

public enum LogLevel
{
    Debug,
    Info,
    Warn,
    Error
}

public sealed record LogLine(DateTimeOffset Timestamp, LogLevel Level, string Message, object? Data);

public sealed class LogService : IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private StreamWriter? _writer;
    private string? _logPath;

    private readonly ConcurrentQueue<LogLine> _buffer = new();
    private const int MaxBufferedLines = 2000;

    public event EventHandler<LogLine>? LineAppended;

    public string? LogPath => _logPath;

    public void InitializeNewLogFile(string prefix = "ExtensionAudit")
    {
        var dir = Path.Combine(FileSystem.AppDataDirectory, "Logs", "ExtensionAudit");
        Directory.CreateDirectory(dir);

        var ts = DateTimeOffset.Now.ToString("yyyyMMdd_HHmmss");
        _logPath = Path.Combine(dir, $"{prefix}_{ts}.log");

        _writer?.Dispose();
        _writer = new StreamWriter(new FileStream(_logPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
        {
            AutoFlush = true
        };

        Info("Logging initialized", new { LogPath = _logPath });
    }

    public void Debug(string message, object? data = null) => Write(LogLevel.Debug, message, data);
    public void Info(string message, object? data = null) => Write(LogLevel.Info, message, data);
    public void Warn(string message, object? data = null) => Write(LogLevel.Warn, message, data);
    public void Error(string message, object? data = null) => Write(LogLevel.Error, message, data);

    public void Write(LogLevel level, string message, object? data = null)
    {
        var line = new LogLine(DateTimeOffset.Now, level, message, data);

        _buffer.Enqueue(line);
        while (_buffer.Count > MaxBufferedLines && _buffer.TryDequeue(out _)) { }

        LineAppended?.Invoke(this, line);

        _ = WriteToFileAsync(line);
    }

    private async Task WriteToFileAsync(LogLine line)
    {
        if (_writer is null) return;

        try
        {
            await _gate.WaitAsync().ConfigureAwait(false);

            var safeData = RedactIfNeeded(line.Data);
            var json = safeData is null
                ? ""
                : " | " + JsonSerializer.Serialize(safeData, new JsonSerializerOptions { WriteIndented = false });

            var text = $"[{line.Timestamp:yyyy-MM-dd HH:mm:ss.fff}] [{line.Level}] {line.Message}{json}";
            await _writer.WriteLineAsync(text).ConfigureAwait(false);
        }
        catch
        {
            // Avoid recursive logging failures.
        }
        finally
        {
            try { _gate.Release(); } catch { }
        }
    }

    private static object? RedactIfNeeded(object? data)
    {
        if (data is null) return null;

        if (data is IDictionary<string, object?> dict)
        {
            var outDict = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            foreach (var (k, v) in dict)
            {
                if (IsSensitiveKey(k)) outDict[k] = "***REDACTED***";
                else outDict[k] = RedactIfNeeded(v);
            }
            return outDict;
        }

        return data;
    }

    private static bool IsSensitiveKey(string key)
    {
        key = key ?? "";
        return key.Equals("authorization", StringComparison.OrdinalIgnoreCase)
            || key.Equals("access_token", StringComparison.OrdinalIgnoreCase)
            || key.Equals("refresh_token", StringComparison.OrdinalIgnoreCase)
            || key.Equals("token", StringComparison.OrdinalIgnoreCase)
            || key.Equals("password", StringComparison.OrdinalIgnoreCase)
            || key.Equals("client_secret", StringComparison.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        try { _writer?.Dispose(); } catch { }
        _writer = null;
    }
}

