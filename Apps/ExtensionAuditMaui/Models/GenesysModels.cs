using System.Text.Json.Serialization;

namespace ExtensionAuditMaui.Models;

public sealed class GenesysPagedResponse<T>
{
    [JsonPropertyName("entities")]
    public List<T>? Entities { get; set; }

    [JsonPropertyName("pageCount")]
    public int PageCount { get; set; }
}

public sealed class GenesysUser
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("email")]
    public string? Email { get; set; }

    [JsonPropertyName("state")]
    public string? State { get; set; }

    [JsonPropertyName("version")]
    public int Version { get; set; }

    [JsonPropertyName("addresses")]
    public List<GenesysUserAddress>? Addresses { get; set; }
}

public sealed class GenesysUserAddress
{
    [JsonPropertyName("mediaType")]
    public string? MediaType { get; set; }

    [JsonPropertyName("type")]
    public string? Type { get; set; }

    [JsonPropertyName("extension")]
    public string? Extension { get; set; }
}

public sealed class GenesysExtension
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("number")]
    public string? Number { get; set; }

    [JsonPropertyName("ownerType")]
    public string? OwnerType { get; set; }

    [JsonPropertyName("owner")]
    public GenesysIdRef? Owner { get; set; }

    [JsonPropertyName("extensionPool")]
    public GenesysIdRef? ExtensionPool { get; set; }
}

public sealed class GenesysIdRef
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }
}

