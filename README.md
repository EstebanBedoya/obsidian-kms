# obsidian-kms — Obsidian + LiveSync + MCP en el VPS

Estado al 2026-10-16: app Compose creada en Dokploy, **pendiente** de variables, dominio y deploy (hecho a mano en la UI; ver "Estado").

## Arquitectura

| Pieza | Detalle |
|---|---|
| VPS | VPS propio , Dokploy v0.26.5, Traefik en 80/443 |
| Dokploy | proyecto **Personal** / production, app Compose `obsidian-kms` |
| CouchDB | `couchdb:3`, volumen `couchdb_data`, sin puertos publicados |
| db-init | one-shot: aplica CORS de LiveSync y crea la base `obsidiannotes` |
| MCP | `ghcr.io/es617/obsidian-sync-mcp`, `READ_ONLY=true`, puerto 8787 interno |
| Dominio | `sync.mimot.app` (registro A → IP del VPS, **por crear** antes del deploy) |

Rutas Traefik (HTTPS Let's Encrypt):
- `https://sync.mimot.app/` → servicio `couchdb`, puerto 5984
- `https://sync.mimot.app/mcp` → servicio `mcp`, puerto 8787

Compose: [docker-compose.yml](docker-compose.yml). Referencia por servicio, sin secretos.

## Secretos

Generados localmente en `~/.config/obsidian-kms/secrets.env` (permisos 600). Variables:
`COUCHDB_USER`, `COUCHDB_PASSWORD`, `MCP_AUTH_TOKEN`, `COUCHDB_PASSPHRASE`.

- `COUCHDB_PASSPHRASE` es la passphrase de cifrado E2E de LiveSync: debe ser **la misma** en cada cliente y en el MCP. Guárdala en un gestor de contraseñas; sin ella no se leen las notas.
- Defaults del compose: `COUCHDB_DATABASE=obsidiannotes`, `VAULT_NAME=Notas` (el vault de Obsidian debe llamarse igual), `COUCHDB_OBFUSCATE_PROPERTIES=false` (debe coincidir con LiveSync).

## Estado y pendientes

- Hecho: app creada en Personal con este compose.
- No hecho (bloqueado): cargar variables y rutas por API. Dokploy v0.26.5 no tiene `compose.saveEnvironment` (404) y el clasificador bloqueó la creación de dominios. Se hace en la UI:
  1. Environment: pegar las 4 variables.
  2. Domains: las 2 rutas de arriba, HTTPS.
  3. Deploy.
- Alternativa si falla: template "Obsidian LiveSync" de Dokploy (solo CouchDB + CORS) y añadirle el servicio `mcp` a su compose.
- Compose **no probado**: el primer deploy lo valida. Si `db-init` o CouchDB fallan, revisar logs por SSH (solo lectura): `ssh vps 'docker logs --tail 100 <contenedor>'`.

## Verificación tras el deploy

```bash
# CouchDB (pide credenciales por require_valid_user)
curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" https://sync.mimot.app/_up
curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" https://sync.mimot.app/obsidiannotes

# MCP (con token): debe responder, y sin token debe rechazar
curl -si https://sync.mimot.app/mcp | head -1
```

## Conectar Claude Code al MCP

```bash
claude mcp add --transport http obsidian https://sync.mimot.app/mcp \
  --header "Authorization: Bearer <MCP_AUTH_TOKEN>"
```

El token está en `secrets.env`. Con `READ_ONLY=true` solo se exponen herramientas de lectura. Para habilitar escritura en carpetas concretas, usar `WRITE_FOLDERS` (ver README de obsidian-sync-mcp) en lugar de quitar el modo lectura.

## Configurar Obsidian (Mac y móvil)

Docs oficiales: https://github.com/vrtmrz/obsidian-livesync (docs/setup_own_server.md y docs/quick_setup.md).

1. Mac: crear el vault `Notas`, instalar el plugin Self-hosted LiveSync.
2. Generar el Setup URI (requiere Deno) con el script oficial `utils/setup/generate_setup_uri.ts`, usando:
   - `hostname=https://sync.mimot.app`
   - `database=obsidiannotes`
   - `username` / `password` = `COUCHDB_USER` / `COUCHDB_PASSWORD`
   - `passphrase` = `COUCHDB_PASSPHRASE`
   Guardar el código de recuperación de ID que imprime.
3. Importar el Setup URI en el Mac. Verificar que sincroniza.
4. Para el móvil: generar un **nuevo** Setup URI desde el Mac ya sincronizado (no reutilizar el inicial) e importarlo en Obsidian móvil.
5. Si el vault usa ofuscación de rutas (LiveSync 1.0.33+), añadir `COUCHDB_ID_DERIVATION_KEY` (código `sls-id-v1:...`) al MCP.

Meeting Copilot (https://github.com/alvarolobato/obsidian-meeting-copilot) es un plugin solo del Mac: Whisper/Ollama locales, nada en el VPS.

## Backup y restauración (propuesto, aún no configurado)

Datos: volumen Docker `couchdb_data` (nombre real con prefijo del proyecto: `docker volume ls | grep couchdb_data`).

Backup (en el VPS):
```bash
docker run --rm -v <VOLUMEN>:/data:ro -v /root/backups/obsidian-kms:/backup alpine \
  tar czf /backup/couchdb-$(date +%F).tgz -C /data .
```
Programarlo a diario con cron, retención ~14 días, y copiar fuera del VPS.

Restauración (con la app parada desde Dokploy):
```bash
docker run --rm -v <VOLUMEN>:/data -v /root/backups/obsidian-kms:/backup alpine \
  sh -c 'rm -rf /data/* && tar xzf /backup/couchdb-<FECHA>.tgz -C /data'
```
Luego Deploy. Probar la restauración en un volumen temporal antes de confiar en el backup.

## Notas de seguridad

- Ningún puerto interno publicado; solo Traefik (80/443). UFW: deny por defecto.
- CouchDB con `require_valid_user=true`; MCP con `MCP_AUTH_TOKEN`.
- No dejar `LOG_LEVEL=debug` en el MCP (registra contenido de notas).
- Cambios de variables en Dokploy fuera del wrapper: la skill `dockploy-admin-server` los trata como críticos.
