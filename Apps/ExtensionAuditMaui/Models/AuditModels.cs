namespace ExtensionAuditMaui.Models;

public sealed record AuditConfig(
    string ApiBaseUri,
    string AccessToken,
    bool IncludeInactive
);

public sealed record ContextSummary(
    DateTimeOffset BuiltAt,
    string ApiBaseUri,
    bool IncludeInactive,
    int UsersTotal,
    int UsersWithProfileExtension,
    int DistinctProfileExtensions,
    int ExtensionsLoaded,
    string ExtensionMode
);

public sealed class UserProfileExtensionRow
{
    public required string UserId { get; init; }
    public string? UserName { get; init; }
    public string? UserEmail { get; init; }
    public string? UserState { get; init; }
    public required string ProfileExtension { get; init; }
}

public sealed class AuditContext
{
    public required AuditConfig Config { get; init; }

    public required List<GenesysUser> Users { get; init; }
    public required Dictionary<string, GenesysUser> UserById { get; init; }
    public required Dictionary<string, string> UserDisplayById { get; init; }
    public required List<UserProfileExtensionRow> UsersWithProfileExtension { get; init; }
    public required List<string> ProfileExtensionNumbers { get; init; }

    public required List<GenesysExtension> Extensions { get; init; }
    public required string ExtensionMode { get; init; } // FULL or TARGETED
    public Dictionary<string, List<GenesysExtension>> ExtensionsByNumber { get; init; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed record MissingAssignmentRow(
    string ProfileExtension,
    string UserId,
    string? UserName,
    string? UserEmail,
    string? UserState
);

public sealed record DiscrepancyRow(
    string Issue,
    string ProfileExtension,
    string UserId,
    string? UserName,
    string? UserEmail,
    string? ExtensionId,
    string? ExtensionOwnerType,
    string? ExtensionOwnerId
);

public sealed record DuplicateUserAssignmentRow(
    string ProfileExtension,
    string UserId,
    string? UserName,
    string? UserEmail,
    string? UserState
);

public sealed record DuplicateExtensionRecordRow(
    string ExtensionNumber,
    string? ExtensionId,
    string? OwnerType,
    string? OwnerId,
    string? ExtensionPoolId
);

public sealed record PatchUpdatedRow(
    string UserId,
    string User,
    string Extension,
    string Status,
    int PatchedVersion
);

public sealed record PatchSkippedRow(
    string Reason,
    string UserId,
    string User,
    string Extension
);

public sealed record PatchFailedRow(
    string UserId,
    string User,
    string Extension,
    string Error
);

public sealed class PatchResult
{
    public required int MissingFound { get; init; }
    public required int Updated { get; init; }
    public required int Skipped { get; init; }
    public required int Failed { get; init; }
    public required bool WhatIf { get; init; }

    public required List<PatchUpdatedRow> UpdatedRows { get; init; }
    public required List<PatchSkippedRow> SkippedRows { get; init; }
    public required List<PatchFailedRow> FailedRows { get; init; }
}

public sealed record ProgressInfo(string Stage, int? Current = null, int? Total = null);

