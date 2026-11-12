function Get-TwitchAccessToken {
    # Gibt Token UND Laufzeit zurück (Objekt mit .Token und .ExpiresIn in Sekunden).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.TwitchClientId) -or
        [string]::IsNullOrWhiteSpace($Config.TwitchClientSecret)) {
        throw 'Twitch API-Zugangsdaten fehlen in config.json (twitchClientId/twitchClientSecret).'
    }

    $body = @{
        client_id = $Config.TwitchClientId
        client_secret = $Config.TwitchClientSecret
        grant_type = 'client_credentials'
    }
    # -TimeoutSec: Ohne Timeout kann ein hängender Request den UI-Thread (und damit das Tray) minutenlang blockieren.
    $response = Invoke-RestMethod -Method Post -Uri 'https://id.twitch.tv/oauth2/token' `
        -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15 -ErrorAction Stop
    return [pscustomobject]@{
        Token = [string]$response.access_token
        ExpiresIn = [int]$response.expires_in
    }
}

function Get-TwitchStreamStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $headers = @{
        'Client-Id' = $Config.TwitchClientId
        'Authorization' = "Bearer $AccessToken"
    }
    $encoded = [uri]::EscapeDataString($Channel)
    $response = Invoke-RestMethod -Method Get `
        -Uri "https://api.twitch.tv/helix/streams?user_login=$encoded" `
        -Headers $headers -TimeoutSec 15 -ErrorAction Stop

    if ($response.data.Count -gt 0) {
        $stream = $response.data[0]
        return [pscustomobject]@{
            Channel = $Channel
            IsLive = $true
            Title = [string]$stream.title
            StartedAt = [datetime]$stream.started_at
        }
    }
    return [pscustomobject]@{ Channel = $Channel; IsLive = $false; Title = ''; StartedAt = $null }
}

function Test-TwitchConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $token = Get-TwitchAccessToken -Config $Config
    return -not [string]::IsNullOrWhiteSpace($token.Token)
}

Export-ModuleMember -Function Get-TwitchAccessToken, Get-TwitchStreamStatus, Test-TwitchConnection
