namespace ExtensionAuditMaui.Services;

public sealed class TokenStore
{
    private const string TokenKey = "GC_ACCESS_TOKEN";

    public Task SaveAsync(string token) => SecureStorage.Default.SetAsync(TokenKey, token);

    public Task<string?> GetAsync() => SecureStorage.Default.GetAsync(TokenKey);

    public void Clear() => SecureStorage.Default.Remove(TokenKey);
}

