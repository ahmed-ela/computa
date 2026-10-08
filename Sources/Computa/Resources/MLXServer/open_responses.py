"""Open Responses presentation for the owned, streaming-only local profile.

This module does not validate or execute model output. The strict stream
consumer remains the admission authority. Sampling values come from the pinned
producer's effective GenerationArguments, not its request-schema defaults.
"""
import math
import time


DONE = b"data: [DONE]\n\n"


def error_payload(message, *, kind="invalid_request", code=None, param=None):
    return {"type": kind, "code": code, "message": message, "param": param,
            "retryable": False}


def sampling_parameters(arguments):
    values = {}
    for name in ("temperature", "top_p", "presence_penalty", "frequency_penalty"):
        value = getattr(arguments, name, None)
        if value is None and name.endswith("_penalty"):
            value = 0.0  # A missing penalty is not applied by the producer.
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError("Invalid effective sampling configuration.")
        values[name] = value
    values["top_logprobs"] = 0  # This owned profile does not return log probabilities.
    return values


class ResponseProfile:
    def __init__(self, request=None, producer=None, max_output_tokens=4096, *, codex_usage=False):
        request = request or {}
        # Retain only response configuration, never another copy of full input.
        keys = ("model", "instructions", "tools", "tool_choice", "parallel_tool_calls",
                "text", "reasoning", "metadata", "safety_identifier", "prompt_cache_key")
        self.request = {key: request[key] for key in keys if key in request}
        self.producer = producer
        self.max_output_tokens = max_output_tokens
        self.codex_usage = codex_usage
        self.created_at = int(time.time())

    def resource(self, response):
        request = self.request
        status = response["status"]
        created = response.get("created_at")
        if type(created) in (int, float) and math.isfinite(created) and created >= 0:
            self.created_at = int(created)
        metadata = dict(request["metadata"]) if isinstance(request.get("metadata"), dict) else {}
        effective = getattr(self.producer, "sampling", None)
        # Pre-generation failure resources still have the schema's numeric
        # fields. Their neutral values are explicitly not applied sampling.
        sampling = effective or {"temperature": 0.0, "top_p": 1.0,
                                 "presence_penalty": 0.0, "frequency_penalty": 0.0,
                                 "top_logprobs": 0}
        metadata["computa_sampling"] = {"verified": effective is not None,
                                         "source": "producer" if effective else "not_applied"}
        usage = response.get("usage")
        standard_usage = None
        if isinstance(usage, dict):
            measured = {name: usage[name] for name in ("input_tokens", "output_tokens", "total_tokens")
                        if type(usage.get(name)) is int and usage[name] >= 0}
            for name, field in (("input_tokens_details", "cached_tokens"),
                                ("output_tokens_details", "reasoning_tokens")):
                details = usage.get(name)
                if isinstance(details, dict) and type(details.get(field)) is int and details[field] >= 0:
                    measured[name] = {field: details[field]}
            # MLX-VLM 0.7.1 does not measure the reasoning-token breakdown.
            # Preserve its genuine counts without inventing zero reasoning.
            if len(measured) == 5:
                standard_usage = measured
            elif measured:
                metadata["computa_measured_usage"] = measured
                metadata["computa_usage_details_complete"] = False
                if self.codex_usage:
                    # The pinned native parser uses partial measured counts
                    # for context occupancy/compaction, and accepts missing
                    # breakdowns. Only this explicit adapter profile preserves
                    # its existing partial Usage shape; do not invent details.
                    standard_usage = measured
        if self.codex_usage:
            metadata["computa_responses_profile"] = "codex-local-usage"
        tools = []
        for tool in request.get("tools") or []:
            if tool.get("type") == "function":
                tools.append({**tool, "description": tool.get("description"),
                              "parameters": tool.get("parameters"), "strict": tool.get("strict")})
            else:
                tools.append(tool)  # Existing Codex extension schemas retain their identity.
        reasoning = request.get("reasoning")
        if isinstance(reasoning, dict):
            reasoning = {"effort": reasoning.get("effort"), "summary": reasoning.get("summary")}
        else:
            reasoning = None
        terminal = status in ("completed", "incomplete", "failed", "cancelled")
        result = {**response, "object": "response", "created_at": self.created_at,
                  "completed_at": max(self.created_at, int(time.time())) if terminal else None,
                  "model": request.get("model") or response.get("model") or "local",
                  "previous_response_id": None, "instructions": request.get("instructions"),
                  "incomplete_details": response.get("incomplete_details"),
                  "error": response.get("error"), "tools": tools,
                  "tool_choice": request.get("tool_choice") or "auto", "truncation": "disabled",
                  "parallel_tool_calls": request.get("parallel_tool_calls", True),
                  "text": request.get("text") or {"format": {"type": "text"}},
                  **sampling, "reasoning": reasoning, "usage": standard_usage,
                  "max_output_tokens": self.max_output_tokens, "max_tool_calls": None,
                  "store": False, "background": False, "service_tier": "default",
                  "metadata": metadata, "safety_identifier": request.get("safety_identifier"),
                  "prompt_cache_key": request.get("prompt_cache_key")}
        return result
