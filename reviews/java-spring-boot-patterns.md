# QA Review: spring-boot-patterns

**Skill path:** `java/spring-boot-patterns/SKILL.md`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter | ✅ Pass | `name` and `description` present with positive and negative triggers |
| Positive triggers | ✅ Pass | 20+ Spring-specific annotations/concepts: `@RestController`, `@SpringBootApplication`, `SecurityFilterChain`, `@ConfigurationProperties`, `@WebMvcTest`, etc. |
| Negative triggers | ✅ Pass | Explicitly excludes Micronaut, Quarkus, Jakarta EE without Spring, general Java, Spring 4.x/XML |
| Line count | ✅ Pass | 499 lines (limit: 500) |
| Voice | ✅ Pass | Imperative/instructional ("Generate projects via CLI", "Use `SecurityFilterChain` beans", "Enable with `@EnableCaching`") |
| Code examples | ✅ Pass | 18 code blocks with realistic, copy-paste-ready examples; input/output pairs shown for REST and error handling |
| References linked | ✅ Pass | 3 reference files (advanced-patterns 796L, troubleshooting 714L, security-deep-dive 1034L) — all exist |
| Scripts linked | ✅ Pass | 3 scripts (spring-init.sh, check-dependencies.sh, native-build.sh) — all exist and are `chmod +x` |
| Assets linked | ✅ Pass | 5 asset files (application-template.yml, docker-compose, GH Actions, test patterns, security config) — all exist |

## B. Content Check (verified via web search)

### Verified Accurate ✅
- **Spring Security 6.x migration**: `WebSecurityConfigurerAdapter` removed, `requestMatchers()` replaces `antMatchers()`, Lambda DSL standard, `@EnableMethodSecurity` replaces `@EnableGlobalMethodSecurity` — all confirmed correct
- **`@MockitoBean` / `@MockitoSpyBean`**: Correctly noted as Boot 3.4+ replacements for `@MockBean` / `@SpyBean` — confirmed via Spring Framework 6.2 docs
- **Virtual threads**: `spring.threads.virtual.enabled: true` in Boot 3.2+ — confirmed correct; auto-configures Tomcat, async executors, scheduling
- **`@ServiceConnection` Testcontainers**: Correctly noted as Boot 3.1+ feature replacing `@DynamicPropertySource`
- **GraalVM native image patterns**: AOT processing, `@RegisterReflectionForBinding`, `RuntimeHintsRegistrar` — all correct
- **`@ConfigurationProperties` with records**: Correct Boot 3.x pattern

### Issues Found ⚠️

1. **ProblemDetail default misleading** (minor): Section says "RFC 7807 `ProblemDetail` (Boot 3.x default)" which implies it's enabled by default. In reality, `spring.mvc.problemdetails.enabled` defaults to **false** — users must opt in. The skill does mention `spring.mvc.problemdetails.enabled=true` at the end, but the section heading is misleading.

2. **`@CreatedDate` without `@EnableJpaAuditing`** (moderate): The `User` entity uses `@CreatedDate` but never mentions that `@EnableJpaAuditing` must be added to a `@Configuration` class for this to work. This is a common gotcha that will silently produce `null` timestamps.

3. **Boot version pinned to 3.4.1** (minor): Latest is 3.4.13. Not a correctness issue since this shows patterns, but could cause confusion with `bootVersion=3.4.1` in the Initializr curl command.

### Missing Topics (moderate gaps)

4. **`@Transactional` gotchas**: The quick reference table mentions it, but there's no section covering common pitfalls: proxy-based AOP (self-invocation bypass), only works on `public` methods, checked exception handling, read-only optimization.

5. **`RestClient` (Boot 3.2+)**: The new synchronous HTTP client replacing `RestTemplate` is not mentioned. This is a significant Boot 3.2+ addition.

6. **Structured logging (Boot 3.4)**: Not covered in main skill. May be in references.

## C. Trigger Check

| Scenario | Would Trigger? | Correct? |
|---|---|---|
| "Add a Spring Boot REST controller" | ✅ Yes | ✅ Correct |
| "Configure Spring Security JWT" | ✅ Yes | ✅ Correct |
| "Spring Data JPA repository query" | ✅ Yes | ✅ Correct |
| "Micronaut HTTP endpoint" | ❌ No | ✅ Correct (negative trigger) |
| "Quarkus REST API" | ❌ No | ✅ Correct (negative trigger) |
| "Java generics tutorial" | ❌ No | ✅ Correct (negative trigger) |
| "Spring WebFlux reactive endpoint" | ⚠️ Maybe | ⚠️ Ambiguous — not in positive triggers, but references cover it |
| "Spring Boot RestClient usage" | ⚠️ Maybe | ⚠️ `RestClient` not in triggers, but "Spring Boot" would match |
| "Spring XML bean configuration" | ❌ No | ✅ Correct (negative trigger excludes legacy XML) |

**Trigger assessment**: Strong positive/negative differentiation. Minor gap for reactive/WebFlux-specific queries, but acceptable since those could warrant a separate skill.

## D. Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 / 5 | Content verified correct against current docs. Minor: ProblemDetail "default" wording misleading; `@CreatedDate` missing `@EnableJpaAuditing` prerequisite. |
| **Completeness** | 4 / 5 | Covers core Boot 3.x patterns thoroughly. References fill advanced gaps well. Missing `RestClient`, `@Transactional` gotchas. |
| **Actionability** | 5 / 5 | Excellent. Code examples are copy-paste ready, input/output pairs shown, scripts and templates provided for CI/CD, security, and Docker. |
| **Trigger Quality** | 4 / 5 | Comprehensive positive triggers with 20+ Spring-specific terms. Explicit negative triggers for competing frameworks. Minor gap for reactive patterns. |
| **Overall** | **4.25 / 5** | **PASS** |

## E. Recommendations

1. **Fix**: Clarify ProblemDetail section — change "(Boot 3.x default)" to "(Boot 3.x, opt-in)" or similar
2. **Fix**: Add `@EnableJpaAuditing` note near the `@CreatedDate` entity example
3. **Add**: Brief `@Transactional` gotchas section (proxy bypass, self-invocation, visibility)
4. **Add**: `RestClient` as a modern alternative to `RestTemplate` (Boot 3.2+)
5. **Consider**: Add `RestClient` to trigger keywords

## F. Issue Filing

No GitHub issues required. Overall score 4.25 ≥ 4.0, no dimension ≤ 2.

## G. Verdict

**PASS** — High-quality skill with accurate, actionable Spring Boot 3.x patterns. Minor improvements recommended but not blocking.
