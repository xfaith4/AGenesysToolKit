using System.Reflection;
using System.Text;

namespace ExtensionAuditMaui.Services;

public sealed class CsvExportService
{
    private readonly LogService _log;

    public CsvExportService(LogService log)
    {
        _log = log;
    }

    public async Task<string> ExportAsync<T>(IReadOnlyCollection<T> rows, string fileNamePrefix, CancellationToken ct)
    {
        var outDir = Path.Combine(FileSystem.AppDataDirectory, "Out");
        Directory.CreateDirectory(outDir);

        var ts = DateTimeOffset.Now.ToString("yyyyMMdd_HHmmss");
        var path = Path.Combine(outDir, $"{fileNamePrefix}_{ts}.csv");

        var props = typeof(T).GetProperties(BindingFlags.Public | BindingFlags.Instance);
        await using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
        await using var sw = new StreamWriter(fs, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

        await sw.WriteLineAsync(string.Join(",", props.Select(p => Escape(p.Name)))).ConfigureAwait(false);
        foreach (var row in rows)
        {
            ct.ThrowIfCancellationRequested();
            var values = props.Select(p => Escape(p.GetValue(row)?.ToString() ?? "")).ToArray();
            await sw.WriteLineAsync(string.Join(",", values)).ConfigureAwait(false);
        }

        _log.Info("CSV exported", new { Path = path, Rows = rows.Count });
        return path;
    }

    private static string Escape(string s)
    {
        s ??= "";
        if (s.Contains('"') || s.Contains(',') || s.Contains('\n') || s.Contains('\r'))
        {
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        }
        return s;
    }
}

