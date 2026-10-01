# cmangos-helm

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/cmangos)](https://artifacthub.io/packages/helm/cmangos/cmangos)

A Helm chart for [CMaNGOS](https://cmangos.net/), a World of Warcraft server. A release runs one of three game versions: Classic (1.12.1), The Burning Crusade (2.4.3), or Wrath of the Lich King (3.3.5a).

The chart runs MySQL, `realmd` (the login server), and `mangosd` (the world server). Two Jobs prepare the data: one installs and migrates the databases, and one extracts the map data from your game client.

CMaNGOS publishes no container images, so this repository builds them from source. The images include the [playerbots](https://github.com/cmangos/playerbots) module and the auction house bot. Both are off by default, and you can turn them on in the chart values.

## Quick start

You need a Kubernetes cluster, Helm 3.8 or later, and a game client of the expansion that you want to run.

1. Write a values file. It tells the chart the expansion, where the client is, and which account to create. This example reads the client from a PVC. For the other options, see [Client data](#client-data).

   ```yaml
   # values.local.yaml
   expansion: classic           # classic, tbc or wotlk
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

2. Install the chart:

   ```sh
   helm install cmangos oci://ghcr.io/christianjacobsen/charts/cmangos \
     -n cmangos --create-namespace -f values.local.yaml
   kubectl -n cmangos get pods -w
   ```

3. Wait for the two Jobs to complete. Then `mangosd` starts.

4. Make sure that the chart works:

   ```sh
   helm test cmangos -n cmangos --logs
   ```

   The test connects to both servers. If `dbInit.accounts` has an account, the test also logs in with it, and the realm must be online.

5. In the client folder, set `realmlist.wtf` to the address of the `realmd` service. Then log in as `admin`.

On an 8-core machine, the first Classic install took about 17 minutes, and the mmaps (navigation meshes) took 14 of them. With 4 mmap threads on a 10-core machine, the extraction took 25 minutes for TBC and 38 minutes for WotLK. Slower nodes take hours for the mmaps.

The chart values pin the images that the CI of this repository publishes to `ghcr.io/christianjacobsen`. To build your own images, see [CONTRIBUTING.md](https://github.com/ChristianJacobsen/cmangos-helm/blob/main/CONTRIBUTING.md).

## Expansions

The `expansion` value selects the game version:

| `expansion` | Game version | Client build | World database |
| --- | --- | --- | --- |
| `classic` (default) | Classic 1.12.1 | 5875 | [classic-db](https://github.com/cmangos/classic-db) |
| `tbc` | The Burning Crusade 2.4.3 | 8606 | [tbc-db](https://github.com/cmangos/tbc-db) |
| `wotlk` | Wrath of the Lich King 3.3.5a | 12340 | [wotlk-db](https://github.com/cmangos/wotlk-db) |

Each expansion has its own images, for example `cmangos-tbc-server` and `cmangos-tbc-db`. The expansion also sets the default database names, for example `tbcmangos` and `tbcrealmd`.

To run more than one expansion, install one release for each expansion. If you change `expansion` on an existing release, the client-data Job stops with an error, because the data volume holds the data of the old expansion.

## What the chart deploys

| Component | Kind | Purpose |
| --- | --- | --- |
| `mysql` | StatefulSet | MySQL 8.4 with the four CMaNGOS databases (optional, see [Database](#database)) |
| `db-init` | Job | Creates the databases, installs the world content, applies the SQL updates, and creates accounts |
| `client-data` | Job | Fills the data volume with dbc, maps, vmaps, and mmaps |
| `realmd` | Deployment and Service | The login server (port 3724) |
| `mangosd` | Deployment and Service | The world server (port 8085) |

The server pods wait until the Jobs of their release revision are complete.

## Client data

`mangosd` needs four kinds of data from the game client:

- dbc files: game tables such as spells and items.
- maps: terrain height.
- vmaps: buildings and other models, for line of sight.
- mmaps: navigation meshes, for creature path finding.

CMaNGOS has no download of this data, so the chart extracts it from your client. Two volumes take part: the client volume, which the Job reads, and the data volume, which the Job fills and `mangosd` reads.

The `clientData.source` value selects how the Job fills the data volume:

| `source` | What the Job does |
| --- | --- |
| `extract` (default) | Runs the extractors against your client (`clientVolume` or `clientUrl`) |
| `download` | Downloads and unpacks an archive of data that you extracted before (`clientData.download.url`) |
| `none` | No Job. The data volume holds the data already |

### The client

The Job reads the folder that contains `Data/`. Set one of these two values:

- `clientData.extract.clientVolume`: any Kubernetes volume source, for example a PVC, an NFS share, or a hostPath folder on the node. `clientSubPath` selects a folder inside the volume.
- `clientData.extract.clientUrl`: an archive of the client folder (`.tar`, `.tar.gz`, `.tgz`, `.tar.xz`, `.tar.bz2`, or `.zip`). If the Job must extract, it downloads the archive into `scratchVolume` and deletes it afterwards. Keep the URL private, because the client is copyrighted.

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

If your cluster has no shared storage and you cannot use hostPath, copy the client into a PVC once. The PVC uses the default storage class:

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
3. A PVC that the chart creates from `clientData.storage` (10 GiB, ReadWriteOnce, the default storage class).

The extracted data uses about 2.3 GB for Classic, 3.1 GB for TBC, and 3.2 GB for WotLK. Most of it is mmaps. The mmap generator uses about 0.5 to 1 GiB of memory per thread, so set `mmapThreads` to fit your node.

The Job records each finished step on the data volume. If the Job restarts, it continues after the last finished step. If you turn on a step later, for example `mmaps: true`, the next upgrade runs only that step. Then restart `mangosd`, so that it loads the new data. To extract everything again, set `clientData.force=true` for one upgrade.

## Database

By default, the chart deploys MySQL 8.4 with a 10 GiB volume. It generates the root password and the password of the `mangos` user, and it keeps both in a Secret.

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

If you set `adminUser`, the db-init Job creates the four databases and the `mangos` user, and it grants the access. If you do not set it, the databases must exist, and `database.user` must be able to create tables in them.

Do not use `;` in the password. CMaNGOS uses it to separate the fields of its connection strings.

The bundled MySQL runs with a few extra arguments, and `mysql.extraArgs` in `values.yaml` gives the reasons. Only MySQL 8.4 is tested.

### What the db-init Job does

The db-init Job runs on every install and upgrade, and it is safe to run many times. It creates the databases, installs the world content from the world database of the expansion, and applies the SQL updates. Then it sets the realm in the realm list and creates your accounts.

The characters, `realmd`, and logs databases hold player data. The Job never drops them.

The world database holds game content only. If the image carries new world content, the Job installs the world database again. That install discards manual changes, for example spawns that a GM added with `.npc add`. Keep such changes in `dbInit.world.extraSql`. The Job applies these files after every world install:

```yaml
dbInit:
  world:
    extraSql:
      10-custom-spawns.sql: |
        INSERT INTO creature ...;
```

To install the world database only once, set `dbInit.world.reinstall=never`.

## Accounts

The base SQL of CMaNGOS contains four accounts: ADMINISTRATOR, GAMEMASTER, MODERATOR, and PLAYER. The password of each account is its name. On a fresh database, the Job deletes them. To keep them, set `dbInit.removeDefaultAccounts=false`.

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

If an account does not exist, the Job creates it. The Job never changes the password of an existing account, because players can change their password in the game. It sets `gmlevel` on every run. Names and passwords have 16 characters at most, and they are not case-sensitive.

You can also use the `mangosd` console:

```sh
kubectl -n cmangos attach -it deploy/cmangos-mangosd -c mangosd
account create <user> <password>
account set gmlevel <user> 3
```

To detach, press ctrl-p ctrl-q. Do not press ctrl-c, because it stops `mangosd`.

Warning: do not type passwords in the attached console. The console echoes your input, and the container log keeps it. Use `dbInit.accounts`, or the remote consoles (see [Remote consoles](#remote-consoles)).

## Configuration

You can set any key from `mangosd.conf.dist` (`mangosd.config`), `realmd.conf.dist` (`realmd.config`), `aiplayerbot.conf.dist` (`playerbots.config`), and `ahbot.conf.dist` (`ahbot.config`). Use the key exactly as the file writes it:

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

The chart sets the database connections, the data folder, the ports, and the remote consoles. For environment variables without a configuration key, use `mangosd.extraEnv` and `realmd.extraEnv`.

The servers log to stdout only. To keep a log file, set its key, for example `mangosd.config.LogFile: Server.log`. At the default `LogLevel = 1`, `mangosd` logs an "Avg Diff" line about every 3 seconds. To make the log quieter, set `mangosd.config.LogLevel: 0`.

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

The chart lowers the number of random bots from 1000 to 50. More bots need more memory for `mangosd`. In a test with 10 bots, `mangosd` used about 2.1 GiB.

On the first start with playerbots, the module builds an equipment cache in the characters database. That start took about 2 minutes. If the startup probe stops `mangosd` during the build, the cache stays incomplete. To build it again, stop `mangosd` and empty the table `ai_playerbot_equip_cache`.

### Remote consoles

`mangosd` has two remote consoles: SOAP (`mangosd.soap.enabled`) and a telnet console (`mangosd.remoteAccess.enabled`). The chart exposes them only inside the cluster, on the Service `<release>-mangosd-admin`. Both need a GM account with gmlevel 3:

```sh
kubectl -n cmangos port-forward svc/cmangos-mangosd-admin 3443:3443
telnet 127.0.0.1 3443     # log in with the GM account, then: account create <user> <password>
```

## Connecting a game client

The game protocols are raw TCP. Ingress routes HTTP only, so the chart does not offer an Ingress.

The client connects to two addresses:

1. The address in `realmlist.wtf`, which is the `realmd` service. The client uses port 3724.
2. The realm address and port from the realm list, which is the `mangosd` service. `dbInit.realm.address` and `dbInit.realm.port` set them.

Both Services are of type LoadBalancer by default, so they listen on the standard ports. On clusters without a load balancer, use NodePort services with fixed ports:

```yaml
mangosd:
  service:
    type: NodePort
    nodePort: 30085
dbInit:
  realm:
    address: 192.168.1.20    # a node address that the clients can reach
```

If `dbInit.realm.port` is empty, the chart uses the `nodePort` of the `mangosd` service (for NodePort) or its port. Clients expect the auth port 3724, so give `realmd` port 3724 on the address in `realmlist.wtf`. `realmd` reads the realm list every 20 seconds, so a new realm address takes effect without a restart.

To test both addresses without a game client, run the login test on your machine with Python 3:

```sh
python3 build/scripts/auth-check.py --expansion classic --host <realmd address> \
  --user admin --password change-me --check-world
```

### Gateway API

A Gateway controller that supports TCPRoute can route the two ports. TCPRoute is in the experimental channel of the Gateway API, so the cluster needs the experimental CRDs. A TCP listener cannot tell two routes apart, so each game port needs its own listener on the Gateway:

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

## Upgrades

`helm upgrade` runs both Jobs again. The db-init Job applies the new SQL updates. The client-data Job finds its finished steps and completes in seconds. Every upgrade restarts both servers.

Chart 0.2.0 moved `images.server` and `images.db` to `images.<expansion>.server` and `images.<expansion>.db`. If your values set them, move them before you upgrade.

## Uninstall

```sh
helm uninstall cmangos -n cmangos
```

Helm keeps three things: the MySQL volume (`data-cmangos-mysql-0`), the data volume (`cmangos-client-data`), and the database Secret (`cmangos-db`). A reinstall with the same release name uses them again. To delete everything, delete them by hand:

```sh
kubectl -n cmangos delete pvc data-cmangos-mysql-0 cmangos-client-data
kubectl -n cmangos delete secret cmangos-db
```

## Signatures

Each chart version and image carries a keyless cosign signature from this repository. To make sure that a chart comes from here, run:

```sh
cosign verify ghcr.io/christianjacobsen/charts/cmangos:<version> \
  --certificate-identity-regexp '^https://github\.com/ChristianJacobsen/cmangos-helm/\.github/workflows/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The same command works for the images. Charts 0.1.0 and 0.1.1 and their images have no signatures.

## Limits

- One realm per release, and one replica of each server.
- The chart has no backup job yet. Use `mysqldump` against the MySQL pod.
- The data volume uses ReadWriteOnce by default. That works on one node. On clusters with more nodes, use a ReadWriteMany volume through `clientData.existingClaim`, or keep the Job and `mangosd` on one node.

## License

The chart uses the GPL-2.0-or-later license, the same as CMaNGOS. See [LICENSE](https://github.com/ChristianJacobsen/cmangos-helm/blob/main/LICENSE).
