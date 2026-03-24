/**
 * React Feature Flag Components — Copy-Paste Ready
 *
 * A complete feature flag toolkit built on the OpenFeature specification.
 * Provides context providers, hooks, declarative gates, and dev tooling
 * for managing feature flags in React applications.
 *
 * @requires react >=18.0.0
 * @requires @openfeature/web-sdk >=1.0.0
 */

import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
  useMemo,
  useRef,
  memo,
  type ReactNode,
  type ComponentType,
  type FC,
} from "react";

import {
  OpenFeature,
  type Client,
  type Provider,
  type EvaluationContext,
  type EvaluationDetails,
  type FlagValue,
  type JsonValue,
  ProviderEvents,
  ErrorCode,
} from "@openfeature/web-sdk";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Possible readiness states of the feature flag provider. */
export type ProviderStatus = "not_ready" | "loading" | "ready" | "error";

/** Bootstrap values allow pre-populating flags for SSR or initial render. */
export type BootstrapValues = Record<string, FlagValue>;

/** Configuration accepted by {@link FeatureFlagProvider}. */
export interface FeatureFlagProviderProps {
  /** An OpenFeature-compatible provider instance (e.g. LaunchDarkly, Flagsmith). */
  provider: Provider;
  /**
   * Optional domain (formerly "client name") scoping flags to a logical area.
   * When omitted the default unnamed client is used.
   */
  domain?: string;
  /** Initial evaluation context (user id, email, plan, etc.). */
  context?: EvaluationContext;
  /** Pre-resolved flag values for SSR / static rendering. */
  bootstrap?: BootstrapValues;
  /** Content rendered while the provider is initialising. */
  loadingComponent?: ReactNode;
  /** Content rendered when provider initialisation fails. */
  errorComponent?: ReactNode;
  children: ReactNode;
}

/** Shape of the value exposed via React context. */
export interface FeatureFlagContextValue {
  /** The OpenFeature client bound to the configured domain. */
  client: Client | null;
  /** Current readiness of the backing provider. */
  status: ProviderStatus;
  /** Error captured during provider initialisation, if any. */
  error: Error | null;
  /** Bootstrap values supplied at mount time. */
  bootstrap: BootstrapValues;
}

/** Return type of the generic {@link useFeatureFlag} hook. */
export interface UseFeatureFlagResult<T extends FlagValue> {
  /** The resolved flag value (or the supplied default while loading). */
  value: T;
  /** `true` while the provider is still initialising. */
  loading: boolean;
  /** Evaluation or provider error, if any. */
  error: Error | null;
  /** OpenFeature resolution reason (e.g. `"TARGETING_MATCH"`). */
  reason: string | undefined;
}

/** Props accepted by the declarative {@link FeatureGate} component. */
export interface FeatureGateProps {
  /** The flag key to evaluate. */
  flagKey: string;
  /** Default value when evaluation fails. Defaults to `false`. */
  defaultValue?: boolean;
  /** Evaluation context override for this gate. */
  context?: EvaluationContext;
  /** Invert the gate — show children when the flag is *off*. */
  negate?: boolean;
  /** Rendered while the provider is loading. */
  loading?: ReactNode;
  /** Rendered when the flag is off (or on, when `negate` is true). */
  fallback?: ReactNode;
  /**
   * Standard children or a render-prop receiving the evaluation details.
   * The render-prop pattern is useful when you need access to the
   * resolved variant string or reason.
   */
  children:
    | ReactNode
    | ((details: UseFeatureFlagResult<boolean>) => ReactNode);
}

/** Props injected by the {@link withFeatureFlag} HOC. */
export interface InjectedFeatureFlagProps<T extends FlagValue = boolean> {
  featureFlag: UseFeatureFlagResult<T>;
}

