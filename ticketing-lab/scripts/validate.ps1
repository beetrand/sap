# AWS Resourceを変更せず、Test・UI Template・Terraform構文をまとめて確認するScript。
$ErrorActionPreference = 'Stop'

# Scriptの1つ上がticketing-lab Root。どこから実行しても同じPathを使える。
$projectRoot = Split-Path -Parent $PSScriptRoot

Push-Location $projectRoot
try {
    # Domain入力ValidationのUnit Test。
    node --test '.\tests\*.test.mjs'
    # TerraformでRenderする前のHTMLとInline JavaScriptを静的検査する。
    node '.\scripts\check-ui.mjs'
    # Format差分、Provider初期化、Terraform Resource Schemaを順に確認する。
    terraform -chdir=infra fmt -recursive -check
    terraform -chdir=infra init -backend=false
    terraform -chdir=infra validate
}
finally {
    # 途中で失敗しても、実行前のCurrent Directoryへ必ず戻す。
    Pop-Location
}
