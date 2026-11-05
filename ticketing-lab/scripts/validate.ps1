# AWS Resourceを変更せず、Test・UI Template・Terraform構文をまとめて確認するScript。
$ErrorActionPreference = 'Stop'

# Scriptの1つ上がticketing-lab Root。どこから実行しても同じPathを使える。
$projectRoot = Split-Path -Parent $PSScriptRoot

Push-Location $projectRoot
try {
    # Domain入力ValidationとWorkflow分岐のUnit Test。PowerShellでFileを列挙してNodeへ渡す。
    $testFiles = Get-ChildItem -LiteralPath '.\tests' -Filter '*.test.mjs' |
        Select-Object -ExpandProperty FullName
    node --test $testFiles
    if ($LASTEXITCODE -ne 0) { throw 'Node tests failed.' }
    # TerraformでRenderする前のHTMLとInline JavaScriptを静的検査する。
    node '.\scripts\check-ui.mjs'
    if ($LASTEXITCODE -ne 0) { throw 'UI template checks failed.' }
    # Format差分、Provider初期化、Terraform Resource Schemaを順に確認する。
    terraform -chdir=infra fmt -recursive -check
    if ($LASTEXITCODE -ne 0) { throw 'Terraform format check failed.' }
    terraform -chdir=infra init -backend=false
    if ($LASTEXITCODE -ne 0) { throw 'Terraform initialization failed.' }
    terraform -chdir=infra validate
    if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }
}
finally {
    # 途中で失敗しても、実行前のCurrent Directoryへ必ず戻す。
    Pop-Location
}
