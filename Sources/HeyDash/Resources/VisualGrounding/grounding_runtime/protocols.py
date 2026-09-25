"""Publisher protocol ports, with a deliberately narrow executable action boundary.

GUI-Owl and Fara prompts are attributed and pinned in native_prompts.json. Holo
explicitly accepts harness-provided tools: we preserve its native Qwen template,
observation wrappers, answer tool and parsed history. A common harness amendment
also treats clean final assistant prose as finish; this is not native Holo stopping.
No output here is permission to act: the environment must enforce its own scope.
"""

from __future__ import annotations

import json
import math
from copy import deepcopy
from pathlib import Path
import re


NATIVE = json.loads(Path(__file__).with_name("native_prompts.json").read_text())
FAMILIES = {"gui_owl", "fara", "holo", "qwen"}
KEYS = {"Enter", "Tab", "Shift+Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Space", "F2"}
KEYS |= {f"{modifier}+{key}" for modifier in ("Control", "Meta", "Control+Shift", "Meta+Shift", "Shift")
         for key in ("A", "C", "V", "X", "F", "Z", "Y", "S", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "Enter")}
KEYS |= {f"{modifier}+{key}" for modifier in ("Control", "Meta", "Control+Shift", "Meta+Shift")
         for key in ("H", "N", "O", "L")}
CAPABILITY_OVERLAY = (
    "\n\n# Controlled environment capabilities\n"
    "This environment supports only clicks, text typing, the listed keypresses, vertical scrolling and final answers. "
    "Do not request mouse movement alone, dragging, horizontal scrolling, waiting, direct URL navigation, search tools, "
    "page-reading tools, user interaction tools, code execution or terminal commands. "
    "After every action a fresh screenshot is supplied. Type at most 4000 characters without NUL. "
    "Scroll by a nonzero amount of at most 1600 pixels per action. Coordinates are in [0,1000]. "
    "When the task asks for an answer, return that answer, including the requested format, in the final-answer text field. "
    "Common completion contract: alternatively, finish by returning only your final answer as plain assistant text, "
    "without a tool call. Any such clean final text ends the task; do not use plain text alone for planning or self-talk. "
    "Finishing does not establish success: an independent evaluator checks the actual result. "
    "Supported key combinations: " + ", ".join(sorted(KEYS)) + "."
)


class ActionParseError(ValueError):
    """Malformed, truncated, ambiguous or unsupported action; never a success."""


def _number(value, name, lower, upper):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ActionParseError(f"{name} must be a number")
    if not math.isfinite(value) or not lower <= value <= upper:
        raise ActionParseError(f"{name} outside [{lower}, {upper}]")
    return value


def _text(value, name, allow_empty=False):
    if not isinstance(value, str) or len(value) > 16000 or (not allow_empty and not value):
        raise ActionParseError(f"{name} must be a bounded string")
    return value


def _typed_text(value):
    _text(value, "typed text", True)
    if len(value) > 4000 or "\x00" in value:
        raise ActionParseError("typed text must be at most 4000 characters without NUL")
    return value


def _scroll(value, name):
    result = _number(value, name, -1600, 1600)
    if result == 0:
        raise ActionParseError("scroll amount must be nonzero")
    return result


def _keys(value):
    if isinstance(value, str):
        value = value.split("+")
    if not isinstance(value, list) or not 1 <= len(value) <= 8:
        raise ActionParseError("keys must contain 1 to 8 key names")
    aliases = {"ctrl": "Control", "control": "Control", "alt": "Alt",
               "shift": "Shift", "super": "Meta", "win": "Meta", "cmd": "Meta",
               "command": "Meta", "meta": "Meta", "return": "Enter", "enter": "Enter", "escape": "Escape", "esc": "Escape",
               "space": "Space", "pgup": "PageUp", "pgdn": "PageDown",
               "up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft", "right": "ArrowRight"}
    keys = []
    for key in value:
        _text(key, "key")
        if len(key) > 40 or any(c in key for c in "\n\r\x00+"):
            raise ActionParseError("invalid key name")
        keys.append(aliases.get(key.lower(), key.upper() if len(key) == 1 else key))
    result = "+".join(keys)
    if result not in KEYS:
        raise ActionParseError("keypress is unavailable in the controlled environment")
    return result


