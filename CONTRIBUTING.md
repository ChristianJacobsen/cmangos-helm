# Contributing

This file covers the images, the local workflow, the CI, and the releases. For the chart itself, see the [README](README.md).

## Images

The Dockerfile in `build/` has two targets. The build argument `EXPANSION` (`classic`, `tbc`, or `wotlk`) selects the CMaNGOS repositories, for example `mangos-tbc` and `tbc-db`.

| Image | Contents | Size |
| --- | --- | --- |
| `cmangos-<expansion>-server` | `mangosd`, `realmd`, and the extractors (`ad`, `vmap_extractor`, `vmap_assembler`, `MoveMapGen`) | 270 to 290 MB |
| `cmangos-<expansion>-db` | the MySQL client, the core SQL, the world database of the expansion, and the playerbots SQL | 450 to 690 MB |

The two images must come from the same build, because the SQL updates follow the core revision. The file `build/sources.env` pins the source repositories of each expansion to commits, and Renovate updates the pins.

To build the images, you need Docker with buildx. The first build takes about 10 minutes on an 8-core machine. This command builds the Classic images:

```sh
make images
```

To build another expansion, set `EXPANSION`:

```sh
EXPANSION=wotlk make images
```

The script loads the images into the local Docker and writes `build/images.generated.yaml`. That file sets `expansion` and the images. To install the chart with these images, give Helm that file:

```sh
helm install cmangos charts/cmangos -n cmangos --create-namespace \
  -f build/images.generated.yaml -f values.local.yaml
```

The script resolves branch names to commits, so you can also build another revision:

```sh
CORE_REF=master DB_REF=master make images
```

Environment variables of `build/build-images.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `EXPANSION` | `classic` | `classic`, `tbc`, or `wotlk` |
| `REGISTRY` | `local` | Image namespace, for example `ghcr.io/you` |
| `TAG` | `<UTC date>-<core commit>` | Image tag |
| `PUSH` | `0` | `1` pushes to `REGISTRY`. Otherwise the script loads the images into Docker |
| `PLATFORMS` | host platform | For example `linux/amd64,linux/arm64`. Two or more platforms need `PUSH=1` |
| `BUILD_JOBS` | `0` | Parallel compile jobs. `0` is one per CPU. Each job can use more than 1 GiB of memory |
| `CORE_REF`, `DB_REF`, `PLAYERBOTS_REF` | from `build/sources.env` | Branch, tag, or commit |
| `CACHE_REF` | empty | Registry cache prefix, for example `ghcr.io/you/cmangos-wotlk-cache:amd64` |

If your cluster cannot pull from the local Docker, push the images to a registry with `REGISTRY` and `PUSH=1`. Then point the chart at them:

```yaml
expansion: wotlk
images:
  wotlk:
    server:
      registry: ghcr.io
      repository: <you>/cmangos-wotlk-server
      tag: "<tag>"
      digest: ""
    db:
      registry: ghcr.io
      repository: <you>/cmangos-wotlk-db
      tag: "<tag>"
      digest: ""
```

A rebuild on the same builder compiles only the changed files, because the compiler cache stays on the builder. With `CACHE_REF`, the build layers also go to a registry cache. If the sources and the base image did not change, a build on any machine then skips the compile.

## Local workflow

```sh
make lint        # helm lint
make images      # build the images
make template    # render with build/images.generated.yaml and values.local.yaml
make validate    # server-side dry run against the current cluster
make install     # helm upgrade --install with the same values
make test        # helm test (TCP checks against both servers)
```

The file `values.local.yaml` is for your local configuration. Git ignores it.

Artifact Hub shows the README outside of this repository. In the README, link to other files of the repository with full GitHub URLs.

## CI

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `chart-ci` | pull request, push | lint, render tests, kubeconform, shellcheck, the SRP6 test vectors |
| `images` | weekly, push to `build/` | builds, signs, and publishes the multi-arch images of the three expansions |
| `pin-merge` | `chart-ci` passes on the pin pull request | fast-forwards `main` to the pin commit, so that the commit keeps its signature |
| `chart-e2e` | nightly | installs the chart on kind for each expansion with the published images, without client data, and checks the databases and `realmd` |
| `chart-release` | tag `chart-v*` | signs and pushes the chart to `oci://ghcr.io/christianjacobsen/charts` |

The images workflow publishes the images with the tags `<date>-<core commit>` and `latest`. Then it opens a pull request that pins the new tags and digests of all three expansions in `charts/cmangos/values.yaml`. If one expansion fails to build, the workflow pins none of them.

## Releases

To release the chart, wait until the pin pull request merges. Then push a tag:

```sh
git tag chart-v0.1.1 && git push --tags
```

The release workflow packages the README and the LICENSE with the chart, and it signs the chart with cosign. It also pushes `artifacthub-repo.yml` to the chart repository, so that Artifact Hub shows the chart as a verified publisher. It writes the images of all three expansions to the `artifacthub.io/images` annotation, so that Artifact Hub scans them for vulnerabilities.
