# 認証済みOperatorだけが、次のWorkflowで発生させる障害Modeを変更するScript。
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'success',
        'payment-transient',
        'payment-declined',
        'confirmation-failure',
        'refund-transient',
        'refund-failure',
        'mail-failure'
    )]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile = 'sap-lab'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$infraPath = Join-Path $projectRoot 'infra'

# Parameter名と許可AccountをTerraform Stateから読み、手入力による対象間違いを減らす。
$outputsJson = terraform "-chdir=$infraPath" output -json
if ($LASTEXITCODE -ne 0) {
    throw 'Terraform outputs could not be read.'
}
$outputs = $outputsJson | ConvertFrom-Json
$parameterName = $outputs.simulation_parameter_name.value
$expectedAccount = $outputs.aws_account_id.value

# AWS Login先がApply先と同じAccountか、変更前に必ず確認する。
$actualAccount = aws sts get-caller-identity `
    --profile $AwsProfile `
    --region ap-northeast-1 `
    --query Account `
    --output text `
    --no-cli-pager
if ($LASTEXITCODE -ne 0 -or $actualAccount -ne $expectedAccount) {
    throw "AWS account mismatch. Expected $expectedAccount but received $actualAccount."
}

aws ssm put-parameter `
    --profile $AwsProfile `
    --region ap-northeast-1 `
    --name $parameterName `
    --type String `
    --value $Mode `
    --overwrite `
    --no-cli-pager | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Simulation mode update failed.'
}

Write-Host "Simulation mode changed to: $Mode"

