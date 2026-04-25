from __future__ import annotations

import importlib

import jwt
import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    main = importlib.import_module("app.main")
    return TestClient(main.app)


def _analysis_payload(**overrides):
    payload = {
        "short_summary": "One latte.",
        "final_confirmation": "Confirm one latte?",
        "needs_confirmation": True,
        "payment_ready": False,
        "contradictions": [],
        "order_items": [{"name": "Latte", "quantity": 1, "notes": ""}],
        "merchant_name": "",
        "customer_name": "",
        "payment_amount": "",
        "currency": "EUR",
        "payment_reason": "Cafe order",
        "speaker_insights": [],
        "split_requested": False,
        "split_summary": "",
        "split_payment_requests": [],
        "agent_response": "Confirm one latte?",
        "session_status": "confirming",
        "should_call_human_server": False,
        "handoff_reason": "",
        "user_type": "customer",
        "hesitation_detected": False,
        "turn_count": 1,
        "turn_limit_reached": False,
    }
    payload.update(overrides)
    return payload


def test_payment_draft_with_transcript_only(client: TestClient, monkeypatch: pytest.MonkeyPatch):
    from app.routes import voice

    async def fake_analyze_order(**kwargs):
        assert kwargs["transcript"] == "One latte please."
        assert kwargs["turn_count"] == 2
        return _analysis_payload(turn_count=2)

    monkeypatch.setattr(voice, "_analyze_order", fake_analyze_order)

    response = client.post(
        "/payment-draft",
        json={"transcript": "One latte please.", "turn_count": 2},
    )

    assert response.status_code == 200
    assert response.json()["agent_response"] == "Confirm one latte?"
    assert response.json()["turn_count"] == 2


def test_voice_order_empty_audio_returns_400(client: TestClient):
    response = client.post(
        "/voice-order",
        files={"audio": ("empty.m4a", b"", "audio/m4a")},
    )

    assert response.status_code == 400
    assert response.json()["detail"] == "Audio upload was empty."