/** Props for the developer debug panel. */
export interface FeatureFlagDebugPanelProps {
  /** Flag keys to display. When omitted the panel is empty until flags are registered. */
  flagKeys?: string[];
  /** Extra evaluation context passed to every flag in the panel. */
  context?: EvaluationContext;
  /** Whether the panel starts in a collapsed state. Defaults to `true`. */
  defaultCollapsed?: boolean;
  /** Fixed position on screen. Defaults to `"bottom-right"`. */
  position?: "top-left" | "top-right" | "bottom-left" | "bottom-right";
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

const FeatureFlagContext = createContext<FeatureFlagContextValue>({
  client: null,
  status: "not_ready",
  error: null,
  bootstrap: {},
});

// ---------------------------------------------------------------------------
// Error Boundary
// ---------------------------------------------------------------------------

interface FlagErrorBoundaryProps {
  fallback?: ReactNode;
  children: ReactNode;
}

interface FlagErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

/**
 * Catches errors thrown during flag evaluation so a single broken flag
 * doesn't take down the entire component tree.
 */
class FlagErrorBoundary extends React.Component<
  FlagErrorBoundaryProps,
  FlagErrorBoundaryState
> {
  constructor(props: FlagErrorBoundaryProps) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): FlagErrorBoundaryState {
    return { hasError: true, error };
  }

  override componentDidCatch(error: Error, info: React.ErrorInfo): void {
    console.error("[FeatureFlag] Evaluation error caught by boundary:", error, info);
  }

  override render() {
    if (this.state.hasError) {
      return this.props.fallback ?? null;
    }
    return this.props.children;
  }
}

// ---------------------------------------------------------------------------
// Provider Component
// ---------------------------------------------------------------------------

/**
 * Initialises an OpenFeature provider and exposes the resulting client to the
 * component tree via React context.
 *
 * @example
 * ```tsx
 * import { InMemoryProvider } from "@openfeature/web-sdk";
 *
 * <FeatureFlagProvider
 *   provider={new InMemoryProvider({ "new-ui": true })}
 *   context={{ targetingKey: user.id }}
 *   loadingComponent={<Spinner />}
 * >
 *   <App />
 * </FeatureFlagProvider>
 * ```
 */
export const FeatureFlagProvider: FC<FeatureFlagProviderProps> = ({
  provider,
  domain,
  context,
  bootstrap = {},
  loadingComponent,
  errorComponent,
  children,
}) => {
  const [status, setStatus] = useState<ProviderStatus>("loading");
  const [error, setError] = useState<Error | null>(null);
  const [client, setClient] = useState<Client | null>(null);

  // Track the provider instance so we can clean up if it changes.
  const providerRef = useRef<Provider | null>(null);

  // ----- Initialisation & shutdown -----
  useEffect(() => {
    let cancelled = false;

    const init = async () => {
      try {
        setStatus("loading");
        setError(null);

        // Register the provider with OpenFeature.
        if (domain) {
          await OpenFeature.setProviderAndWait(domain, provider);
        } else {
          await OpenFeature.setProviderAndWait(provider);
        }

        if (cancelled) return;

        const featureClient = domain
          ? OpenFeature.getClient(domain)
          : OpenFeature.getClient();

        providerRef.current = provider;
        setClient(featureClient);
        setStatus("ready");
      } catch (err) {
        if (cancelled) return;
        const wrapped =
          err instanceof Error ? err : new Error(String(err));
        setError(wrapped);
        setStatus("error");
        console.error("[FeatureFlagProvider] Initialisation failed:", wrapped);
      }
    };

    init();

    return () => {
      cancelled = true;
      // Best-effort shutdown — providers may or may not support this.
      OpenFeature.close().catch((err) => {
        console.warn("[FeatureFlagProvider] Shutdown error:", err);
      });
    };
  }, [provider, domain]);

  // ----- Propagate evaluation context changes -----
  useEffect(() => {
    if (context) {
      OpenFeature.setContext(context);
    }
  }, [context]);

  // ----- Subscribe to provider lifecycle events -----
  useEffect(() => {
    if (!client) return;

    const handleReady = () => setStatus("ready");
    const handleError = () => setStatus("error");
    const handleStale = () => setStatus("loading");

    client.addHandler(ProviderEvents.Ready, handleReady);
    client.addHandler(ProviderEvents.Error, handleError);
    client.addHandler(ProviderEvents.Stale, handleStale);

    return () => {
      client.removeHandler(ProviderEvents.Ready, handleReady);
      client.removeHandler(ProviderEvents.Error, handleError);
      client.removeHandler(ProviderEvents.Stale, handleStale);
    };
  }, [client]);

  const value = useMemo<FeatureFlagContextValue>(
    () => ({ client, status, error, bootstrap }),
    [client, status, error, bootstrap],
  );

  // ----- Render gates -----
  if (status === "loading" && loadingComponent) {
    return <>{loadingComponent}</>;
  }

  if (status === "error" && errorComponent) {
    return <>{errorComponent}</>;
  }

  return (
    <FeatureFlagContext.Provider value={value}>
      <FlagErrorBoundary>{children}</FlagErrorBoundary>
    </FeatureFlagContext.Provider>
  );
};

