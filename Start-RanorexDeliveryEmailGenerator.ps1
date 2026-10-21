param(
    # Fixed port so the hosted page (github.io) can find the service without discovery.
    [int]$Port = 8768,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$baseUrl = "http://127.0.0.1:$Port/"
$AllowedOrigins = @(
    'https://giridharmv.github.io',
    "http://127.0.0.1:$Port",
    "http://localhost:$Port"
)
$AllowedTfsHost = 'saturn.tfs.siemens.net'
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($baseUrl)
$logPath = Join-Path $env:TEMP 'RanorexDeliveryEmailGenerator.log'

function Log-Message {
    param([string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    "$ts`t$Message" | Out-File -FilePath $logPath -Append -Encoding UTF8
}

# The CredMan P/Invoke type is added once to the process and is visible from every
# pooled runspace afterwards (Add-Type registers types AppDomain-wide, not per-runspace).
if (-not ([System.Management.Automation.PSTypeName]'CredMan.Api').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CredMan
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    public static class Api
    {
        [DllImport("Advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredEnumerate(string Filter, int Flags, out int Count, out IntPtr Credentials);

        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
        public static extern void CredFree(IntPtr cred);
    }
}
'@
}

# Auto-launch browser once
$htmlPath = Join-Path $PSScriptRoot 'RanorexDeliveryEmailGenerator.html'

# Thread-safe state shared by every pooled runspace (synchronized hashtables are safe for
# concurrent read/write from multiple threads without extra locking for simple get/set use).
$SharedCreds     = [hashtable]::Synchronized(@{ Info = $null })
$SharedPdfCache  = [hashtable]::Synchronized(@{ Loaded = $false; Files = @() })
$TfsCache        = [hashtable]::Synchronized(@{})
$OutlookProgress = [hashtable]::Synchronized(@{})
$TfsCacheSeconds = 45

# Handles one HTTP request end-to-end. Runs inside a pooled runspace so multiple requests
# (e.g. several TFS fetches triggered together from the browser) execute concurrently instead
# of being serialized on a single thread.
$RequestHandler = {
    param($context, $SharedCreds, $SharedPdfCache, $TfsCache, $OutlookProgress, $TfsCacheSeconds, $htmlPath, $logPath, $scriptRoot, $AllowedTfsHost)

    function Log-Message {
        param([string]$Message)
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        "$ts`t$Message" | Out-File -FilePath $logPath -Append -Encoding UTF8
    }

    # Pooled runspaces start from a fresh default session state, so System.Web (used below for
    # query-string parsing) has to be loaded explicitly here - it isn't guaranteed to already be
    # loaded the way it would be in a single, long-lived main-thread session.
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    function Get-WindowsCredentialByTarget {
        param([string]$FilterPattern)

        $best = $null
        $bestTicks = -1
        $count = 0
        $credentialsPtr = [IntPtr]::Zero

        try {
            $ok = [CredMan.Api]::CredEnumerate($FilterPattern, 0, [ref]$count, [ref]$credentialsPtr)
            if (-not $ok -or $count -eq 0) {
                return $null
            }

            for ($i = 0; $i -lt $count; $i++) {
                $entryPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($credentialsPtr, $i * [System.IntPtr]::Size)
                $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [type]'CredMan.CREDENTIAL')

                $targetName = if ($cred.TargetName -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cred.TargetName) } else { $null }
                $userName = if ($cred.UserName -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cred.UserName) } else { $null }
                $password = $null
                if ($cred.CredentialBlobSize -gt 0 -and $cred.CredentialBlob -ne [IntPtr]::Zero) {
                    $bytes = New-Object byte[] $cred.CredentialBlobSize
                    [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
                    $password = [System.Text.Encoding]::Unicode.GetString($bytes)
                }

                $ticks = ([Int64]$cred.LastWritten.dwHighDateTime -shl 32) -bor ([UInt32]$cred.LastWritten.dwLowDateTime)

                # Prefer the most recently modified matching credential when duplicates exist.
                if ($ticks -gt $bestTicks) {
                    $bestTicks = $ticks
                    $best = @{
                        Target   = $targetName
                        UserName = $userName
                        Password = $password
                    }
                }
            }
        } catch {
            return $null
        } finally {
            if ($credentialsPtr -ne [IntPtr]::Zero) {
                [CredMan.Api]::CredFree($credentialsPtr)
            }
        }

        return $best
    }

    function Get-UserCredentialInfo {
        if ($null -ne $SharedCreds.Info) {
            return $SharedCreds.Info
        }

        $email = $null
        $pat = $null

        # Look up the Windows-stored credential whose target matches 'git:https://saturn.tfs.siemens.net'
        # directly (instead of letting the git credential helper pick an arbitrary/cached entry),
        # so the most recently modified matching entry for this specific target is always used.
        $winCred = Get-WindowsCredentialByTarget -FilterPattern 'git:https://saturn.tfs.siemens.net*'
        if ($winCred -and $winCred.Password) {
            $email = $winCred.UserName
            $pat = $winCred.Password
        }

        if (-not $pat) {
            try {
                $inputData = "protocol=https`nhost=saturn.tfs.siemens.net`n`n"
                $credOutput = $inputData | git credential fill 2>$null
                foreach ($line in $credOutput) {
                    if ($line -match '^username=(.*)$') {
                        $email = $Matches[1]
                    }
                    if ($line -match '^password=(.*)$') {
                        $pat = $Matches[1]
                    }
                }
            } catch {}
        }

        if (-not $email) {
            $email = "$env:USERNAME@siemens.com"
        }

        $windowsAccount = Get-CimInstance Win32_UserAccount -Filter "Name='$env:USERNAME'" -ErrorAction SilentlyContinue | Select-Object -First 1
        $fullName = if ($windowsAccount -and $windowsAccount.FullName) { $windowsAccount.FullName } else { $env:USERNAME }

        $SharedCreds.Info = @{
            Name  = $fullName
            Email = $email
            Pat   = $pat
        }

        return $SharedCreds.Info
    }

    function Find-DeliveryPdfFiles {
        if ($SharedPdfCache.Loaded) {
            return @($SharedPdfCache.Files)
        }

        # The PDFs always live right next to this script - no need to scan the whole machine.
        $pdfs = Get-ChildItem -Path $scriptRoot -Filter '*.pdf' -File -ErrorAction SilentlyContinue
        $SharedPdfCache.Files = @($pdfs | ForEach-Object { $_.FullName })
        $SharedPdfCache.Loaded = $true
        return @($SharedPdfCache.Files)
    }

    function Set-OutlookProgress {
        param([string]$RequestId, [string]$Step, [int]$Percent, [bool]$Done = $false, [string]$ErrorMessage = $null)

        if (-not $RequestId) { return }

        # Lazily prune stale entries so the shared table doesn't grow unbounded across a long session.
        foreach ($key in @($OutlookProgress.Keys)) {
            $entry = $OutlookProgress[$key]
            if ($entry -and ((Get-Date).ToUniversalTime() - $entry.Timestamp).TotalMinutes -gt 5) {
                $OutlookProgress.Remove($key)
            }
        }

        $OutlookProgress[$RequestId] = @{
            step      = $Step
            percent   = $Percent
            done      = $Done
            error     = $ErrorMessage
            Timestamp = (Get-Date).ToUniversalTime()
        }
    }

    $req = $context.Request
    $res = $context.Response

    try {
        if ($req.HttpMethod -eq 'OPTIONS') {
            $res.StatusCode = 204
            return
        }

        if ($req.Url.AbsolutePath -eq '/' -and (Test-Path $htmlPath)) {
            $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
            $res.StatusCode = 200
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            return
        }

        if ($req.Url.AbsolutePath -eq '/neoTA.png') {
            $logoName = [System.IO.Path]::GetFileName($req.Url.AbsolutePath)
            $logoPath = Join-Path $scriptRoot $logoName
            if (Test-Path $logoPath) {
                $bytes = [System.IO.File]::ReadAllBytes($logoPath)
                $res.StatusCode = 200
                $res.ContentType = 'image/png'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                return
            }
        }

        # Lightweight health check used by the page's "Connect TFS" button
        if ($req.Url.AbsolutePath -eq '/ping') {
            $outBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            $res.StatusCode = 200
            $res.ContentType = 'application/json; charset=utf-8'
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
            return
        }

        # Dynamic user info endpoint
        if ($req.Url.AbsolutePath -eq '/user-info') {
            $userInfo = Get-UserCredentialInfo
            $jsonInfo = @{
                name   = $userInfo.Name
                email  = $userInfo.Email
                hasPat = [bool]$userInfo.Pat
            } | ConvertTo-Json -Compress

            $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonInfo)
            $res.StatusCode = 200
            $res.ContentType = 'application/json; charset=utf-8'
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
            return
        }

        # Progress polling endpoint for the Outlook draft flow
        if ($req.Url.AbsolutePath -eq '/outlook-status') {
            $reqId = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)['id']
            $status = $null
            if ($reqId -and $OutlookProgress.ContainsKey($reqId)) {
                $entry = $OutlookProgress[$reqId]
                $status = @{ step = $entry.step; percent = $entry.percent; done = $entry.done; error = $entry.error }
            }
            if (-not $status) {
                $status = @{ step = 'Pending'; percent = 0; done = $false; error = $null }
            }

            $outBytes = [System.Text.Encoding]::UTF8.GetBytes(($status | ConvertTo-Json -Compress))
            $res.StatusCode = 200
            $res.ContentType = 'application/json; charset=utf-8'
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
            return
        }

        # TFS API Proxy endpoint with PAT Injection
        if ($req.Url.AbsolutePath -eq '/tfs-api') {
            try {
                $targetUrl = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)['url']
                if (-not $targetUrl) {
                    throw "Missing 'url' query parameter."
                }

                # The stored PAT is injected into this request, so only ever forward to the TFS server.
                $targetUri = $null
                if (-not [System.Uri]::TryCreate($targetUrl, [System.UriKind]::Absolute, [ref]$targetUri) -or
                    $targetUri.Scheme -ne 'https' -or $targetUri.Host -ne $AllowedTfsHost) {
                    throw "Only https://$AllowedTfsHost URLs are allowed."
                }

                $method = $req.HttpMethod

                # Serve repeated identical GET lookups from a short-lived shared cache instead of
                # round-tripping to TFS again (big win when the same sprint/work item/wiki page is
                # requested more than once while preparing a single email).
                if ($method -eq 'GET' -and $TfsCache.ContainsKey($targetUrl)) {
                    $cached = $TfsCache[$targetUrl]
                    if (((Get-Date).ToUniversalTime() - $cached.Timestamp).TotalSeconds -lt $TfsCacheSeconds) {
                        Log-Message "TFS cache hit: $targetUrl"
                        $outBytes = [System.Text.Encoding]::UTF8.GetBytes($cached.Body)
                        $res.StatusCode = 200
                        $res.ContentType = 'application/json; charset=utf-8'
                        $res.ContentLength64 = $outBytes.Length
                        $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
                        return
                    }
                    $TfsCache.Remove($targetUrl)
                }

                $authHeader = $req.Headers['Authorization']
                if (-not $authHeader) {
                    $userInfo = Get-UserCredentialInfo
                    if ($userInfo.Pat) {
                        $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($userInfo.Pat)"))
                        $authHeader = "Basic $encodedCreds"
                    }
                }

                $headers = @{
                    'Accept' = 'application/json'
                }
                if ($authHeader) {
                    $headers['Authorization'] = $authHeader
                }

                $body = $null
                if ($method -eq 'POST') {
                    $reader = [System.IO.StreamReader]::new($req.InputStream)
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                    $headers['Content-Type'] = 'application/json'
                }

                $apiParams = @{
                    Uri             = $targetUrl
                    Method          = $method
                    Headers         = $headers
                    ErrorAction     = 'Stop'
                }
                if ($body) { $apiParams['Body'] = $body }

                $apiResponse = Invoke-RestMethod @apiParams
                $responseBody = $apiResponse | ConvertTo-Json -Depth 10 -Compress

                if ($method -eq 'GET') {
                    $TfsCache[$targetUrl] = @{ Body = $responseBody; Timestamp = (Get-Date).ToUniversalTime() }
                }

                $res.StatusCode = 200
                $res.ContentType = 'application/json; charset=utf-8'
            } catch {
                Log-Message "TFS Proxy Error: $_"
                $statusCode = 500
                try {
                    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                } catch {}
                $res.StatusCode = $statusCode

                # The raw exception message is a generic .NET description (e.g. "401 Unauthorized").
                # Read the actual response body TFS sent back, which usually contains the real
                # TF-prefixed error code/reason (auth failure vs. permission/identity issue, etc.).
                $tfsErrorDetail = $null
                try {
                    $errorStream = $_.Exception.Response.GetResponseStream()
                    if ($errorStream) {
                        $streamReader = [System.IO.StreamReader]::new($errorStream)
                        $tfsErrorDetail = $streamReader.ReadToEnd()
                        $streamReader.Dispose()
                    }
                } catch {
                    $tfsErrorDetail = $null
                }
                if ($tfsErrorDetail) { Log-Message "TFS Proxy Error Detail: $tfsErrorDetail" }

                $errorMessage = $_.Exception.Message
                if ($tfsErrorDetail) {
                    try {
                        $parsedDetail = $tfsErrorDetail | ConvertFrom-Json
                        if ($parsedDetail.message) { $errorMessage = $parsedDetail.message }
                    } catch {
                        $errorMessage = $tfsErrorDetail
                    }
                }
                $responseBody = (@{ error = $errorMessage } | ConvertTo-Json -Compress)
            }

            $outBytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
            return
        }

        if ($req.Url.AbsolutePath -eq '/create-outlook-draft' -and $req.HttpMethod -eq 'POST') {
            $reqId = $null
            try {
                $reader = [System.IO.StreamReader]::new($req.InputStream)
                $json = $reader.ReadToEnd()
                $reader.Dispose()

                $data = $json | ConvertFrom-Json
                $reqId = [string]$data.requestId
                Log-Message "Received draft request. Subject: $($data.subject)"

                Set-OutlookProgress -RequestId $reqId -Step 'Preparing content' -Percent 10
                $user = Get-UserCredentialInfo

                Set-OutlookProgress -RequestId $reqId -Step 'Locating attachments' -Percent 35
                $pdfFiles = Find-DeliveryPdfFiles

                $outlook = $null
                $mail = $null
                try {
                    Set-OutlookProgress -RequestId $reqId -Step 'Launching Outlook' -Percent 60
                    $outlook = [activator]::CreateInstance([type]::GetTypeFromProgID("Outlook.Application"))
                    $mail = $outlook.CreateItem(0)

                    $mail.Subject = [string]$data.subject
                    $mail.To = [string]$data.to

                    if ($null -ne $data.cc) {
                        $rawCcString = [string]$data.cc
                        $ccEntries = $rawCcString -split ',\s*(?=")' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrEmpty($_) }
                        if ($ccEntries.Count -gt 0) {
                            $mail.CC = ($ccEntries -join '; ')
                        }
                    }

                    Set-OutlookProgress -RequestId $reqId -Step 'Populating draft' -Percent 85
                    foreach ($pdf in $pdfFiles) {
                        $mail.Attachments.Add($pdf)
                        Log-Message "Attached PDF: $pdf"
                    }

                    $mail.HTMLBody = [string]$data.html + $mail.HTMLBody
                    $mail.Display($false)
                } finally {
                    if ($mail) {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
                    }
                    if ($outlook) {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook) | Out-Null
                    }
                }

                Set-OutlookProgress -RequestId $reqId -Step 'Done' -Percent 100 -Done $true
                $responseBody = '{"opened":true}'
                $res.StatusCode = 200
                Log-Message "Outlook draft populated successfully for $($user.Name)."
            } catch {
                Log-Message "Error: $_"
                Set-OutlookProgress -RequestId $reqId -Step 'Failed' -Percent 100 -Done $true -ErrorMessage $_.Exception.Message
                $responseBody = (@{ opened = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
                $res.StatusCode = 500
            }

            $outBytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
            $res.ContentType = 'application/json; charset=utf-8'
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
            return
        }

        $res.StatusCode = 404
    } catch {
        Log-Message "Unhandled request error: $_"
        try { $res.StatusCode = 500 } catch {}
    } finally {
        try { $res.Close() } catch {}
    }
}

