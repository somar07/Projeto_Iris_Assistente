$ErrorActionPreference = "Stop"

$Container = "assistencia_n8n"
$Base = "C:\n8n-backups"
$Repo = "C:\n8n-backups\repo"
$ProjectRoot = "C:\Users\Rafael\Documents\AgentesIA - RR InforTech\projeto-assistencia"
$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$SnapshotRoot = Join-Path $Base "snapshots\$Stamp"
$SnapshotWorkflows = Join-Path $SnapshotRoot "workflows"
$SnapshotCredentials = Join-Path $SnapshotRoot "credentials"

$RepoWorkflows = Join-Path $Repo "workflows\$Stamp"
$RepoInfra = Join-Path $Repo "infra"

function Sanitize-WorkflowFile {
    param([string]$FilePath)

    $content = Get-Content -Raw -Path $FilePath

    $replacements = @(
        @{ Pattern = '(Bearer\s+)gsk_[A-Za-z0-9_\-]+'; Replacement = '${1}REMOVIDO' }
        @{ Pattern = 'gsk_[A-Za-z0-9_\-]+'; Replacement = 'gsk_REMOVIDO' }
        @{ Pattern = 'sk-proj-[A-Za-z0-9_\-]+'; Replacement = 'sk-proj-REMOVIDO' }
        @{ Pattern = '(?i)("authorization"\s*:\s*")Bearer\s+[^"]+(")'; Replacement = '${1}Bearer REMOVIDO${2}' }
        @{ Pattern = '(?i)("api[-_ ]?key"\s*:\s*")[^"]+(")'; Replacement = '${1}REMOVIDO${2}' }
        @{ Pattern = '(?i)("x-api-key"\s*:\s*")[^"]+(")'; Replacement = '${1}REMOVIDO${2}' }
        @{ Pattern = '(?i)("value"\s*:\s*")Bearer\s+[^"]+(")'; Replacement = '${1}Bearer REMOVIDO${2}' }
    )

    foreach ($r in $replacements) {
        $content = [regex]::Replace($content, $r.Pattern, $r.Replacement)
    }

    Set-Content -Path $FilePath -Value $content -Encoding UTF8
}

function Sanitize-ComposeFile {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return }

    $content = Get-Content -Raw -Path $FilePath

    $content = [regex]::Replace($content, '(?m)^(\s*-\s*DB_POSTGRESDB_PASSWORD=).+$', '${1}REMOVIDO')
    $content = [regex]::Replace($content, '(?m)^(\s*-\s*N8N_ENCRYPTION_KEY=).+$', '${1}REMOVIDO')
    $content = [regex]::Replace($content, '(?m)^(\s*-\s*GROQ_API_KEY=).+$', '${1}REMOVIDO')
    $content = [regex]::Replace($content, '(?m)^(\s*-\s*OPENAI_API_KEY=).+$', '${1}REMOVIDO')

    Set-Content -Path $FilePath -Value $content -Encoding UTF8
}

function Assert-NoSecrets {
    param([string]$RepoPath)

    $suspects = @(
        'gsk_[A-Za-z0-9_\-]+',
        'sk-proj-[A-Za-z0-9_\-]+'
    )

    $files = Get-ChildItem -Path $RepoPath -Recurse -File | Where-Object {
        $_.Extension -in '.json', '.yml', '.yaml', '.env', '.txt'
    }

    $hits = @()

    foreach ($file in $files) {
        $content = Get-Content -Raw -Path $file.FullName
        foreach ($pattern in $suspects) {
            if ($content -match $pattern) {
                $hits += [PSCustomObject]@{
                    File    = $file.FullName
                    Pattern = $pattern
                }
            }
        }
    }

    if ($hits.Count -gt 0) {
        Write-Host ""
        Write-Host "ERRO: possíveis segredos ainda encontrados nos arquivos do repositório." -ForegroundColor Red
        $hits | Format-Table -AutoSize
        throw "Segredos detectados. Push cancelado."
    }
}

New-Item -ItemType Directory -Force -Path $SnapshotWorkflows | Out-Null
New-Item -ItemType Directory -Force -Path $SnapshotCredentials | Out-Null
New-Item -ItemType Directory -Force -Path $RepoWorkflows | Out-Null
New-Item -ItemType Directory -Force -Path $RepoInfra | Out-Null

Write-Host "Exportando workflows..."
docker exec -u node $Container n8n export:workflow --backup --output="/backups/snapshots/$Stamp/workflows/"

Write-Host "Exportando credenciais..."
docker exec -u node $Container n8n export:credentials --backup --output="/backups/snapshots/$Stamp/credentials/"

Write-Host "Copiando workflows para o repositório Git..."
Copy-Item "$SnapshotWorkflows\*" $RepoWorkflows -Recurse -Force

Write-Host "Copiando docker-compose.yml..."
Copy-Item (Join-Path $ProjectRoot "docker-compose.yml") (Join-Path $RepoInfra "docker-compose.yml") -Force

Write-Host "Sanitizando workflows no repositório Git..."
Get-ChildItem -Path $RepoWorkflows -Recurse -Filter *.json | ForEach-Object {
    Sanitize-WorkflowFile -FilePath $_.FullName
}

Write-Host "Sanitizando docker-compose no repositório Git..."
Sanitize-ComposeFile -FilePath (Join-Path $RepoInfra "docker-compose.yml")

Write-Host "Validando se ainda restaram segredos..."
Assert-NoSecrets -RepoPath $Repo

Set-Location $Repo

Write-Host "Adicionando arquivos ao Git..."
git add .

$hasChanges = $true
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    $hasChanges = $false
}

if ($hasChanges) {
    $msg = "Backup n8n $Stamp"
    Write-Host "Criando commit: $msg"
    git commit -m $msg

    Write-Host "Enviando para o GitHub..."
    git push origin main
}
else {
    Write-Host "Sem alterações para commit."
}

Write-Host "Backup concluído com sucesso."
Write-Host "Snapshot completo em: $SnapshotRoot"