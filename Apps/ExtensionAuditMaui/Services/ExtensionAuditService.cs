using ExtensionAuditMaui.Models;

namespace ExtensionAuditMaui.Services;

public sealed class ExtensionAuditService
{
    private readonly GenesysCloudClient _gc;
    private readonly LogService _log;

    public ExtensionAuditService(GenesysCloudClient gc, LogService log)
    {
        _gc = gc;
        _log = log;
    }

    public static string? GetUserProfileExtension(GenesysUser user)
    {
        var addresses = user.Addresses ?? [];
        var phones = addresses.Where(a => a is not null && string.Equals(a.MediaType, "PHONE", StringComparison.OrdinalIgnoreCase)).ToList();
        if (phones.Count == 0) return null;

        var work = phones.Where(a => string.Equals(a.Type, "WORK", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(a.Extension)).ToList();
        if (work.Count > 0) return work[0].Extension?.Trim();

        var any = phones.Where(a => !string.IsNullOrWhiteSpace(a.Extension)).ToList();
        if (any.Count > 0) return any[0].Extension?.Trim();

        return null;
    }

    public async Task<(AuditContext Context, ContextSummary Summary)> BuildContextAsync(
        AuditConfig cfg,
        IProgress<ProgressInfo>? progress,
        CancellationToken ct,
        int usersPageSize = 200,
        int extensionsPageSize = 100,
        int maxFullExtensionPages = 25)
    {
        _log.Info("Building audit context", new { cfg.ApiBaseUri, cfg.IncludeInactive, UsersPageSize = usersPageSize, ExtensionsPageSize = extensionsPageSize, MaxFullExtensionPages = maxFullExtensionPages });

        // Users
        var users = new List<GenesysUser>(capacity: 2000);
        var page = 1;
        GenesysPagedResponse<GenesysUser>? respUsers;
        do
        {
            progress?.Report(new ProgressInfo("Fetching users", page, null));
            respUsers = await _gc.GetUsersPageAsync(cfg, usersPageSize, page, ct).ConfigureAwait(false);
            var ents = respUsers?.Entities ?? [];
            users.AddRange(ents);
            _log.Info("Users page fetched", new { PageNumber = page, respUsers?.PageCount, Entities = ents.Count, TotalSoFar = users.Count });
            page++;
        } while (respUsers is not null && page <= respUsers.PageCount && respUsers.PageCount > 0);

        // User lookups + profile extensions
        progress?.Report(new ProgressInfo("Processing users"));
        var userById = new Dictionary<string, GenesysUser>(StringComparer.OrdinalIgnoreCase);
        var userDisplayById = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var usersWithProfileExt = new List<UserProfileExtensionRow>();
        var profileExtNumbers = new List<string>();

        foreach (var u in users)
        {
            if (u is null) continue;
            if (string.IsNullOrWhiteSpace(u.Id)) continue;
            userById[u.Id] = u;

            var disp = !string.IsNullOrWhiteSpace(u.Email) ? $"{u.Name} <{u.Email}>" : (u.Name ?? u.Id);
            userDisplayById[u.Id] = disp;

            var ext = GetUserProfileExtension(u);
            if (!string.IsNullOrWhiteSpace(ext))
            {
                usersWithProfileExt.Add(new UserProfileExtensionRow
                {
                    UserId = u.Id,
                    UserName = u.Name,
                    UserEmail = u.Email,
                    UserState = u.State,
                    ProfileExtension = ext!
                });
                profileExtNumbers.Add(ext!);
            }
        }

        var distinctProfile = profileExtNumbers
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Select(n => n.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase)
            .ToList();

        _log.Info("User profile extensions collected", new { UsersTotal = users.Count, UsersWithProfileExtension = usersWithProfileExt.Count, DistinctProfileExtensions = distinctProfile.Count });

        // Extensions strategy
        progress?.Report(new ProgressInfo("Probing extensions"));
        var probe = await _gc.GetExtensionsPageAsync(cfg, extensionsPageSize, 1, ct).ConfigureAwait(false);
        var pageCount = probe?.PageCount ?? 0;

        var extensions = new List<GenesysExtension>();
        string mode;

        if (pageCount > 0 && pageCount <= maxFullExtensionPages)
        {
            mode = "FULL";
            _log.Info("Fetching extensions (full crawl)", new { extensionsPageSize, PageCount = pageCount });

            var ePage = 1;
            GenesysPagedResponse<GenesysExtension>? respExt;
            do
            {
                progress?.Report(new ProgressInfo("Fetching extensions (full)", ePage, pageCount));
                respExt = await _gc.GetExtensionsPageAsync(cfg, extensionsPageSize, ePage, ct).ConfigureAwait(false);
                var ents = respExt?.Entities ?? [];
                extensions.AddRange(ents);
                _log.Info("Extensions page fetched", new { PageNumber = ePage, respExt?.PageCount, Entities = ents.Count, TotalSoFar = extensions.Count });
                ePage++;
            } while (respExt is not null && ePage <= respExt.PageCount && respExt.PageCount > 0);
        }
        else
        {
            mode = "TARGETED";
            _log.Info("Fetching extensions (targeted by number)", new { DistinctNumbers = distinctProfile.Count, SleepMs = 75 });

            var i = 0;
            foreach (var n in distinctProfile)
            {
                ct.ThrowIfCancellationRequested();
                i++;
                progress?.Report(new ProgressInfo("Fetching extensions (targeted)", i, distinctProfile.Count));

                try
                {
                    var r = await _gc.GetExtensionsByNumberAsync(cfg, n, ct).ConfigureAwait(false);
                    var ents = r?.Entities ?? [];
                    extensions.AddRange(ents);
                }
                catch (Exception ex)
                {
                    _log.Warn($"Extension lookup failed for number {n}", new { Error = ex.Message });
                }

                await Task.Delay(75, ct).ConfigureAwait(false);
            }
        }

        _log.Info("Extensions loaded", new { Mode = mode, ProbePageCount = pageCount, ExtensionsLoaded = extensions.Count });

        // By number
        var byNumber = new Dictionary<string, List<GenesysExtension>>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in extensions)
        {
            var num = (e?.Number ?? "").Trim();
            if (string.IsNullOrWhiteSpace(num)) continue;
            if (!byNumber.TryGetValue(num, out var list))
            {
                list = new List<GenesysExtension>();
                byNumber[num] = list;
            }
            list.Add(e);
        }

        var context = new AuditContext
        {
            Config = cfg,
            Users = users,
            UserById = userById,
            UserDisplayById = userDisplayById,
            UsersWithProfileExtension = usersWithProfileExt,
            ProfileExtensionNumbers = distinctProfile,
            Extensions = extensions,
            ExtensionMode = mode,
            ExtensionsByNumber = byNumber
        };

        var summary = new ContextSummary(
            BuiltAt: DateTimeOffset.Now,
            ApiBaseUri: cfg.ApiBaseUri,
            IncludeInactive: cfg.IncludeInactive,
            UsersTotal: users.Count,
            UsersWithProfileExtension: usersWithProfileExt.Count,
            DistinctProfileExtensions: distinctProfile.Count,
            ExtensionsLoaded: extensions.Count,
            ExtensionMode: mode
        );

        return (context, summary);
    }

