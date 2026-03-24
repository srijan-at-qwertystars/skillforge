// =============================================================================
// Process Manager / Saga Template — TypeScript
//
// Usage: Copy and adapt for each multi-aggregate workflow.
// Pattern: React to events → maintain state machine → dispatch commands
//
// Key rules:
//   - Every step is idempotent (re-processing the same event is safe)
//   - Compensating actions for every non-terminal step
//   - Saga state is persisted (event-sourced or document-based)
//   - Timeouts handled via scheduled events
// =============================================================================

// --- Types ---

export interface DomainEvent {
  readonly type: string;
  readonly data: Record<string, unknown>;
  readonly metadata: {
    timestamp: string;
    correlationId: string;
    causationId?: string;
  };
}

export interface Command {
  readonly type: string;
  readonly data: Record<string, unknown>;
  readonly commandId: string;
  readonly correlationId: string;
}

export interface CommandBus {
  dispatch(command: Command): Promise<void>;
}

export interface TimeoutScheduler {
  schedule(sagaId: string, timeoutEvent: DomainEvent, delayMs: number): Promise<void>;
  cancel(sagaId: string): Promise<void>;
}

// --- Saga State Machine ---

type SagaStatus =
  | 'not_started'
  | 'awaiting_inventory'
  | 'awaiting_payment'
  | 'awaiting_shipment'
  | 'completed'
  | 'compensating'
  | 'failed';

interface SagaState {
  sagaId: string;
  correlationId: string;
  status: SagaStatus;
  orderId: string;
  customerId: string;
  startedAt: string;
  completedSteps: string[];
  failureReason?: string;
}

// --- Saga Implementation ---

export class OrderFulfillmentSaga {
  private state: SagaState;

  constructor(sagaId: string) {
    this.state = {
      sagaId,
      correlationId: sagaId,
      status: 'not_started',
      orderId: '',
      customerId: '',
      startedAt: '',
      completedSteps: [],
    };
  }

  // --- Event Handlers (react to events, transition state, return commands) ---

  async handleEvent(
    event: DomainEvent,
    commandBus: CommandBus,
    timeoutScheduler: TimeoutScheduler,
  ): Promise<void> {
    // Idempotency: skip if this step is already completed
    if (this.state.completedSteps.includes(event.type)) return;

    switch (event.type) {
      case 'OrderConfirmed':
        await this.onOrderConfirmed(event, commandBus, timeoutScheduler);
        break;
      case 'InventoryReserved':
        await this.onInventoryReserved(event, commandBus, timeoutScheduler);
        break;
      case 'PaymentProcessed':
        await this.onPaymentProcessed(event, commandBus, timeoutScheduler);
        break;
      case 'OrderShipped':
        await this.onOrderShipped(event, timeoutScheduler);
        break;
      // --- Failure / Compensation ---
      case 'InventoryReservationFailed':
        await this.onInventoryFailed(event, commandBus);
        break;
      case 'PaymentFailed':
        await this.onPaymentFailed(event, commandBus);
        break;
      // --- Timeout ---
      case 'SagaTimeout':
        await this.onTimeout(event, commandBus);
        break;
    }
  }

  // --- Step 1: Order confirmed → Reserve inventory ---

  private async onOrderConfirmed(
    event: DomainEvent,
    commandBus: CommandBus,
    timeoutScheduler: TimeoutScheduler,
  ): Promise<void> {
    this.state.orderId = event.data.orderId as string;
    this.state.customerId = event.data.customerId as string;
    this.state.startedAt = event.metadata.timestamp;
    this.state.status = 'awaiting_inventory';
    this.state.completedSteps.push('OrderConfirmed');

    await commandBus.dispatch({
      type: 'ReserveInventory',
      data: { orderId: this.state.orderId, items: event.data.items },
      commandId: `${this.state.sagaId}-reserve-inv`,
      correlationId: this.state.correlationId,
    });

    // Schedule timeout: if inventory not reserved within 5 minutes
    await timeoutScheduler.schedule(
      this.state.sagaId,
      {
        type: 'SagaTimeout',
        data: { step: 'awaiting_inventory', sagaId: this.state.sagaId },
        metadata: { timestamp: '', correlationId: this.state.correlationId },
      },
      5 * 60 * 1000,
    );
  }

  // --- Step 2: Inventory reserved → Process payment ---

