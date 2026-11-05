# Schedulerを有効にする前に、OperatorがOutbox Publisherを1回だけ手動実行するScript。
param(
    [Parameter(Mandatory = $false)]
    [string]$AwsProfile = 'sap-lab'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$infraPath = Join-Path $projectRoot 'infra'

# Function名をTerraform Stateから取得し、別Functionを誤操作しないようにする。
$functionName = terraform "-chdir=$infraPath" output -raw outbox_publisher_function_name
if ($LASTEXITCODE -ne 0 -or -not $functionName) {
    throw 'Outbox Publisher output could not be read. Apply the workflow infrastructure first.'
}

$responseFile = New-TemporaryFile
try {
    aws lambda invoke `
        --profile $AwsProfile `
        --region ap-northeast-1 `
        --function-name $functionName `
        --cli-binary-format raw-in-base64-out `
        --payload '{}' `
        --no-cli-pager `
        $responseFile.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Outbox Publisher invocation failed.'
    }

    Get-Content -LiteralPath $responseFile.FullName -Raw
}
finally {
    Remove-Item -LiteralPath $responseFile.FullName -Force -ErrorAction SilentlyContinue
}
