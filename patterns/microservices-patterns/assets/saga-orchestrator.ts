/**
 * Saga Orchestrator with Compensation
 *
 * A generic, type-safe saga orchestrator that coordinates distributed transactions
 * across microservices. Supports forward execution with automatic compensation
 * on failure, persistent state tracking, and retry logic.
 *
 * Usage:
 *   const saga = new SagaOrchestrator<OrderContext>("order-fulfillment");
 *   saga
 *     .step("create-order", createOrder, cancelOrder)
 *     .step("charge-payment", chargePayment, refundPayment)
 *     .step("reserve-inventory", reserveInventory, releaseInventory)
 *     .step("schedule-shipping", scheduleShipping, cancelShipping);
 *   const result = await saga.execute({ orderId: "ord-123", amount: 99.99 });
 */

// --- Types ---

interface SagaStep<TContext> {
  name: string;
  execute: (ctx: TContext) => Promise<TContext>;
  compensate: (ctx: TContext) => Promise<void>;
}

type SagaStatus = "pending" | "running" | "completed" | "compensating" | "failed" | "compensated";

interface SagaState<TContext> {
  sagaId: string;
  sagaName: string;
  status: SagaStatus;
  currentStep: number;
  completedSteps: string[];
  context: TContext;
  error?: string;
  startedAt: Date;
  completedAt?: Date;
}

interface SagaResult<TContext> {
  success: boolean;
  sagaId: string;
  context: TContext;
  error?: string;
  completedSteps: string[];
  compensatedSteps: string[];
}

interface SagaStore {
  save(state: SagaState<unknown>): Promise<void>;
  load(sagaId: string): Promise<SagaState<unknown> | null>;
}

interface SagaLogger {
  info(message: string, meta?: Record<string, unknown>): void;
  error(message: string, meta?: Record<string, unknown>): void;
  warn(message: string, meta?: Record<string, unknown>): void;
}

// --- Default implementations ---

class InMemorySagaStore implements SagaStore {
  private store = new Map<string, SagaState<unknown>>();

  async save(state: SagaState<unknown>): Promise<void> {
    this.store.set(state.sagaId, structuredClone(state));
  }

  async load(sagaId: string): Promise<SagaState<unknown> | null> {
    const state = this.store.get(sagaId);
    return state ? structuredClone(state) : null;
  }
}

const consoleLogger: SagaLogger = {
  info: (msg, meta) => console.log(`[saga] ${msg}`, meta ?? ""),
  error: (msg, meta) => console.error(`[saga] ${msg}`, meta ?? ""),
  warn: (msg, meta) => console.warn(`[saga] ${msg}`, meta ?? ""),
};

// --- Orchestrator ---

class SagaOrchestrator<TContext extends Record<string, unknown>> {
  private steps: SagaStep<TContext>[] = [];
  private store: SagaStore;
  private logger: SagaLogger;
  private maxCompensationRetries = 3;
  private compensationRetryDelayMs = 1000;

  constructor(
    private sagaName: string,
    options?: {
      store?: SagaStore;
      logger?: SagaLogger;
      maxCompensationRetries?: number;
    }
  ) {
    this.store = options?.store ?? new InMemorySagaStore();
    this.logger = options?.logger ?? consoleLogger;
    if (options?.maxCompensationRetries !== undefined) {
      this.maxCompensationRetries = options.maxCompensationRetries;
    }
  }

  /** Add a step with its forward action and compensating action. */
  step(
    name: string,
    execute: (ctx: TContext) => Promise<TContext>,
    compensate: (ctx: TContext) => Promise<void>
  ): this {
    this.steps.push({ name, execute, compensate });
    return this;
  }

