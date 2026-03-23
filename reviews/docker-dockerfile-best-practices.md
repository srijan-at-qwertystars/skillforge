# Review: dockerfile-best-practices

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:
- Line 332: States heredocs require "dockerfile:1.4+" but the feature originated in `1.3-labs`. The examples correctly use `# syntax=docker/dockerfile:1` (recommended stable channel), so this is a minor parenthetical error that won't cause real problems.
- Missing coverage of multi-platform builds (`docker buildx build --platform`), which is increasingly important for production workflows.
- No explicit mention of `ADD` vs `COPY` preference (though all examples correctly use COPY throughout).
