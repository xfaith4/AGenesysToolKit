# Addons

Addons are **manifest-driven** extensions that live under `Addons/` and can appear as **modules** under one of the existing left-rail workspaces in the WPF app.

## How discovery works

At app startup, `App/GenesysCloudTool.ps1` scans for `*.addon.psd1` files under `Addons/` (recursively) and:

- Adds the addon `Module` to the specified `Workspace` in the module rail
- Routes `Workspace::Module` to the addon when selected
- Dot-sources the addon `EntryPoint` on first use
- Calls `ViewFactory` (if provided) to render the in-app view

If `ViewFactory` is not provided (or not found), the app shows a small launcher view with shortcuts to open the addon folder/entry/manifest.

## Manifest format (`*.addon.psd1`)

Minimum required keys:

```powershell
@{
  Workspace  = 'Conversations'               # must match an existing workspace
  Module     = 'My Addon Module Name'        # appears in the module rail
  EntryPoint = 'MyAddon.Addon.ps1'           # relative to the manifest folder
}
```

Common optional keys:

```powershell
@{
  Id          = 'my-addon-id'
  Name        = 'My Addon'
  Version     = '0.1.0'
  Description = 'What this does'
  ViewFactory = 'New-GcMyAddonView'          # function defined in EntryPoint
}
```

Supported workspaces (current app):
- `Orchestration`
- `Routing & People`
- `Conversations`
- `Operations`
- `Reports & Exports`

## EntryPoint (`*.Addon.ps1`)

The entrypoint should be **safe to dot-source** (no side effects). It typically defines a `ViewFactory` function that returns a WPF `UserControl`.

The app calls the view factory with:

```powershell
New-GcMyAddonView -Addon $Addon
```

## Template

Copy `Addons/_Template/` as a starting point. The app intentionally ignores manifests inside `_Template/`.

