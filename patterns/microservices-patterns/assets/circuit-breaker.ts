/**
 * Circuit Breaker with Sliding Window
 *
 * Prevents cascading failures by monitoring downstream call failure rates
 * over a sliding time window. Opens the circuit when failures exceed a
 * threshold, providing fallback responses and allowing recovery probes.
 *
 * Usage:
 *   const breaker = new CircuitBreaker("payment-service", {
 *     failureThreshold: 0.5,   // 50% failure rate
 *     windowSizeMs: 10_000,    // 10-second sliding window
 *     openDurationMs: 30_000,  // 30 seconds before half-open probe
 *     halfOpenMaxCalls: 3,     // 3 probe calls in half-open state
 *   });
 *   const result = await breaker.call(() => fetch("/api/payments"), () => cachedResponse);
 */

// --- Types ---

type CircuitState = "CLOSED" | "OPEN" | "HALF_OPEN";

interface CircuitBreakerOptions {
  /** Failure rate threshold (0.0–1.0) to trip the circuit. Default: 0.5 */
  failureThreshold?: number;
  /** Sliding window duration in ms. Default: 10000 */
  windowSizeMs?: number;
  /** How long the circuit stays open before probing. Default: 30000 */
  openDurationMs?: number;
  /** Number of probe calls allowed in half-open state. Default: 3 */
  halfOpenMaxCalls?: number;
  /** Minimum number of calls in window before evaluating threshold. Default: 5 */
  minimumCalls?: number;
  /** Called on state transitions. */
  onStateChange?: (from: CircuitState, to: CircuitState, name: string) => void;
}

interface CallRecord {
  timestamp: number;
  success: boolean;
  durationMs: number;
}

interface CircuitBreakerMetrics {
  state: CircuitState;
  totalCalls: number;
  successCount: number;
  failureCount: number;
  failureRate: number;
  lastFailureTime?: number;
  avgResponseTimeMs: number;
}

// --- Implementation ---

class CircuitBreaker {
  private state: CircuitState = "CLOSED";
  private records: CallRecord[] = [];
  private openedAt = 0;
  private halfOpenCalls = 0;
  private halfOpenSuccesses = 0;
  private totalCalls = 0;

  private readonly failureThreshold: number;
  private readonly windowSizeMs: number;
  private readonly openDurationMs: number;
  private readonly halfOpenMaxCalls: number;
  private readonly minimumCalls: number;
  private readonly onStateChange?: (from: CircuitState, to: CircuitState, name: string) => void;

  constructor(
    private readonly name: string,
    options: CircuitBreakerOptions = {}
  ) {
    this.failureThreshold = options.failureThreshold ?? 0.5;
    this.windowSizeMs = options.windowSizeMs ?? 10_000;
    this.openDurationMs = options.openDurationMs ?? 30_000;
    this.halfOpenMaxCalls = options.halfOpenMaxCalls ?? 3;
    this.minimumCalls = options.minimumCalls ?? 5;
    this.onStateChange = options.onStateChange;
  }

  /**
   * Execute a call through the circuit breaker.
   * @param fn The async function to execute (your downstream call)
   * @param fallback Optional fallback when circuit is open
   * @returns The result of fn or fallback
   */
  async call<T>(fn: () => Promise<T>, fallback?: () => T | Promise<T>): Promise<T> {
    this.totalCalls++;

    // Check state transitions
    if (this.state === "OPEN") {
      if (Date.now() - this.openedAt >= this.openDurationMs) {
        this.transitionTo("HALF_OPEN");
      } else {
        // Circuit is open — fail fast
        if (fallback) return fallback();
        throw new CircuitOpenError(this.name, this.remainingOpenTimeMs());
      }
    }

    if (this.state === "HALF_OPEN" && this.halfOpenCalls >= this.halfOpenMaxCalls) {
      // Max probe calls reached, still waiting for results
      if (fallback) return fallback();
      throw new CircuitOpenError(this.name, 0);
    }

    // Execute the call
    const startTime = Date.now();
    try {
      if (this.state === "HALF_OPEN") this.halfOpenCalls++;

      const result = await fn();
      this.recordSuccess(Date.now() - startTime);
      return result;
    } catch (error) {
      this.recordFailure(Date.now() - startTime);
      throw error;
    }
  }

