param(
    # Terraform outputのecr_repository_urlを渡す。
    # 例: <account>.dkr.ecr.ap-northeast-1.amazonaws.com/sap-commerce-lab-phase1
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EcrRepositoryUrl,

    # 同じ内容を識別する不変タグ。ECR側でタグ上書きは禁止している。
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')]
    [string]$ImageTag = 'phase1-v1',

    # この学習環境は誤操作防止のため東京リージョンだけを許可する。
    [Parameter(Mandatory = $false)]
    [ValidateSet('ap-northeast-1')]
    [string]$Region = 'ap-northeast-1',

    # AWS IAM Identity Centerで認証したAWS CLI profile名。
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AwsProfile = 'sap-lab'
)

$ErrorActionPreference = 'Stop'

# PATH上のDocker CLIを探す。見つからなければDocker Desktopの標準的な
# ユーザーインストール先も確認する。
$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
if ($null -ne $dockerCommand) {
    $dockerExe = $dockerCommand.Source
}
else {
    $dockerDesktopCandidate = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'
    if (Test-Path -LiteralPath $dockerDesktopCandidate) {
        $dockerExe = $dockerDesktopCandidate
        Write-Host "Docker CLI was not on PATH. Using: $dockerExe" -ForegroundColor Yellow
    }
    else {
        throw 'Docker CLI was not found. Start Docker Desktop, open a new PowerShell window, and try again.'
    }
}

# CLIだけでなく、Linuxコンテナを実行するDocker Desktop Engineも起動中か確認する。
& $dockerExe version --format 'Docker client {{.Client.Version}} / server {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})'
if ($LASTEXITCODE -ne 0) {
    throw 'Docker CLI was found, but the Docker Desktop Linux engine is not accessible.'
}

# ECRへの短期認証情報をDockerへ渡すAmazon ECR Credential Helperを探す。
# docker loginでWindows Credential Storeへ認証情報を保存しない方式を採用する。
$ecrCredentialHelper = Get-Command docker-credential-ecr-login.exe -ErrorAction SilentlyContinue
if ($null -eq $ecrCredentialHelper) {
    $ecrCredentialHelperCandidate = 'C:\tools\docker-credential-ecr-login.exe'
    if (Test-Path -LiteralPath $ecrCredentialHelperCandidate) {
        $ecrCredentialHelperDirectory = Split-Path -Parent $ecrCredentialHelperCandidate
        $env:PATH = "$ecrCredentialHelperDirectory;$env:PATH"
        $ecrCredentialHelper = Get-Command docker-credential-ecr-login.exe -ErrorAction Stop
        Write-Host "ECR Credential Helper was not on PATH. Using: $($ecrCredentialHelper.Source)" -ForegroundColor Yellow
    }
    else {
        throw 'Amazon ECR Docker Credential Helper was not found on PATH or at C:\tools\docker-credential-ecr-login.exe.'
    }
}

# 渡されたURLからECR registry部分を取り出す。
$registry = ($EcrRepositoryUrl -split '/')[0]

# 東京リージョンの正式なECR registry形式以外は拒否する。
if ($registry -notmatch '^\d{12}\.dkr\.ecr\.ap-northeast-1\.amazonaws\.com$') {
    throw "Unexpected ECR registry for the Phase 1 Tokyo lab: $registry"
}

# profile設定に記録されたアカウントとリージョンを取得する。
$registryAccount = $registry.Split('.')[0]
$expectedAccount = (aws configure get sso_account_id --profile $AwsProfile).Trim()
$profileRegion = (aws configure get region --profile $AwsProfile).Trim()

# ECR URL、profile設定、現在のSTS認証が同じAWSアカウントを指すことを三重確認する。
# 別アカウントへ誤pushする事故を防ぐためのガード。
if ($expectedAccount -notmatch '^\d{12}$') {
    throw "Profile '$AwsProfile' does not contain a valid SSO account ID."
}

if ($expectedAccount -ne $registryAccount) {
    throw "The ECR repository account does not match profile '$AwsProfile'."
}

