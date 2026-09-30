# cmangos-helm

A Helm chart for [CMaNGOS](https://cmangos.net/) Classic, a World of Warcraft
1.12.1 (build 5875) server. The chart runs MySQL, `realmd` (the login server),
and `mangosd` (the world server). Two Jobs prepare the data: one installs and
migrates the databases, and one extracts the map data from your game client.

CMaNGOS publishes no container images. This repository builds them from
source with a Dockerfile and a build script. The images include the
[playerbots](https://github.com/cmangos/playerbots) module and the auction
house bot. Both are off by default, and you can turn them on in the chart
values.

## Quick start

You need a Kubernetes cluster, Helm 3.8 or later, and a 1.12.1 game client.

1. Get the images. The images workflow of this repository publishes them to
   `ghcr.io/christianjacobsen`, and the chart values pin the latest build.
   To build your own images instead, you need Docker with buildx. The first
   build takes about 10 minutes on an 8-core machine:

   ```sh
   make images
   ```

   The script loads the images into the local Docker and writes
   `build/images.generated.yaml` for Helm. If your cluster cannot pull from
   the local Docker, push the images to a registry with `REGISTRY` and
   `PUSH=1` (see [Images](#images)).

2. Write a values file. It tells the chart where the client is and which
   account to create. This example reads the client from a PVC. See
   [Client data](#client-data) for the other options (a node folder, NFS,
   or a download):

   ```yaml
   # values.local.yaml
   clientData:
     extract:
       clientVolume:
         persistentVolumeClaim:
           claimName: wow-client    # holds the folder that contains Data/
           readOnly: true
   dbInit:
     accounts:
       - username: admin
         password: change-me
         gmlevel: 3
   ```

3. Install the chart from the OCI registry:

   ```sh
   helm install cmangos oci://ghcr.io/christianjacobsen/charts/cmangos \
     -n cmangos --create-namespace -f values.local.yaml
   kubectl -n cmangos get pods -w
   ```

   With your own images, install from this repository:

   ```sh
   helm install cmangos charts/cmangos -n cmangos --create-namespace \
     -f build/images.generated.yaml -f values.local.yaml
   ```

4. In the client folder, set `realmlist.wtf` to the address of the `realmd`
   service, and log in as `admin`.

On an 8-core machine with 6 mmap threads, the first install took about 17
minutes. The db-init Job takes a few minutes. The client-data
Job extracted dbc files, maps, and vmaps in about 2 minutes, and then it
generated mmaps for about 14 minutes. Slower nodes take hours for the mmaps.
When both Jobs are done, `mangosd` starts. It loads the world in seconds.

5. Make sure that the chart works:

   ```sh
   helm test cmangos -n cmangos --logs
   ```

   The test connects to both servers. If `dbInit.accounts` has an account,
   the test also logs in with the first one. The test then requires an online
   realm (see [Testing a login](#testing-a-login)).

## What the chart deploys

| Component | Kind | Purpose |
| --- | --- | --- |
| `mysql` | StatefulSet | MySQL 8.4 with the four CMaNGOS databases (optional, see [Database](#database)) |
| `db-init` | Job | Creates the databases, installs the world content, applies the SQL updates, and creates accounts |
| `client-data` | Job | Fills the data volume with dbc, maps, vmaps, and mmaps |
| `realmd` | Deployment and Service | The login server (port 3724) |
| `mangosd` | Deployment and Service | The world server (port 8085) |

The server pods wait in init containers until the Jobs of their release
revision are complete. The Jobs carry the revision in their names, because
Kubernetes does not let you change a Job after you create it.

## Images

The Dockerfile in `build/` has two targets:

| Image | Contents | Size |
| --- | --- | --- |
| `cmangos-classic-server` | `mangosd`, `realmd`, and the extractors (`ad`, `vmap_extractor`, `vmap_assembler`, `MoveMapGen`) | about 270 MB |
| `cmangos-classic-db` | the MySQL client, the core SQL, [classic-db](https://github.com/cmangos/classic-db), and the playerbots SQL | about 450 MB |

The two images must come from the same build, because the SQL updates follow
the core revision.

The file `build/sources.env` pins the three source repositories to commits.
Renovate updates the pins. The build script resolves branch names to commits,
so you can also build another revision:

```sh
CORE_REF=master DB_REF=master make images
```

Environment variables of `build/build-images.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `REGISTRY` | `local` | Image namespace, for example `ghcr.io/you` |
| `TAG` | `<UTC date>-<core commit>` | Image tag |
| `PUSH` | `0` | `1` pushes to `REGISTRY`. Otherwise the script loads the images into Docker |
| `PLATFORMS` | host platform | For example `linux/amd64,linux/arm64`. Two or more platforms need `PUSH=1` |
| `BUILD_JOBS` | `0` | Parallel compile jobs. `0` is one per CPU. Each job can use more than 1 GiB of memory |
| `CORE_REF`, `DB_REF`, `PLAYERBOTS_REF` | from `build/sources.env` | Branch, tag, or commit |
| `CACHE_REF` | empty | Registry cache prefix, for example `ghcr.io/you/cmangos-classic-cache:amd64`. The script appends `-<target>` and uses a docker-container builder |

The compiler cache (ccache) lives in a BuildKit cache mount on the builder. On
the same builder, a rebuild after a small source change compiles only the
changed files. A new builder starts with an empty compiler cache.

With `CACHE_REF`, the build layers go to a registry cache. If
`build/sources.env` and the Ubuntu base image are unchanged, a later build on
any machine skips the compile. A cache that fails to load or save does not
fail the build.

The GitHub workflow `images.yaml` builds both images every week, and after
each change in `build/`. It builds on native amd64 and arm64 runners and
keeps its registry cache in `ghcr.io/christianjacobsen/cmangos-classic-cache`.
It publishes the images to `ghcr.io/christianjacobsen/cmangos-classic-{server,db}`
with the tags `<date>-<commit>` and `latest`. Then it opens a pull request
that pins the new tag and digest in `charts/cmangos/values.yaml`
(`build/pin-images.py`). A chart release after that merge installs the new
images by default.

To use another registry, set the image values:

```yaml
images:
  server:
    registry: ghcr.io
    repository: <you>/cmangos-classic-server
    tag: "20260930-8ec338a"
    digest: ""
  db:
    registry: ghcr.io
    repository: <you>/cmangos-classic-db
    tag: "20260930-8ec338a"
    digest: ""
```

## Client data

`mangosd` needs four kinds of data from the game client:

- dbc files: game tables such as spells and items.
- maps: terrain height.
- vmaps: buildings and other models, for line of sight.
- mmaps: navigation meshes, for creature path finding.

CMaNGOS has no download of this data, so the chart extracts it from your
client. Two volumes take part: the client volume, which the Job reads, and
the data volume, which the Job fills and `mangosd` reads.

The `clientData.source` value selects how the Job fills the data volume:

| `source` | What the Job does |
| --- | --- |
| `extract` (default) | Runs the extractors against your client (`clientVolume` or `clientUrl`) |
| `download` | Downloads and unpacks an archive of data that you extracted before (`clientData.download.url`) |
| `none` | No Job. The data volume holds the data already |

### The client

The Job reads the folder that contains `Data/`. Set one of these two values:

- `clientData.extract.clientVolume`: any Kubernetes volume source, for
  example a PVC, an NFS share, or a hostPath folder on the node.
  `clientSubPath` selects a folder inside the volume.
- `clientData.extract.clientUrl`: an archive of the client folder (`.tar`,
  `.tar.gz`, `.tgz`, `.tar.xz`, `.tar.bz2`, or `.zip`). If the maps or vmaps
  are missing, the Job downloads the archive into `scratchVolume` (an
  emptyDir with 12 GiB by default). It deletes the client after the
  extraction. Tar
  archives stream, so only the unpacked client (about 5 GB) needs space.
  Keep the URL private, because the client is copyrighted.

```yaml
clientData:
  extract:
    clientVolume:
      nfs:
        server: nas.example.com
        path: /export/games
    clientSubPath: "World of Warcraft 1.12.1"
    mmapThreads: 4       # 0 = one thread per CPU
```

If your cluster has no shared storage and you cannot use hostPath, copy the
client into a PVC once. The PVC uses the default storage class:

```sh
kubectl -n cmangos apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wow-client
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 8Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: wow-client-upload
spec:
  containers:
    - name: upload
      image: busybox:1.37.0
      command: ["sleep", "3600"]
      volumeMounts:
        - name: client
          mountPath: /client
  volumes:
    - name: client
      persistentVolumeClaim:
        claimName: wow-client
EOF
kubectl -n cmangos wait --for=condition=Ready pod/wow-client-upload
tar -C "/path/to/World of Warcraft 1.12.1" -cf - Data \
  | kubectl -n cmangos exec -i wow-client-upload -- tar -xf - -C /client
kubectl -n cmangos delete pod wow-client-upload
```

### The data volume

The chart selects the data volume in this order:

1. `clientData.volume`: any Kubernetes volume source, for example NFS.
2. `clientData.existingClaim`: a PVC that you manage.
3. A PVC that the chart creates from `clientData.storage` (10 GiB,
   ReadWriteOnce, the default storage class).

The Job writes a progress marker after each step into
`<data volume>/.cmangos/`. If the Job restarts, it continues after the last
finished step. If you turn on a step later (for example `mmaps: true`), the
next upgrade runs only that step. After the new step, restart `mangosd`, so
that it loads the new data.

To extract everything again, set `clientData.force=true` for one upgrade.

The chart keeps the PVC that it creates on `helm uninstall`
(`helm.sh/resource-policy: keep`). A reinstall with the same release name
uses the data again.

If you turn off vmaps or mmaps, the chart turns off the matching `mangosd`
configuration keys (`vmap.enableLOS`, `vmap.enableHeight`, `vmap.enableIndoorCheck`,
`mmap.enabled`).

Memory: the mmap generator uses about 0.5 to 1 GiB per thread on the large
continents. The default limit is 8 GiB. Set `mmapThreads` to fit your node.

The extracted data uses about 2.3 GB: 28 MB dbc, 150 MB maps, 270 MB vmaps,
and 1.8 GB mmaps. The default PVC size is 10 GiB.

## Database

By default, the chart deploys MySQL 8.4 with a 10 GiB volume. It generates the
root password and the password of the `mangos` user, and it keeps both in a
Secret. The Secret survives `helm uninstall`. The MySQL volume also
survives, and MySQL keeps its first root password.

To use your own MySQL or MariaDB server:

```yaml
mysql:
  enabled: false
externalDatabase:
  host: mysql.example.com
  port: 3306
  adminUser: root          # optional, see below
database:
  user: mangos
  existingSecret: cmangos-db   # keys: password, admin-password
```

If you set `adminUser`, the db-init Job creates the four databases and the
`mangos` user, and it grants the access. If you do not set it, the databases
must exist, and `database.user` must be able to create tables in them.

Do not use `;` in the password. CMaNGOS uses it to separate the fields of its
connection strings.

The bundled MySQL starts with three extra arguments (`mysql.extraArgs`):

- `--innodb-buffer-pool-size=512M`: room for the world database.
- `--skip-log-bin`: MySQL 8.4 writes a binary log for replication by
  default and flushes it to disk after each statement. One world install
  wrote about 400 MB of it. The playerbots module writes its equipment cache
  one row at a time. With the binary log, that first start took more than 10
  minutes. Without it, the start took about 2 minutes.
- `--innodb-flush-log-at-trx-commit=2`: MySQL flushes its log once a second
  instead of at each commit. A crash of MySQL loses nothing. A crash of the
  node can lose the last second of writes.

MariaDB leaves the binary log off by default, so it does not have this
problem. The chart uses `--skip-log-bin` because MySQL and MariaDB both
accept it. The bundled StatefulSet runs MySQL, and only MySQL 8.4 is tested.
CMaNGOS also supports MariaDB as an external database.

### What the db-init Job does

The Job runs on every install and upgrade. It is safe to run many times.

1. It creates the databases and the database user (with admin access only).
2. It loads the core base schema into each empty database.
3. It installs the world database with the `InstallFullDB.sh` script of
   classic-db. The Job then applies the playerbots world tables and your
   `dbInit.world.extraSql` files.
4. It applies the core SQL updates to all four databases.
5. If the playerbots tables are missing from the characters database, it
   creates them.
6. It sets the name, address, and port of the realm in the realm list.
7. It removes the default accounts and creates your accounts (see
   [Accounts](#accounts)).

The characters, `realmd`, and logs databases hold player data. The Job never
drops them.

The world database holds game content only. The image carries a fingerprint
of all world content. If the fingerprint changes (a new classic-db, core, or
playerbots version), the Job installs the world database again. That install
discards manual changes in the world database, for example spawns that a GM
added with `.npc add`. Keep such changes in `dbInit.world.extraSql`. The Job
applies these files after every world install:

```yaml
dbInit:
  world:
    extraSql:
      10-custom-spawns.sql: |
        INSERT INTO creature ...;
```

To install the world database only once, set `dbInit.world.reinstall=never`.
The Job still applies the core updates, but it does not apply new world
content.

## Accounts

The base SQL of CMaNGOS contains four accounts: ADMINISTRATOR, GAMEMASTER,
MODERATOR, and PLAYER. The password of each account is its name. On a fresh
database, the Job deletes them. To keep them, set
`dbInit.removeDefaultAccounts=false`.

The Job creates the accounts in `dbInit.accounts`:

```yaml
dbInit:
  accounts:
    - username: admin
      password: change-me       # stored in a Secret by the chart
      gmlevel: 3                # 0 player, 1 moderator, 2 game master, 3 administrator
    - username: friend
      existingSecret: my-accounts
      passwordKey: friend-password
```

If an account does not exist, the Job creates it. The Job never changes the
password of an existing account, because players can change their password
in the game. It sets `gmlevel` on every run. Names and passwords have 16
characters at most, and they are not case-sensitive.

You can also use the `mangosd` console:

```sh
kubectl -n cmangos attach -it deploy/cmangos-mangosd -c mangosd
account create <user> <password>
account set gmlevel <user> 3
```

To detach, press ctrl-p ctrl-q. Do not press ctrl-c, because it stops
`mangosd`.

Warning: do not type passwords in the attached console. The console echoes
your input, and the container log keeps it. Use `dbInit.accounts`, or the
remote consoles (see [Remote consoles](#remote-consoles)).

## Configuration

You can set any key from `mangosd.conf.dist`, `realmd.conf.dist`,
`aiplayerbot.conf.dist`, and `ahbot.conf.dist`. Use the key exactly as the
file writes it:

```yaml
mangosd:
  config:
    Rate.XP.Kill: 3
    Rate.Drop.Money: 2
    GameType: 1             # PvP realm
realmd:
  config:
    WrongPass.MaxCount: 5
```

CMaNGOS reads each key from an environment variable: a prefix, then the key
with `.` changed to `_`. For example, `Rate.XP.Kill` becomes
`Mangosd_Rate_XP_Kill`. The chart converts `true` and `false` to `1` and `0`.

| Values section | Configuration file | Prefix |
| --- | --- | --- |
| `mangosd.config` | `mangosd.conf` | `Mangosd_` |
| `realmd.config` | `realmd.conf` | `Realmd_` |
| `playerbots.config` | `aiplayerbot.conf` | `PlayerBots_` |
| `ahbot.config` | `ahbot.conf` | `Mangosd_` (the core uses the same prefix for this file) |

The chart sets the database connections, the data folder, the ports, and the
remote consoles. It also turns off the log files, so the servers log to
stdout only. To keep a log file, set its key, for example
`mangosd.config.LogFile: Server.log`. The files go to an emptyDir volume at
`/opt/cmangos/logs`.

For variables without a configuration key, use `mangosd.extraEnv` and
`realmd.extraEnv`.

At the default `LogLevel = 1`, `mangosd` logs an "Avg Diff" line about every
3 seconds. To make the log quieter, set `mangosd.config.LogLevel: 0`.

### Playerbots and the auction house bot

```yaml
playerbots:
  enabled: true
  config:
    AiPlayerbot.MinRandomBots: 100
    AiPlayerbot.MaxRandomBots: 100
mangosd:
  resources:
    limits:
      memory: 6Gi
ahbot:
  enabled: true
  config:
    AuctionHouseBot.Chance.Sell: 10
    AuctionHouseBot.Chance.Buy: 10
```

The playerbots module logs in 1000 random bots by default. The chart lowers
that number to 50. More bots need more memory for `mangosd`. In a test with
10 bots, `mangosd` used about 2.1 GiB.

On the first start with playerbots, the module creates 200 bot accounts
with 9 characters each. It also builds an equipment cache in the characters
database. That start took about 2 minutes. Later
starts load the cache. The startup probe allows 30 minutes
(`mangosd.startupProbe`). If the probe stops `mangosd` during the first
build, the cache stays incomplete. To build it again, stop `mangosd` and
empty the table `ai_playerbot_equip_cache`.

If `ahbot.enabled` is false, the chart sets `AuctionHouseBot.Chance.Sell`
and `AuctionHouseBot.Chance.Buy` to 0.

### Remote consoles

`mangosd` has two remote consoles: SOAP (`mangosd.soap.enabled`) and a telnet
console (`mangosd.remoteAccess.enabled`). The chart exposes them only inside
the cluster, on the Service `<release>-mangosd-admin`. Use
`kubectl port-forward` to reach them. Both need a GM account with gmlevel 3.
Because the chart can create that account (`dbInit.accounts`), you can also
create more accounts through them:

```sh
kubectl -n cmangos port-forward svc/cmangos-mangosd-admin 3443:3443
telnet 127.0.0.1 3443     # log in with the GM account, then: account create <user> <password>
```

## Testing a login

The db image contains `cmangos-auth-check`, a small test client for the
login protocol of the 1.12.1 client. It logs in with SRP6 and prints the
realm list. With `--check-world`, it also connects to each realm address and
waits for the greeting of `mangosd`. That proves that a real client can use the
address in `dbInit.realm`. You need no game client for it:

```sh
kubectl -n cmangos run auth-check --rm -it --restart=Never \
  --image=<db image> --env=AUTH_USERNAME=admin --env=AUTH_PASSWORD=change-me \
  --command -- cmangos-auth-check --host cmangos-realmd --expect-online
```

The script also runs outside the cluster with plain Python 3:

```sh
python3 build/scripts/auth-check.py --host <realmd address> \
  --user admin --password change-me --check-world
```

## Connecting a game client

The game protocols are raw TCP. Ingress routes HTTP only, so the chart does
not offer an Ingress.

The client connects to two addresses:

1. The address in `realmlist.wtf`, which is the `realmd` service. The client
   uses port 3724.
2. The realm address and port from the realm list, which is the `mangosd`
   service. `dbInit.realm.address` and `dbInit.realm.port` set them.

Both Services are of type LoadBalancer by default, so they listen on the
standard ports. On clusters without a load balancer, use NodePort services
with fixed ports:

```yaml
mangosd:
  service:
    type: NodePort
    nodePort: 30085
dbInit:
  realm:
    address: 192.168.1.20    # a node address that the clients can reach
```

If `dbInit.realm.port` is empty, the chart uses the `nodePort` of the
`mangosd` service (for NodePort) or its port. Clients expect the auth port
3724, so give `realmd` port 3724 on the address in `realmlist.wtf`.

`realmd` reads the realm list every 20 seconds, so a new realm address
takes effect without a restart.

### Gateway API

A Gateway controller that supports TCPRoute can route the two ports.
TCPRoute is in the experimental channel of the Gateway API, so the cluster
needs the experimental CRDs. A TCP listener cannot tell two routes apart, so
each game port needs its own listener on the Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: games
  namespace: gateway-system
spec:
  gatewayClassName: <your gateway class>
  listeners:
    - name: wow-auth
      protocol: TCP
      port: 3724
      allowedRoutes:
        namespaces:
          from: All
    - name: wow-world
      protocol: TCP
      port: 8085
      allowedRoutes:
        namespaces:
          from: All
```

The chart values attach one TCPRoute to each listener:

```yaml
gateway:
  enabled: true
  parentRefs:
    realmd:
      - name: games
        namespace: gateway-system
        sectionName: wow-auth     # a TCP listener on port 3724
    mangosd:
      - name: games
        namespace: gateway-system
        sectionName: wow-world    # a TCP listener on port 8085
realmd:
  service:
    type: ClusterIP
mangosd:
  service:
    type: ClusterIP
dbInit:
  realm:
    address: <Gateway address>
```

The chart renders the TCPRoute version that the cluster serves (`v1` or
`v1alpha2`). If the cluster serves neither, the chart fails with a message.

## Upgrades

`helm upgrade` runs both Jobs again. The db-init Job applies the new SQL
updates. If the world content changed, it also installs the world database
again. The client-data Job finds its markers and finishes in seconds.
Every upgrade restarts both servers, because their init containers wait for
the Jobs of the new revision.

## Uninstall

```sh
helm uninstall cmangos -n cmangos
```

Helm keeps three things: the MySQL volume (`data-cmangos-mysql-0`), the data
volume (`cmangos-client-data`), and the database Secret (`cmangos-db`). A
reinstall with the same release name uses them again. To delete everything,
delete them by hand:

```sh
kubectl -n cmangos delete pvc data-cmangos-mysql-0 cmangos-client-data
kubectl -n cmangos delete secret cmangos-db
```

## Development

```sh
make lint        # helm lint
make images      # build the images
make template    # render with build/images.generated.yaml and values.local.yaml
make validate    # server-side dry run against the current cluster
make install     # helm upgrade --install with the same values
make test        # helm test (TCP checks against both servers)
```

The file `values.local.yaml` is for your local configuration. Git ignores it.

The CI runs these workflows:

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `chart-ci` | pull request, push | lint, render tests, kubeconform, shellcheck, the SRP6 test vectors |
| `images` | weekly, push to `build/` | builds and publishes the multi-arch images |
| `chart-e2e` | nightly | installs the chart on kind with the published images, without client data, and checks the databases and `realmd` |
| `chart-release` | tag `chart-v*` | pushes the chart to `oci://ghcr.io/christianjacobsen/charts` |

The images workflow opens its pin pull request with the default token. Before
the first run, turn on "Allow GitHub Actions to create and approve pull
requests" in the repository under `Settings > Actions > General`. A pull request from the default token
does not start other workflows. To run `chart-ci` on it, add a
`PIN_PR_TOKEN` secret: a fine-grained token with write access to contents
and pull requests.

To release the chart, merge the pin pull request, then push a tag:

```sh
git tag chart-v0.1.0 && git push --tags
```

## Limits

- One realm per release, and one replica of each server.
- The chart has no backup job yet. Use `mysqldump` against the MySQL pod.
- C++ changes need a new image. Configuration changes need only an upgrade.
- The data volume uses ReadWriteOnce by default. That works on one node. On
  clusters with more nodes, use a ReadWriteMany volume through
  `clientData.existingClaim`, or keep the Job and `mangosd` on one node.
