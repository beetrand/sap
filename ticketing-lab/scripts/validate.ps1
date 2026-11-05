$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

Push-Location $projectRoot
try {
    node --test '.\tests\*.test.mjs'
    terraform -chdir=infra fmt -recursive -check
    terraform -chdir=infra init -backend=false
    terraform -chdir=infra validate
}
finally {
    Pop-Location
}
