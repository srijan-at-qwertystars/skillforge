# Review: data-validation-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

Outstanding validation guide with standard description format. Covers validation philosophy (validate at boundaries, fail early, defense in depth), validation layers table (client/gateway/server/domain/database), schema-first approach (JSON Schema 2020-12, OpenAPI, Protocol Buffers), library comparison (Zod/Valibot/ArkType/Yup/TypeBox, Pydantic/marshmallow/attrs, Joi/class-validator with bundle sizes), form validation (progressive enhancement, React Hook Form + Zod), API request validation (Express middleware, NestJS decorator, FastAPI), parse-don't-validate pattern, branded/nominal types, refinement types, error aggregation (safeParse/flatten), sanitization vs validation (XSS/SQLi/encoding), cross-field validation (Zod refine, Pydantic model_validator, discriminatedUnion), async validation, custom validators (composition, factories), and anti-patterns table.