def _strict_json(value):
    def pairs(items):
        out = {}
        for key, item in items:
            if key in out:
                raise ActionParseError(f"duplicate JSON key: {key}")
            out[key] = item
        return out
    try:
        return json.loads(value, object_pairs_hook=pairs,
                          parse_constant=lambda x: (_ for _ in ()).throw(ActionParseError("nonfinite JSON")))
    except (json.JSONDecodeError, TypeError) as exc:
        raise ActionParseError("invalid tool-call JSON") from exc


def strip_reasoning(raw):
    """Qwen can pre-open <think> in the prompt, so output may omit its start tag."""
    opens, closes = raw.count("<think>"), raw.count("</think>")
    if opens > 1 or closes > 1 or (opens and closes and raw.index("<think>") > raw.index("</think>")):
        raise ActionParseError("malformed reasoning block")
    if closes:
        content = raw.split("</think>", 1)[1].strip()
    elif opens:
        raise ActionParseError("unfinished reasoning block")
    else:
        content = raw.strip()
    if re.search(r"<\s*/?\s*think", content, re.I) or re.search(r"<\s*/?\s*(?:t|th|thi|thin)\s*$", content, re.I):
        raise ActionParseError("unfinished reasoning marker")
    return content


def parse_native_call(raw, family):
    if family not in FAMILIES:
        raise ValueError("unknown model family")
    _text(raw, "model output")
    content = strip_reasoning(raw)
    matches = list(re.finditer(r"<tool_call>\s*(.*?)\s*</tool_call>", content, re.S))
    if len(matches) != 1 or content.count("<tool_call>") != 1 or content.count("</tool_call>") != 1:
        raise ActionParseError("expected exactly one complete tool call")
    match = matches[0]
    # Do not silently accept a second, unterminated instruction after the call.
    suffix = content[match.end():].replace("<|im_end|>", "").strip()
    if suffix:
        raise ActionParseError("unexpected content after tool call")
    body = match.group(1)
    if family in {"gui_owl", "fara"}:
        call = _strict_json(body)
        if not isinstance(call, dict) or set(call) != {"name", "arguments"}:
            raise ActionParseError("expected name and arguments object")
    else:
        # Qwen3.5's publisher template uses this non-XML attribute syntax.
        fn = re.fullmatch(r"<function=([a-zA-Z_][\w]*)>\s*(.*?)\s*</function>", body, re.S)
        if not fn:
            raise ActionParseError("expected native Qwen function envelope")
        arguments = {}
        rest = fn.group(2)
        param_pattern = r"\s*<parameter=([a-zA-Z_][\w]*)>\n?(.*?)\n?</parameter>"
        while rest.strip():
            param = re.match(param_pattern, rest, re.S)
            if not param or param.group(1) in arguments:
                raise ActionParseError("malformed or duplicate function parameter")
            key, value = param.group(1), param.group(2)
            # String values are literal per the publisher template, not JSON.
            # Only known numerical/boolean/list parameters undergo JSON decoding.
            if key == "press_enter" and value in {"true", "false", "True", "False"}:
                # Jinja renders Python booleans as True/False in native history.
                value = value.lower() == "true"
            elif key in {"x", "y", "pixels", "delta_y", "press_enter", "keys", "clicks"}:
                value = _strict_json(value)
            arguments[key] = value
            rest = rest[param.end():]
        call = {"name": fn.group(1), "arguments": arguments}
    if not isinstance(call.get("arguments"), dict) or not isinstance(call.get("name"), str):
        raise ActionParseError("invalid call types")
    return call, content[:match.start()].strip()


def _check_fields(args, required, optional=()):
    if not set(required) <= set(args) or set(args) - set(required) - set(optional):
        raise ActionParseError("missing or unexpected action fields")


