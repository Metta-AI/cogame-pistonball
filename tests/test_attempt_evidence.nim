import std/[base64, json, options, unittest]
import bitworld/decision_trajectory
import ../src/pistonball/attempt_evidence

suite "native request chronology":
  test "a first start cannot claim response facts, including observed false":
    let started = newDecisionAttempt("issued-native", "ordinary", aoModel)
    validateNativeStart(started)
    for key in ["response", "raw_response", "response_complete", "response_reader_joined",
        "latency_ms", "http_status", "response_body_b64", "platform_call_id"]:
      var observed = started
      case key
      of "response": observed.response = %"already finished"
      of "raw_response": observed.rawResponse = %"private body"
      of "response_complete": observed.responseComplete = some(false)
      of "response_reader_joined": observed.responseReaderJoined = some(false)
      of "latency_ms": observed.latencyMs = some(0.0)
      of "http_status": observed.httpStatus = some(200)
      of "response_body_b64": observed.responseBodyB64 = some(encode("partial"))
      of "platform_call_id": observed.platformCallId = some("local synthetic identity")
      else: discard
      expect ValueError: validateNativeStart(observed)

  test "partial bytes may advance until actual reader join seals all facts":
    var partial = newDecisionAttempt("issued-native", "ordinary", aoModel)
    partial.responseBodyB64 = some(encode("p"))
    let before = partial.attemptEvidenceJson()
    partial.responseBodyB64 = some(encode("partial"))
    partial.responseReaderJoined = some(true)
    let joined = partial.attemptEvidenceJson()
    validateNativeProgress(before, joined)
    validateNativeProgress(joined, joined)
    let mutation = partial.attemptEvidenceJson()
    mutation["response_complete"] = %true
    expect ValueError: validateNativeProgress(joined, mutation)
    let rewrite = partial.attemptEvidenceJson()
    rewrite["response_body_b64"] = %encode("rewritten")
    expect ValueError: validateNativeProgress(before, rewrite)

  test "model identity cannot diverge from the started request":
    var started = newDecisionAttempt("issued-native", "ordinary", aoModel)
    started.model = some("original-native-model")
    let before = started.attemptEvidenceJson()
    started.model = some("changed-model")
    expect ValueError: validateNativeProgress(before, started.attemptEvidenceJson())
