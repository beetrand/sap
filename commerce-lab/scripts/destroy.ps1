param(
    [Parameter(Mandatory = $false)]
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot '..\infra'),

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile = 'sap-lab'
)

$ErrorActionPreference = 'Stop'
$resolvedTerraformDirectory = (Resolve-Path -LiteralPath $TerraformDirectory).Path
$expectedDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\infra')).Path

if ($resolvedTerraformDirectory -ne $expectedDirectory) {
    throw "Refusing to run outside the expected Terraform directory: $expectedDirectory"
}

$expectedAccount = (aws configure get sso_account_id --profile $AwsProfile).Trim()
$profileRegion = (aws configure get region --profile $AwsProfile).Trim()

if ($expectedAccount -notmatch '^[0-9]{12}$') {
    throw "Profile '$AwsProfile' does not contain a valid SSO account ID."
}

if ($profileRegion -ne 'ap-northeast-1') {
    throw "Refusing to destroy outside ap-northeast-1. Profile region: $profileRegion"
}

$caller = aws sts get-caller-identity --profile $AwsProfile --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Could not verify AWS identity for profile '$AwsProfile'."
}

if ($caller.Account -ne $expectedAccount) {
    throw "The active AWS account does not match profile '$AwsProfile'."
}

$env:AWS_PROFILE = $AwsProfile
$env:TF_VAR_allowed_account_id = $expectedAccount

Push-Location $resolvedTerraformDirectory
try {
    Write-Host "AWS identity verified with profile '$AwsProfile' in ap-northeast-1." -ForegroundColor Cyan

    terraform plan -destroy -out destroy.tfplan
    terraform show destroy.tfplan

    $confirmation = Read-Host 'Review the destroy plan above. Type DESTROY to apply it'
    if ($confirmation -cne 'DESTROY') {
        throw 'Destroy cancelled. No resources were changed.'
    }

    terraform apply destroy.tfplan

    Write-Host 'Terraform destroy finished. Verify these resources in ap-northeast-1:' -ForegroundColor Yellow
    Write-Host '- RDS instances and manual snapshots'
    Write-Host '- NAT gateways and unassociated Elastic IP addresses'
    Write-Host '- ALB and target groups'
    Write-Host '- ECS services and running tasks'
    Write-Host '- ECR repositories and images'
    Write-Host '- CloudWatch log groups'
    Write-Host '- RDS-managed Secrets Manager secrets'
}
finally {
    Pop-Location
}
