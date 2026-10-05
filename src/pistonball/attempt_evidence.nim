## Engine-side chronology for authenticated, issued native decisions.
## Player transport facts never choose the applied script or supply teacher authority.

import std/[base64, json, math, options, strutils]
import bitworld/decision_trajectory
import ./llm, ./scripts

proc validateNativeStart*(attempt: DecisionAttempt) =
  if attempt.origin != aoModel:
    raise newException(ValueError, "request start must identify a native model call")
  if attempt.response.kind != JNull or attempt.rawResponse.kind != JNull or
      attempt.platformCallId.isSome or attempt.providerRequestId.isSome or
      attempt.responseHeaders.isSome or attempt.responseHeadersB64.isSome or
      attempt.responseBodyB64.isSome or attempt.responseComplete.isSome or
      attempt.responseReaderJoined.isSome or attempt.httpStatus.isSome or
      attempt.latencyMs.isSome or attempt.inputTokens.isSome or attempt.outputTokens.isSome or
      attempt.promptTokenIds.isSome or attempt.sampledTokenIds.isSome or
      attempt.behaviorLogprobs.isSome or attempt.stopReason.isSome or
      attempt.rejectionReason.isSome or attempt.modelIdentity.isSome or
      attempt.tokenizerIdentity.isSome or attempt.chatTemplateSha256.isSome:
    raise newException(ValueError, "first model start must precede observed response facts")

proc validateNativeProgress*(before, evidence: JsonNode) =
  for key in ["attempt_id", "prompt", "request", "decoder", "policy", "origin", "model"]:
    if evidence[key] != before[key]:
      raise newException(ValueError, "native progress changed started request evidence")
  if (before["latency_ms"].kind != JNull or before["response_reader_joined"] == %true) and
      evidence != before:
    raise newException(ValueError, "finished native evidence is immutable")
  for key in ["response_body_b64", "response_headers_b64"]:
    if before[key].kind != JNull and
        (evidence[key].kind != JString or
          not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr()))):
      raise newException(ValueError, "received native bytes cannot be rewritten")
  if before["response_complete"] == %true:
    for key in ["response_complete", "response_body_b64", "response_headers_b64"]:
      if evidence[key] != before[key]:
        raise newException(ValueError, "complete native bytes are immutable")
  for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
      "model_identity", "tokenizer_identity", "chat_template_sha256"]:
    if before[key].kind != JNull and evidence[key] != before[key]:
      raise newException(ValueError, "received native identity is immutable")

proc validateNativeRequest*(attempt: DecisionAttempt, view, operatorPrompt,
    policy: string, retry: bool) =
  var user = userMessage(operatorPrompt, view)
  if retry: user.add("\n\nYour previous reply was unusable. Return only JSON.")
  let prompt = %*[{"role": "system", "content": SystemPrompt},
    {"role": "user", "content": user}]
  if attempt.prompt != prompt or attempt.policy != policy or
      attempt.request["system"] != %SystemPrompt or
      attempt.request["messages"] != %*[{"role": "user", "content": user}] or
      attempt.model.isNone or attempt.request["model"] != %attempt.model.get():
    raise newException(ValueError, "native request differs from the issued private decision")
  for key, value in attempt.request:
    if key notin ["model", "system", "messages", "max_tokens", "temperature"]:
      raise newException(ValueError, "native request has an unrecorded control")
  let maxTokens = attempt.request["max_tokens"].getInt()
  if maxTokens <= 0:
    raise newException(ValueError, "native token budget must be positive")
  var decoder = %*{"max_tokens": maxTokens}
  if attempt.request.hasKey("temperature"):
    let temperature = attempt.request["temperature"].getFloat()
    if classify(temperature) in {fcNan, fcInf, fcNegInf} or temperature < 0 or temperature > 2:
      raise newException(ValueError, "native temperature must be finite in 0..2")
    decoder["temperature"] = attempt.request["temperature"]
  if attempt.decoder != decoder:
    raise newException(ValueError, "native decoder differs from actually sent controls")

proc validateNativeAction*(attempt: DecisionAttempt, action: JsonNode) =
  if attempt.responseComplete != some(true) or attempt.responseReaderJoined != some(true) or
      attempt.httpStatus.isNone or attempt.httpStatus.get() notin 200 .. 299 or
      attempt.rawResponse.kind != JString or attempt.response.kind != JString or
      attempt.model.isNone:
    raise newException(ValueError, "selected native action requires a complete joined response")
  let native = parseJson(attempt.rawResponse.getStr())
  if native["model"] != %attempt.model.get():
    raise newException(ValueError, "native response model differs from retained evidence")
  var completion = ""
  for blockValue in native["content"]:
    if blockValue["type"] == %"text": completion.add(blockValue["text"].getStr())
  if completion != attempt.response.getStr() or extractJsonObject(completion) != action:
    raise newException(ValueError, "native response differs from submitted action")
