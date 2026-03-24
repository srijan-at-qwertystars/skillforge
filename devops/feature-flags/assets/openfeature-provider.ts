/**
 * Custom OpenFeature Provider — In-Memory Feature Flag Provider
 *
 * A complete, production-style OpenFeature provider with an in-memory flag store,
 * targeting rules engine, percentage rollouts, and provider lifecycle events.
 *
 * @module InMemoryFeatureFlagProvider
 * @see https://openfeature.dev/docs/reference/concepts/provider
 */

import type {
  EvaluationContext,
  Hook,
  JsonValue,
  Logger,
  Provider,
  ProviderMetadata,
  ResolutionDetails,
  ServerProviderEvents,
} from "@openfeature/server-sdk";

import {
  ErrorCode,
  OpenFeatureEventEmitter,
  ProviderEvents,
  StandardResolutionReasons,
} from "@openfeature/server-sdk";

// ─── Types & Interfaces ──────────────────────────────────────────────────────

/** Supported flag value types. */
export type FlagValueType = boolean | string | number | JsonValue;

/** A single variant definition within a flag. */
export interface FlagVariant<T extends FlagValueType = FlagValueType> {
  /** The concrete value returned when this variant is selected. */
  value: T;
}

/** Operators available for attribute-based targeting rules. */
export type TargetingOperator = "equals" | "in";

/** A single targeting rule evaluated against the EvaluationContext. */
export interface TargetingRule {
  /** Lower numbers evaluate first. Rules are stable-sorted by priority. */
  priority: number;

  /** The variant key to return when this rule matches. */
  variant: string;

  /**
   * Match when the evaluation context's targeting key is one of these values.
   * Takes precedence over `attribute` matching within the same rule.
   */
  targetingKeys?: string[];

  /** Attribute-based condition (ignored when `targetingKeys` matches). */
  attribute?: {
    /** Dot-path into `EvaluationContext.attributes` (e.g. `"plan"` or `"geo.country"`). */
    key: string;
    /** Comparison operator. */
    operator: TargetingOperator;
    /** Value(s) to compare against. For `"in"`, supply an array. */
    value: JsonValue;
  };

  /**
   * Percentage rollout (0–100). When set, the rule only matches if the hash
   * of the targeting key falls within this percentage. Evaluated *after*
   * `targetingKeys` / `attribute` checks pass (or if neither is specified).
   */
  percentage?: number;
}

/** Complete configuration for a single feature flag. */
export interface FlagConfiguration<T extends FlagValueType = FlagValueType> {
  /** Whether the flag is active. Disabled flags always return the default. */
  enabled: boolean;
  /** Map of variant key → variant definition. */
  variants: Record<string, FlagVariant<T>>;
  /** Key into `variants` used when no targeting rule matches. */
  defaultVariant: string;
  /** Ordered targeting rules. Evaluated from lowest to highest priority. */
  targetingRules?: TargetingRule[];
}

/** A complete flag store: flag key → flag configuration. */
export type FlagStore = Record<string, FlagConfiguration>;

/** Options accepted by the provider constructor. */
export interface InMemoryProviderOptions {
  /** Initial set of flags to load on construction. */
  flags?: FlagStore;
  /** Optional logger (falls back to `console`). */
  logger?: Logger;
  /**
   * Duration in milliseconds after which flag data is considered stale
   * if no updates have been received. Set to `0` to disable. Default: `0`.
   */
  staleDurationMs?: number;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Deterministic hash of a string to a number in [0, 1).
 * Uses FNV-1a for speed and reasonable distribution — not cryptographic.
 */
function hashToPercentage(input: string): number {
  let hash = 0x811c9dc5; // FNV offset basis
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193); // FNV prime
  }
  return ((hash >>> 0) % 10_000) / 100; // 0.00 – 99.99
}

/**
 * Read a nested attribute from the evaluation context using a dot-delimited key.
 *
 * @example
 * resolveAttribute({ geo: { country: "US" } }, "geo.country"); // "US"
 */
