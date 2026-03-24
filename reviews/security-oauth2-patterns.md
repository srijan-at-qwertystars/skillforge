# QA Review: security/oauth2-patterns

**Reviewed**: 2025-07-15
**Skill path**: `~/skillforge/security/oauth2-patterns/`
**Verdict**: **PASS** (with noted issues)

---

## Scores

| Dimension      | Score | Notes |
|----------------|-------|-------|
| Accuracy       | 4 / 5 | All RFC numbers verified correct (7662, 8693, 9126, 9396, 9449). OAuth 2.1 claims match spec. Deducted for deprecated AzureADProvider in NextAuth template and not noting OAuth 2.1 is still an IETF draft. |
| Completeness   | 5 / 5 | Exceptionally thorough. Covers all grant types, PKCE, OIDC, token storage, 7 providers, troubleshooting, advanced patterns (DPoP, PAR, RAR, CIBA, token exchange), and 3 production-ready code templates. |
| Actionability  | 5 / 5 | Working code in JS/TS/Python/Bash/Java-YAML. Two utility scripts. Three TypeScript asset templates with mutex-based refresh, JWKS caching, scope middleware. Copy-paste ready. |
| Trigger quality| 4 / 5 | Good positive triggers (OAuth 2.0/2.1, PKCE, OIDC, social login, token exchange). Negative triggers properly exclude API keys, basic auth, sessions-only, JWT-only, SAML. Could add "SSO"/"single sign-on" to positive triggers. |
| **Overall**    | **4.5 / 5** | |

---

## A. Structure Check

| Criterion | Status | Detail |
|-----------|--------|--------|
| YAML frontmatter `name` | ✅ | `oauth2-patterns` |
| YAML frontmatter `description` | ✅ | Comprehensive, includes grant types, PKCE, OIDC, providers |
| Positive triggers | ✅ | 12+ trigger phrases in `Use when:` |
| Negative triggers | ✅ | 5 exclusions in `Do NOT use when:` |
| SKILL.md body < 500 lines | ✅ | 382 lines |
| Imperative voice | ✅ | Consistent throughout ("Use for:", "Generate…", "Implement…", "Never use…") |
| Code examples | ✅ | JS, Python, YAML, HTTP, shell — all grant types covered |
| Resources linked | ✅ | 3 references, 2 scripts, 3 assets — all linked from tables in SKILL.md |

---

## B. Content Verification

### RFC References — All Verified ✅

| Cited RFC | Title | Correct? |
|-----------|-------|----------|
| RFC 7662 | OAuth 2.0 Token Introspection | ✅ |
| RFC 8693 | OAuth 2.0 Token Exchange | ✅ |
| RFC 9126 | Pushed Authorization Requests (PAR) | ✅ |
| RFC 9396 | Rich Authorization Requests (RAR) | ✅ |
| RFC 9449 | DPoP — Demonstrating Proof of Possession | ✅ |

### Key Claims Verified

- ✅ OAuth 2.1 removes implicit grant and ROPC — confirmed
- ✅ OAuth 2.1 mandates PKCE for all clients — confirmed
- ✅ PKCE code_verifier: 43-128 chars — matches RFC 7636
- ✅ Google requires `access_type=offline` + `prompt=consent` for refresh tokens — confirmed
- ✅ GitHub has no OIDC discovery, no standard refresh tokens — confirmed
- ✅ Microsoft requires `offline_access` scope for refresh tokens — confirmed
- ✅ DPoP uses `Authorization: DPoP` scheme (not Bearer) — confirmed per RFC 9449

### Issues Found

1. **`AzureADProvider` is deprecated** (assets/nextauth-config.ts, line 49)
   - `next-auth/providers/azure-ad` is deprecated since mid-2024.
   - Should import `MicrosoftEntraIDProvider` from `next-auth/providers/microsoft-entra-id`.
   - The `AzureADProvider` may not accept `tenantId` in recent NextAuth v5+ versions.

2. **OAuth 2.1 draft status not mentioned** (SKILL.md, line 19-30)
   - OAuth 2.1 is still an IETF draft (`draft-ietf-oauth-v2-1-15`), not yet a published RFC.
   - The skill presents it as though it's finalized. Should add a brief note that it's a draft but widely adopted.

3. **PKCE + GitHub incompatibility not flagged** (scripts/test-oauth-flow.sh)
   - The test script always sends PKCE parameters, but provider-guide.md notes GitHub doesn't support PKCE.
   - GitHub will ignore PKCE params (not fail), but this should be documented in the script header.

4. **Missing positive trigger: "SSO" / "single sign-on"**
   - Users searching for SSO implementation often need OAuth/OIDC patterns.
   - Consider adding to the `Use when:` triggers.

### Missing Gotchas (Minor)

- No mention of OAuth 2.0 for Browser-Based Apps (draft-ietf-oauth-browser-based-apps) which is the canonical BFF guidance.
- No coverage of GNAP (Grant Negotiation and Authorization Protocol) as a future-looking alternative, though this is arguably out of scope.

---

## C. Trigger Analysis

### Would the description trigger correctly?

**Yes** — the description is well-structured with explicit `Use when:` and `Do NOT use when:` sections. It covers the most common search terms developers would use (OAuth, PKCE, OIDC, social login, access tokens, refresh tokens, token exchange).

### False trigger risks

| Scenario | Risk | Verdict |
|----------|------|---------|
| "Implement JWT validation" (no OAuth context) | Low | Correctly excluded by "JWT-only auth without OAuth flows" negative trigger |
| "Implement SAML SSO" | None | Explicitly excluded |
| "Social login with Firebase" | Medium | Would trigger — Firebase Auth uses OAuth under the hood, so this is appropriate |
| "API key authentication" | None | Explicitly excluded |
| "Implement SSO for enterprise" | Medium | May NOT trigger — "SSO" is not in the positive trigger list |

### Recommendations

- Add "SSO", "single sign-on", "enterprise authentication" to positive triggers
- Add "Firebase Auth" to negative triggers if Firebase has its own skill

---

## D. File Inventory

| File | Lines | Status |
|------|-------|--------|
| SKILL.md | 382 | ✅ Good |
| references/advanced-patterns.md | 654 | ✅ Comprehensive |
| references/troubleshooting.md | 509 | ✅ Practical |
| references/provider-guide.md | 337 | ✅ 7 providers covered |
| scripts/generate-pkce.sh | 65 | ✅ Correct PKCE generation |
| scripts/test-oauth-flow.sh | 289 | ⚠️ Works but no PKCE/GitHub note |
| assets/oauth-middleware.ts | 383 | ✅ Production-quality |
| assets/oauth-client.ts | 441 | ✅ Well-structured with mutex |
| assets/nextauth-config.ts | 367 | ⚠️ Uses deprecated AzureADProvider |

---

## E. Issues Summary

| # | Severity | Description | File |
|---|----------|-------------|------|
| 1 | **Medium** | `AzureADProvider` is deprecated; use `MicrosoftEntraIDProvider` | assets/nextauth-config.ts |
| 2 | **Low** | OAuth 2.1 is still an IETF draft — add a note | SKILL.md |
| 3 | **Low** | Test script uses PKCE with all providers; GitHub ignores it silently | scripts/test-oauth-flow.sh |
| 4 | **Low** | Missing "SSO"/"single sign-on" in positive triggers | SKILL.md frontmatter |

---

## F. GitHub Issues

No issues filed. Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

---

## Result

**Status**: ✅ PASS
**Review path**: `~/skillforge/reviews/security-oauth2-patterns.md`
