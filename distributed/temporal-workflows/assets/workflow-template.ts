/**
 * Temporal Workflow Template — TypeScript
 *
 * Production-ready workflow with:
 * - Activities with retry policies
 * - Signals for external input
 * - Queries for state inspection
 * - Updates for validated mutations
 * - Error handling with saga compensation
 * - ContinueAsNew for long-running workflows
 *
 * Usage: Copy and adapt for your use case.
 */
import * as wf from '@temporalio/workflow';
import type * as activities from './activities';

// --- Activity Proxies ---

const { validateOrder, processPayment, reserveInventory, sendConfirmation } =
  wf.proxyActivities<typeof activities>({
    startToCloseTimeout: '30s',
    retry: {
      initialInterval: '1s',
      backoffCoefficient: 2,
      maximumInterval: '30s',
      maximumAttempts: 5,
      nonRetryableErrorTypes: ['InvalidInputError', 'DuplicateOrderError'],
    },
  });

const { releaseInventory, refundPayment } =
  wf.proxyActivities<typeof activities>({
    startToCloseTimeout: '1m',
    retry: { maximumAttempts: 10 },
  });

// --- Signals ---

export const approveSignal = wf.defineSignal<[string]>('approve');
export const cancelSignal = wf.defineSignal('cancel');
export const addItemSignal = wf.defineSignal<[OrderItem]>('addItem');

// --- Queries ---

export const statusQuery = wf.defineQuery<OrderStatus>('status');
export const itemsQuery = wf.defineQuery<OrderItem[]>('items');

// --- Updates ---

export const updateQuantityUpdate = wf.defineUpdate<OrderItem, [string, number]>(
  'updateQuantity'
);

// --- Types ---

export interface OrderInput {
  orderId: string;
  customerId: string;
  items: OrderItem[];
}

export interface OrderItem {
  sku: string;
  quantity: number;
  price: number;
}

export type OrderStatus =
  | 'pending'
  | 'approved'
  | 'processing'
  | 'payment_completed'
  | 'fulfilled'
  | 'cancelled'
  | 'failed';

// --- Workflow ---

export async function orderWorkflow(input: OrderInput): Promise<string> {
  // --- State ---
  let status: OrderStatus = 'pending';
  let items = [...input.items];
  let cancelled = false;
  let approvedBy = '';

  // --- Compensations for saga pattern ---
  const compensations: Array<() => Promise<void>> = [];

  // --- Register handlers ---

  wf.setHandler(statusQuery, () => status);
  wf.setHandler(itemsQuery, () => items);

  wf.setHandler(approveSignal, (approver: string) => {
    approvedBy = approver;
  });

  wf.setHandler(cancelSignal, () => {
    cancelled = true;
  });

  wf.setHandler(addItemSignal, (item: OrderItem) => {
    if (status === 'pending') {
      items.push(item);
    }
  });

  wf.setHandler(updateQuantityUpdate, (sku: string, newQty: number) => {
    if (newQty < 0) {
      throw new Error('Quantity must be non-negative');
    }
    const item = items.find((i) => i.sku === sku);
    if (!item) {
      throw new Error(`Item ${sku} not found`);
    }
    item.quantity = newQty;
    return item;
  });

  // --- Step 1: Wait for approval ---

  const approved = await wf.condition(
    () => approvedBy !== '' || cancelled,
    '24 hours'
  );

  if (!approved || cancelled) {
    status = 'cancelled';
    return `Order ${input.orderId} cancelled or timed out`;
  }

  // --- Step 2: Validate ---

  status = 'processing';
  await validateOrder({ orderId: input.orderId, customerId: input.customerId, items });

  // --- Step 3: Saga — Reserve, Pay, Confirm ---

  try {
    // Reserve inventory
    const reservationId = await reserveInventory({
      orderId: input.orderId,
      items,
    });
    compensations.push(() => releaseInventory(reservationId));

    // Check for cancellation between steps
    if (cancelled) {
      throw wf.ApplicationFailure.create({
        type: 'CancelledByUser',
        message: 'Order cancelled during processing',
      });
    }

    // Process payment
    const total = items.reduce((sum, i) => sum + i.price * i.quantity, 0);
    const paymentId = await processPayment({
      orderId: input.orderId,
      customerId: input.customerId,
      amount: total,
    });
    compensations.push(() => refundPayment(paymentId));
    status = 'payment_completed';

    // Send confirmation
    await sendConfirmation({
      orderId: input.orderId,
      customerId: input.customerId,
      paymentId,
      reservationId,
    });
    status = 'fulfilled';

    return `Order ${input.orderId} fulfilled. Payment: ${paymentId}`;
  } catch (err) {
    status = 'failed';

    // Compensate in reverse order
    for (const compensate of compensations.reverse()) {
      try {
        await compensate();
      } catch (compErr) {
        // Log but continue compensating
        wf.log.error('Compensation failed', { error: String(compErr) });
      }
    }

    if (err instanceof wf.ApplicationFailure && err.type === 'CancelledByUser') {
      status = 'cancelled';
      return `Order ${input.orderId} cancelled and compensated`;
    }

    throw err;
  }
}

// --- Long-Running Variant with ContinueAsNew ---

export interface SubscriptionState {
  customerId: string;
  plan: string;
  billingCycle: number;
  status: 'active' | 'paused' | 'cancelled';
}

export const pauseSignal = wf.defineSignal('pause');
export const resumeSignal = wf.defineSignal('resume');
export const subscriptionStatusQuery = wf.defineQuery<SubscriptionState>('subscriptionStatus');

export async function subscriptionWorkflow(state: SubscriptionState): Promise<string> {
  wf.setHandler(subscriptionStatusQuery, () => state);
  wf.setHandler(pauseSignal, () => { state.status = 'paused'; });
  wf.setHandler(resumeSignal, () => { state.status = 'active'; });
  wf.setHandler(cancelSignal, () => { state.status = 'cancelled'; });

  while (state.status !== 'cancelled') {
    // ContinueAsNew every 100 cycles to keep history bounded
    if (state.billingCycle > 0 && state.billingCycle % 100 === 0) {
      await wf.continueAsNew<typeof subscriptionWorkflow>(state);
    }

    if (state.status === 'active') {
      await processPayment({
        orderId: `sub-${state.customerId}-${state.billingCycle}`,
        customerId: state.customerId,
        amount: 29.99,
      });
      state.billingCycle++;
    }

    // Wait for next billing period or status change
    await wf.condition(() => state.status === 'cancelled', '30 days');
  }

  return `Subscription cancelled after ${state.billingCycle} cycles`;
}