def normalize_call(call, family):
    name, args = call["name"], call["arguments"]
    if family in {"gui_owl", "fara"}:
        if name != "computer_use":
            raise ActionParseError("unoffered function")
        action = args.get("action")
        if action not in bounded_computer_tool(family)["parameters"]["properties"]["action"]["enum"]:
            raise ActionParseError(f"unsupported native action: {action}")
        clicks = {"left_click": ("left", 1), "right_click": ("right", 1),
                  "middle_click": ("middle", 1), "double_click": ("left", 2),
                  "triple_click": ("left", 3)}
        if action in clicks:
            _check_fields(args, ["action", "coordinate"])
            xy = args["coordinate"]
            if not isinstance(xy, list) or len(xy) != 2:
                raise ActionParseError("coordinate must be [x, y]")
            return {"action": "click", "x": _number(xy[0], "x", 0, 1000),
                    "y": _number(xy[1], "y", 0, 1000),
                    "button": clicks[action][0], "clicks": clicks[action][1]}
        if action == "type":
            _check_fields(args, ["action", "text"])
            return {"action": "type", "text": _typed_text(args["text"])}
        if action == "key":
            _check_fields(args, ["action", "keys"])
            return {"action": "keypress", "key": _keys(args["keys"])}
        if action == "scroll":
            _check_fields(args, ["action", "pixels"], ["coordinate"])
            result = {"action": "scroll", "delta_y": -_scroll(args["pixels"], "pixels")}
            if "coordinate" in args:
                xy = args["coordinate"]
                if not isinstance(xy, list) or len(xy) != 2:
                    raise ActionParseError("coordinate must be [x, y]")
                result.update(x=_number(xy[0], "x", 0, 1000), y=_number(xy[1], "y", 0, 1000))
            return result
        if action == "answer" and family == "gui_owl":
            _check_fields(args, ["action", "text"])
            return {"action": "finish", "text": _text(args["text"], "text", True)}
        if action == "terminate":
            if family == "fara":
                _check_fields(args, ["action", "answer"])
                return {"action": "finish", "text": _text(args["answer"], "answer", True)}
            _check_fields(args, ["action", "status"])
            if args["status"] != "success":
                raise ActionParseError("model terminated without success")
            return {"action": "finish", "text": ""}
        # Requests for help, wait, navigation, dragging etc. are not converted
        # to finish/no-op; callers can report this action-space limitation.
        raise ActionParseError(f"unsupported native action: {action}")
    if name == "click":
        _check_fields(args, ["element", "x", "y"], ["button", "clicks"])
        _text(args["element"], "element")
        button, clicks = args.get("button", "left"), args.get("clicks", 1)
        if button not in {"left", "right"} or isinstance(clicks, bool) or not isinstance(clicks, int) or not 1 <= clicks <= 3:
            raise ActionParseError("unsupported button or click count")
        return {"action": "click", "x": _number(args["x"], "x", 0, 1000),
                "y": _number(args["y"], "y", 0, 1000), "button": button, "clicks": clicks}
    if name == "write":
        _check_fields(args, ["content"], ["press_enter"])
        if not isinstance(args.get("press_enter", False), bool):
            raise ActionParseError("press_enter must be boolean")
        return {"action": "type", "text": _typed_text(args["content"]),
                "press_enter": args.get("press_enter", False)}
    if name == "press_key":
        _check_fields(args, ["key"])
        return {"action": "keypress", "key": _keys(args["key"])}
    if name == "scroll":
        _check_fields(args, ["delta_y"], ["x", "y"])
        if ("x" in args) != ("y" in args):
            raise ActionParseError("scroll target requires both x and y")
        result = {"action": "scroll", "delta_y": _scroll(args["delta_y"], "delta_y")}
        if "x" in args:
            result.update(x=_number(args["x"], "x", 0, 1000), y=_number(args["y"], "y", 0, 1000))
        return result
    if name == "answer":
        _check_fields(args, ["content"])
        return {"action": "finish", "text": _text(args["content"], "content", True)}
    raise ActionParseError(f"unoffered function: {name}")