    public List<DuplicateUserAssignmentRow> FindDuplicateUserAssignments(AuditContext ctx)
    {
        var byExt = ctx.UsersWithProfileExtension
            .GroupBy(r => r.ProfileExtension ?? "", StringComparer.OrdinalIgnoreCase)
            .Where(g => !string.IsNullOrWhiteSpace(g.Key) && g.Count() > 1);

        var rows = new List<DuplicateUserAssignmentRow>();
        foreach (var g in byExt)
        {
            foreach (var row in g)
            {
                rows.Add(new DuplicateUserAssignmentRow(
                    ProfileExtension: g.Key,
                    UserId: row.UserId,
                    UserName: row.UserName,
                    UserEmail: row.UserEmail,
                    UserState: row.UserState
                ));
            }
        }

        _log.Info("Duplicate user extension assignments", new { DuplicateRows = rows.Count, DuplicateExtensions = rows.Select(r => r.ProfileExtension).Distinct(StringComparer.OrdinalIgnoreCase).Count() });
        return rows;
    }

    public List<DuplicateExtensionRecordRow> FindDuplicateExtensionRecords(AuditContext ctx)
    {
        var rows = new List<DuplicateExtensionRecordRow>();
        foreach (var (num, arr) in ctx.ExtensionsByNumber)
        {
            if (arr.Count <= 1) continue;
            foreach (var e in arr)
            {
                rows.Add(new DuplicateExtensionRecordRow(
                    ExtensionNumber: num,
                    ExtensionId: e.Id,
                    OwnerType: e.OwnerType,
                    OwnerId: e.Owner?.Id,
                    ExtensionPoolId: e.ExtensionPool?.Id
                ));
            }
        }

        _log.Info("Duplicate extension records", new { DuplicateRows = rows.Count, DuplicateNumbers = rows.Select(r => r.ExtensionNumber).Distinct(StringComparer.OrdinalIgnoreCase).Count() });
        return rows;
    }