  /** Execute the saga. Returns the result with success/failure status. */
  async execute(initialContext: TContext): Promise<SagaResult<TContext>> {
    const sagaId = `${this.sagaName}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const completedSteps: string[] = [];
    let context = { ...initialContext };

    const state: SagaState<TContext> = {
      sagaId,
      sagaName: this.sagaName,
      status: "running",
      currentStep: 0,
      completedSteps: [],
      context,
      startedAt: new Date(),
    };

    await this.store.save(state as SagaState<unknown>);
    this.logger.info(`Saga started: ${sagaId}`, { sagaName: this.sagaName });

    // Forward execution
    for (let i = 0; i < this.steps.length; i++) {
      const step = this.steps[i];
      state.currentStep = i;

      try {
        this.logger.info(`Executing step: ${step.name}`, { sagaId, step: i });
        context = await step.execute(context);
        completedSteps.push(step.name);
        state.completedSteps = [...completedSteps];
        state.context = context;
        await this.store.save(state as SagaState<unknown>);
      } catch (error) {
        const errMsg = error instanceof Error ? error.message : String(error);
        this.logger.error(`Step failed: ${step.name}`, { sagaId, error: errMsg });

        state.status = "compensating";
        state.error = errMsg;
        await this.store.save(state as SagaState<unknown>);

        // Compensate in reverse order
        const compensatedSteps = await this.compensate(sagaId, context, completedSteps);

        state.status = "compensated";
        state.completedAt = new Date();
        await this.store.save(state as SagaState<unknown>);

        return {
          success: false,
          sagaId,
          context,
          error: errMsg,
          completedSteps,
          compensatedSteps,
        };
      }
    }

    state.status = "completed";
    state.completedAt = new Date();
    await this.store.save(state as SagaState<unknown>);
    this.logger.info(`Saga completed: ${sagaId}`);

    return {
      success: true,
      sagaId,
      context,
      completedSteps,
      compensatedSteps: [],
    };
  }

  /** Compensate completed steps in reverse order with retry logic. */
  private async compensate(
    sagaId: string,
    context: TContext,
    completedSteps: string[]
  ): Promise<string[]> {
    const compensatedSteps: string[] = [];

    for (let i = completedSteps.length - 1; i >= 0; i--) {
      const stepName = completedSteps[i];
      const step = this.steps.find((s) => s.name === stepName);
      if (!step) continue;

      let retries = 0;
      while (retries <= this.maxCompensationRetries) {
        try {
          this.logger.info(`Compensating step: ${stepName}`, { sagaId, attempt: retries + 1 });
          await step.compensate(context);
          compensatedSteps.push(stepName);
          break;
        } catch (error) {
          retries++;
          const errMsg = error instanceof Error ? error.message : String(error);
          if (retries > this.maxCompensationRetries) {
            this.logger.error(`Compensation failed permanently: ${stepName}`, {
              sagaId,
              error: errMsg,
              action: "MANUAL_INTERVENTION_REQUIRED",
            });
          } else {
            this.logger.warn(`Compensation retry: ${stepName}`, { sagaId, attempt: retries });
            await this.delay(this.compensationRetryDelayMs * Math.pow(2, retries - 1));
          }
        }
      }
    }

    return compensatedSteps;
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// --- Example Usage ---

interface OrderContext extends Record<string, unknown> {
  orderId: string;
  amount: number;
  currency: string;
  paymentId?: string;
  inventoryReservationId?: string;
  shipmentId?: string;
}

async function exampleUsage() {
  const saga = new SagaOrchestrator<OrderContext>("order-fulfillment");

  saga
    .step(
      "create-order",
      async (ctx) => {
        // Call Order Service API
        console.log(`Creating order: ${ctx.orderId}`);
        return { ...ctx, orderStatus: "CREATED" };
      },
      async (ctx) => {
        console.log(`Cancelling order: ${ctx.orderId}`);
        // Call Order Service cancel API
      }
    )
    .step(
      "charge-payment",
      async (ctx) => {
        console.log(`Charging payment: $${ctx.amount} ${ctx.currency}`);
        return { ...ctx, paymentId: "pay-789" };
      },
      async (ctx) => {
        console.log(`Refunding payment: ${ctx.paymentId}`);
        // Call Payment Service refund API
      }
    )
    .step(
      "reserve-inventory",
      async (ctx) => {
        console.log(`Reserving inventory for: ${ctx.orderId}`);
        return { ...ctx, inventoryReservationId: "inv-321" };
      },
      async (ctx) => {
        console.log(`Releasing inventory: ${ctx.inventoryReservationId}`);
        // Call Inventory Service release API
      }
    )
    .step(
      "schedule-shipping",
      async (ctx) => {
        console.log(`Scheduling shipment for: ${ctx.orderId}`);
        return { ...ctx, shipmentId: "ship-654" };
      },
      async (ctx) => {
        console.log(`Cancelling shipment: ${ctx.shipmentId}`);
        // Call Shipping Service cancel API
      }
    );

  const result = await saga.execute({
    orderId: "ord-123",
    amount: 99.99,
    currency: "USD",
  });

  console.log("Saga result:", JSON.stringify(result, null, 2));
}

export { SagaOrchestrator, SagaStep, SagaState, SagaResult, SagaStore, SagaLogger, InMemorySagaStore };
