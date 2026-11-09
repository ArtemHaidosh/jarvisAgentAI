-- Schema for the agent's own data. Idempotent: start.ps1 applies it on every start.

-- Long-term facts about the owner. The agent reads all of them on every message
-- (Load facts node) and adds or removes them with the "Save fact" / "Forget fact" tools.
CREATE TABLE IF NOT EXISTS jarvis_facts (
    id         serial PRIMARY KEY,
    fact       text NOT NULL CHECK (length(fact) BETWEEN 1 AND 500),
    created_at timestamptz NOT NULL DEFAULT now()
);
