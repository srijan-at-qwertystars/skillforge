---
name: llm-prompt-engineering
description:
  positive: "Use when user crafts prompts for LLMs, asks about chain-of-thought, few-shot examples, system prompts, structured output (JSON mode), tool/function calling, prompt templates, or prompt optimization techniques."
  negative: "Do NOT use for fine-tuning, RAG pipeline architecture, embedding models, or ML model training."
---

# LLM Prompt Engineering Patterns

## 1. Prompting Fundamentals

Every effective prompt has four components: **Role**, **Instruction**, **Context**, and **Output Format**.

### Structure

```
[ROLE]       Who the model should be
[CONTEXT]    Background the model needs
[INSTRUCTION] What to do — specific, unambiguous
[OUTPUT]     Exact format, length, constraints
```

### Example

```text
System: You are a senior backend engineer reviewing pull requests.

User:
Review this Python function for bugs, security issues, and performance.
Return a JSON array of findings. Each finding must have: severity (critical|warning|info),
line, and description. If no issues, return an empty array.

def get_user(id):
    query = f"SELECT * FROM users WHERE id = {id}"
    return db.execute(query).fetchone()
```

Expected output:
```json
[
  {
    "severity": "critical",
    "line": 2,
    "description": "SQL injection via string interpolation. Use parameterized queries."
  }
]
```

### Rules

- Put the most important instruction first.
- Use delimiters (`"""`, `<xml>`, `---`) to separate data from instructions.
- State what to do, not what to avoid.
- Specify length: "in 2-3 sentences" or "under 100 words."
- Handle edge cases: "If input is empty, return `{}`."

---

## 2. Chain-of-Thought (CoT) and Step-by-Step Reasoning

CoT prompts the model to show intermediate reasoning before answering. Use for math, logic, multi-step analysis, classification with justification.

### Zero-shot CoT

Append a trigger phrase:

```text
User: A store sells apples at $1.50 each. Buy 4, pay with $10. How much change?
Think step by step before giving the final answer.
```

Expected:
```
Step 1: Cost = 4 × $1.50 = $6.00
Step 2: Change = $10.00 − $6.00 = $4.00
Final answer: $4.00
```

### Few-shot CoT

Provide worked examples:

```text
Q: 12 × 15 = ?
A: 12 × 15 = 12 × 10 + 12 × 5 = 120 + 60 = 180.

Q: 23 × 17 = ?
A:
```

### When to use CoT

| Use CoT                          | Skip CoT                    |
|----------------------------------|-----------------------------|
| Multi-step math or logic         | Simple lookups or rewording |
| Classification needing rationale | Translation, summarization  |
| Debugging code                   | Creative writing            |

### Extended thinking (Claude)

Set `thinking` budget for internal scratch-pad reasoning:

```json
{ "model": "claude-sonnet-4-20250514", "max_tokens": 8000,
  "thinking": { "type": "enabled", "budget_tokens": 4000 },
  "messages": [{ "role": "user", "content": "Solve: 287 × 463" }] }
```

---

## 3. Few-Shot Prompting

Provide input→output examples so the model learns format and edge cases by demonstration.

### Best practices

1. **Diverse examples.** Cover typical cases *and* edge cases.
2. **Order matters.** Put the hardest example last (recency bias).
3. **Match format exactly.** Same delimiters, keys, structure in every example.
4. **3-5 examples usually suffice.** Diminishing returns past ~10.
5. **Label clearly.** Use `Input:` / `Output:` consistently.

### Example — sentiment classification

```text
Classify the sentiment as positive, negative, or neutral.

Input: "The battery lasts all day, love it!"
Output: positive

Input: "Broke after two weeks. Waste of money."
Output: negative

Input: "It arrived on Tuesday."
Output: neutral

Input: "Camera is okay but the screen is amazing."
Output:
```

Expected output: `positive`

### Dynamic few-shot

Retrieve examples from a vector store based on similarity to current input. Keeps examples relevant without bloating the prompt.

---

## 4. System Prompts

System prompts set persistent behavior: persona, constraints, output format, and rules.

### Anatomy

```text
You are [PERSONA] that [CORE BEHAVIOR].

## Rules
- Respond in [LANGUAGE/FORMAT].
- If uncertain, say "I don't know" instead of guessing.
- Keep responses under [N] words unless asked to elaborate.

## Output format
Return results as a markdown table with columns: [COL1], [COL2], [COL3].

## Knowledge boundaries
Only answer questions about [DOMAIN]. For anything else:
"That's outside my area. Please ask about [DOMAIN]."
```

### Guidelines

- Put behavioral rules *before* output format.
- Use numbered/bulleted lists for rules, not prose.
- Repeat critical constraints at end of system prompt.
- Test adversarial inputs (prompt injection) and add guardrails.

