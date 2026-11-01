param(
    [switch]$SkipDocker
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

Push-Location $repositoryRoot
try {
    npm.cmd test
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }

    npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

    npm.cmd run lint
    if ($LASTEXITCODE -ne 0) { throw 'Type check failed.' }

    if (-not $SkipDocker) {
        docker build --pull --tag sap-commerce-lab:phase3-local .
        if ($LASTEXITCODE -ne 0) { throw 'Docker build failed.' }
    }

    Push-Location (Join-Path $repositoryRoot 'infra')
    try {
        terraform fmt -recursive -check
        if ($LASTEXITCODE -ne 0) { throw 'Terraform formatting check failed.' }

        terraform validate
        if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }
    }
    finally {
        Pop-Location
    }

    Write-Host 'Local validation passed. No AWS resources were changed.' -ForegroundColor Green
}
finally {
    Pop-Location
}
