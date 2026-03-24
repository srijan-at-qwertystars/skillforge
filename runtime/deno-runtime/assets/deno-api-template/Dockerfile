# ── Stage 1: Cache dependencies ──
FROM denoland/deno:latest AS deps

WORKDIR /app
COPY deno.json deno.lock* ./
RUN deno install

# ── Stage 2: Build (type-check and cache all modules) ──
FROM denoland/deno:latest AS build

WORKDIR /app
COPY --from=deps /root/.cache/deno /root/.cache/deno
COPY . .
RUN deno check main.ts
RUN deno cache main.ts

# ── Stage 3: Runtime ──
FROM denoland/deno:latest

WORKDIR /app

# Copy cached deps and source
COPY --from=build /root/.cache/deno /root/.cache/deno
COPY --from=build /app .

# Run as non-root
USER deno

EXPOSE 8000

# Use minimal permissions
CMD ["run", "--allow-net=0.0.0.0:8000", "--allow-env=PORT", "--allow-read=.", "--cached-only", "main.ts"]