# Runspace pool so multiple requests are handled concurrently instead of one at a time.
# STA is required because Outlook COM automation only works reliably on an STA thread.
$runspacePool = [runspacefactory]::CreateRunspacePool(1, 8)
$runspacePool.ApartmentState = [System.Threading.ApartmentState]::STA
$runspacePool.Open()
$pending = [System.Collections.Generic.List[object]]::new()

try {
    $listener.Start()
} catch {
    # Port already bound - most likely this service is already running.
    Write-Host "Could not listen on $baseUrl (already running?): $($_.Exception.Message)"
    Log-Message "Listener start failed: $_"
    $runspacePool.Close()
    exit 0
}
if ((Test-Path $htmlPath) -and -not $NoBrowser) {
    Start-Process $baseUrl
}
Write-Host "Server running at $baseUrl - Press Ctrl+C to exit."

try {
    while ($listener.IsListening) {
        # Use GetContextAsync() with a timeout so the thread remains responsive to Ctrl+C
        $contextTask = $listener.GetContextAsync()

        while (-not $contextTask.AsyncWaitHandle.WaitOne(250)) {
            # While waiting for the next connection, reap any requests that finished handling.
            for ($i = $pending.Count - 1; $i -ge 0; $i--) {
                $item = $pending[$i]
                if ($item.Handle.IsCompleted) {
                    try { $item.PS.EndInvoke($item.Handle) } catch { Log-Message "Handler error: $_" }
                    $item.PS.Dispose()
                    $pending.RemoveAt($i)
                }
            }
        }

        $context = $contextTask.GetAwaiter().GetResult()

        # Only the hosted page / local origins may call this service (it can use the stored PAT and drive Outlook).
        $origin = $context.Request.Headers['Origin']
        if ($origin) {
            if ($AllowedOrigins -notcontains $origin) {
                Log-Message "Rejected request from origin: $origin"
                $context.Response.StatusCode = 403
                $context.Response.Close()
                continue
            }
            $context.Response.Headers.Add('Access-Control-Allow-Origin', $origin)
            $context.Response.Headers.Add('Vary', 'Origin')
        }
        $context.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        $context.Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        # Required by Chrome's Private Network Access preflight for public-site -> localhost calls.
        $context.Response.Headers.Add('Access-Control-Allow-Private-Network', 'true')

        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($RequestHandler).
            AddArgument($context).
            AddArgument($SharedCreds).
            AddArgument($SharedPdfCache).
            AddArgument($TfsCache).
            AddArgument($OutlookProgress).
            AddArgument($TfsCacheSeconds).
            AddArgument($htmlPath).
            AddArgument($logPath).
            AddArgument($PSScriptRoot).
            AddArgument($AllowedTfsHost)

        $handle = $ps.BeginInvoke()
        $pending.Add([pscustomobject]@{ PS = $ps; Handle = $handle })
    }
} finally {
    foreach ($item in $pending) {
        try {
            $item.Handle.AsyncWaitHandle.WaitOne(5000) | Out-Null
            $item.PS.EndInvoke($item.Handle)
        } catch {}
        $item.PS.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    $listener.Stop()
    $listener.Close()
    Write-Host "Server stopped."
}