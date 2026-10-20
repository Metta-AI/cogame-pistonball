## Private runtime checkpoints after owned input or inference has returned.
## Published identity comes from the dispatcher; rules version stays separate.

import std/[base64, json, monotimes, options, os, strutils, times]
import bitworld/[artifact_runtime, decision_trajectory, native_stop]
import ./sim_types

type StagedMacro* = object
  decisionId*: string
  seat*, turn*, startTick*, endTick*: int
  observation*, action*: JsonNode
  attempts*: seq[DecisionAttempt]
  selected*: Option[string]
  status*: ActionStatus
  controls*: string

proc recordMacros*(trajectory: DecisionTrajectory, macros: seq[StagedMacro],
    terminal: bool) =
  for index, issued in macros:
    var execution = none(ExecutionEvidence)
    if issued.controls.len > 0:
      doAssert issued.controls.len == issued.endTick - issued.startTick
      execution = some(ExecutionEvidence(controlEncoding: ceU8,
        startTick: issued.startTick, endTick: issued.endTick, tickHz: TargetFps,
        seatControlsBase64: encode(issued.controls)))
    trajectory.recordDecision(issued.decisionId, $issued.seat, issued.observation,
      issued.attempts, issued.selected, issued.action, issued.status,
      terminal = terminal and index == macros.high,
      fallbackOrigin = (if issued.status == asFallback: some("engine_scripted") else: none(string)),
      execution = execution)

proc writePrivateEpisode*(trajectory: DecisionTrajectory, cleanupDeadline: MonoTime) =
  let destination = getEnv(CogameSaveTrajectoryUriEnv)
  if destination.len == 0: return
  let httpMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(PistonballError, "trajectory method must be PUT or POST")
  trajectory.writeTrajectoryArtifact(destination, cleanupDeadline, httpMethod)

proc writeInitializationCheckpoint*(status: EpisodeStatus, phase, errorType,
    errorMessage: string, episodeDeadline: MonoTime, inputs: JsonNode) =
  requestNativeStop()
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return
  let episodeId = getEnv("COWORLD_EPISODE_ID")
  let trajectory = newDecisionTrajectory(episodeId,
    "pistonball-initialization-" & episodeId, "pistonball",
    getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))
  doAssert status in {esFailed, esTruncated}
  trajectory.finish(status, %*{"reason": "runtime_initialization", "phase": phase,
    "error_type": errorType, "error": errorMessage, "seed_known": false,
    "engine_version": GameVersion, "runtime_inputs": inputs}, newJNull())
  trajectory.writePrivateEpisode(min(episodeDeadline,
    getMonoTime() + initDuration(seconds = 5)))
