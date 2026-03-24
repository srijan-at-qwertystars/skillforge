# Review: keycloak-auth

Accuracy: 4/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **Management port 9000 not documented in SKILL.md body** — KC 25+ moves health/metrics to a dedicated management interface on port 9000 by default. The docker-compose.yml correctly uses port 9000 in its healthcheck, but SKILL.md §Monitoring says endpoints are `/health/live`, `/health/ready` without noting they are on port 9000, not 8080. Users following the SKILL.md text alone will get 404s.

2. **`bearerOnly` deprecated** — `realm-export.json` uses `"bearerOnly": true` on the API backend client (line 229). This attribute is deprecated in KC 25+ Quarkus distribution. Resource servers should instead simply not enable any grant flows. Functional but misleading for new deployments.

3. **`defaultRoles` format outdated** — `realm-export.json` uses `"defaultRoles": ["user"]` (line 108). KC 13+ replaced this with `"defaultRole"` object format. Import may still work via backward compat, but the template should use the modern format.

4. **Java 17 nuance** — SKILL.md line 69 comment says "Java 17 deprecated in KC 25+" which is accurate, but the phrasing "Requires Java 21" is slightly misleading since KC 25 still *runs* on Java 17 (deprecated ≠ removed). Should say "Java 21 recommended; Java 17 deprecated."

5. **`KC_PROXY` → `KC_PROXY_HEADERS` transition not noted** — SKILL.md correctly uses `KC_PROXY_HEADERS=xforwarded` but doesn't mention the old `KC_PROXY` env var is removed. Users migrating from older KC versions will hit this.

## Structure Assessment
- ✅ YAML frontmatter: name + description present
- ✅ Positive triggers: SSO, OAuth2/OIDC, realms/clients/users, SAML, LDAP, SPIs, etc.
- ✅ Negative triggers: Auth0, Okta, AWS Cognito, Firebase Auth, general OAuth2/OIDC
- ✅ Body: 499 lines (under 500 limit)
- ✅ Imperative voice throughout
- ✅ Examples with input/output: bash commands, Java/JS/YAML code, Docker configs
- ✅ References linked: 3 reference docs, 3 scripts, 3 asset templates all present and valid
- ✅ Scripts well-documented with usage headers, error handling, env var configs

## Content Verification (web-searched)
- ✅ Java 21 default / Java 17 deprecated — confirmed via KC 25 release notes
- ✅ Argon2 default password hashing (non-FIPS) — confirmed
- ✅ KC_PROXY_HEADERS=xforwarded — confirmed
- ✅ persistent-user-sessions preview feature — confirmed
- ✅ Organizations feature (KC 25+) — confirmed
- ✅ Legacy adapters removed (KC 24+) — confirmed
- ✅ keycloak-js PKCE S256 config — confirmed
- ✅ Spring Boot native OAuth2 (no KC adapter) — confirmed
- ✅ Admin API endpoints and paths — confirmed
- ✅ Health endpoints on port 9000 — confirmed (docker-compose is correct)

## Trigger Assessment
- Strong keyword coverage for real Keycloak queries
- Clear negative boundaries prevent Auth0/Okta/Cognito false positives
- Low false-trigger risk
- Would activate correctly for: "set up Keycloak SSO", "Keycloak Docker", "Keycloak LDAP integration", "Keycloak custom SPI", "Keycloak token exchange"