FeatureFlagProvider.displayName = "FeatureFlagProvider";

// ---------------------------------------------------------------------------
// Core Hook — useFeatureFlag
// ---------------------------------------------------------------------------

/**
 * Evaluate a feature flag and subscribe to real-time updates.
 *
 * The hook is generic over the flag value type, allowing full type safety:
 *
 * @example
 * ```tsx
 * const { value, loading } = useFeatureFlag<boolean>("dark-mode", false);
 * const { value: limit } = useFeatureFlag<number>("rate-limit", 100);
 * ```
 */
export function useFeatureFlag<T extends FlagValue = boolean>(
  flagKey: string,
  defaultValue: T,
  evalContext?: EvaluationContext,
): UseFeatureFlagResult<T> {
  const { client, status, bootstrap } = useContext(FeatureFlagContext);

  // Seed with bootstrap value when available.
  const bootstrapValue = (bootstrap[flagKey] as T) ?? defaultValue;

  const [value, setValue] = useState<T>(bootstrapValue);
  const [error, setError] = useState<Error | null>(null);
  const [reason, setReason] = useState<string | undefined>(undefined);

  // Stable reference to the most recent evaluation context so the event
  // handler always sees the latest value without re-subscribing.
  const evalContextRef = useRef(evalContext);
  evalContextRef.current = evalContext;

  const evaluate = useCallback(async () => {
    if (!client) return;

    try {
      const ctx = evalContextRef.current;
      let details: EvaluationDetails<FlagValue>;

      // Determine value type and call the appropriate typed method.
      switch (typeof defaultValue) {
        case "boolean":
          details = await client.getBooleanDetails(
            flagKey,
            defaultValue as boolean,
            ctx,
          );
          break;
        case "number":
          details = await client.getNumberDetails(
            flagKey,
            defaultValue as number,
            ctx,
          );
          break;
        case "string":
          details = await client.getStringDetails(
            flagKey,
            defaultValue as string,
            ctx,
          );
          break;
        default:
          details = await client.getObjectDetails(
            flagKey,
            defaultValue as JsonValue,
            ctx,
          );
          break;
      }

      setValue(details.value as T);
      setReason(details.reason);
      setError(
        details.errorCode
          ? new Error(`Flag evaluation error: ${details.errorCode}`)
          : null,
      );
    } catch (err) {
      const wrapped = err instanceof Error ? err : new Error(String(err));
      setError(wrapped);
      setValue(defaultValue);
    }
  }, [client, flagKey, defaultValue]);

  // Evaluate on mount and whenever key dependencies change.
  useEffect(() => {
    if (status === "ready") {
      evaluate();
    }
  }, [evaluate, status, evalContext]);

  // Subscribe to configuration-change events for live flag updates.
  useEffect(() => {
    if (!client) return;

    const handleChange = () => {
      evaluate();
    };

    client.addHandler(ProviderEvents.ConfigurationChanged, handleChange);

    return () => {
      client.removeHandler(ProviderEvents.ConfigurationChanged, handleChange);
    };
  }, [client, evaluate]);

  return useMemo(
    () => ({
      value,
      loading: status === "loading" || status === "not_ready",
      error,
      reason,
    }),
    [value, status, error, reason],
  );
}

