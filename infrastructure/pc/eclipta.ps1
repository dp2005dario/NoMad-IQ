# =============================================================================
# ECLIPTA en tu PC con Windows, para usarlo desde tu móvil (gratis).
#
# El servidor de ECLIPTA corre aquí, en Docker Desktop, y tu móvil llega a él
# por Tailscale (una red privada gratis entre TUS aparatos, con https). Nadie
# más puede entrar: los puertos solo escuchan en este PC.
#
# Lo normal es hacer doble clic en ARRANCAR.cmd o PARAR.cmd (en esta carpeta).
# A mano, desde PowerShell en la carpeta del proyecto:
#   powershell -ExecutionPolicy Bypass -File infrastructure\pc\eclipta.ps1 arrancar
#   ... eclipta.ps1 parar               apaga ECLIPTA (los datos se quedan)
#   ... eclipta.ps1 clave TRAVELPAYOUTS_TOKEN   pone una clave sin que se vea
#   ... eclipta.ps1 estado              cómo va y cuál es tu dirección
#
# Se adapta a tu PC: con 16 GB de memoria o más enciende la IA de Flyra
# (Ollama); con menos, Flyra contesta con reglas sencillas y todo lo demás
# funciona igual.
#
# Nunca enseña una clave por pantalla. Las claves se guardan en
# infrastructure\.env, que git no sube nunca a GitHub.
# =============================================================================
param(
    [string]$Accion = 'arrancar',
    [string]$Nombre = ''
)
$ErrorActionPreference = 'Stop'

$Infra = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Infra '.env'
$Llaves = Join-Path $PSScriptRoot 'llaves'
$Direccion = Join-Path $PSScriptRoot 'direccion.txt'
$Compose = @('compose', '-f', 'docker-compose.yml', '-f', 'docker-compose.pc.yml')
# Las claves de webs externas que se pueden poner con "clave".
$ClavesValidas = @('TRAVELPAYOUTS_TOKEN', 'TRAVELPAYOUTS_MARKER', 'TICKETMASTER_API_KEY',
    'MAPILLARY_TOKEN', 'GOOGLE_CLIENT_ID')

function Paso([string]$Texto) { Write-Host ''; Write-Host "== $Texto ==" -ForegroundColor Cyan }
function Falla([string]$Texto) { Write-Host ''; Write-Host $Texto -ForegroundColor Red; exit 1 }

# --- .env: leer y escribir valores (UTF-8 SIN "BOM": Docker no lo entiende) --
function Leer-Env {
    if (Test-Path $EnvFile) { return [System.IO.File]::ReadAllLines($EnvFile) | ForEach-Object { $_.TrimEnd("`r") } }
    return [string[]]@()
}
function Valor([string]$Clave) {
    foreach ($l in Leer-Env) {
        if ($l.StartsWith("$Clave=")) { return $l.Substring($Clave.Length + 1) }
    }
    return ''
}
function Poner([string]$Clave, [string]$Val) {
    $lineas = @(Leer-Env | Where-Object { -not $_.StartsWith("$Clave=") })
    $lineas += "$Clave=$Val"
    # Saltos de línea "LF" (los de Linux): Docker lee mal los de Windows (CRLF).
    [System.IO.File]::WriteAllText($EnvFile, (($lineas -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# --- Números al azar fuertes (para las contraseñas que se inventan solas) ---
function Bytes-Azar([int]$N) {
    $b = New-Object byte[] $N
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($b)
    $rng.Dispose()
    return $b
}
function Hex-Azar([int]$N) { return (-join ((Bytes-Azar $N) | ForEach-Object { $_.ToString('x2') })) }
function Rellenar([string]$Clave, [string]$Val) {
    if ([string]::IsNullOrEmpty((Valor $Clave))) { Poner $Clave $Val; Write-Host "  creada $Clave" }
}

function Comprobar-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Falla "Falta Docker Desktop. Instálalo de https://www.docker.com/products/docker-desktop/ y vuelve a probar."
    }
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Falla "Docker Desktop no está encendido. Ábrelo, espera a que abajo a la izquierda ponga 'Engine running' y vuelve a probar."
    }
}

function Buscar-Tailscale {
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $ruta = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $ruta) { return $ruta }
    return $null
}

