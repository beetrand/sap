param(
    [Parameter(Mandatory = $false)]
    [string]$AwsProfile = 'sap-lab'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$infraPath = Join-Path $projectRoot 'infra'
$schemaPath = Join-Path $projectRoot 'sql\schema.sql'

$clusterArn = terraform -chdir=$infraPath output -raw database_cluster_arn
$secretArn = terraform -chdir=$infraPath output -raw database_secret_arn
$databaseName = terraform -chdir=$infraPath output -raw database_name

if ($LASTEXITCODE -ne 0 -or -not $clusterArn -or -not $secretArn -or -not $databaseName) {
    throw 'Terraform outputs could not be read. Apply the infrastructure first.'
}

$statements = (Get-Content -LiteralPath $schemaPath -Raw) -split '(?m)^-- statement-break\s*$'

foreach ($statement in $statements) {
    $sql = $statement.Trim()
    if (-not $sql) {
        continue
    }

    aws rds-data execute-statement `
        --profile $AwsProfile `
        --region ap-northeast-1 `
        --resource-arn $clusterArn `
        --secret-arn $secretArn `
        --database $databaseName `
        --sql $sql `
        --no-cli-pager | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw 'Database initialization failed. Review the AWS CLI error above.'
    }
}

Write-Host 'Database schema and sample seats were initialized.'