function resolveAttribute(
  attributes: Record<string, JsonValue> | undefined,
  path: string,
): JsonValue | undefined {
  if (!attributes) return undefined;
  const segments = path.split(".");
  let current: JsonValue | undefined = attributes;
  for (const segment of segments) {
    if (current === null || current === undefined || typeof current !== "object" || Array.isArray(current)) {
      return undefined;
    }
    current = (current as Record<string, JsonValue>)[segment];
  }
  return current;
}

// ─── Provider Implementation ─────────────────────────────────────────────────

/**
 * An in-memory OpenFeature provider with targeting rules and lifecycle events.
 *
 * @example
 * ```ts
 * const provider = new InMemoryFeatureFlagProvider({
 *   flags: { "dark-mode": { enabled: true, variants: { on: { value: true }, off: { value: false } }, defaultVariant: "off" } },
 * });
 * OpenFeature.setProvider(provider);
 * ```
 */
export class InMemoryFeatureFlagProvider implements Provider {
  public readonly metadata: ProviderMetadata = {
    name: "in-memory-feature-flag-provider",
  };

  /** Hook attachment point required by the Provider interface. */
  public hooks: Hook[] = [];

  /** Event emitter surfaced to the OpenFeature SDK. */
  public readonly events = new OpenFeatureEventEmitter();

  private readonly flags: Map<string, FlagConfiguration> = new Map();
  private readonly logger: Logger;
  private readonly staleDurationMs: number;
  private staleTimer: ReturnType<typeof setTimeout> | null = null;
  private lastUpdateTimestamp: number = Date.now();

