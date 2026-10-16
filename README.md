# obsidian-kms — Obsidian + LiveSync + MCP en el VPS

Estado al 2026-10-16: **desplegado y verificado** (CouchDB + MCP de solo lectura, HTTPS válido). Falta solo configurar Obsidian en Mac y móvil.

## Arquitectura

| Pieza | Detalle |
|---|---|
| VPS | VPS propio , Dokploy v0.26.5, Traefik en 80/443 |
| Dokploy | proyecto **Personal** / production, app Compose `obsidian-kms` |
| CouchDB | `couchdb:3`, volumen `couchdb_data`, sin puertos publicados |
| db-init | one-shot: crea la base de datos (`COUCHDB_DATABASE`) si no existe |
| MCP | `ghcr.io/es617/obsidian-sync-mcp`, escritura limitada a `MCP/` (`WRITE_FOLDERS`), puerto 8787 interno |
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

El token está en `secrets.env`. El MCP puede leer todo el vault, pero **solo escribe dentro de `MCP/`** (`WRITE_FOLDERS=MCP`, aplicado en el servidor). Para ampliar las carpetas, cambia `WRITE_FOLDERS` en Dokploy → Environment y haz Deploy; para volver a solo lectura, `READ_ONLY=true`. El MCP puede modificar y borrar notas dentro de esas carpetas: confía en los backups.

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

## Backup y restauración

**Automático** (configurado el 2026-10-16): [scripts/backup.sh](scripts/backup.sh) corre en el VPS cada día a las 03:30 UTC (`/etc/cron.d/obsidian-kms-backup`).
- Copia el volumen de CouchDB (`compose-navigate-neural-alarm-rmwayh_couchdb_data`) a `/var/backups/obsidian-kms/couchdb-<fecha>.tgz`, con su `.sha256`. Permisos 600, solo root.
- Comprueba la integridad del `.tgz` antes de conservarlo y borra copias de más de 14 días.
- Log: `/var/log/obsidian-kms-backup.log`. Los ficheros de CouchDB son append-only, así que copiarlos con el servidor encendido es seguro.
- No incluye el volumen del MCP (índice de búsqueda y sesiones OAuth): se regenera solo.
- Si el `appName` de Dokploy cambia, cambia el nombre del volumen: el script falla con un error claro; ajusta `VOL`.

**Reinstalar el script** (si se rehace el VPS):
```bash
scp scripts/backup.sh vps:/tmp/obsidian-kms-backup.sh
ssh vps 'install -m 750 /tmp/obsidian-kms-backup.sh /usr/local/bin/obsidian-kms-backup.sh'
ssh vps 'echo "30 3 * * * root /usr/local/bin/obsidian-kms-backup.sh >> /var/log/obsidian-kms-backup.log 2>&1" > /etc/cron.d/obsidian-kms-backup'
```

**Restaurar** (la app se para desde Dokploy para que CouchDB no escriba):
```bash
# 1. En Dokploy: Stop obsidian-kms
# 2. En el VPS (elige la copia y verifícala):
cd /var/backups/obsidian-kms && sha256sum -c couchdb-<FECHA>.tgz.sha256
V=compose-navigate-neural-alarm-rmwayh_couchdb_data
mv /var/lib/docker/volumes/$V/_data /var/lib/docker/volumes/$V/_data.old   # no borrar hasta comprobar
mkdir /var/lib/docker/volumes/$V/_data
tar xzf couchdb-<FECHA>.tgz -C /var/lib/docker/volumes/$V/_data
# 3. En Dokploy: Deploy obsidian-kms
# 4. Comprobar notas y sync; si todo va bien, borrar _data.old
```

**Probado** el 2026-10-16: la copia extraída en un directorio temporal es idéntica (`diff -rq`) al volumen vivo. Aún no se ha arrancado un CouchDB desde una copia restaurada; hazlo una vez con datos reales.

**Copia fuera del VPS (Disk X):** [scripts/pull-backups.sh](scripts/pull-backups.sh) trae las copias del VPS a `/Volumes/Disk X/Backups/obsidian-kms/` con `rsync` por SSH (alias `vps`), verifica cada `.sha256` y conserva 60 días. Si Disk X no está montado, se salta sin error y se pone al día en la siguiente ejecución.
- A mano (funciona desde Terminal): `./scripts/pull-backups.sh`
- Automático: LaunchAgent [scripts/com.ebedoya.obsidian-kms-pull.plist](scripts/com.ebedoya.obsidian-kms-pull.plist), diario a las 08:00 hora local **y cada vez que se monta un disco** (si Disk X está conectado hace el backup; si no, se salta) (`~/Library/LaunchAgents/`). Log: `~/Library/Logs/obsidian-kms-pull.log`.
- **Permiso necesario (una vez):** macOS impide que los procesos de `launchd` escriban en discos externos. Hay que añadir `/bin/bash` en Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco. Sin eso el agente falla con `Operation not permitted` (código 12); a mano sigue funcionando.
- Disk X es ExFAT: no guarda permisos de Unix, así que quien tenga el disco puede leer las copias. Las notas van cifradas de extremo a extremo con la passphrase de LiveSync, pero conviene tratar el disco como sensible.
- Quitar la automatización: `launchctl bootout gui/$(id -u)/com.ebedoya.obsidian-kms-pull && rm ~/Library/LaunchAgents/com.ebedoya.obsidian-kms-pull.plist`

## Notas de seguridad

- Ningún puerto interno publicado; solo Traefik (80/443). UFW: deny por defecto.
- CouchDB con `require_valid_user=true`; MCP con `MCP_AUTH_TOKEN`.
- No dejar `LOG_LEVEL=debug` en el MCP (registra contenido de notas).
- Cambios de variables en Dokploy fuera del wrapper: la skill `dockploy-admin-server` los trata como críticos.