// ---------------------------------------------------------------------------
// Typed Convenience Hooks
// ---------------------------------------------------------------------------

/**
 * Evaluate a boolean feature flag.
 *
 * @example
 * ```tsx
 * const { value: enabled } = useBooleanFlag("new-checkout", false);
 * ```
 */
export function useBooleanFlag(
  flagKey: string,
  defaultValue: boolean = false,
  context?: EvaluationContext,
): UseFeatureFlagResult<boolean> {
  return useFeatureFlag<boolean>(flagKey, defaultValue, context);
}

/**
 * Evaluate a string feature flag (useful for A/B variant keys).
 *
 * @example
 * ```tsx
 * const { value: variant } = useStringFlag("hero-copy", "control");
 * ```
 */
export function useStringFlag(
  flagKey: string,
  defaultValue: string = "",
  context?: EvaluationContext,
): UseFeatureFlagResult<string> {
  return useFeatureFlag<string>(flagKey, defaultValue, context);
}

/**
 * Evaluate a numeric feature flag (useful for thresholds, limits, rollout %).
 *
 * @example
 * ```tsx
 * const { value: maxItems } = useNumberFlag("cart-limit", 10);
 * ```
 */
export function useNumberFlag(
  flagKey: string,
  defaultValue: number = 0,
  context?: EvaluationContext,
): UseFeatureFlagResult<number> {
  return useFeatureFlag<number>(flagKey, defaultValue, context);
}

// ---------------------------------------------------------------------------
// Declarative Gate Component
// ---------------------------------------------------------------------------

/**
 * Conditionally render children based on a boolean feature flag.
 *
 * Supports a standard children pattern, render-props for accessing evaluation
 * details, `negate` for inverse gating, and dedicated `loading` / `fallback`
 * slots.
 *
 * @example
 * ```tsx
 * // Simple gate
 * <FeatureGate flagKey="new-dashboard">
 *   <NewDashboard />
 * </FeatureGate>
 *
 * // With fallback + loading
 * <FeatureGate
 *   flagKey="new-dashboard"
 *   fallback={<LegacyDashboard />}
 *   loading={<Skeleton />}
 * >
 *   <NewDashboard />
 * </FeatureGate>
 *
 * // Render-prop for variant access
 * <FeatureGate flagKey="new-dashboard">
 *   {({ value, reason }) => (
 *     <NewDashboard reason={reason} />
 *   )}
 * </FeatureGate>
 *
 * // Negated gate — show children when flag is OFF
 * <FeatureGate flagKey="kill-switch" negate>
 *   <NormalExperience />
 * </FeatureGate>
 * ```
 */
export const FeatureGate: FC<FeatureGateProps> = memo(
  ({
    flagKey,
    defaultValue = false,
    context,
    negate = false,
    loading: loadingSlot,
    fallback = null,
    children,
  }) => {
    const result = useFeatureFlag<boolean>(flagKey, defaultValue, context);

    if (result.loading && loadingSlot) {
      return <>{loadingSlot}</>;
    }

    const isEnabled = negate ? !result.value : result.value;

    if (!isEnabled) {
      return <>{fallback}</>;
    }

    if (typeof children === "function") {
      return <>{children(result)}</>;
    }

    return <>{children}</>;
  },
);

FeatureGate.displayName = "FeatureGate";

// ---------------------------------------------------------------------------
// Higher-Order Component — withFeatureFlag
// ---------------------------------------------------------------------------

