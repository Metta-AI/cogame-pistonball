## Jev chooses a piston program from the same private view as prompt players.
import std/[json, os, strutils]
import curly

let Modes = %*{
  "wave": "Raise behind the ball and lower ahead of it.",
  "lift": "Raise while the ball is visible.",
  "drop": "Lower while the ball is visible.",
  "hold": "Hold a steady resting height.",
  "catch": "Stop a ball rolling back toward the right.",
  "ripple": "Run a blind travelling wave."
}

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc chooseJevAction*(view: JsonNode, seat, timeoutSeconds: int): JsonNode =
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let endpoint = if sidecar.len > 0: sidecar
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model = if sidecar.len > 0: getEnv("BEDROCK_MODEL")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key = if sidecar.len > 0: "" else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $seat
  let body = %*{
    "model": model,
    "state": "Choose a piston program for the next 9.4 seconds from this " &
      "seat's private view. Move the ball left toward the goal.\n" & $view,
    "questions": {"mode": {
      "type": "choice",
      "instructions": "Choose the mode for this piston.",
      "criteria": Modes
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answer = parseJson(response.body)["answers"]["mode"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != Modes.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned an invalid mode choice")
  var best = -1.0
  var total = 0.0
  var mode = ""
  for choice, probability in probabilities.pairs:
    if not Modes.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown mode")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      mode = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  %*{
    "note": "Jev mode choice", "mode": mode, "trigger_m": 1.0,
    "lead_ticks": 6, "up_m": 1.45, "down_m": 0.1,
    "idle_m": 0.25, "speed": 1.0, "blind": "idle", "say": ""
  }