  /** Get current metrics snapshot. */
  getMetrics(): CircuitBreakerMetrics {
    this.pruneWindow();
    const windowRecords = this.records;
    const successes = windowRecords.filter((r) => r.success).length;
    const failures = windowRecords.filter((r) => !r.success).length;
    const total = windowRecords.length;
    const failureRecord = windowRecords.filter((r) => !r.success).pop();
    const avgDuration = total > 0
      ? windowRecords.reduce((sum, r) => sum + r.durationMs, 0) / total
      : 0;

    return {
      state: this.state,
      totalCalls: this.totalCalls,
      successCount: successes,
      failureCount: failures,
      failureRate: total > 0 ? failures / total : 0,
      lastFailureTime: failureRecord?.timestamp,
      avgResponseTimeMs: Math.round(avgDuration),
    };
  }

  /** Force the circuit to a specific state (for testing or manual override). */
  forceState(state: CircuitState): void {
    this.transitionTo(state);
    if (state === "CLOSED") this.reset();
  }

  // --- Internal ---

  private recordSuccess(durationMs: number): void {
    this.records.push({ timestamp: Date.now(), success: true, durationMs });
    this.pruneWindow();

    if (this.state === "HALF_OPEN") {
      this.halfOpenSuccesses++;
      if (this.halfOpenSuccesses >= this.halfOpenMaxCalls) {
        // All probe calls succeeded — close circuit
        this.transitionTo("CLOSED");
        this.reset();
      }
    }
  }

  private recordFailure(durationMs: number): void {
    this.records.push({ timestamp: Date.now(), success: false, durationMs });
    this.pruneWindow();

    if (this.state === "HALF_OPEN") {
      // Any failure in half-open reopens the circuit
      this.transitionTo("OPEN");
      this.openedAt = Date.now();
      this.halfOpenCalls = 0;
      this.halfOpenSuccesses = 0;
      return;
    }

    // Check if we should trip the circuit
    if (this.state === "CLOSED") {
      const total = this.records.length;
      if (total >= this.minimumCalls) {
        const failures = this.records.filter((r) => !r.success).length;
        if (failures / total >= this.failureThreshold) {
          this.transitionTo("OPEN");
          this.openedAt = Date.now();
        }
      }
    }
  }

  private pruneWindow(): void {
    const cutoff = Date.now() - this.windowSizeMs;
    this.records = this.records.filter((r) => r.timestamp > cutoff);
  }

  private transitionTo(newState: CircuitState): void {
    if (this.state !== newState) {
      const oldState = this.state;
      this.state = newState;
      this.onStateChange?.(oldState, newState, this.name);
    }
  }

  private reset(): void {
    this.records = [];
    this.halfOpenCalls = 0;
    this.halfOpenSuccesses = 0;
  }

  private remainingOpenTimeMs(): number {
    return Math.max(0, this.openDurationMs - (Date.now() - this.openedAt));
  }
}

// --- Error Types ---

class CircuitOpenError extends Error {
  constructor(
    public readonly serviceName: string,
    public readonly retryAfterMs: number
  ) {
    super(`Circuit breaker OPEN for "${serviceName}". Retry after ${retryAfterMs}ms.`);
    this.name = "CircuitOpenError";
  }
}

// --- Example Usage ---

async function exampleUsage() {
  const breaker = new CircuitBreaker("payment-service", {
    failureThreshold: 0.5,
    windowSizeMs: 10_000,
    openDurationMs: 30_000,
    halfOpenMaxCalls: 3,
    minimumCalls: 5,
    onStateChange: (from, to, name) => {
      console.log(`[circuit-breaker] ${name}: ${from} → ${to}`);
    },
  });

  // Wrap downstream calls
  try {
    const result = await breaker.call(
      async () => {
        const res = await fetch("http://payment-service:8082/api/payments", {
          method: "POST",
          body: JSON.stringify({ orderId: "ord-123", amount: 99.99 }),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      },
      // Fallback when circuit is open
      () => ({ status: "PENDING", message: "Payment service temporarily unavailable" })
    );
    console.log("Payment result:", result);
  } catch (error) {
    if (error instanceof CircuitOpenError) {
      console.log(`Circuit open, retry after ${error.retryAfterMs}ms`);
    }
    throw error;
  }

  // Check metrics
  console.log("Metrics:", breaker.getMetrics());
}

export { CircuitBreaker, CircuitBreakerOptions, CircuitState, CircuitBreakerMetrics, CircuitOpenError };