def parse_model_output(raw, family, *, finish_reason):
    """Native action or common clean-text finish, never salvage malformed calls.

    Unlike Holo's publisher loop, this harness stops on a clean assistant final
    message. Apply equally to every family, without observing task state/scoring.
    """
    if family not in FAMILIES:
        raise ValueError("unknown model family")
    _text(raw, "model output")
    if finish_reason != "stop":
        raise ActionParseError(f"generation did not stop cleanly: {finish_reason}")
    content = strip_reasoning(raw)
    if "<tool_call>" in content:
        call, note = parse_native_call(raw, family)
        return normalize_call(call, family), call, note, "native_tool_call"
    # Partial/wrong tool envelopes must remain failures, never become a finish.
    # JSON answers remain possible, but an apparent serialized function call is
    # not an answer merely because its publisher delimiter was omitted.
    markers = re.search(r"<\s*/?\s*(?:tool|function|parameter)|<\|", content, re.I)
    partial = re.search(r"<\s*/?\s*(?:t|to|too|f|fu|fun|func|funct|functi|functio|p|pa|par|para|param|parame|paramet|paramete)\s*$", content, re.I)
    envelope = re.search(r'["\'](?:tool_calls?|function|arguments)["\']\s*:', content)
    bare_call = re.search(r"\b(?:computer_use|click|write|press_key|scroll|answer)\s*\(", content)
    if markers or partial or envelope or bare_call:
        raise ActionParseError("malformed or incomplete tool envelope")
    if not content or "\x00" in content:
        raise ActionParseError("final assistant text must be nonempty without NUL")
    return {"action": "finish", "text": content}, None, content, "common_plain_text_finish"


def parse_action(raw, family, *, finish_reason="stop"):
    return parse_model_output(raw, family, finish_reason=finish_reason)[0]


