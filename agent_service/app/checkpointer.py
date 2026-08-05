"""Postgres checkpointer setup — own schema, own setup, not Ecto's migrations.

Shares the same Postgres instance as the Elixir app but writes to a
dedicated `langgraph` schema, so the two stacks' migrations never collide.
See CONTEXT.md's checkpointer-schema-ownership decision.
"""

import os
from contextlib import contextmanager

import psycopg
from langgraph.checkpoint.postgres import PostgresSaver
from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer
from psycopg.rows import dict_row

SCHEMA = "langgraph"

# Checkpoint state holds our own ExtractionResult (app/schemas.py), so it must
# be explicitly allow-listed for msgpack deserialization — otherwise this
# warns now and will be rejected outright in a future langgraph-checkpoint version.
ALLOWED_MSGPACK_MODULES = [("app.schemas", "ExtractionResult")]


def database_url() -> str:
    return os.environ.get(
        "CHECKPOINTER_DATABASE_URL",
        "postgresql://postgres:postgres@localhost:5432/vendor_onboarding_dev",
    )


def _conn_string() -> str:
    return f"{database_url()}?options=-c%20search_path%3D{SCHEMA},public"


def ensure_schema() -> None:
    with psycopg.connect(database_url(), autocommit=True) as conn:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")


@contextmanager
def get_checkpointer():
    """Context manager yielding a `PostgresSaver` scoped to the `langgraph` schema."""
    ensure_schema()

    with psycopg.connect(
        _conn_string(), autocommit=True, prepare_threshold=0, row_factory=dict_row
    ) as conn:
        serde = JsonPlusSerializer(allowed_msgpack_modules=ALLOWED_MSGPACK_MODULES)
        yield PostgresSaver(conn, serde=serde)
