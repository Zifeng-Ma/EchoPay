"""ADK entrypoint for `adk web` or `adk api_server`."""

from app.services.adk_loop import root_agent as _build_root_agent

root_agent = _build_root_agent()

