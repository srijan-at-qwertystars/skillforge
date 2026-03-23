# Review: design-patterns-practical
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5
Issues: Non-standard description format.

Excellent practical design patterns guide with strong "never introduce a pattern without concrete justification" framing. Covers creational (Factory Method/Abstract Factory with factory-vs-constructor/DI guidance, Builder with fluent/step variants, Singleton marked as "usually bad" with DI alternative), structural (Adapter at system boundaries with Stripe example, Decorator with GoF-vs-Python distinction and retry example, Facade with OrderFacade, Proxy with CachingUserRepo), behavioral (Strategy as function parameters, Observer with TypedEmitter, Command with undo/redo/CommandHistory, Chain of Responsibility as validator pipeline, State with FSM transitions dict), modern/functional (Repository with interface/Postgres/InMemory, Result/Option discriminated union in TS and Python, Specification with composable and/or/not), pattern selection guide table mapping problems to patterns, and anti-patterns (pattern for pattern's sake, premature abstraction, speculative generality, singleton abuse, god decorator). Golden rule: "if removing the pattern makes the code simpler and you lose nothing, remove it."