    public List<DiscrepancyRow> FindDiscrepancies(AuditContext ctx)
    {
        var dupUserSet = FindDuplicateUserAssignments(ctx).Select(r => r.ProfileExtension).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var dupExtSet = FindDuplicateExtensionRecords(ctx).Select(r => r.ExtensionNumber).ToHashSet(StringComparer.OrdinalIgnoreCase);

        var rows = new List<DiscrepancyRow>();
        foreach (var u in ctx.UsersWithProfileExtension)
        {
            var n = (u.ProfileExtension ?? "").Trim();
            if (string.IsNullOrWhiteSpace(n)) continue;
            if (dupUserSet.Contains(n)) continue;
            if (dupExtSet.Contains(n)) continue;

            var extList = ctx.ExtensionsByNumber.TryGetValue(n, out var list) ? list : [];
            if (extList.Count == 0) continue;
            if (extList.Count > 1) continue;

            var e = extList[0];
            var ownerType = (e.OwnerType ?? "").Trim();
            var ownerId = (e.Owner?.Id ?? "").Trim();

            if (!ownerType.Equals("USER", StringComparison.OrdinalIgnoreCase))
            {
                rows.Add(new DiscrepancyRow(
                    Issue: "OwnerTypeNotUser",
                    ProfileExtension: n,
                    UserId: u.UserId,
                    UserName: u.UserName,
                    UserEmail: u.UserEmail,
                    ExtensionId: e.Id,
                    ExtensionOwnerType: ownerType,
                    ExtensionOwnerId: ownerId
                ));
                continue;
            }

            if (!string.IsNullOrWhiteSpace(ownerId) && !ownerId.Equals(u.UserId, StringComparison.OrdinalIgnoreCase))
            {
                rows.Add(new DiscrepancyRow(
                    Issue: "OwnerMismatch",
                    ProfileExtension: n,
                    UserId: u.UserId,
                    UserName: u.UserName,
                    UserEmail: u.UserEmail,
                    ExtensionId: e.Id,
                    ExtensionOwnerType: ownerType,
                    ExtensionOwnerId: ownerId
                ));
            }
        }

        _log.Info("Extension discrepancies found", new { Count = rows.Count });
        return rows;
    }

    public List<MissingAssignmentRow> FindMissingAssignments(AuditContext ctx)
    {
        var dupUserSet = FindDuplicateUserAssignments(ctx).Select(r => r.ProfileExtension).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var dupExtSet = FindDuplicateExtensionRecords(ctx).Select(r => r.ExtensionNumber).ToHashSet(StringComparer.OrdinalIgnoreCase);

        var rows = new List<MissingAssignmentRow>();
        foreach (var u in ctx.UsersWithProfileExtension)
        {
            var n = (u.ProfileExtension ?? "").Trim();
            if (string.IsNullOrWhiteSpace(n)) continue;
            if (dupUserSet.Contains(n)) continue;
            if (dupExtSet.Contains(n)) continue;

            var hasAny = ctx.ExtensionsByNumber.TryGetValue(n, out var extList) && extList.Count > 0;
            if (!hasAny)
            {
                rows.Add(new MissingAssignmentRow(
                    ProfileExtension: n,
                    UserId: u.UserId,
                    UserName: u.UserName,
                    UserEmail: u.UserEmail,
                    UserState: u.UserState
                ));
            }
        }

        _log.Info("Missing assignments found (profile ext not in extension list)", new { Count = rows.Count });
        return rows;
    }

