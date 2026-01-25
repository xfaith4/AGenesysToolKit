@{
  Id          = 'sample-addon'
  Name        = 'Sample Addon'
  Version     = '0.1.0'
  Workspace   = 'Operations'
  Module      = 'Sample Addon'
  Description = 'Template addon: shows a simple view and a button.'
  EntryPoint  = 'SampleAddon.Addon.ps1'
  ViewFactory = 'New-GcSampleAddonView'
}