if ($profileRegion -ne $Region) {
    throw "Profile '$AwsProfile' uses region '$profileRegion', expected '$Region'."
}

$callerResult = aws sts get-caller-identity --profile $AwsProfile --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not verify AWS identity for profile '$AwsProfile': $($callerResult -join [Environment]::NewLine)"
}

$caller = ($callerResult | Out-String) | ConvertFrom-Json
if ($caller.Account -ne $expectedAccount) {
    throw "The active AWS account does not match profile '$AwsProfile'."
}

Write-Host "AWS identity verified with profile '$AwsProfile' in $Region." -ForegroundColor Cyan

# 外部変更となるpushの直前に、利用者へ対象Repositoryとタグを表示して明示確認する。
$confirmation = Read-Host "Push $EcrRepositoryUrl`:$ImageTag using profile '$AwsProfile'? Type PUSH"
if ($confirmation -cne 'PUSH') {
    throw 'Push cancelled.'
}

# 通常のDocker設定を変更しないよう、このpushだけで使う一時config directoryを作る。
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryDockerConfig = Join-Path $temporaryRoot "sap-ecr-docker-$([Guid]::NewGuid().ToString('N'))"
$hadAwsProfile = Test-Path Env:AWS_PROFILE
$originalAwsProfile = $env:AWS_PROFILE
$hadEcrDisableCache = Test-Path Env:AWS_ECR_DISABLE_CACHE
$originalEcrDisableCache = $env:AWS_ECR_DISABLE_CACHE

# 対象ECR registryだけecr-login helperへ委譲する最小のDocker config.json。
New-Item -ItemType Directory -Path $temporaryDockerConfig | Out-Null
$temporaryDockerConfigJson = @{
    credHelpers = @{
        $registry = 'ecr-login'
    }
} | ConvertTo-Json -Depth 3
Set-Content -LiteralPath (Join-Path $temporaryDockerConfig 'config.json') -Value $temporaryDockerConfigJson -Encoding utf8NoBOM

try {
    # Helperは指定profileから短期ECR tokenを取得する。
    # この一時学習環境ではtokenをローカルキャッシュしない。
    $env:AWS_PROFILE = $AwsProfile
    $env:AWS_ECR_DISABLE_CACHE = 'true'

    # Repository URLとタグを結合した完全なイメージ名を作る。
    $image = "${EcrRepositoryUrl}:${ImageTag}"

    # 現在のプロジェクトをbuild contextとしてLinux/amd64イメージを構築する。
    # --pullでDockerfileのベースイメージに更新がないか確認する。
    & $dockerExe --config $temporaryDockerConfig build --pull --platform linux/amd64 --tag $image .
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker image build failed.'
    }

    # 構築したローカルイメージのlayerとmanifestをECRへ送信する。
    & $dockerExe --config $temporaryDockerConfig push $image
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker image push failed.'
    }

    Write-Host "Pushed $image" -ForegroundColor Green
}
finally {
    # このスクリプトが一時的に変更した環境変数を、実行前の状態へ必ず戻す。
    if ($hadAwsProfile) {
        $env:AWS_PROFILE = $originalAwsProfile
    }
    else {
        Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
    }

    if ($hadEcrDisableCache) {
        $env:AWS_ECR_DISABLE_CACHE = $originalEcrDisableCache
    }
    else {
        Remove-Item Env:AWS_ECR_DISABLE_CACHE -ErrorAction SilentlyContinue
    }

    # 認証helper設定を含む一時directoryがOS temp配下であることを再確認してから削除する。
    if (Test-Path -LiteralPath $temporaryDockerConfig) {
        $resolvedTemporaryDockerConfig = (Resolve-Path -LiteralPath $temporaryDockerConfig).Path
        if (-not $resolvedTemporaryDockerConfig.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected Docker config path: $resolvedTemporaryDockerConfig"
        }

        Remove-Item -LiteralPath $resolvedTemporaryDockerConfig -Recurse -Force
    }
}