    public async Task<PatchResult> PatchMissingAssignmentsAsync(
        AuditContext ctx,
        bool whatIf,
        int sleepMsBetween,
        int maxUpdates,
        IProgress<ProgressInfo>? progress,
        CancellationToken ct)
    {
        var missing = FindMissingAssignments(ctx);
        var dupUsers = FindDuplicateUserAssignments(ctx);
        var dupSet = dupUsers.Select(d => d.ProfileExtension).ToHashSet(StringComparer.OrdinalIgnoreCase);

        var updated = new List<PatchUpdatedRow>();
        var skipped = new List<PatchSkippedRow>();
        var failed = new List<PatchFailedRow>();

        var done = 0;
        var i = 0;
        foreach (var m in missing)
        {
            ct.ThrowIfCancellationRequested();
            i++;
            progress?.Report(new ProgressInfo("Patching missing assignments", i, missing.Count));

            if (dupSet.Contains(m.ProfileExtension))
            {
                skipped.Add(new PatchSkippedRow("DuplicateUserAssignment", m.UserId, ctx.UserDisplayById.GetValueOrDefault(m.UserId, m.UserId), m.ProfileExtension));
                continue;
            }

            if (maxUpdates > 0 && done >= maxUpdates)
            {
                skipped.Add(new PatchSkippedRow("MaxUpdatesReached", m.UserId, ctx.UserDisplayById.GetValueOrDefault(m.UserId, m.UserId), m.ProfileExtension));
                continue;
            }

            try
            {
                var userDisplay = ctx.UserDisplayById.GetValueOrDefault(m.UserId, m.UserId);
                _log.Info("Patching missing assignment (user resync)", new { m.UserId, User = userDisplay, Extension = m.ProfileExtension, WhatIf = whatIf });

                if (whatIf)
                {
                    updated.Add(new PatchUpdatedRow(m.UserId, userDisplay, m.ProfileExtension, "WhatIf", 0));
                    done++;
                    continue;
                }

                var u = await _gc.GetUserAsync(ctx.Config, m.UserId, ct).ConfigureAwait(false);
                if (u?.Id is null) throw new Exception($"Failed to GET user {m.UserId}.");

                var addresses = (u.Addresses ?? []).ToList();
                var idx = -1;
                for (var ai = 0; ai < addresses.Count; ai++)
                {
                    if (string.Equals(addresses[ai].MediaType, "PHONE", StringComparison.OrdinalIgnoreCase) &&
                        string.Equals(addresses[ai].Type, "WORK", StringComparison.OrdinalIgnoreCase))
                    {
                        idx = ai;
                        break;
                    }
                }
                if (idx < 0)
                {
                    for (var ai = 0; ai < addresses.Count; ai++)
                    {
                        if (string.Equals(addresses[ai].MediaType, "PHONE", StringComparison.OrdinalIgnoreCase))
                        {
                            idx = ai;
                            break;
                        }
                    }
                }
                if (idx < 0) throw new Exception($"User {m.UserId} has no PHONE address entry to set extension.");

                addresses[idx].Extension = m.ProfileExtension;

                var patchBody = new Dictionary<string, object?>
                {
                    ["addresses"] = addresses,
                    ["version"] = u.Version + 1
                };

                _ = await _gc.PatchUserAsync(ctx.Config, m.UserId, patchBody, ct).ConfigureAwait(false);

                updated.Add(new PatchUpdatedRow(m.UserId, userDisplay, m.ProfileExtension, "Patched", u.Version + 1));
                done++;

                if (sleepMsBetween > 0) await Task.Delay(sleepMsBetween, ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                var userDisplay = ctx.UserDisplayById.GetValueOrDefault(m.UserId, m.UserId);
                failed.Add(new PatchFailedRow(m.UserId, userDisplay, m.ProfileExtension, ex.Message));
                _log.Error("Patch failed", new { m.UserId, Extension = m.ProfileExtension, Error = ex.Message });
            }
        }

        return new PatchResult
        {
            MissingFound = missing.Count,
            Updated = updated.Count,
            Skipped = skipped.Count,
            Failed = failed.Count,
            WhatIf = whatIf,
            UpdatedRows = updated,
            SkippedRows = skipped,
            FailedRows = failed
        };
    }
}

