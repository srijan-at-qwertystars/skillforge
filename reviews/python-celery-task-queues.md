# Review: celery-task-queues

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **advanced-patterns.md line 712–715: Incorrect `state()` constructor usage**
   ```python
   from celery.states import state, STARTED
   PROGRESS = state("PROGRESS", STARTED)  # treated as "in progress"
   ```
   `celery.states.state` is a `str` subclass and does not accept a second positional argument for precedence. This will raise a `TypeError`. Custom states don't need registration — just pass any string to `update_state()`. The `state` class is only used for comparison ordering. Fix: remove the second argument or delete this section; the custom state examples earlier in the file are already correct.

2. **SKILL.md line 259–265: Misleading chain+group composition example**
   ```python
   workflow = chain(
       fetch_user_ids.s(),
       group(process_user.s(uid) for uid in range(100)),
       summarize_results.s(),
   )
   ```
   This constructs the group statically at definition time with `range(100)`, not dynamically from `fetch_user_ids`'s result. An AI might interpret this as dynamic fan-out. The advanced-patterns.md "Dynamic fan-out" section handles this correctly — consider either removing this example from SKILL.md or adding a comment clarifying it's static.

3. **Docker Compose `version: "3.8"` in assets/docker-compose.yml and scripts**
   Docker Compose V2 ignores the `version` key entirely (deprecated since 2023). Harmless but could confuse users into thinking it matters. Minor.

4. **Missing pitfall in SKILL.md: Redis visibility timeout with `task_acks_late`**
   The troubleshooting.md covers this (visibility_timeout defaults to 1 hour; long tasks get redelivered), but the main SKILL.md "Common Pitfalls" table omits it. This is a frequent production footgun with Redis broker. Consider adding a row.

## Structure check
- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (Celery imports, async task queues, background jobs, periodic tasks, canvas workflows, retry strategies, broker setup, framework integration, deployment) AND negative triggers (asyncio without Celery, RQ/Dramatiq/Huey/ARQ, pure pub/sub, Kafka/RabbitMQ without Celery)
- ✅ Body is 467 lines (under 500)
- ✅ Imperative voice, no filler
- ✅ Examples with input/output throughout
- ✅ references/, scripts/, assets/ properly linked from SKILL.md

## Content verification (web-searched)
- ✅ Config names correct: lowercase `broker_url`, `task_serializer`, `result_serializer`, `accept_content` (Celery 5.x convention)
- ✅ Canvas API (chain, group, chord, starmap, .s(), .si()) matches official Celery 5.6 docs
- ✅ `crontab(hour=9, minute=0, day_of_week=1)` parameter names correct
- ✅ `broker_connection_retry_on_startup` correctly noted as Celery 5.3+
- ✅ `link_error` callback signature `(request, exc, traceback)` is correct for Celery 5.x
- ✅ `celery amqp queue.purge` still valid in Celery 5.x CLI
- ✅ Django namespace convention (`CELERY_BROKER_URL` in settings.py) correctly distinguished from standalone (`broker_url`)
- ✅ `@shared_task` vs `@app.task` guidance is correct

## Trigger check
- Description is specific and well-scoped. Positive triggers cover the right surface area (imports, concepts, frameworks, deployment).
- Negative triggers correctly exclude competing task queues and non-Celery message patterns.
- Low false-positive risk. Phrase "async task queues" has slight ambiguity with generic asyncio but the negative trigger clause handles this.

## Verdict: PASS
All facts, commands, and API names verified against Celery 5.6 documentation. Minor issues are in reference files (not the main SKILL.md) and don't block an AI from executing correctly. The skill is comprehensive, well-structured, and production-ready.
