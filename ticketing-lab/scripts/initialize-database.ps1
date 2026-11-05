# apply後のAuroraへTableとSample Dataを作るScript。
# AWSを変更するため、Account・Region確認後にユーザーが手動実行する。
param(
    [Parameter(Mandatory = $false)]
    [string]$AwsProfile = 'sap-lab'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$infraPath = Join-Path $projectRoot 'infra'
$schemaPath = Join-Path $projectRoot 'sql\schema.sql'

# ARNやDB名を手入力せず、Terraform Stateから取得して対象間違いを防ぐ。
# 3回に分けて`terraform output -raw`を呼ぶと、どのCommandが失敗したか分からず、
# `$LASTEXITCODE`も最後のCommandの結果しか表さない。そこでJSONを1回だけ取得する。
$terraformOutputJson = terraform "-chdir=$infraPath" output -json
if ($LASTEXITCODE -ne 0) {
    throw "Terraform output command failed for: $infraPath"
}

try {
    $terraformOutputs = $terraformOutputJson | ConvertFrom-Json
    $clusterArn = $terraformOutputs.database_cluster_arn.value
    $secretArn = $terraformOutputs.database_secret_arn.value
    $databaseName = $terraformOutputs.database_name.value
}
catch {
    throw "Terraform outputs were returned, but could not be parsed: $($_.Exception.Message)"
}

if (-not $clusterArn -or -not $secretArn -or -not $databaseName) {
    throw 'Required Terraform outputs are missing: database_cluster_arn, database_secret_arn, or database_name.'
}

# Data APIは1回に1 SQL Statementを送るため、専用CommentでSchemaを分割する。
$statements = (Get-Content -LiteralPath $schemaPath -Raw) -split '(?m)^-- statement-break\s*$'

foreach ($statement in $statements) {
    $sql = $statement.Trim()
    if (-not $sql) {
        continue
    }

    # Passwordを取得せず、Cluster ARNとSecret ARNをData APIへ渡す。
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