---

## 5. Structured Output

Force machine-readable responses for downstream parsing.

### JSON mode — request JSON and provide the schema:

```text
Extract entities. Return valid JSON matching this schema:
{"people": [{"name": str, "role": str}], "organizations": [{"name": str, "industry": str}], "dates": [str]}

Text: """Jane Smith, CTO of Acme Corp (fintech), announced the merger on Jan 15, 2025."""
```

Expected output:
```json
{
  "people": [{"name": "Jane Smith", "role": "CTO"}],
  "organizations": [{"name": "Acme Corp", "industry": "fintech"}],
  "dates": ["2025-01-15"]
}
```

### XML tags (Claude-preferred)

```text
<analysis>
  <summary>One-sentence summary</summary>
  <issues><issue severity="critical|warning|info">Description</issue></issues>
  <suggestion>Recommended fix</suggestion>
</analysis>
```

### Schema enforcement (OpenAI)

```python
from pydantic import BaseModel

class Extraction(BaseModel):
    sentiment: str
    confidence: float
    topics: list[str]

response = client.responses.parse(
    model="gpt-4o",
    input=[{"role": "user", "content": "Analyze: 'Great product, fast shipping!'"}],
    text_format=Extraction,
)
result = response.output_parsed  # Guaranteed valid Extraction object
```

### Tips

- Show an example of desired output in the prompt.
- Use `"strict": true` in OpenAI JSON schema mode.
- Validate with Pydantic, Zod, or JSON Schema before using downstream.
- Prefer JSON for nested data, markdown tables for flat data, XML for documents.

---

## 6. Tool / Function Calling Patterns

Tool use lets the model invoke external functions and APIs.

### Flow

```
User message → Model emits tool call → Code executes → Result fed back → Final answer
```

### Tool definition (OpenAI)

```json
{
  "type": "function",
  "function": {
    "name": "get_weather",
    "description": "Get current weather for a city.",
    "parameters": {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "City name" },
        "units": { "type": "string", "enum": ["celsius", "fahrenheit"] }
      },
      "required": ["city"]
    }
  }
}
```

### Tool definition (Claude)

```json
{
  "name": "get_weather",
  "description": "Get current weather for a city.",
  "input_schema": {
    "type": "object",
    "properties": {
      "city": { "type": "string", "description": "City name" },
      "units": { "type": "string", "enum": ["celsius", "fahrenheit"] }
    },
    "required": ["city"]
  }
}
```

### Multi-step tool use

```
1. User: "Book a flight NYC→London next Friday under $500"
2. Model calls: search_flights(origin="NYC", dest="London", date="2025-08-01", max_price=500)
3. Code returns: [{flight_id: "AA100", price: 450, departs: "08:00"}]
4. Model calls: book_flight(flight_id="AA100")
5. Code returns: {confirmation: "ABC123"}
6. Model: "Booked AA100, departing 08:00. Confirmation: ABC123."
```

### Parallel tool calls

When multiple independent data fetches are needed, the model emits several tool calls at once. Process them concurrently and return all results together.

### Best practices

- Write descriptions as if explaining to a new engineer.
- Include parameter descriptions with examples and valid ranges.
- Return errors as structured objects: `{"error": "City not found", "code": 404}`.
- Limit available tools to those relevant to the current task.
- Validate tool call arguments before execution.

---

## 7. Prompt Templates and Variable Injection

Separate prompt logic from data. Prevents injection and enables reuse.

### Template pattern

```python
TEMPLATE = """You are a {role} specializing in {domain}.
Analyze the following {input_type}:
<input>{user_input}</input>
Return JSON with keys: summary, score (1-10), recommendations (list)."""

prompt = TEMPLATE.format(
    role="security auditor", domain="web applications",
    input_type="HTTP access log", user_input=log_data,
)
```

### Rules

- Escape or sanitize `user_input` — never interpolate raw user content into instructions.
- Use XML tags or triple-quotes to delimit injected content.
- Store templates in version control. Treat prompt changes like code changes.

---

## 8. Prompt Chaining and Decomposition

Break complex tasks into a pipeline of simpler prompts.

Use when: task has distinct phases, single prompt is inconsistent, or steps need different models.

### Pattern: sequential chain

```
Step 1 (extract):   "Extract all dates and monetary values from this contract."
Step 2 (normalize): "Convert dates to ISO 8601 and amounts to USD."
Step 3 (validate):  "Check: are all required fields present? Return missing fields."
Step 4 (format):    "Produce final JSON matching this schema: {...}"
```

### Pattern: gate / router

```
Step 1: "Classify this ticket: billing, technical, or general."
Step 2a (billing):   → billing-specialist prompt
Step 2b (technical): → technical-specialist prompt
Step 2c (general):   → general-FAQ prompt
```

