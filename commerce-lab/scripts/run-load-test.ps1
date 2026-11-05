param(
    # terraform output application_urlで得たPhase 3 ALBのHTTP URLだけを受け付ける。
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl,

    # 自分たちが所有する検証環境であることをCommand実行者が明示するSafety Switch。
    [Parameter(Mandatory = $true)]
    [switch]$ConfirmOwnedEnvironment,

    # 再現性のため、確認済みの公式k6 Image Versionへ固定する。
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$K6Image = 'grafana/k6:2.3.0'
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmOwnedEnvironment) {
    throw 'Refusing to run without -ConfirmOwnedEnvironment.'
}

$normalizedBaseUrl = $BaseUrl.Trim().TrimEnd('/')
$targetUri = $null
if (-not [Uri]::TryCreate($normalizedBaseUrl, [UriKind]::Absolute, [ref]$targetUri)) {
    throw 'BaseUrl must be an absolute URL.'
}

# Project名、Phase、Region、AWS ALB Domainをすべて固定し、第三者や別環境を対象にしない。
$expectedHostPattern = '^sap-commerce-lab-phase3-[0-9]+\.ap-northeast-1\.elb\.amazonaws\.com$'
if (
    $targetUri.Scheme -cne 'http' -or
    $targetUri.Host -notmatch $expectedHostPattern -or
    ($targetUri.AbsolutePath -ne '/' -and $targetUri.AbsolutePath -ne '') -or
    $targetUri.Query -ne '' -or
    $targetUri.Fragment -ne '' -or
    $targetUri.UserInfo -ne ''
) {
    throw 'BaseUrl must be the root HTTP URL of the Tokyo ALB created for sap-commerce-lab-phase3.'
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$loadTestsDirectory = (Resolve-Path -LiteralPath (Join-Path $repositoryRoot 'load-tests')).Path
$resultsDirectory = (Resolve-Path -LiteralPath (Join-Path $loadTestsDirectory 'results')).Path

# Docker CLIの探索方法をBuild Scriptとそろえる。
$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
if ($null -ne $dockerCommand) {
    $dockerExe = $dockerCommand.Source
}
else {
    $dockerDesktopCandidate = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'
    if (Test-Path -LiteralPath $dockerDesktopCandidate) {
        $dockerExe = $dockerDesktopCandidate
    }
    else {
        throw 'Docker CLI was not found. Start Docker Desktop and try again.'
    }
}

& $dockerExe version --format 'Docker client {{.Client.Version}} / server {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})'
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop Linux engine is not available.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryFile = "scaling-$timestamp-summary.json"
$metadataFile = Join-Path $resultsDirectory "scaling-$timestamp-metadata.json"

# k6 Summaryと、実行条件を後から対応付けられるようLocal Metadataを保存する。
[ordered]@{
    startedAt      = (Get-Date).ToString('o')
    baseUrl        = $normalizedBaseUrl
    k6Image        = $K6Image
    maxRatePerSec  = 30
    maxVUs         = 100
    loadDuration   = '15m'
    ecsTaskHardMax = 6
} | ConvertTo-Json | Set-Content -LiteralPath $metadataFile -Encoding utf8

$dockerArguments = @(
    'run', '--rm',
    '--volume', "${loadTestsDirectory}:/scripts:ro",
    '--volume', "${resultsDirectory}:/results",
    $K6Image,
    'run',
    '-e', "BASE_URL=$normalizedBaseUrl",
    '-e', 'ALLOW_LOAD_TEST=phase3-owned-environment',
    "--summary-export=/results/$summaryFile",
    '/scripts/scaling.js'
)

Write-Host 'Starting the controlled Phase 3 load profile: 1 -> 5 -> 10 -> 20 -> 30 RPS, 15 minutes.' -ForegroundColor Cyan
Write-Host "Target: $normalizedBaseUrl" -ForegroundColor Cyan

& $dockerExe @dockerArguments
if ($LASTEXITCODE -ne 0) {
    throw "k6 stopped or failed. Review $metadataFile and any generated summary before retrying."
}

Write-Host "k6 completed. Summary: $(Join-Path $resultsDirectory $summaryFile)" -ForegroundColor Green
