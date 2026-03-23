-- =============================================================================
-- WebAuthn Credential Storage Schema
-- Supports both PostgreSQL and SQLite with conditional sections.
-- =============================================================================

-- #############################################################################
-- POSTGRESQL VERSION
-- #############################################################################

-- Enable required extensions (PostgreSQL only)
-- CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- for gen_random_uuid()
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- alternative UUID generation

CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           TEXT UNIQUE NOT NULL,
    display_name    TEXT NOT NULL,
    -- Password hash is nullable: fully passwordless accounts have no password.
    password_hash   TEXT,
    -- Track whether the user has completed passkey enrollment.
    has_passkey     BOOLEAN NOT NULL DEFAULT false,
    -- Recovery codes (hashed, JSON array). Null if not generated.
    recovery_codes  JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS webauthn_credentials (
    -- Raw credential ID from the authenticator (binary, variable length).
    -- Base64url-decode the credential ID from the registration response before storing.
    credential_id       BYTEA PRIMARY KEY,

    -- Foreign key to the user who owns this credential.
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- COSE-encoded public key (binary). Do NOT convert to PEM/JWK for storage.
    public_key          BYTEA NOT NULL,

    -- Signature counter. Used to detect cloned authenticators.
    -- For multiDevice (synced) passkeys, this may always be 0.
    counter             BIGINT NOT NULL DEFAULT 0,

    -- WebAuthn transports hint from registration response.
    -- Values: 'internal', 'hybrid', 'usb', 'nfc', 'ble'
    -- Store as array and replay in allowCredentials during authentication.
    transports          TEXT[] NOT NULL DEFAULT '{}',

    -- Credential device type from verification result.
    -- 'singleDevice' = device-bound (hardware key, TPM)
    -- 'multiDevice'  = sync-eligible (passkey in iCloud/Google/1Password)
    device_type         TEXT NOT NULL CHECK (device_type IN ('singleDevice', 'multiDevice')),

    -- Whether the credential is currently backed up to cloud sync.
    backed_up           BOOLEAN NOT NULL DEFAULT false,

    -- AAGUID identifies the authenticator model.
    -- Cross-reference with FIDO MDS3 for device name/capabilities.
    aaguid              UUID,

    -- Attestation format used during registration.
    attestation_format  TEXT DEFAULT 'none',

    -- User-assigned label for credential management UI.
    friendly_name       TEXT,

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at        TIMESTAMPTZ,

    -- User-agent at registration time (for auto-labeling).
    registered_ua       TEXT
);

-- Index for looking up all credentials for a user (authentication flow).
CREATE INDEX IF NOT EXISTS idx_webauthn_cred_user_id
    ON webauthn_credentials(user_id);

-- Index for AAGUID-based queries (admin: "which users have YubiKey 5?").
CREATE INDEX IF NOT EXISTS idx_webauthn_cred_aaguid
    ON webauthn_credentials(aaguid)
    WHERE aaguid IS NOT NULL;

-- WebAuthn challenges (ephemeral, with TTL).
-- Alternative: use Redis or in-memory session store.
CREATE TABLE IF NOT EXISTS webauthn_challenges (
    session_id      TEXT PRIMARY KEY,
    challenge       BYTEA NOT NULL,
    ceremony_type   TEXT NOT NULL CHECK (ceremony_type IN ('registration', 'authentication')),
    user_id         UUID REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '5 minutes')
);

-- Auto-cleanup expired challenges (requires pg_cron or application-level cleanup).
CREATE INDEX IF NOT EXISTS idx_challenges_expires
    ON webauthn_challenges(expires_at);


-- #############################################################################
-- SQLITE VERSION
-- #############################################################################
-- Uncomment below and comment out PostgreSQL version above for SQLite.

/*
CREATE TABLE IF NOT EXISTS users (
    id              TEXT PRIMARY KEY,  -- UUID as text (SQLite has no native UUID)
    email           TEXT UNIQUE NOT NULL,
    display_name    TEXT NOT NULL,
    password_hash   TEXT,
    has_passkey     INTEGER NOT NULL DEFAULT 0,  -- 0=false, 1=true
    recovery_codes  TEXT,  -- JSON string
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS webauthn_credentials (
    credential_id       BLOB PRIMARY KEY,
    user_id             TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    public_key          BLOB NOT NULL,
    counter             INTEGER NOT NULL DEFAULT 0,
    -- SQLite has no array type; store as JSON array: '["internal","hybrid"]'
    transports          TEXT NOT NULL DEFAULT '[]',
    device_type         TEXT NOT NULL CHECK (device_type IN ('singleDevice', 'multiDevice')),
    backed_up           INTEGER NOT NULL DEFAULT 0,
    aaguid              TEXT,  -- UUID as text
    attestation_format  TEXT DEFAULT 'none',
    friendly_name       TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    last_used_at        TEXT,
    registered_ua       TEXT
);

CREATE INDEX IF NOT EXISTS idx_webauthn_cred_user_id
    ON webauthn_credentials(user_id);

CREATE TABLE IF NOT EXISTS webauthn_challenges (
    session_id      TEXT PRIMARY KEY,
    challenge       BLOB NOT NULL,
    ceremony_type   TEXT NOT NULL CHECK (ceremony_type IN ('registration', 'authentication')),
    user_id         TEXT REFERENCES users(id) ON DELETE CASCADE,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+5 minutes'))
);

CREATE INDEX IF NOT EXISTS idx_challenges_expires
    ON webauthn_challenges(expires_at);
*/


-- #############################################################################
-- COMMON QUERIES (both PostgreSQL and SQLite)
-- #############################################################################

-- Find all credentials for a user (authentication: build allowCredentials list)
-- SELECT credential_id, transports FROM webauthn_credentials WHERE user_id = ?;

-- Find credential by ID (assertion verification)
-- SELECT * FROM webauthn_credentials WHERE credential_id = ?;

-- Update counter after successful authentication
-- UPDATE webauthn_credentials SET counter = ?, last_used_at = NOW() WHERE credential_id = ?;

-- Delete a specific credential
-- DELETE FROM webauthn_credentials WHERE credential_id = ? AND user_id = ?;

-- Count credentials per user (warn if deleting last one)
-- SELECT COUNT(*) FROM webauthn_credentials WHERE user_id = ?;

-- Cleanup expired challenges
-- DELETE FROM webauthn_challenges WHERE expires_at < NOW();

-- List all credentials for management UI
-- SELECT credential_id, friendly_name, device_type, backed_up, transports,
--        created_at, last_used_at, aaguid
-- FROM webauthn_credentials
-- WHERE user_id = ?
-- ORDER BY created_at DESC;