  private async onInventoryReserved(
    event: DomainEvent,
    commandBus: CommandBus,
    timeoutScheduler: TimeoutScheduler,
  ): Promise<void> {
    this.state.status = 'awaiting_payment';
    this.state.completedSteps.push('InventoryReserved');

    await timeoutScheduler.cancel(this.state.sagaId); // Cancel inventory timeout

    await commandBus.dispatch({
      type: 'ProcessPayment',
      data: {
        orderId: this.state.orderId,
        customerId: this.state.customerId,
        amount: event.data.totalAmount,
      },
      commandId: `${this.state.sagaId}-process-pmt`,
      correlationId: this.state.correlationId,
    });

    await timeoutScheduler.schedule(
      this.state.sagaId,
      {
        type: 'SagaTimeout',
        data: { step: 'awaiting_payment', sagaId: this.state.sagaId },
        metadata: { timestamp: '', correlationId: this.state.correlationId },
      },
      2 * 60 * 1000,
    );
  }

  // --- Step 3: Payment processed → Ship order ---

  private async onPaymentProcessed(
    event: DomainEvent,
    commandBus: CommandBus,
    timeoutScheduler: TimeoutScheduler,
  ): Promise<void> {
    this.state.status = 'awaiting_shipment';
    this.state.completedSteps.push('PaymentProcessed');

    await timeoutScheduler.cancel(this.state.sagaId);

    // PIVOT TRANSACTION: After this, compensation is not possible
    await commandBus.dispatch({
      type: 'ShipOrder',
      data: { orderId: this.state.orderId },
      commandId: `${this.state.sagaId}-ship`,
      correlationId: this.state.correlationId,
    });
  }

  // --- Step 4: Order shipped → Saga complete ---

  private async onOrderShipped(
    event: DomainEvent,
    timeoutScheduler: TimeoutScheduler,
  ): Promise<void> {
    this.state.status = 'completed';
    this.state.completedSteps.push('OrderShipped');
    await timeoutScheduler.cancel(this.state.sagaId);
  }

  // --- Compensation: Inventory reservation failed ---

  private async onInventoryFailed(
    event: DomainEvent,
    commandBus: CommandBus,
  ): Promise<void> {
    this.state.status = 'failed';
    this.state.failureReason = `Inventory reservation failed: ${event.data.reason}`;

    // No prior steps to compensate (inventory was the first step after order confirmation)
    await commandBus.dispatch({
      type: 'NotifyCustomer',
      data: {
        customerId: this.state.customerId,
        orderId: this.state.orderId,
        message: 'Order could not be fulfilled: items unavailable',
      },
      commandId: `${this.state.sagaId}-notify-inv-fail`,
      correlationId: this.state.correlationId,
    });
  }

  // --- Compensation: Payment failed → Release inventory ---

  private async onPaymentFailed(
    event: DomainEvent,
    commandBus: CommandBus,
  ): Promise<void> {
    this.state.status = 'compensating';
    this.state.failureReason = `Payment failed: ${event.data.reason}`;

    // Compensate: release the reserved inventory
    await commandBus.dispatch({
      type: 'ReleaseInventory',
      data: { orderId: this.state.orderId },
      commandId: `${this.state.sagaId}-release-inv`,
      correlationId: this.state.correlationId,
    });

    await commandBus.dispatch({
      type: 'NotifyCustomer',
      data: {
        customerId: this.state.customerId,
        orderId: this.state.orderId,
        message: 'Payment could not be processed. Inventory has been released.',
      },
      commandId: `${this.state.sagaId}-notify-pmt-fail`,
      correlationId: this.state.correlationId,
    });

    this.state.status = 'failed';
  }

  // --- Timeout handler ---

  private async onTimeout(
    event: DomainEvent,
    commandBus: CommandBus,
  ): Promise<void> {
    const step = event.data.step as string;

    if (step === 'awaiting_inventory' && this.state.status === 'awaiting_inventory') {
      this.state.status = 'failed';
      this.state.failureReason = 'Inventory reservation timed out';
      await commandBus.dispatch({
        type: 'NotifyCustomer',
        data: {
          customerId: this.state.customerId,
          orderId: this.state.orderId,
          message: 'Order processing timed out. Please try again.',
        },
        commandId: `${this.state.sagaId}-timeout-notify`,
        correlationId: this.state.correlationId,
      });
    }

    if (step === 'awaiting_payment' && this.state.status === 'awaiting_payment') {
      this.state.status = 'compensating';
      this.state.failureReason = 'Payment processing timed out';
      await commandBus.dispatch({
        type: 'ReleaseInventory',
        data: { orderId: this.state.orderId },
        commandId: `${this.state.sagaId}-timeout-release`,
        correlationId: this.state.correlationId,
      });
      this.state.status = 'failed';
    }
  }

  // --- Accessors ---

  getState(): Readonly<SagaState> { return { ...this.state }; }
  isCompleted(): boolean { return this.state.status === 'completed' || this.state.status === 'failed'; }
}
