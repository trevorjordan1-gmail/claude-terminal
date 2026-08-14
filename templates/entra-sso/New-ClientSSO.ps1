<#
.SYNOPSIS
  Creates the one-per-client "<code>-sso" Entra app registration - the single object that
  serves Cloudflare Access sign-in today, any future direct-SSO app (redirect URIs and
  per-app secrets get added to this same registration; no second registration, ever), and
  the aiops MAIL RIDER: delegated Mail.Read/ReadWrite/Send consented for the aiops account
  ONLY, public-client device-code enabled - the Claude Code Terminals send and read mail
  as aiops@<clientdomain> through it (templates/aiops-mail.sh). Retrofit an existing
  registration with Grant-AiopsMail.ps1.

.DESCRIPTION
  Run by a Global Administrator (or Privileged Role Admin + Application Admin) of the
  CLIENT's tenant - adNET staff for managed tenants, the client's own IT provider
  otherwise. Everything is parameter-driven; the script prints exactly what was created
  and the three values to hand back (tenant ID, client ID, secret - the secret displays
  ONCE).

  Requires the Microsoft Graph PowerShell SDK:  Install-Module Microsoft.Graph -Scope CurrentUser

.EXAMPLE
  ./New-ClientSSO.ps1 -ClientCode acme -AiopsUpn aiops@acme-example.com

  Creates "acme-sso" with redirect https://acme.cloudflareaccess.com/cdn-cgi/access/callback,
  grants the sign-in permissions, adds aiops as owner, mints a 12-month secret labeled
  "cloudflare-access".

.NOTES
  WARNING: First-run status: authored 2026-08-01 from the documented Graph SDK surface; do the
  first execution against an adNET-controlled tenant and fix forward before sending to an
  external provider.
#>
param(
  # Short client code - names the app "<code>-sso" and the Zero Trust callback host.
  [Parameter(Mandatory)] [string]$ClientCode,
  # Cloudflare Zero Trust team name. WARNING (field-hit): Cloudflare AUTO-GENERATES team
  # domains (e.g. hidden-resonance-c421) and the conventional short name may be taken by
  # another customer. Look up the REAL value first:
  #   GET https://api.cloudflare.com/client/v4/accounts/{id}/access/organizations
  #   -> .result.auth_domain (strip ".cloudflareaccess.com")
  # and pass it here. A wrong value = staff sign-in fails AADSTS50011.
  [string]$TeamName = $ClientCode,
  # UPN of the service account to add as OWNER of the registration (recommended:
  # object-scoped power only - lets automation add redirect URIs/secrets later without
  # any directory role). Omit to skip.
  [string]$AiopsUpn,
  # Also grant the registration Application.ReadWrite.OwnedBy (app permission) so
  # automation can extend it headlessly using its own credentials. Optional.
  [switch]$IncludeOwnedBy,
  # Sign in via device code instead of a local browser - for running on a Linux terminal
  # (pwsh): the admin enters the printed code at microsoft.com/devicelogin from their OWN
  # device, so admin credentials never touch the box running the script.
  [switch]$DeviceCode,
  # Pre-acquired Graph access token via $env:GRAPH_TOKEN - the field-proven relay flow:
  # mint with get-graph-token-devicecode.sh (15-min window, tenant-pinned, az-cli client)
  # and feed it here. Preferred over -DeviceCode for relayed sign-ins (the SDK's own
  # device-code wait is hardcoded ~120s).
  [switch]$UseEnvToken,
  # Secret lifetime - adNET standard is 12 months (all client credentials rotate together).
  [int]$SecretMonths = 12
)
$ErrorActionPreference = 'Stop'

$AppName     = "$ClientCode-sso"
$RedirectUri = "https://$TeamName.cloudflareaccess.com/cdn-cgi/access/callback"

$scopes = @('Application.ReadWrite.All','Directory.Read.All',
            'DelegatedPermissionGrant.ReadWrite.All','AppRoleAssignment.ReadWrite.All')
if ($UseEnvToken)   { Connect-MgGraph -AccessToken (ConvertTo-SecureString $env:GRAPH_TOKEN -AsPlainText -Force) -NoWelcome }
elseif ($DeviceCode) { Connect-MgGraph -Scopes $scopes -UseDeviceCode -NoWelcome -ClientTimeout 900 }
else                 { Connect-MgGraph -Scopes $scopes -NoWelcome }
$ctx = Get-MgContext

# Refuse to duplicate - one registration per client, ever.
if (Get-MgApplication -Filter "displayName eq '$AppName'" -Top 1) {
  throw "'$AppName' already exists in this tenant - there is only ever ONE per client. Extend it instead."
}