/**
 * HOC that injects a `featureFlag` prop into the wrapped component.
 * Primarily intended for class components that cannot use hooks directly.
 *
 * @example
 * ```tsx
 * interface DashboardProps extends InjectedFeatureFlagProps {}
 *
 * class Dashboard extends React.Component<DashboardProps> {
 *   render() {
 *     const { value, loading } = this.props.featureFlag;
 *     if (loading) return <Spinner />;
 *     return value ? <NewDashboard /> : <LegacyDashboard />;
 *   }
 * }
 *
 * export default withFeatureFlag("new-dashboard", false)(Dashboard);
 * ```
 */
export function withFeatureFlag<
  T extends FlagValue = boolean,
  P extends InjectedFeatureFlagProps<T> = InjectedFeatureFlagProps<T>,
>(flagKey: string, defaultValue: T, evalContext?: EvaluationContext) {
  return function wrapper(
    WrappedComponent: ComponentType<P>,
  ): ComponentType<Omit<P, keyof InjectedFeatureFlagProps<T>>> {
    const WithFeatureFlag: FC<Omit<P, keyof InjectedFeatureFlagProps<T>>> = (
      props,
    ) => {
      const featureFlag = useFeatureFlag<T>(flagKey, defaultValue, evalContext);

      return (
        <WrappedComponent
          {...(props as unknown as P)}
          featureFlag={featureFlag}
        />
      );
    };

    WithFeatureFlag.displayName = `withFeatureFlag(${
      WrappedComponent.displayName || WrappedComponent.name || "Component"
    })`;

    return WithFeatureFlag;
  };
}

// ---------------------------------------------------------------------------
// Dev-Only Debug Panel
// ---------------------------------------------------------------------------

const PANEL_POSITIONS = {
  "top-left": { top: 8, left: 8 } as const,
  "top-right": { top: 8, right: 8 } as const,
  "bottom-left": { bottom: 8, left: 8 } as const,
  "bottom-right": { bottom: 8, right: 8 } as const,
} as const;

interface DebugFlagRow {
  key: string;
  value: FlagValue;
  reason: string | undefined;
  error: Error | null;
}

/**
 * A development-only overlay that shows the current state of all specified
 * flags. Automatically excluded from production builds when guarded behind
 * `process.env.NODE_ENV !== "production"`.
 *
 * @example
 * ```tsx
 * {process.env.NODE_ENV !== "production" && (
 *   <FeatureFlagDebugPanel
 *     flagKeys={["dark-mode", "new-checkout", "rate-limit"]}
 *     position="bottom-right"
 *   />
 * )}
 * ```
 */
