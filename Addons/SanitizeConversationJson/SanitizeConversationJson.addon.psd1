@{
  Id          = 'sanitize-conversation-json'
  Name        = 'Sanitize Conversation JSON'
  Version     = '0.1.0'
  Workspace   = 'Conversations'
  Module      = 'Sanitize Conversation JSON'
  Description = 'Remove PII from Genesys Cloud conversation JSON exports (local file sanitizer).'
  EntryPoint  = 'SanitizeConversationJson.Addon.ps1'
  ViewFactory = 'New-GcSanitizeConversationJsonAddonView'
}

