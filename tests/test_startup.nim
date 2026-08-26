## Startup: a clean message and a non-zero exit on a bad config, a seed that is
## randomised when unpinned and honoured when pinned, and both entrypoints.

import
  std/[json, os, strutils, unittest],
  ../src/pistonball/[sim],
  ../src/pistonball as entrypoint

let root = currentSourcePath().parentDir().parentDir()
let manifest = parseJson(readFile(root / "coworld_manifest_template.json"))

suite "startup":
  test "an unparseable config is a clean PistonballError, not a traceback":
    var config = defaultGameConfig()
    expect PistonballError:
      config.update("{not json at all")
    var second = defaultGameConfig()
    expect PistonballError:
      second.update("[1, 2, 3]")

  test "an illegal config is rejected before a single tick runs":
    var config = defaultGameConfig()
    expect PistonballError:
      config.update("{\"num_agents\": 4}")
    var turns = defaultGameConfig()
    expect PistonballError:
      turns.update("{\"maxTicks\": 1000, \"turnTicks\": 225}")

  test "a pinned seed is honoured and drives every seeded draw":
    var config = defaultGameConfig()
    config.update("{\"seed\": 20260825}")
    check config.seed == 20260825
    let a = initSimServer(config)
    let b = initSimServer(config)
    check a.perm == b.perm
    var other = defaultGameConfig()
    other.update("{\"seed\": 20260826}")
    let c = initSimServer(other)
    check c.perm != a.perm or c.restHeights != a.restHeights

  test "the entrypoint randomises an UNPINNED seed":
    # The sentinel is the compiled-in default: a config carrying it (or no
    # seed at all) gets a fresh random seed, because a public fixed seed would
    # make the seat -> piston permutation pre-computable by an entrant.
    let source = readFile(root / "src" / "pistonball.nim")
    check "LegacyFixedSeed* = 4417231" in source
    check "seed not pinned; randomized" in source
    check "stripUnpinnedSeed" in source
    check defaultGameConfig().seed == 4417231

  test "the SENTINEL seed is not a pin, wherever it comes from":
    # The collision the value has with the certification fixture is the point,
    # not an accident: the manifest is public, so a seed pinned there is a seed
    # every entrant can read. Asserted on the fixture's own config text.
    let fixture = $manifest["certification"]["game_config"]
    check manifest["certification"]["game_config"]["seed"].getInt ==
      entrypoint.LegacyFixedSeed
    check not entrypoint.seedPinned(fixture)
    check not entrypoint.seedPinned("{\"seed\": 4417231}")
    check not entrypoint.seedPinned("{}")
    check not entrypoint.seedPinned("")
    check entrypoint.seedPinned("{\"seed\": 20260825}")
    # …and the sentinel is STRIPPED, so it cannot clobber the injected seed.
    let stripped = parseJson(entrypoint.stripUnpinnedSeed(fixture))
    check not stripped.hasKey("seed")
    check stripped["num_agents"].getInt == 20
    check parseJson(entrypoint.stripUnpinnedSeed(
      "{\"seed\": 20260825}")).hasKey("seed") == false

  test "both entrypoints exist and the image installs them":
    check fileExists(root / "src" / "pistonball.nim")
    check fileExists(root / "src" / "pistonball_player.nim")
    let dockerfile = readFile(root / "Dockerfile")
    check "/bin/pistonball" in dockerfile
    check "/bin/pistonball-player" in dockerfile
    check "CMD [\"/bin/pistonball\"]" in dockerfile
    let compose = readFile(root / "compose.yaml")
    check "image: coworld-pistonball:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose

  test "the CI scaffold is present and the hooks are committed executable":
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh", "tools/ci/viewer_smoke.mjs",
                 "tools/ci/policies.json", "tools/ci/renderer_fixture.html",
                 "tools/build_replay_viewer.sh", "tools/replay_summary.py"]:
      checkpoint(path)
      check fileExists(root / path)
    for hook in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"]:
      checkpoint(hook)
      check fpUserExec in getFilePermissions(root / hook)

  test "no unsubstituted scaffold placeholder survives":
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh", "tools/ci/policies.json"]:
      checkpoint(path)
      let source = readFile(root / path)
      check "<slug>" notin source
      check "<IMAGE>" notin source
      check "<SEATS>" notin source