def test_voice_order_returns_agent_audio(client: TestClient, monkeypatch: pytest.MonkeyPatch):
    from app.routes import voice

    async def fake_transcribe_audio(**kwargs):
        return voice.TranscriptionResult(transcript="One latte please.", speaker_turns=[])

    async def fake_analyze_order(**kwargs):
        return _analysis_payload(agent_response="Confirm one latte?")

    async def fake_synthesize_speech(text: str):
        assert text == "Confirm one latte?"
        return b"wav-bytes"

    monkeypatch.setattr(voice, "_transcribe_audio", fake_transcribe_audio)
    monkeypatch.setattr(voice, "_analyze_order", fake_analyze_order)
    monkeypatch.setattr(voice, "_synthesize_speech", fake_synthesize_speech)

    response = client.post(
        "/voice-order",
        files={"audio": ("voice.wav", b"not-empty", "audio/wav")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["transcript"] == "One latte please."
    assert payload["agent_response"] == "Confirm one latte?"
    assert payload["agent_audio_base64"] == "d2F2LWJ5dGVz"
    assert payload["agent_audio_content_type"] == "audio/wav"


def test_agent_text_returns_compat_agent_response(client: TestClient):
    response = client.post(
        "/agent/text",
        json={
            "text": "Two lattes and checkout",
            "restaurant_id": "restaurant-1",
            "session_id": "session-1",
            "menu_context": [
                {"id": "latte-id", "name": "Latte", "price": 450},
            ],
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert set(payload) == {"message", "intents", "trigger_checkout"}
    assert payload["trigger_checkout"] is True
    assert payload["intents"][0]["action"] == "add_item"
    assert payload["intents"][0]["menu_item_id"] == "latte-id"
    assert payload["intents"][0]["quantity"] == 2


def test_agent_turn_requires_confirmation_before_cart_intents(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    from app.routes import agent

    async def fake_speech(text: str):
        return {}

    monkeypatch.setattr(agent, "_try_synthesize_speech", fake_speech)

    token = jwt.encode({"sub": "user-1"}, "test", algorithm="HS256")
    response = client.post(
        "/agent/turn",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "text": "Two lattes",
            "restaurant_id": "restaurant-1",
            "session_id": "session-1",
            "menu_context": [
                {"id": "latte-id", "name": "Latte", "price": 450},
            ],
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["requires_confirmation"] is True
    assert payload["cart_intents"] == []
    assert payload["pending_action"]["cart_intents"][0]["quantity"] == 2


def test_agent_turn_confirmation_emits_pending_cart_intents(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    from app.routes import agent

    async def fake_speech(text: str):
        return {}

    monkeypatch.setattr(agent, "_try_synthesize_speech", fake_speech)

    token = jwt.encode({"sub": "user-1"}, "test", algorithm="HS256")
    headers = {"Authorization": f"Bearer {token}"}
    body = {
        "text": "Two lattes",
        "restaurant_id": "restaurant-1",
        "session_id": "session-2",
        "menu_context": [
            {"id": "latte-id", "name": "Latte", "price": 450},
        ],
    }

    client.post("/agent/turn", headers=headers, json=body)
    response = client.post(
        "/agent/turn",
        headers=headers,
        json={**body, "text": "confirm", "confirm_action": True},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["requires_confirmation"] is False
    assert payload["cart_intents"][0]["menu_item_id"] == "latte-id"
    assert payload["action_result"] == {"status": "completed", "type": "cart"}


def test_agent_turn_keeps_session_memory_for_context_answers(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    from app.routes import agent

    seen_history_lengths = []
    seen_history_texts = []

    async def fake_context_answer(
        text,
        context,
        language,
        *,
        conversation_history,
        cart_context,
        memory_state,
        turn_analysis,
    ):
        seen_history_lengths.append(len(conversation_history))
        seen_history_texts.append([turn.text for turn in conversation_history])
        assert memory_state.allergies == ["peanuts"] or memory_state.allergies == []
        assert isinstance(turn_analysis, dict)
        return "Memory-aware reply."

    async def fake_speech(text: str):
        return {}

    monkeypatch.setattr(agent, "_generate_context_answer", fake_context_answer)
    monkeypatch.setattr(agent, "_try_synthesize_speech", fake_speech)

    token = jwt.encode({"sub": "user-memory"}, "test", algorithm="HS256")
    headers = {"Authorization": f"Bearer {token}"}
    body = {
        "restaurant_id": "restaurant-1",
        "session_id": "memory-session-1",
        "menu_context": [
            {"id": "latte-id", "name": "Latte", "price": 450},
        ],
    }

    first = client.post(
        "/agent/turn",
        headers=headers,
        json={**body, "text": "I am allergic to peanuts."},
    )
    second = client.post(
        "/agent/turn",
        headers=headers,
        json={**body, "text": "What can I safely order?"},
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert seen_history_lengths == [0, 2]
    assert seen_history_texts[1] == [
        "I am allergic to peanuts.",
        "Memory-aware reply.",
    ]


def test_agent_turn_returns_structured_memory_snapshot(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    from app.routes import agent

    async def fake_context_answer(
        text,
        context,
        language,
        *,
        conversation_history,
        cart_context,
        memory_state,
        turn_analysis,
    ):
        assert "peanuts" in memory_state.allergies
        assert turn_analysis["memory_update"]["allergies"] == ["peanuts"]
        return "I will keep peanut allergy in mind."

    async def fake_speech(text: str):
        return {}

    monkeypatch.setattr(agent, "_generate_context_answer", fake_context_answer)
    monkeypatch.setattr(agent, "_try_synthesize_speech", fake_speech)

    token = jwt.encode({"sub": "user-structured-memory"}, "test", algorithm="HS256")
    response = client.post(
        "/agent/turn",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "text": "I am allergic to peanuts.",
            "restaurant_id": "restaurant-1",
            "session_id": "memory-session-2",
            "menu_context": [
                {"id": "latte-id", "name": "Latte", "price": 450},
            ],
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["memory"]["allergies"] == ["peanuts"]
    assert payload["turn_analysis"]["memory_update"]["allergies"] == ["peanuts"]
    assert payload["message"] == "I will keep peanut allergy in mind."


def test_agent_turn_introduces_menu_by_category(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    from app.routes import agent

    async def fake_speech(text: str):
        return {}

    monkeypatch.setattr(agent, "_try_synthesize_speech", fake_speech)

    token = jwt.encode({"sub": "user-menu-intro"}, "test", algorithm="HS256")
    response = client.post(
        "/agent/turn",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "text": "Introduce the menu",
            "restaurant_id": "restaurant-1",
            "session_id": "menu-session-1",
            "menu_context": [
                {"id": "soup-id", "name": "Tomato Soup", "category": "Starters", "price": 650},
                {"id": "steak-id", "name": "Steak Frites", "category": "Mains", "price": 2250},
            ],
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert "First, Starters" in payload["agent_response"]
    assert "Tomato Soup" in payload["agent_response"]
    assert "Steak Frites" not in payload["agent_response"]
    assert "Shall I continue with Mains?" in payload["agent_response"]


def test_agent_turn_continues_menu_introduction(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    from app.routes import agent

    async def fake_speech(text: str):
        return {}

    monkeypatch.setattr(agent, "_try_synthesize_speech", fake_speech)

    token = jwt.encode({"sub": "user-menu-continue"}, "test", algorithm="HS256")
    headers = {"Authorization": f"Bearer {token}"}
    body = {
        "restaurant_id": "restaurant-1",
        "session_id": "menu-session-2",
        "menu_context": [
            {"id": "soup-id", "name": "Tomato Soup", "category": "Starters", "price": 650},
            {"id": "steak-id", "name": "Steak Frites", "category": "Mains", "price": 2250},
        ],
    }

    client.post(
        "/agent/turn",
        headers=headers,
        json={**body, "text": "Walk me through the menu"},
    )
    response = client.post(
        "/agent/turn",
        headers=headers,
        json={**body, "text": "continue"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert "Next is Mains" in payload["agent_response"]
    assert "Steak Frites" in payload["agent_response"]
    assert "Tomato Soup" not in payload["agent_response"]
    assert "That is the last category" in payload["agent_response"]