  constructor(options: InMemoryProviderOptions = {}) {
    this.logger = options.logger ?? (console as unknown as Logger);
    this.staleDurationMs = options.staleDurationMs ?? 0;

    if (options.flags) {
      for (const [key, config] of Object.entries(options.flags)) {
        this.flags.set(key, structuredClone(config));
      }
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /** Called by the SDK when this provider is registered. */
  async initialize(): Promise<void> {
    try {
      this.logger.info?.("InMemoryFeatureFlagProvider initializing…");
      this.resetStaleTimer();
      this.emitEvent(ProviderEvents.Ready);
      this.logger.info?.("InMemoryFeatureFlagProvider ready.");
    } catch (error) {
      this.emitEvent(ProviderEvents.Error, {
        message: `Initialization failed: ${String(error)}`,
      });
      throw error;
    }
  }

  /** Called by the SDK when this provider is replaced or the SDK shuts down. */
  async onClose(): Promise<void> {
    this.logger.info?.("InMemoryFeatureFlagProvider shutting down…");
    this.clearStaleTimer();
    this.flags.clear();
  }

  // ── Flag CRUD (thread-safe via synchronous Map operations) ───────────────

  /**
   * Replace the entire flag store atomically and notify listeners.
   *
   * @param flags - New flag definitions. The existing store is cleared first.
   */
  public putFlags(flags: FlagStore): void {
    this.flags.clear();
    for (const [key, config] of Object.entries(flags)) {
      this.flags.set(key, structuredClone(config));
    }
    this.onFlagsChanged();
  }

  /**
   * Add or update a single flag. Existing flags with the same key are overwritten.
   *
   * @param key    - Flag key.
   * @param config - Full flag configuration.
   */
  public putFlag(key: string, config: FlagConfiguration): void {
    this.flags.set(key, structuredClone(config));
    this.onFlagsChanged();
  }

  /**
   * Remove a flag from the store.
   *
   * @param key - Flag key to delete.
   * @returns `true` if the flag existed and was removed.
   */
  public deleteFlag(key: string): boolean {
    const deleted = this.flags.delete(key);
    if (deleted) this.onFlagsChanged();
    return deleted;
  }

  // ── Resolution Methods ──────────────────────────────────────────────────

  /** Resolve a boolean flag. */
  async resolveBooleanEvaluation(
    flagKey: string,
    defaultValue: boolean,
    context: EvaluationContext,
    logger: Logger,
  ): Promise<ResolutionDetails<boolean>> {
    return this.resolve<boolean>(flagKey, defaultValue, context, "boolean");
  }

  /** Resolve a string flag. */
  async resolveStringEvaluation(
    flagKey: string,
    defaultValue: string,
    context: EvaluationContext,
    logger: Logger,
  ): Promise<ResolutionDetails<string>> {
    return this.resolve<string>(flagKey, defaultValue, context, "string");
  }

  /** Resolve a number flag. */
  async resolveNumberEvaluation(
    flagKey: string,
    defaultValue: number,
    context: EvaluationContext,
    logger: Logger,
  ): Promise<ResolutionDetails<number>> {
    return this.resolve<number>(flagKey, defaultValue, context, "number");
  }

  /** Resolve a JSON/object flag. */
  async resolveObjectEvaluation<T extends JsonValue>(
    flagKey: string,
    defaultValue: T,
    context: EvaluationContext,
    logger: Logger,
  ): Promise<ResolutionDetails<T>> {
    return this.resolve<T>(flagKey, defaultValue, context, "object");
  }

  // ── Core Resolution Engine ──────────────────────────────────────────────

  /**
   * Central resolution logic shared by all typed evaluation methods.
   *
   * Resolution order:
   * 1. Flag existence check.
   * 2. Enabled check — disabled flags short-circuit to the default variant.
   * 3. Targeting rules are evaluated in priority order; first match wins.
   * 4. If no rule matches, the flag's `defaultVariant` is used.
   * 5. Type validation on the resolved value.
   */
  private resolve<T extends FlagValueType>(
    flagKey: string,
    defaultValue: T,
    context: EvaluationContext,
    expectedType: string,
  ): ResolutionDetails<T> {
    const config = this.flags.get(flagKey);

    if (!config) {
      this.logger.debug?.(`Flag "${flagKey}" not found, returning default.`);
      return {
        value: defaultValue,
        reason: StandardResolutionReasons.DEFAULT,
        errorCode: ErrorCode.FLAG_NOT_FOUND,
        errorMessage: `Flag "${flagKey}" not found in the store.`,
      };
    }

    // Disabled flags always return the default variant without evaluating rules.
    if (!config.enabled) {
      const variant = config.variants[config.defaultVariant];
      if (!variant) {
        return {
          value: defaultValue,
          reason: StandardResolutionReasons.ERROR,
          errorCode: ErrorCode.PARSE_ERROR,
          errorMessage: `Default variant "${config.defaultVariant}" missing for disabled flag "${flagKey}".`,
        };
      }
      return {
        value: variant.value as T,
        variant: config.defaultVariant,
        reason: StandardResolutionReasons.DISABLED,
      };
    }

    // Evaluate targeting rules (sorted by priority, ascending).
    const matchedVariantKey = this.evaluateTargetingRules(config, context);

    const selectedVariantKey = matchedVariantKey ?? config.defaultVariant;
    const reason = matchedVariantKey
      ? StandardResolutionReasons.TARGETING_MATCH
      : StandardResolutionReasons.DEFAULT;

    const selectedVariant = config.variants[selectedVariantKey];
    if (!selectedVariant) {
      return {
        value: defaultValue,
        reason: StandardResolutionReasons.ERROR,
        errorCode: ErrorCode.PARSE_ERROR,
        errorMessage: `Variant "${selectedVariantKey}" not found in flag "${flagKey}".`,
      };
    }

    // Type guard: make sure the stored value matches the expected type.
    if (!this.isExpectedType(selectedVariant.value, expectedType)) {
      return {
        value: defaultValue,
        reason: StandardResolutionReasons.ERROR,
        errorCode: ErrorCode.TYPE_MISMATCH,
        errorMessage: `Flag "${flagKey}" variant "${selectedVariantKey}" has type "${typeof selectedVariant.value}", expected "${expectedType}".`,
      };
    }

    return {
      value: selectedVariant.value as T,
      variant: selectedVariantKey,
      reason,
    };
  }

  // ── Targeting Rules Engine ──────────────────────────────────────────────

  /**
   * Evaluate targeting rules for a flag configuration against the given context.
   *
   * @returns The variant key of the first matching rule, or `undefined` if none match.
   */
  private evaluateTargetingRules(
    config: FlagConfiguration,
    context: EvaluationContext,
  ): string | undefined {
    if (!config.targetingRules || config.targetingRules.length === 0) {
      return undefined;
    }

    const sortedRules = [...config.targetingRules].sort(
      (a, b) => a.priority - b.priority,
    );

    for (const rule of sortedRules) {
      if (this.evaluateRule(rule, context)) {
        return rule.variant;
      }
    }

    return undefined;
  }

  /**
   * Evaluate a single targeting rule.
   *
   * Matching logic:
   * 1. If `targetingKeys` is specified, the context's targeting key must be in the list.
   * 2. If `attribute` is specified, the referenced attribute must satisfy the operator.
   * 3. If `percentage` is specified, a hash of the targeting key must fall within range.
   * 4. Steps are ANDed together: all specified conditions must pass.
   */
  private evaluateRule(rule: TargetingRule, context: EvaluationContext): boolean {
    const targetingKey = context.targetingKey;

    // ── Targeting key match ──
    if (rule.targetingKeys) {
      if (!targetingKey || !rule.targetingKeys.includes(targetingKey)) {
        return false;
      }
    }

    // ── Attribute match ──
    if (rule.attribute) {
      const actual = resolveAttribute(
        context as unknown as Record<string, JsonValue>,
        rule.attribute.key,
      );

      if (actual === undefined) return false;

      switch (rule.attribute.operator) {
        case "equals":
          if (!this.deepEquals(actual, rule.attribute.value)) return false;
          break;

        case "in":
          if (!Array.isArray(rule.attribute.value)) return false;
          if (!rule.attribute.value.some((v) => this.deepEquals(actual, v))) return false;
          break;

        default:
          this.logger.warn?.(
            `Unknown targeting operator "${rule.attribute.operator}", rule skipped.`,
          );
          return false;
      }
    }

    // ── Percentage rollout ──
    if (rule.percentage !== undefined) {
      if (!targetingKey) return false;
      const bucket = hashToPercentage(targetingKey);
      if (bucket >= rule.percentage) return false;
    }

    return true;
  }

  // ── Internals ───────────────────────────────────────────────────────────

  /** Emit a provider event with optional details. */
  private emitEvent(
    event: ProviderEvents,
    details?: Record<string, unknown>,
  ): void {
    (this.events as OpenFeatureEventEmitter).emit(event, details);
  }

  /** Notify the SDK that flags changed and reset the stale timer. */
  private onFlagsChanged(): void {
    this.lastUpdateTimestamp = Date.now();
    this.resetStaleTimer();
    this.emitEvent(ProviderEvents.ConfigurationChanged, {
      flagsChanged: [...this.flags.keys()],
    });
    this.logger.debug?.("Flag configuration updated.");
  }

  /** Start (or restart) the stale-data timer. */
  private resetStaleTimer(): void {
    this.clearStaleTimer();
    if (this.staleDurationMs <= 0) return;

    this.staleTimer = setTimeout(() => {
      this.logger.warn?.(
        `No flag updates for ${this.staleDurationMs}ms — marking provider stale.`,
      );
      this.emitEvent(ProviderEvents.Stale, {
        lastUpdate: this.lastUpdateTimestamp,
      });
    }, this.staleDurationMs);

    // Allow the process to exit even if the timer is pending.
    if (typeof this.staleTimer === "object" && this.staleTimer !== null && "unref" in this.staleTimer) {
      (this.staleTimer as ReturnType<typeof setTimeout> & { unref(): void }).unref();
    }
  }

  /** Clear any running stale timer. */
  private clearStaleTimer(): void {
    if (this.staleTimer !== null) {
      clearTimeout(this.staleTimer);
      this.staleTimer = null;
    }
  }

  /** Runtime type check for resolved flag values. */
  private isExpectedType(value: FlagValueType, expected: string): boolean {
    switch (expected) {
      case "boolean":
        return typeof value === "boolean";
      case "string":
        return typeof value === "string";
      case "number":
        return typeof value === "number";
      case "object":
        return typeof value === "object" && value !== null;
      default:
        return false;
    }
  }

  /** Structural equality check for JSON-compatible values. */
  private deepEquals(a: JsonValue, b: JsonValue): boolean {
    if (a === b) return true;
    if (a === null || b === null) return false;
    if (typeof a !== typeof b) return false;
    if (typeof a !== "object") return false;

    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) return false;
      return a.every((val, i) => this.deepEquals(val, b[i]));
    }

    if (Array.isArray(a) !== Array.isArray(b)) return false;

    const aObj = a as Record<string, JsonValue>;
    const bObj = b as Record<string, JsonValue>;
    const keys = Object.keys(aObj);
    if (keys.length !== Object.keys(bObj).length) return false;
    return keys.every((k) => this.deepEquals(aObj[k], bObj[k]));
  }
}

