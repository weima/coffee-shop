-- Initial Oreo schema migration (version 1). See ../../schema.md for the contract.
-- The store enables foreign_keys before applying this file.

CREATE TABLE provider_profiles (
    profile_id TEXT PRIMARY KEY NOT NULL,
    provider TEXT NOT NULL CHECK (provider <> ''),
    model TEXT NOT NULL CHECK (model <> ''),
    thinking TEXT NOT NULL CHECK (thinking <> ''),
    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
    UNIQUE (provider, model, thinking)
) STRICT;

CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('open', 'closing', 'closed')),
    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= 0),
    closed_at_ms INTEGER,
    CHECK (
        (status = 'closed' AND closed_at_ms IS NOT NULL) OR
        (status <> 'closed' AND closed_at_ms IS NULL)
    )
) STRICT;

CREATE TABLE work_items (
    work_item_id TEXT PRIMARY KEY NOT NULL,
    session_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    request TEXT NOT NULL,
    status TEXT NOT NULL CHECK (
        status IN (
            'queued', 'running', 'needs_input', 'completed', 'failed',
            'cancelled', 'interrupted', 'expired'
        )
    ),
    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
    queued_at_ms INTEGER NOT NULL CHECK (queued_at_ms >= 0),
    started_at_ms INTEGER CHECK (started_at_ms IS NULL OR started_at_ms >= 0),
    expires_at_ms INTEGER CHECK (expires_at_ms IS NULL OR expires_at_ms >= 0),
    cancel_requested_at_ms INTEGER CHECK (
        cancel_requested_at_ms IS NULL OR cancel_requested_at_ms >= 0
    ),
    finished_at_ms INTEGER CHECK (finished_at_ms IS NULL OR finished_at_ms >= 0),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE RESTRICT,
    FOREIGN KEY (profile_id) REFERENCES provider_profiles(profile_id) ON DELETE RESTRICT,
    CHECK (
        (status IN ('queued', 'running', 'needs_input') AND finished_at_ms IS NULL) OR
        (status IN ('completed', 'failed', 'cancelled', 'interrupted', 'expired')
            AND finished_at_ms IS NOT NULL)
    ),
    CHECK (status NOT IN ('running', 'needs_input') OR started_at_ms IS NOT NULL)
) STRICT;

CREATE TABLE work_item_records (
    work_item_id TEXT NOT NULL,
    sequence_no INTEGER NOT NULL CHECK (sequence_no > 0),
    kind TEXT NOT NULL CHECK (
        kind IN (
            'assistant_message', 'tool_call', 'tool_result', 'needs_input',
            'input_response', 'progress', 'final_result'
        )
    ),
    payload_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
    PRIMARY KEY (work_item_id, sequence_no),
    FOREIGN KEY (work_item_id) REFERENCES work_items(work_item_id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX sessions_by_status_updated
    ON sessions(status, updated_at_ms DESC, session_id);

CREATE INDEX sessions_by_title
    ON sessions(title, session_id)
    WHERE title <> '';

CREATE INDEX work_items_by_session_created
    ON work_items(session_id, created_at_ms, work_item_id);

CREATE INDEX work_items_queued_by_time
    ON work_items(queued_at_ms, work_item_id)
    WHERE status = 'queued';

CREATE INDEX work_items_expiring_queue
    ON work_items(expires_at_ms, work_item_id)
    WHERE status = 'queued'
      AND started_at_ms IS NULL
      AND expires_at_ms IS NOT NULL;

PRAGMA user_version = 1;