### Tips

- Pass structured data (JSON) between steps, not free text.
- Add validation steps between chains.
- Log intermediate outputs for debugging.
- Use cheaper models for classification/routing, powerful models for generation.

---

## 9. Output Parsing and Validation

Never trust raw model output in production.

| Strategy              | Tool / Library         | Use case                     |
|-----------------------|------------------------|------------------------------|
| JSON.parse + schema   | Zod, Pydantic, ajv     | Structured data extraction   |
| Regex extraction      | Native regex           | Pull values from free text   |
| Retry on failure      | Tenacity, custom loop  | Malformed output recovery    |
| Constrained decoding  | Outlines, LMFE         | Guaranteed grammar adherence |

### Retry pattern

```python
for attempt in range(3):
    response = call_llm(prompt)
    try:
        parsed = MySchema.model_validate_json(response)
        break
    except ValidationError as e:
        prompt = f"Your previous output was invalid: {e}. Fix and retry:\n{response}"
else:
    raise RuntimeError("Failed to get valid output after 3 attempts")
```

### Tips

- Include schema in the error-retry prompt.
- Set temperature to 0 for deterministic structured output.
- Use streaming parsers for real-time validation.

---

## 10. Common Failure Modes and Fixes

### Hallucination

| Cause                 | Fix                                                    |
|-----------------------|--------------------------------------------------------|
| No grounding data     | Provide source text; instruct "only use provided info" |
| Vague question        | Make the question specific and bounded                 |
| Over-confident model  | Ask model to rate confidence; add "say I don't know"   |

### Instruction following failures

| Cause                 | Fix                                                    |
|-----------------------|--------------------------------------------------------|
| Prompt too long       | Move instructions to system prompt; trim context       |
| Conflicting rules     | Audit for contradictions; prioritize with numbering    |
| Format drift          | Re-state format requirements in each user turn         |

### Verbosity

| Cause                 | Fix                                                    |
|-----------------------|--------------------------------------------------------|
| No length constraint  | Add "in under N words" or "max 3 bullet points"        |
| Model hedging         | Add "be direct, no disclaimers"                        |
| Preamble filler       | Add "start with the answer directly, no preamble"      |

### Refusal to answer valid queries

- Rephrase to avoid false-positive safety triggers.
- Add context explaining the legitimate use case.

---

## 11. Evaluation and Iteration

### A/B testing

1. Define a test set of 20-50 representative inputs with expected outputs.
2. Run both prompt variants against the test set.
3. Score with automated metrics (exact match, F1) + human review.
4. Track cost and latency alongside quality.

### Scoring rubric

```text
Rate output 1-5 on: Accuracy, Completeness, Format adherence, Conciseness.
```

### Iteration loop

```
1. Write initial prompt → 2. Test on 5 diverse inputs → 3. Identify failure pattern →
4. Add instruction/example for the failure → 5. Retest full set → 6. Repeat until ≥ target
```

### Tips

- Version prompts with git. Diff prompt changes like code.
- Log every prompt+response pair in production.
- Use LLM-as-judge for subjective evaluation.
- Set a quality bar before shipping (e.g., ≥90% on test set).

---

## 12. Provider-Specific Tips

### Claude (Anthropic)

- Use XML tags for structure (`<instructions>`, `<context>`, `<output>`).
- Use `thinking` blocks for complex reasoning without cluttering output.
- Prefill assistant turn to steer format: start with `{` for JSON, `<` for XML.
- Long context (200K tokens) — put large documents in `<document>` tags.
- Use `cache_control` to cache static prompt parts and reduce cost/latency.
- Write detailed tool `description` fields — Claude uses them heavily for routing.

### GPT (OpenAI)

- Use `response_format: { type: "json_schema", ... }` for guaranteed structured output.
- `developer` role sets persistent behavior.
- Supports parallel function calling — batch independent tool definitions.
- `temperature: 0` for deterministic output; `0.7-1.0` for creative tasks.
- Seed parameter enables reproducible outputs for testing.

### Gemini (Google)

- Use `functionDeclarations` with OpenAPI schema for tool calling.
- Supports grounding with Google Search for real-time information.
- Multimodal natively: images, video, audio alongside text.
- Use `responseMimeType: "application/json"` with `responseSchema` for structured output.
- Safety settings configurable per-category.

### Open-source (Llama, Mistral, Qwen)

- Use the model's chat template (check tokenizer config).
- Structured output less reliable — use constrained decoding (Outlines, llama.cpp grammars).
- Few-shot examples more critical than for frontier models.
- Keep prompts shorter — smaller context windows.
- Test with lower temperature (0.1-0.3) for factual tasks.

<!-- tested: pass -->
