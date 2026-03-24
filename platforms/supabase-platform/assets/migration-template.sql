-- ==========================================================================
-- Migration Template: __TABLE_NAME__
--
-- Replace all occurrences of __TABLE_NAME__ with your actual table name.
-- Adjust columns, types, and policies to match your requirements.
--
-- Conventions used:
--   • UUID primary key (auto-generated via gen_random_uuid())
--   • user_id FK to auth.users for ownership
--   • created_at / updated_at timestamps with auto-update trigger
--   • RLS enabled with ownership-based policies
--   • Indexes on foreign keys and commonly queried columns
--
-- Usage:
--   supabase migration new create___TABLE_NAME__
--   # Paste this template into the generated file, then:
--   supabase db reset
-- ==========================================================================


-- =========================================================================
-- 1. Table Definition
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.__TABLE_NAME__ (
  -- Primary key: UUID auto-generated on insert
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Foreign key: links each row to the owning user
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- ---- Add your columns below ----
  title       text NOT NULL,
  description text,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
  metadata    jsonb DEFAULT '{}'::jsonb,
  -- ---- Add your columns above ----

  -- Timestamps: auto-managed
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Table comment for documentation / Supabase dashboard
COMMENT ON TABLE public.__TABLE_NAME__
  IS 'TODO: Describe what this table stores.';


-- =========================================================================
-- 2. Row Level Security (RLS)
-- =========================================================================

-- Enable RLS — without policies, ALL access is denied by default
ALTER TABLE public.__TABLE_NAME__ ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2a. SELECT policy: users can only read their own rows
-- ---------------------------------------------------------------------------
-- Change USING(true) if you want public read access instead.
CREATE POLICY "Users can view their own __TABLE_NAME__"
  ON public.__TABLE_NAME__
  FOR SELECT
  USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 2b. INSERT policy: users can only create rows they will own
-- ---------------------------------------------------------------------------
CREATE POLICY "Users can create their own __TABLE_NAME__"
  ON public.__TABLE_NAME__
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 2c. UPDATE policy: users can only modify their own rows
-- ---------------------------------------------------------------------------
-- USING = which existing rows can be targeted
-- WITH CHECK = what the row must look like after the update
CREATE POLICY "Users can update their own __TABLE_NAME__"
  ON public.__TABLE_NAME__
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 2d. DELETE policy: users can only delete their own rows
-- ---------------------------------------------------------------------------
CREATE POLICY "Users can delete their own __TABLE_NAME__"
  ON public.__TABLE_NAME__
  FOR DELETE
  USING (auth.uid() = user_id);


-- =========================================================================
-- 3. Indexes
-- =========================================================================

-- Index on user_id: critical for RLS performance (every query filters by user)
CREATE INDEX IF NOT EXISTS idx___TABLE_NAME___user_id
  ON public.__TABLE_NAME__ (user_id);

-- Index on status: speeds up filtered queries (e.g., "show me published items")
CREATE INDEX IF NOT EXISTS idx___TABLE_NAME___status
  ON public.__TABLE_NAME__ (status);

-- Index on created_at: speeds up ORDER BY / pagination queries
CREATE INDEX IF NOT EXISTS idx___TABLE_NAME___created_at
  ON public.__TABLE_NAME__ (created_at DESC);

-- Composite index example: user + status (for "my published items" queries)
-- Uncomment if you frequently query by both:
-- CREATE INDEX IF NOT EXISTS idx___TABLE_NAME___user_status
--   ON public.__TABLE_NAME__ (user_id, status);


-- =========================================================================
-- 4. Updated_at Trigger
-- =========================================================================

-- Reusable trigger function: auto-sets updated_at to now() on any UPDATE.
-- Using CREATE OR REPLACE so this is safe to include in multiple migrations.
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Attach the trigger to this table
DROP TRIGGER IF EXISTS on___TABLE_NAME___updated ON public.__TABLE_NAME__;
CREATE TRIGGER on___TABLE_NAME___updated
  BEFORE UPDATE ON public.__TABLE_NAME__
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();


-- =========================================================================
-- 5. Grants (Optional — Supabase sets these automatically)
-- =========================================================================
-- These grants allow the PostgREST API layer to access the table.
-- Supabase manages these for hosted projects, but self-hosted setups may
-- need them explicitly.

-- GRANT SELECT, INSERT, UPDATE, DELETE ON public.__TABLE_NAME__ TO authenticated;
-- GRANT SELECT ON public.__TABLE_NAME__ TO anon;  -- only if public read needed


-- =========================================================================
-- 6. Seed Data (Optional — for development only)
-- =========================================================================
-- Move seed data to supabase/seed.sql for local development.
-- Example:
--
-- INSERT INTO public.__TABLE_NAME__ (user_id, title, description, status)
-- VALUES
--   ('00000000-0000-0000-0000-000000000000', 'Sample Item', 'A test row', 'draft');
