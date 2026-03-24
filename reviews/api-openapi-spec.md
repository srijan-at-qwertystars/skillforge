# Review: openapi-spec

Accuracy: 5/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:
- `assets/pagination-schemas.yaml` exists but is not documented in the SKILL.md Assets section (line 496–499 list only `openapi-template.yaml` and `error-response.yaml`)
- Line 392 formatting bug: code fence ` ```yaml ` is on the same line as the heading text (`**Paginated list (offset):**```yaml`); should be on a new line
- Description could add `NOT for AsyncAPI event-driven specs` as a negative trigger to avoid confusion with the webhooks coverage
- All key technical claims verified correct: OpenAPI 3.1 webhooks, nullable via type arrays, license `identifier` field (3.1 only), `spectral lint`, `openapi-generator-cli generate -i -g -o` flags, RFC 7807 error format, Prism mock server usage
- Scripts are well-structured with proper argument parsing, error handling, and auto-install
- Reference docs are thorough (advanced patterns, troubleshooting, field reference)
- Examples are syntactically correct and would be directly usable
