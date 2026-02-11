using ExtensionAuditMaui.Models;

namespace ExtensionAuditMaui.Services;

public sealed class AuditState
{
    public AuditContext? Context { get; private set; }
    public ContextSummary? Summary { get; private set; }

    public bool HasContext => Context is not null && Summary is not null;

    public void SetContext(AuditContext ctx, ContextSummary summary)
    {
        Context = ctx;
        Summary = summary;
    }

    public void Clear()
    {
        Context = null;
        Summary = null;
    }
}