# Resolve Microsoft Graph's service principal + permission IDs dynamically (no hardcoded GUIDs).
# Declared delegated set = the sign-in scopes + the aiops MAIL RIDER (Mail.*). Declaration
# is portal visibility only - the mail scopes are CONSENTED Principal-scoped to the aiops
# account alone (step 2 below), never tenant-wide: no other user's mailbox is ever reachable.
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$delegated = 'openid','profile','email','offline_access',
             'Mail.Read','Mail.ReadWrite','Mail.Send' | ForEach-Object {
  $v = $_; $s = $graphSp.Oauth2PermissionScopes | Where-Object Value -eq $v
  if (-not $s) { throw "Graph scope '$v' not found" }
  @{ Id = $s.Id; Type = 'Scope' }
}
$resourceAccess = @($delegated)
if ($IncludeOwnedBy) {
  $role = $graphSp.AppRoles | Where-Object Value -eq 'Application.ReadWrite.OwnedBy'
  $resourceAccess += @{ Id = $role.Id; Type = 'Role' }
}

# 1 - the registration - single tenant, web redirect = the Zero Trust callback.
# IsFallbackPublicClient: lets the terminal's aiops-mail tool use the device-code flow
# (no secret on the mail path); the CF Access web flow keeps using its own secret.
$app = New-MgApplication -DisplayName $AppName -SignInAudience 'AzureADMyOrg' `
  -Web @{ RedirectUris = @($RedirectUri) } `
  -IsFallbackPublicClient:$true `
  -RequiredResourceAccess @(@{ ResourceAppId = $graphSp.AppId; ResourceAccess = $resourceAccess })
$sp = New-MgServicePrincipal -AppId $app.AppId
Write-Host "Created $AppName  (appId $($app.AppId))"

# 2 - admin consent - delegated sign-in scopes for all users
New-MgOauth2PermissionGrant -BodyParameter @{
  clientId    = $sp.Id
  consentType = 'AllPrincipals'
  resourceId  = $graphSp.Id
  scope       = 'openid profile email offline_access'
} | Out-Null
Write-Host 'Granted admin consent: openid profile email offline_access'

# 2b - the aiops mail rider: Mail.* consented for the aiops PRINCIPAL only - the terminal
# sends/reads mail as aiops@<clientdomain> (aiops-mail.sh, device code); this grant shape
# means no other account can ever ride these scopes through this app.
$aiops = $null
if ($AiopsUpn) {
  $aiops = Get-MgUser -UserId $AiopsUpn
  New-MgOauth2PermissionGrant -BodyParameter @{
    clientId    = $sp.Id
    consentType = 'Principal'
    principalId = $aiops.Id
    resourceId  = $graphSp.Id
    scope       = 'openid profile email offline_access Mail.Read Mail.ReadWrite Mail.Send'
  } | Out-Null
  Write-Host "Granted mail consent for $AiopsUpn ONLY (Mail.Read/ReadWrite/Send - its own mailbox; nothing tenant-wide)"
} else {
  Write-Host 'NOTE: -AiopsUpn omitted - mail scopes are declared but UNCONSENTED. Run Grant-AiopsMail.ps1 when the aiops account exists.'
}
if ($IncludeOwnedBy) {
  $role = $graphSp.AppRoles | Where-Object Value -eq 'Application.ReadWrite.OwnedBy'
  New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{
    principalId = $sp.Id; resourceId = $graphSp.Id; appRoleId = $role.Id } | Out-Null
  Write-Host 'Granted app permission: Application.ReadWrite.OwnedBy (self-serve extension)'
}

# 3 - owner (object-scoped control - no directory roles anywhere)
if ($aiops) {
  $ref = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($aiops.Id)" }
  New-MgApplicationOwnerByRef -ApplicationId $app.Id -BodyParameter $ref
  New-MgServicePrincipalOwnerByRef -ServicePrincipalId $sp.Id -BodyParameter $ref
  Write-Host "Added owner: $AiopsUpn (this object only)"
}

# 4 - first secret - labeled for its consumer, 12-month standard
$secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
  DisplayName = 'cloudflare-access'
  EndDateTime = (Get-Date).AddMonths($SecretMonths)
}

Write-Host ''
Write-Host '======== HAND THESE BACK (secret displays ONCE - read it over a call or a one-time link, never plain email) ========'
Write-Host "  Tenant ID : $($ctx.TenantId)"
Write-Host "  Client ID : $($app.AppId)"
Write-Host "  Secret    : $($secret.SecretText)"
Write-Host "  Expires   : $($secret.EndDateTime)  (label: cloudflare-access)"
Write-Host ''
Write-Host "Next (adNET side): Zero Trust -> Settings -> Authentication -> add Microsoft Entra ID with the three values, run its Test."
Disconnect-MgGraph | Out-Null
