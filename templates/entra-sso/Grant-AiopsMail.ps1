<#
.SYNOPSIS
  Retrofits the aiops MAIL RIDER onto an EXISTING "<code>-sso" registration - for clients
  whose registration predates the rider (New-ClientSSO.ps1 creates it inline since 2026-08).
  After this, the client's Claude Code Terminals send and read mail as aiops@<clientdomain>
  via templates/aiops-mail.sh (device-code sign-in, no secret on the mail path).

.DESCRIPTION
  Idempotent - safe to re-run. Three changes, each skipped if already true:
    1. Declares delegated Mail.Read / Mail.ReadWrite / Mail.Send on the registration
       (portal visibility; declaration alone grants nothing).
    2. Enables the public-client fallback (device-code flow for the terminal's mail tool).
    3. Consents the mail scopes for the aiops PRINCIPAL ONLY (consentType 'Principal') -
       never tenant-wide: no other user's mailbox is ever reachable through this app.

  Run by a Global Administrator of the CLIENT's tenant - adNET staff for managed tenants
  (relay flow from a terminal works: get-graph-token-devicecode.sh -> -UseEnvToken), the
  client's own IT provider otherwise.

.EXAMPLE
  ./Grant-AiopsMail.ps1 -ClientCode acme -AiopsUpn aiops@acme-example.com

.NOTES
  WARNING: First-run status: authored 2026-08-14 from the documented Graph SDK surface; do
  the first execution against an adNET-controlled tenant and fix forward before sending to
  an external provider.
#>
param(
  # Short client code - the registration is "<code>-sso".
  [Parameter(Mandatory)] [string]$ClientCode,
  # UPN of the aiops service account whose mailbox the terminals use. The consent grant is
  # scoped to exactly this principal.
  [Parameter(Mandatory)] [string]$AiopsUpn,
  # Sign in via device code (admin enters the printed code from their OWN device).
  [switch]$DeviceCode,
  # Pre-acquired Graph access token via $env:GRAPH_TOKEN (the relay flow - preferred when
  # Claude runs this on a terminal; mint with get-graph-token-devicecode.sh).
  [switch]$UseEnvToken
)
$ErrorActionPreference = 'Stop'

$AppName    = "$ClientCode-sso"
$MailScopes = 'Mail.Read','Mail.ReadWrite','Mail.Send'

$scopes = @('Application.ReadWrite.All','Directory.Read.All','DelegatedPermissionGrant.ReadWrite.All')
if ($UseEnvToken)    { Connect-MgGraph -AccessToken (ConvertTo-SecureString $env:GRAPH_TOKEN -AsPlainText -Force) -NoWelcome }
elseif ($DeviceCode) { Connect-MgGraph -Scopes $scopes -UseDeviceCode -NoWelcome -ClientTimeout 900 }
else                 { Connect-MgGraph -Scopes $scopes -NoWelcome }

$app = Get-MgApplication -Filter "displayName eq '$AppName'" -Top 1
if (-not $app) { throw "'$AppName' not found in this tenant - run New-ClientSSO.ps1 first (ONE registration per client, ever)." }
$sp      = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
if (-not $sp) { $sp = New-MgServicePrincipal -AppId $app.AppId }
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$aiops   = Get-MgUser -UserId $AiopsUpn

# 1 - declare the delegated mail scopes (merge into the existing Graph resource block)
$graphReq = $app.RequiredResourceAccess | Where-Object ResourceAppId -eq $graphSp.AppId
if (-not $graphReq) { throw "Registration has no Microsoft Graph resource block - unexpected shape; extend by hand." }
$existing = @($graphReq.ResourceAccess)
$added = @()
foreach ($v in $MailScopes) {
  $s = $graphSp.Oauth2PermissionScopes | Where-Object Value -eq $v
  if (-not $s) { throw "Graph scope '$v' not found" }
  if (-not ($existing | Where-Object { $_.Id -eq $s.Id -and $_.Type -eq 'Scope' })) {
    $existing += @{ Id = $s.Id; Type = 'Scope' }; $added += $v
  }
}
if ($added) {
  $other = @($app.RequiredResourceAccess | Where-Object ResourceAppId -ne $graphSp.AppId)
  Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess `
    ($other + @(@{ ResourceAppId = $graphSp.AppId; ResourceAccess = $existing }))
  Write-Host "Declared: $($added -join ', ')"
} else { Write-Host 'Declared mail scopes already present - skipped.' }

# 2 - public-client fallback (device-code for aiops-mail.sh; the Access web flow is untouched)
if (-not $app.IsFallbackPublicClient) {
  Update-MgApplication -ApplicationId $app.Id -IsFallbackPublicClient:$true
  Write-Host 'Enabled public-client fallback (device-code).'
} else { Write-Host 'Public-client fallback already on - skipped.' }

# 3 - consent, Principal-scoped to aiops only (extend the existing grant if one exists)
$grant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($sp.Id)' and consentType eq 'Principal' and principalId eq '$($aiops.Id)'" |
  Where-Object ResourceId -eq $graphSp.Id | Select-Object -First 1
$want = 'openid profile email offline_access Mail.Read Mail.ReadWrite Mail.Send'
if ($grant) {
  $merged = (($grant.Scope -split ' ') + ($want -split ' ') | Where-Object { $_ } | Select-Object -Unique) -join ' '
  if ($merged -ne $grant.Scope) {
    Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope $merged
    Write-Host "Extended $AiopsUpn's consent grant: $merged"
  } else { Write-Host "Consent for $AiopsUpn already complete - skipped." }
} else {
  New-MgOauth2PermissionGrant -BodyParameter @{
    clientId    = $sp.Id
    consentType = 'Principal'
    principalId = $aiops.Id
    resourceId  = $graphSp.Id
    scope       = $want
  } | Out-Null
  Write-Host "Granted mail consent for $AiopsUpn ONLY (Mail.Read/ReadWrite/Send - its own mailbox; nothing tenant-wide)"
}

Write-Host ''
Write-Host "Done. On each terminal: scripts/aiops-mail.sh login (sign in AS $AiopsUpn - Hudu creds), then scripts/aiops-mail.sh verify."
Disconnect-MgGraph | Out-Null