def _tool(name, description, properties, required):
    return {"type": "function", "function": {"name": name, "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required}}}


def bounded_computer_tool(family):
    """Preserve publisher serialization, explicitly restrict available capability.

    The original complete prompts remain unchanged in the provenance JSON. This
    overlay is task-independent and applied before seeing any benchmark result.
    """
    if family == "gui_owl":
        tool = json.loads(NATIVE["gui_owl"].split("<tools>\n", 1)[1].split("\n</tools>", 1)[0])["function"]
    else:
        f = NATIVE["fara"]
        tool = {"name": "computer_use", "description": f["description"], "parameters": deepcopy(f["parameters"])}
    props = tool["parameters"]["properties"]
    supported = {"key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "terminate"}
    if family == "gui_owl":
        supported.add("answer")
    props["action"]["enum"] = [name for name in props["action"]["enum"] if name in supported]
    props["action"]["description"] = "\n".join(line for line in props["action"]["description"].splitlines()
        if not line.startswith("* `") or line.split("`", 2)[1] in supported)
    props = {key: value for key, value in props.items() if key in {"action", "keys", "text", "coordinate", "pixels", "status", "answer"}}
    props["keys"]["description"] = "Key names pressed together; their '+'-joined combination must be one of: " + ", ".join(sorted(KEYS))
    props["text"]["maxLength"] = 16000 if family == "gui_owl" else 4000
    props["text"]["description"] = "Text to type (at most 4000 characters without NUL)" + ("; or the final answer for action=answer (at most 16000 characters)." if family == "gui_owl" else ".")
    props["pixels"].update(minimum=-1600, maximum=1600)
    props["pixels"]["description"] += " Must be nonzero and at most 1600 pixels in magnitude."
    tool["parameters"]["properties"] = props
    tool["description"] = "\n".join(line for line in tool["description"].splitlines() if "wait" not in line.lower())
    return tool


def native_tools():
    coord = {"type": "integer", "minimum": 0, "maximum": 1000}
    string = {"type": "string"}
    return [
        _tool("click", "Click at (x, y) coordinates", {"element": {"type": "string", "description": "Detailed description of the target UI element"}, "x": coord, "y": coord, "button": {"type": "string", "enum": ["left", "right"]}, "clicks": {"type": "integer", "minimum": 1, "maximum": 3}}, ["element", "x", "y"]),
        _tool("write", "Type at most 4000 characters without NUL, optionally pressing Enter afterward.", {"content": {"type": "string", "maxLength": 4000}, "press_enter": {"type": "boolean", "default": False}}, ["content"]),
        _tool("press_key", "Press one key or a simultaneous keyboard shortcut.", {"key": {"type": "string", "enum": sorted(KEYS)}}, ["key"]),
        _tool("scroll", "Scroll vertically by delta_y pixels (positive down, negative up); optional x,y target in [0,1000].", {"delta_y": {"type": "number", "minimum": -1600, "maximum": 1600}, "x": coord, "y": coord}, ["delta_y"]),
        _tool("answer", "Provide a final answer", {"content": {"type": "string", "description": "The answer content"}}, ["content"]),
    ]


def build_conversation(family, instruction, history, screenshot):
    """Return messages, ordered PNG byte images, optional native tool schemas.

    History is caller-owned executed steps: {screenshot?:bytes, raw_text:str,
    result?:str}. It must contain the actually executed proposal only. No scorer,
    task ID, DOM, expected answer or evaluator fields are accepted or consumed.
    """
    if family not in FAMILIES:
        raise ValueError("unknown model family")
    _text(instruction, "instruction")
    if not isinstance(history, list) or len(history) > 100:
        raise ValueError("history must be a list of at most 100 steps")
    for step in history:
        if not isinstance(step, dict) or set(step) - {"screenshot", "raw_text", "result"}:
            raise ValueError("history accepts screenshot, raw_text and result only")
        _text(step.get("raw_text"), "history raw_text")
        if "result" in step:
            _text(step["result"], "history result", True)
    if family == "gui_owl":
        system = NATIVE["gui_owl"]
        a, b = system.index("<tools>\n") + len("<tools>\n"), system.index("\n</tools>")
        system = system[:a] + json.dumps({"type": "function", "function": bounded_computer_tool(family)}) + system[b:]
        system = system.replace("- If finishing, use action=terminate in the tool call.",
            "- If the task asks for an answer, finish with action=answer and put the complete answer in text. "
            "Otherwise finish with action=terminate and status=success only when done.")
    elif family == "fara":
        f = NATIVE["fara"]
        tool = bounded_computer_tool(family)
        system = f["FARA_QWEN35_IDENTITY"] + "\n\n" + f["CRITICAL_POINTS_FARA_1_5"] + "\n\n" + f["FN_CALL_FORMAT"].format(tool_descs=json.dumps(tool))
    else:
        system = ("You are a computer-use assistant. Complete the user's task using the provided tools. "
                  "Use the current screenshot to ground actions. Coordinates are normalized to [0, 1000]. "
                  "Call exactly one tool for an action; finish only when the task is complete. "
                  "Never invent personal information or act outside the user's instructions.")
    messages = [{"role": "system", "content": system + CAPABILITY_OVERLAY}]
    images = []
    tools = native_tools() if family in {"holo", "qwen"} else None
    image_window = 4 if family == "gui_owl" else 2  # history, plus current image
    history_start = max(0, len(history) - image_window)
    if family == "gui_owl":
        older = []
        for i, item in enumerate(history[:history_start]):
            output = item["raw_text"]
            if "Action:" in output and "<tool_call>" in output:
                output = output.split("Action:", 1)[1].split("<tool_call>", 1)[0].strip()
            older.append(f"Step {i + 1}: {output}")
        task_text = ("Please generate the next move according to the UI screenshot, "
                     "instruction and previous actions.\n\n" + f"Instruction: {instruction}\n\n"
                     + "Previous actions:\n" + ("\n".join(older) or "None"))
        steps = history[history_start:]
    else:
        task_text = instruction
        steps = history
    for i, step in enumerate([*steps, {"screenshot": screenshot}]):
        content = []
        if i == 0:
            content.append({"type": "text", "text": task_text})
        elif family == "fara":
            content.append({"type": "text", "text": "Here is the next screenshot. Think about what to do next."})
        if family in {"holo", "qwen"}:
            content.append({"type": "text", "text": "<observation>\n"})
        keep_image = family == "gui_owl" or i >= history_start
        if keep_image and isinstance(step.get("screenshot"), bytes):
            images.append(step["screenshot"])
            content.append({"type": "image"})
        else:
            content.append({"type": "text", "text": "[screenshot evicted or unavailable]"})
        if family in {"holo", "qwen"}:
            content.append({"type": "text", "text": "\n</observation>"})
        messages.append({"role": "user", "content": content})
        if "raw_text" not in step:
            continue
        if family in {"holo", "qwen"}:
            call, note = parse_native_call(step["raw_text"], family)
            tool_id = f"step-{i}"
            messages.append({"role": "assistant", "content": note,
                             "tool_calls": [{"id": tool_id, "type": "function", "function": call}]})
            messages.append({"role": "tool", "tool_call_id": tool_id,
                             "content": step.get("result", "Action executed; inspect the next screenshot.")})
        else:
            messages.append({"role": "assistant", "content": step["raw_text"]})
            if step.get("result"):
                messages.append({"role": "user", "content": step["result"]})
    return messages, images, tools
