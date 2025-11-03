# Uso: .\script\test-mcp.ps1 [-BaseUrl http://localhost:80]
param(
  [string]$BaseUrl = 'http://localhost:80'
)

Write-Host "Probando MCP Server en $BaseUrl" -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tmpDir = Join-Path $env:TEMP "mcp-test-$timestamp"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$headersPath = Join-Path $tmpDir 'sse_headers.txt'
$eventsPath  = Join-Path $tmpDir 'sse_events.txt'
$errorsPath  = Join-Path $tmpDir 'sse_errors.txt'

# Genera un SessionId y pásalo al SSE; si el servidor devuelve otro, lo usamos.
$SessionId = [guid]::NewGuid().ToString()

Write-Host "Abriendo SSE en $BaseUrl/mcp..." -ForegroundColor Green
$curlArgs = @('-s', '-D', $headersPath, '-N', "$BaseUrl/mcp", '-H', "Mcp-Session-Id: $SessionId")
$proc = Start-Process -FilePath 'curl.exe' -ArgumentList $curlArgs -NoNewWindow -PassThru -RedirectStandardOutput $eventsPath -RedirectStandardError $errorsPath

# Espera un poco para que se escriban los headers
Start-Sleep -Seconds 1

if (-not (Test-Path $headersPath)) {
  Write-Host "No se pudo obtener headers de SSE." -ForegroundColor Red
  if ($proc -and -not $proc.HasExited) { $proc.Kill() }
  exit 1
}

$headers = Get-Content -Path $headersPath
$parsedSession = ($headers | Where-Object { $_ -match '^(?i)mcp-session-id:\s*(.+)$' } | ForEach-Object { $_ -replace '^(?i)mcp-session-id:\s*', '' }).Trim()
if ($parsedSession) {
  $SessionId = $parsedSession
}
Write-Host "Mcp-Session-Id: $SessionId" -ForegroundColor Yellow

function Send-JsonRpc {
  param(
    [Parameter(Mandatory=$true)][string]$Id,
    [Parameter(Mandatory=$true)][string]$Method,
    [object]$Params
  )
  $payload = @{ jsonrpc = '2.0'; id = $Id; method = $Method }
  if ($Params) { $payload.params = $Params }
  $json = $payload | ConvertTo-Json -Depth 10
  try {
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/mcp/messages" -Headers @{ 'Content-Type'='application/json'; 'Mcp-Session-Id'=$SessionId } -Body $json | Out-Null
  } catch {
    Write-Host ("Fallo request id={0}: {1}" -f $Id, $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host "Enviando initialize, tools/list y tools/call..." -ForegroundColor Green
Send-JsonRpc -Id '1' -Method 'initialize'
Send-JsonRpc -Id '2' -Method 'tools/list'
Send-JsonRpc -Id '3' -Method 'tools/call' -Params @{ name = 'get_utc_time'; arguments = @{} }

# Pruebas negativas según JSON-RPC 2.0
Write-Host "Enviando pruebas negativas..." -ForegroundColor Green
# Método inexistente (espera error -32601, id=E1)
Send-JsonRpc -Id 'E1' -Method 'nope'
# JSON inválido (espera error -32700 en respuesta directa, sin SSE)
try {
  $badPayload = 'not-json'
  $resp = Invoke-WebRequest -Method Post -Uri "$BaseUrl/mcp/messages" -Headers @{ 'Content-Type'='application/json'; 'Mcp-Session-Id'=$SessionId } -Body $badPayload
  $content = $resp.Content
  Write-Host "Respuesta a JSON inválido:" -ForegroundColor Yellow
  Write-Host $content
} catch {
  Write-Host ("Fallo prueba JSON inválido: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host "Esperando eventos SSE..." -ForegroundColor Green
Start-Sleep -Seconds 3

if (-not (Test-Path $eventsPath)) {
  Write-Host "No hay eventos SSE capturados." -ForegroundColor Red
} else {
  $events = Get-Content -Path $eventsPath
  Write-Host "--- Headers HTTP ---" -ForegroundColor Cyan
  $headers | ForEach-Object { Write-Host $_ }

  Write-Host "--- Eventos SSE (ready/ping/message) ---" -ForegroundColor Cyan
  $events | Select-String -Pattern 'event: ready|event: message|: ping' | ForEach-Object { $_.Line }

  Write-Host "--- Resultados JSON-RPC (ids 1,2,3) ---" -ForegroundColor Cyan
  foreach ($line in $events) {
    if ($line -match '^data:\s*(\{.+\})$') {
      try {
        $obj = $matches[1] | ConvertFrom-Json -ErrorAction Stop
        if ($obj.id -in @('1','2','3','E1')) {
          $jsonOut = $obj | ConvertTo-Json -Depth 10
          Write-Host ("id={0} => {1}" -f $obj.id, $jsonOut)
        }
      } catch {}
    }
  }
}

Write-Host "Cerrando SSE..." -ForegroundColor Green
try {
  if ($proc -and -not $proc.HasExited) { $proc.Kill() }
} catch {}

Write-Host ("Logs guardados en: {0}" -f $tmpDir) -ForegroundColor Yellow
exit 0