function Memoria-GB {
    $bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    return [math]::Round($bytes / 1GB)
}

# Docker Desktop (con WSL2) usa por defecto solo la MITAD de la memoria del PC.
# Con 8 GB se quedaría en 4 y ECLIPTA no cabe: se le deja usar el 75 %.
function Revisar-WSL([int]$Ram) {
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if ($Ram -ge 20 -or (Test-Path $cfg)) { return }
    $gb = [math]::Floor($Ram * 0.75)
    [System.IO.File]::WriteAllLines($cfg, [string[]]@('[wsl2]', "memory=${gb}GB", 'swap=8GB'),
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host "He dejado que Docker use $gb GB de tus $Ram GB (antes solo la mitad)." -ForegroundColor Yellow
    Write-Host 'Para que se aplique: cierra Docker Desktop (icono de la ballena, abajo a la derecha -> Quit),'
    Write-Host 'espera 10 segundos, ábrelo otra vez y vuelve a hacer doble clic en ARRANCAR.cmd.'
    exit 0
}

function Preparar-Env([int]$Ram) {
    Paso '1/5 Contraseñas y ajustes (se inventan solas la primera vez)'
    if (-not (Test-Path $EnvFile)) { Copy-Item (Join-Path $Infra '.env.example') $EnvFile }
    Rellenar 'POSTGRES_PASSWORD' (Hex-Azar 24)
    Rellenar 'REDIS_PASSWORD' (Hex-Azar 24)
    Rellenar 'QDRANT_API_KEY' (Hex-Azar 24)
    # Kafka quiere un identificador de 22 letras (base64 "url" de 16 bytes).
    Rellenar 'KAFKA_CLUSTER_ID' (([Convert]::ToBase64String((Bytes-Azar 16))).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
    Rellenar 'NOTIFY_PSEUDONYM_KEY' (Hex-Azar 32)
    Rellenar 'NOTIFY_TOKEN_KEY' (Hex-Azar 32)

    # La IA de Flyra según la memoria del PC.
    if ($Ram -ge 24) { Poner 'LLM_ENABLED' 'true'; Poner 'OLLAMA_MODEL' 'llama3.1:8b' }
    elseif ($Ram -ge 16) { Poner 'LLM_ENABLED' 'true'; Poner 'OLLAMA_MODEL' 'llama3.2:3b' }
    else { Poner 'LLM_ENABLED' 'false' }

    # Precios de vuelos reales si ya has puesto tu clave de Travelpayouts.
    if ((Valor 'TRAVELPAYOUTS_TOKEN') -and (Valor 'TRAVELPAYOUTS_MARKER')) {
        Poner 'FARE_PROVIDER' 'travelpayouts'
    } else {
        Poner 'FARE_PROVIDER' 'simulated'
        Write-Host '  OJO: sin clave de Travelpayouts los precios de vuelos son inventados.' -ForegroundColor Yellow
        Write-Host '  Ponla con PONER-CLAVE.cmd (TRAVELPAYOUTS_TOKEN y TRAVELPAYOUTS_MARKER).' -ForegroundColor Yellow
    }

    # La llave que firma las sesiones (se crea una vez y se guarda en llaves\).
    if (-not (Test-Path (Join-Path $Llaves 'jwt-active.pem'))) {
        New-Item -ItemType Directory -Force -Path $Llaves | Out-Null
        docker run --rm -v "${Llaves}:/k" alpine:3.20 sh -c 'apk add -q --no-cache openssl >/dev/null && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out /k/jwt-active.pem && chmod 644 /k/jwt-active.pem'
        if ($LASTEXITCODE -ne 0) { Falla 'No he podido crear la llave de las sesiones (¿hay internet?).' }
        Write-Host '  creada la llave de las sesiones'
    }
}

function Arrancar {
    Comprobar-Docker
    $ram = Memoria-GB
    Write-Host "Tu PC tiene $ram GB de memoria."
    Revisar-WSL $ram
    $ts = Buscar-Tailscale
    if (-not $ts) {
        Falla 'Falta Tailscale. Instálalo de https://tailscale.com/download/windows, entra con tu cuenta y vuelve a probar.'
    }
    Preparar-Env $ram

    $perfiles = @('--profile', 'apps')
    $ia = (Valor 'LLM_ENABLED') -eq 'true'
    if ($ia) { $perfiles += @('--profile', 'ai') }

    Paso '2/5 Construyendo y arrancando ECLIPTA (la primera vez tarda 30-60 min)'
    Push-Location $Infra
    try {
        docker @Compose @perfiles up -d --build --wait
        if ($LASTEXITCODE -ne 0) { Falla 'Algo no arrancó. Mira qué con: docker compose ps   (y ESTADO.cmd)' }
        if ($ia) {
            Paso '3/5 Descargando la IA de Flyra (solo la primera vez, unos GB)'
            docker @Compose exec ollama ollama pull (Valor 'OLLAMA_MODEL')
        } else {
            Paso '3/5 IA de Flyra apagada (tu PC tiene menos de 16 GB): Flyra contesta con reglas'
        }
    } finally { Pop-Location }

    Paso '4/5 Abriendo la puerta privada para tu móvil (Tailscale)'
    & $ts serve --bg http://127.0.0.1:8080
    if ($LASTEXITCODE -ne 0) {
        Falla 'Tailscale no ha podido abrir la puerta. Si te da un enlace, ábrelo y activa "HTTPS Certificates"; luego vuelve a probar.'
    }
    $yo = (& $ts status --json | ConvertFrom-Json).Self.DNSName.TrimEnd('.')
    $url = "https://$yo"
    [System.IO.File]::WriteAllText($Direccion, $url)

    Paso '5/5 Comprobando'
    Start-Sleep -Seconds 5
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 "$url/.well-known/jwks.json" | Out-Null
        Write-Host 'El servidor contesta bien.' -ForegroundColor Green
    } catch {
        Write-Host 'Aún no contesta por https (la primera vez Tailscale tarda un minuto en sacar el certificado). Prueba ESTADO.cmd en un rato.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host "Tu dirección de ECLIPTA: $url" -ForegroundColor Green
    Write-Host 'En tu móvil: Tailscale encendido, con la misma cuenta. Esa dirección es la que lleva la app.'
}

function Parar {
    Comprobar-Docker
    Push-Location $Infra
    try { docker @Compose --profile apps --profile ai down } finally { Pop-Location }
    Write-Host 'ECLIPTA apagado. Tus datos se quedan guardados para la próxima vez.' -ForegroundColor Green
}

function Clave([string]$N) {
    if ($ClavesValidas -notcontains $N) {
        Write-Host 'Dime qué clave quieres poner. Puedes poner:'
        $ClavesValidas | ForEach-Object { Write-Host "  $_" }
        $N = (Read-Host 'Nombre de la clave').Trim().ToUpper()
        if ($ClavesValidas -notcontains $N) { Falla 'Ese nombre no está en la lista.' }
    }
    if (-not (Test-Path $EnvFile)) { Copy-Item (Join-Path $Infra '.env.example') $EnvFile }
    $seg = Read-Host "Pega el valor de $N y pulsa Enter (no se verá)" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seg)
    try { $v = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    $v = $v.Trim()
    if (-not $v) { Falla 'No has pegado nada: no cambio nada.' }
    Poner $N $v
    Remove-Variable v
    Write-Host "Guardada $N (el valor no se enseña). Para que se use: ARRANCAR.cmd" -ForegroundColor Green
}

function Estado {
    Comprobar-Docker
    Push-Location $Infra
    try { docker @Compose --profile apps --profile ai ps --format 'table {{.Service}}\t{{.Status}}' } finally { Pop-Location }
    if (Test-Path $Direccion) {
        $url = [System.IO.File]::ReadAllText($Direccion).Trim()
        Write-Host ''
        Write-Host "Tu dirección: $url"
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 "$url/.well-known/jwks.json" | Out-Null
            Write-Host 'El servidor contesta bien.' -ForegroundColor Green
        } catch { Write-Host 'El servidor no contesta por esa dirección.' -ForegroundColor Yellow }
    }
}

switch ($Accion.ToLower()) {
    'arrancar' { Arrancar }
    'parar' { Parar }
    'clave' { Clave $Nombre.ToUpper() }
    'estado' { Estado }
    default { Falla "No conozco '$Accion'. Usa: arrancar, parar, clave o estado." }
}
