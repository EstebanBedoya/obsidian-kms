# obsidian-kms — Obsidian + LiveSync + MCP en el VPS

Estado al 2026-10-16: **desplegado y verificado** (CouchDB + MCP de solo lectura, HTTPS válido). Falta solo configurar Obsidian en Mac y móvil.

## Arquitectura

| Pieza | Detalle |
|---|---|
| VPS | VPS propio , Dokploy v0.26.5, Traefik en 80/443 |
| Dokploy | proyecto **Personal** / production, app Compose `obsidian-kms` |
| CouchDB | `couchdb:3`, volumen `couchdb_data`, sin puertos publicados |
| db-init | one-shot: crea la base de datos (`COUCHDB_DATABASE`) si no existe |
| MCP | `ghcr.io/es617/obsidian-sync-mcp`, `READ_ONLY=true`, puerto 8787 interno |
| Dominios | `sync.mimot.app` (CouchDB) y `mcp.mimot.app` (MCP); registros A → IP del VPS |

Rutas Traefik (HTTPS Let's Encrypt):
- `https://sync.mimot.app/` → servicio `couchdb`, puerto 5984
- `https://mcp.mimot.app/` → servicio `mcp`, puerto 8787 (endpoint MCP: `https://mcp.mimot.app/mcp`)

Compose: [docker-compose.yml](docker-compose.yml). La config de CouchDB (single_node, CORS, auth) está en [couchdb-init.ini](couchdb-init.ini), montado al arrancar. Dokploy despliega desde este repo (rama `main`).

## Secretos

Generados localmente en `~/.config/obsidian-kms/secrets.env` (permisos 600). Variables:
`COUCHDB_USER`, `COUCHDB_PASSWORD`, `MCP_AUTH_TOKEN`, `COUCHDB_PASSPHRASE`. Además `MCP_DOMAIN=mcp.mimot.app` (no secreta, sin `https://`; alimenta `BASE_URL` del MCP).

- `COUCHDB_PASSPHRASE` es la passphrase de cifrado E2E de LiveSync: debe ser **la misma** en cada cliente y en el MCP. Guárdala en un gestor de contraseñas; sin ella no se leen las notas.
- Defaults del compose: `COUCHDB_DATABASE=obsidiannotes`, `VAULT_NAME=Notas` (el vault de Obsidian debe llamarse igual), `COUCHDB_OBFUSCATE_PROPERTIES=false` (debe coincidir con LiveSync).

## Estado y lecciones del despliegue

- Hecho: variables, dominios y deploy; CouchDB, CORS (desktop y móvil), certificados y MCP verificados.
- Los valores reales de las variables (usuario, base, vault) son los que hay en **Dokploy → Environment**, que pueden diferir de los defaults y de `secrets.env`. El vault de Obsidian debe llamarse como `VAULT_NAME` y LiveSync debe usar la base `COUCHDB_DATABASE`.
- Lecciones (cada una costó un despliegue colgado):
  1. CouchDB necesita `single_node=true` **al arrancar** (ini montado); fijarlo luego por API no crea `_users`.
  2. El `.ini` se monta **sin `:ro`**: la imagen hace `chown` al arrancar y sale con código 1 sin loguear nada.
  3. Dokploy deja los servicios con dominio solo en `dokploy-network`; `db-init` debe unirse a esa red o no resuelve `couchdb`.
  4. Tras cambiar el repo hay que usar **Deploy**, no Redeploy (Redeploy reutiliza el código ya clonado).
  5. Si un deploy se cuelga esperando a `db-init`, hay que parar la app antes de redesplegar.
- Alternativa descartada: template "Obsidian LiveSync" de Dokploy (solo CouchDB, sin MCP).
- Logs por SSH (solo lectura): `ssh vps 'docker logs --tail 100 <contenedor>'`.

## Verificación tras el deploy

```bash
# CouchDB (pide credenciales por require_valid_user)
curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" https://sync.mimot.app/_up
curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" https://sync.mimot.app/obsidiannotes

# MCP (con token): debe responder, y sin token debe rechazar
curl -si https://mcp.mimot.app/mcp | head -1
```

## Conectar Claude Code al MCP

```bash
claude mcp add --transport http obsidian https://mcp.mimot.app/mcp \
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