export const FeatureFlagDebugPanel: FC<FeatureFlagDebugPanelProps> = memo(
  ({
    flagKeys = [],
    context,
    defaultCollapsed = true,
    position = "bottom-right",
  }) => {
    const { client, status } = useContext(FeatureFlagContext);
    const [collapsed, setCollapsed] = useState(defaultCollapsed);
    const [rows, setRows] = useState<DebugFlagRow[]>([]);

    // Re-evaluate all supplied keys whenever the provider is ready or flags change.
    const evaluateAll = useCallback(async () => {
      if (!client || flagKeys.length === 0) {
        setRows([]);
        return;
      }

      const results: DebugFlagRow[] = await Promise.all(
        flagKeys.map(async (key) => {
          try {
            // Attempt boolean first; fall back to string for non-boolean flags.
            const details = await client.getBooleanDetails(key, false, context);

            if (details.errorCode === ErrorCode.TYPE_MISMATCH) {
              const strDetails = await client.getStringDetails(key, "", context);
              return {
                key,
                value: strDetails.value,
                reason: strDetails.reason,
                error: strDetails.errorCode
                  ? new Error(strDetails.errorCode)
                  : null,
              };
            }

            return {
              key,
              value: details.value,
              reason: details.reason,
              error: details.errorCode ? new Error(details.errorCode) : null,
            };
          } catch (err) {
            return {
              key,
              value: "⚠ error",
              reason: undefined,
              error: err instanceof Error ? err : new Error(String(err)),
            };
          }
        }),
      );

      setRows(results);
    }, [client, flagKeys, context]);

    useEffect(() => {
      if (status === "ready") {
        evaluateAll();
      }
    }, [status, evaluateAll]);

    // Subscribe to live changes.
    useEffect(() => {
      if (!client) return;
      const handler = () => evaluateAll();
      client.addHandler(ProviderEvents.ConfigurationChanged, handler);
      return () => {
        client.removeHandler(ProviderEvents.ConfigurationChanged, handler);
      };
    }, [client, evaluateAll]);

    // Do not render anything in production.
    if (typeof process !== "undefined" && process.env?.NODE_ENV === "production") {
      return null;
    }

    const positionStyles = PANEL_POSITIONS[position];

    return (
      <div
        style={{
          position: "fixed",
          ...positionStyles,
          zIndex: 99999,
          fontFamily: "ui-monospace, monospace",
          fontSize: 12,
          background: "#1a1a2e",
          color: "#e0e0e0",
          borderRadius: 8,
          boxShadow: "0 4px 24px rgba(0,0,0,0.4)",
          maxWidth: 420,
          minWidth: collapsed ? 0 : 300,
          overflow: "hidden",
          transition: "min-width 0.2s ease",
        }}
      >
        {/* Header */}
        <button
          onClick={() => setCollapsed((c) => !c)}
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            width: "100%",
            padding: "8px 12px",
            background: "#16213e",
            color: "#e94560",
            border: "none",
            cursor: "pointer",
            fontFamily: "inherit",
            fontSize: 12,
            fontWeight: 700,
            letterSpacing: "0.05em",
          }}
        >
          <span>⚑ Feature Flags</span>
          <span style={{ fontSize: 10, opacity: 0.7 }}>
            {collapsed ? "▸" : "▾"} {status}
          </span>
        </button>

        {/* Body */}
        {!collapsed && (
          <div style={{ padding: "4px 0", maxHeight: 360, overflowY: "auto" }}>
            {rows.length === 0 && (
              <div style={{ padding: "8px 12px", opacity: 0.5 }}>
                No flags registered
              </div>
            )}
            {rows.map((row) => (
              <div
                key={row.key}
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  alignItems: "center",
                  padding: "4px 12px",
                  borderBottom: "1px solid rgba(255,255,255,0.05)",
                }}
              >
                <span
                  style={{
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                    maxWidth: 180,
                  }}
                  title={row.key}
                >
                  {row.key}
                </span>
                <span
                  style={{
                    fontWeight: 600,
                    color:
                      row.value === true
                        ? "#0ead69"
                        : row.value === false
                          ? "#e94560"
                          : "#f4a261",
                  }}
                  title={row.reason ?? ""}
                >
                  {String(row.value)}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    );
  },
);

FeatureFlagDebugPanel.displayName = "FeatureFlagDebugPanel";

// ---------------------------------------------------------------------------
// Usage Examples
// ---------------------------------------------------------------------------

/*
 * ═══════════════════════════════════════════════════════════════════════════
 *  USAGE EXAMPLES
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * 1. PROVIDER SETUP
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { FeatureFlagProvider } from "./react-feature-flag";
 *   import { LaunchDarklyProvider } from "@launchdarkly/openfeature-web";
 *
 *   function App() {
 *     const ldProvider = new LaunchDarklyProvider("sdk-key-xxx");
 *
 *     return (
 *       <FeatureFlagProvider
 *         provider={ldProvider}
 *         context={{ targetingKey: currentUser.id, email: currentUser.email }}
 *         loadingComponent={<FullPageSpinner />}
 *         errorComponent={<ErrorBanner message="Flags unavailable" />}
 *         bootstrap={{ "dark-mode": false, "new-checkout": true }}
 *       >
 *         <Router />
 *       </FeatureFlagProvider>
 *     );
 *   }
 *
 *
 * 2. BOOLEAN FLAG HOOK
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { useBooleanFlag } from "./react-feature-flag";
 *
 *   function Sidebar() {
 *     const { value: showNewNav, loading } = useBooleanFlag("new-nav", false);
 *
 *     if (loading) return <NavSkeleton />;
 *     return showNewNav ? <NewNav /> : <LegacyNav />;
 *   }
 *
 *
 * 3. STRING / VARIANT FLAG
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { useStringFlag } from "./react-feature-flag";
 *
 *   function HeroBanner() {
 *     const { value: variant } = useStringFlag("hero-experiment", "control");
 *
 *     switch (variant) {
 *       case "short-copy":  return <ShortHero />;
 *       case "video":       return <VideoHero />;
 *       default:            return <DefaultHero />;
 *     }
 *   }
 *
 *
 * 4. NUMERIC FLAG
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { useNumberFlag } from "./react-feature-flag";
 *
 *   function ProductGrid() {
 *     const { value: pageSize } = useNumberFlag("grid-page-size", 20);
 *     return <Grid items={products} pageSize={pageSize} />;
 *   }
 *
 *
 * 5. DECLARATIVE GATE
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { FeatureGate } from "./react-feature-flag";
 *
 *   // Basic gate with fallback
 *   <FeatureGate
 *     flagKey="redesigned-checkout"
 *     fallback={<LegacyCheckout />}
 *     loading={<CheckoutSkeleton />}
 *   >
 *     <NewCheckout />
 *   </FeatureGate>
 *
 *   // Render-prop for accessing evaluation details
 *   <FeatureGate flagKey="redesigned-checkout">
 *     {({ value, reason }) => (
 *       <Checkout variant={value ? "new" : "legacy"} debugReason={reason} />
 *     )}
 *   </FeatureGate>
 *
 *   // Negated gate — render only when flag is OFF
 *   <FeatureGate flagKey="maintenance-mode" negate>
 *     <NormalApp />
 *   </FeatureGate>
 *
 *
 * 6. HOC FOR CLASS COMPONENTS
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { withFeatureFlag, InjectedFeatureFlagProps } from "./react-feature-flag";
 *
 *   interface Props extends InjectedFeatureFlagProps<boolean> {
 *     userName: string;
 *   }
 *
 *   class ProfilePage extends React.Component<Props> {
 *     render() {
 *       const { value: showBeta } = this.props.featureFlag;
 *       return showBeta ? <BetaProfile /> : <StableProfile />;
 *     }
 *   }
 *
 *   export default withFeatureFlag<boolean, Props>("beta-profile", false)(ProfilePage);
 *
 *
 * 7. SSR BOOTSTRAP
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   // In your server handler (e.g. Next.js getServerSideProps):
 *   const bootstrapFlags = await evaluateFlagsOnServer(userId);
 *   // => { "dark-mode": true, "new-checkout": false }
 *
 *   // Pass to the provider — flags render immediately, no flash:
 *   <FeatureFlagProvider
 *     provider={clientSideProvider}
 *     bootstrap={bootstrapFlags}
 *   >
 *     <App />
 *   </FeatureFlagProvider>
 *
 *
 * 8. DEBUG PANEL (development only)
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   import { FeatureFlagDebugPanel } from "./react-feature-flag";
 *
 *   function AppShell({ children }) {
 *     return (
 *       <>
 *         {children}
 *         {process.env.NODE_ENV !== "production" && (
 *           <FeatureFlagDebugPanel
 *             flagKeys={["dark-mode", "new-checkout", "hero-experiment", "grid-page-size"]}
 *             position="bottom-right"
 *             defaultCollapsed
 *           />
 *         )}
 *       </>
 *     );
 *   }
 *
 *
 * 9. EVALUATION CONTEXT OVERRIDE (per-component)
 * ─────────────────────────────────────────────────────────────────────────
 *
 *   // Override the global context for a specific flag evaluation:
 *   const { value } = useBooleanFlag("premium-feature", false, {
 *     targetingKey: teamId,
 *     plan: "enterprise",
 *   });
 *
 */
