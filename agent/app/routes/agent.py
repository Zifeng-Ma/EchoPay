"""Compatibility routes for the Flutter intent-based ordering client."""

from __future__ import annotations

import json
import re
from typing import Any

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field

router = APIRouter(prefix="/agent", tags=["agent"])


class AgentTextRequest(BaseModel):
    text: str
    restaurant_id: str | None = None
    session_id: str | None = None
    language: str = "en"
    menu_context: list[dict[str, Any]] = Field(default_factory=list)


@router.post("/text")
async def agent_text(request: AgentTextRequest) -> dict[str, Any]:
    return _build_agent_response(request.text, request.menu_context)


@router.post("/voice")
async def agent_voice(
    audio: UploadFile = File(...),
    restaurant_id: str = Form(default=""),
    session_id: str = Form(default=""),
    language: str = Form(default="en"),
    menu_context: str = Form(default="[]"),
) -> dict[str, Any]:
    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Audio upload was empty.")

    try:
        parsed_menu = json.loads(menu_context)
    except json.JSONDecodeError:
        parsed_menu = []

    menu = parsed_menu if isinstance(parsed_menu, list) else []
    return _build_agent_response("", [item for item in menu if isinstance(item, dict)])


def _build_agent_response(
    text: str,
    menu_context: list[dict[str, Any]],
) -> dict[str, Any]:
    normalized = text.lower()
    intents: list[dict[str, Any]] = []

    if _mentions_clear_cart(normalized):
        intents.append({"action": "clear_cart", "quantity": 1, "modifiers": []})

    if normalized.strip():
        for item in menu_context:
            name = str(item.get("name") or "").strip()
            item_id = str(item.get("id") or "").strip()
            if not name or not _mentions_item(normalized, name):
                continue
            intents.append(
                {
                    "action": "add_item",
                    "menu_item_id": item_id or None,
                    "name": name,
                    "quantity": _extract_quantity(normalized, name),
                    "modifiers": [],
                    "special_instructions": None,
                }
            )

    trigger_checkout = _mentions_checkout(normalized)
    if trigger_checkout:
        intents.append({"action": "checkout", "quantity": 1, "modifiers": []})

    if intents:
        message = "I've updated your order."
    elif trigger_checkout:
        message = "I'll get checkout ready."
    else:
        message = "What would you like to order?"

    return {
        "message": message,
        "intents": intents,
        "trigger_checkout": trigger_checkout,
    }


def _mentions_item(text: str, name: str) -> bool:
    normalized_name = re.sub(r"\s+", " ", name.lower()).strip()
    return normalized_name in text


def _mentions_clear_cart(text: str) -> bool:
    return any(
        phrase in text
        for phrase in (
            "clear cart",
            "clear my order",
            "cancel my order",
            "start over",
        )
    )


def _mentions_checkout(text: str) -> bool:
    return any(
        phrase in text
        for phrase in (
            "checkout",
            "check out",
            "pay",
            "ready to order",
            "that's all",
            "that is all",
        )
    )


def _extract_quantity(text: str, item_name: str) -> int:
    words = {
        "a": 1,
        "an": 1,
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
        "ten": 10,
    }
    escaped = re.escape(item_name.lower())
    match = re.search(rf"\b(\d+|{'|'.join(words)})\s+{escaped}(?:s|es)?\b", text)
    if match is None:
        return 1
    raw = match.group(1)
    if raw.isdigit():
        return max(int(raw), 1)
    return words.get(raw, 1)