// ─── Usage Example ───────────────────────────────────────────────────────────
//
// import { OpenFeature } from "@openfeature/server-sdk";
// import { InMemoryFeatureFlagProvider } from "./openfeature-provider";
//
// // 1. Define your flags
// const flags = {
//   "new-checkout-flow": {
//     enabled: true,
//     variants: {
//       on:  { value: true },
//       off: { value: false },
//     },
//     defaultVariant: "off",
//     targetingRules: [
//       // Rule 1: Always on for internal testers
//       {
//         priority: 1,
//         variant: "on",
//         targetingKeys: ["user-42", "user-99"],
//       },
//       // Rule 2: On for enterprise customers
//       {
//         priority: 2,
//         variant: "on",
//         attribute: {
//           key: "plan",
//           operator: "equals" as const,
//           value: "enterprise",
//         },
//       },
//       // Rule 3: Gradual rollout — 25 % of remaining users
//       {
//         priority: 3,
//         variant: "on",
//         percentage: 25,
//       },
//     ],
//   },
//
//   "banner-text": {
//     enabled: true,
//     variants: {
//       default:  { value: "Welcome!" },
//       holiday:  { value: "Happy Holidays! 🎄" },
//       sale:     { value: "Summer Sale — 20 % off!" },
//     },
//     defaultVariant: "default",
//     targetingRules: [
//       {
//         priority: 1,
//         variant: "holiday",
//         attribute: {
//           key: "region",
//           operator: "in" as const,
//           value: ["US", "CA", "GB"],
//         },
//       },
//     ],
//   },
//
//   "max-items-per-page": {
//     enabled: true,
//     variants: {
//       low:    { value: 10 },
//       medium: { value: 25 },
//       high:   { value: 50 },
//     },
//     defaultVariant: "medium",
//   },
//
//   "dashboard-layout": {
//     enabled: true,
//     variants: {
//       v1: { value: { columns: 2, showSidebar: true,  theme: "light" } },
//       v2: { value: { columns: 3, showSidebar: false, theme: "dark"  } },
//     },
//     defaultVariant: "v1",
//   },
// };
//
// // 2. Create and register the provider
// const provider = new InMemoryFeatureFlagProvider({
//   flags,
//   staleDurationMs: 60_000, // emit STALE after 60 s without updates
// });
//
// OpenFeature.setProvider(provider);
//
// // 3. Get a client and evaluate flags
// const client = OpenFeature.getClient();
//
// const showNewCheckout = await client.getBooleanValue(
//   "new-checkout-flow",
//   false,
//   { targetingKey: "user-42", plan: "free" },
// );
// console.log("New checkout flow:", showNewCheckout); // true (targeting key match)
//
// const banner = await client.getStringValue(
//   "banner-text",
//   "Welcome!",
//   { targetingKey: "user-1", region: "US" },
// );
// console.log("Banner:", banner); // "Happy Holidays! 🎄"
//
// const pageSize = await client.getNumberValue(
//   "max-items-per-page",
//   25,
//   { targetingKey: "user-1" },
// );
// console.log("Page size:", pageSize); // 25
//
// const layout = await client.getObjectValue(
//   "dashboard-layout",
//   { columns: 2, showSidebar: true, theme: "light" },
//   { targetingKey: "user-1" },
// );
// console.log("Layout:", layout); // { columns: 2, showSidebar: true, theme: "light" }
//
// // 4. Update flags at runtime
// provider.putFlag("new-checkout-flow", {
//   enabled: true,
//   variants: { on: { value: true }, off: { value: false } },
//   defaultVariant: "on", // now on for everyone
// });
//
// // 5. Listen for provider events
// OpenFeature.addHandler(ProviderEvents.ConfigurationChanged, (details) => {
//   console.log("Flags changed:", details?.flagsChanged);
// });
