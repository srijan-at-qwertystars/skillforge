// =============================================================================
// Projection Handler Template — TypeScript Read Model
//
// Usage: Copy for each projection. Implement handle() cases and configure
//        the read model store (PostgreSQL, Elasticsearch, Redis, etc.).
//
// Pattern: Subscribe to event stream → apply events → update read model
// =============================================================================

// --- Types ---

export interface StoredEvent {
  readonly globalPosition: number;
  readonly streamId: string;
  readonly version: number;
  readonly type: string;
  readonly data: Record<string, unknown>;
  readonly metadata: {
    timestamp: string;
    causationId?: string;
    correlationId?: string;
  };
}

export interface ReadModelStore {
  upsert(table: string, id: string, data: Record<string, unknown>): Promise<void>;
  delete(table: string, id: string): Promise<void>;
  query(table: string, filter: Record<string, unknown>): Promise<Record<string, unknown>[]>;
}

export interface CheckpointStore {
  getPosition(projectionName: string): Promise<number>;
  setPosition(projectionName: string, position: number): Promise<void>;
}

// --- Projection Base ---

export abstract class Projection {
  abstract readonly name: string;
  abstract readonly subscribedEvents: string[];

  constructor(
    protected readonly readModel: ReadModelStore,
    protected readonly checkpoint: CheckpointStore,
  ) {}

  // Override in subclass: apply one event to the read model
  abstract handle(event: StoredEvent): Promise<void>;

  // Process a batch of events with idempotency and checkpointing
  async processBatch(events: StoredEvent[]): Promise<number> {
    const lastPosition = await this.checkpoint.getPosition(this.name);
    let processed = 0;

    for (const event of events) {
      // Skip already-processed events (idempotency)
      if (event.globalPosition <= lastPosition) continue;

      // Skip events this projection doesn't care about
      if (!this.subscribedEvents.includes(event.type)) {
        await this.checkpoint.setPosition(this.name, event.globalPosition);
        continue;
      }

      try {
        await this.handle(event);
        await this.checkpoint.setPosition(this.name, event.globalPosition);
        processed++;
      } catch (error) {
        console.error(
          `[${this.name}] Failed to process event ${event.type} at position ${event.globalPosition}:`,
          error,
        );
        throw error; // Let the subscription infrastructure handle retries/DLQ
      }
    }

    return processed;
  }

  // Rebuild from scratch: clear read model, reset checkpoint, replay all events
  async rebuild(allEvents: StoredEvent[]): Promise<void> {
    console.log(`[${this.name}] Starting full rebuild...`);
    await this.checkpoint.setPosition(this.name, 0);
    // NOTE: Clear the read model tables for this projection before calling this
    await this.processBatch(allEvents);
    console.log(`[${this.name}] Rebuild complete. Processed ${allEvents.length} events.`);
  }
}

// =============================================================================
// Example: Order Summary Projection
// =============================================================================

export class OrderSummaryProjection extends Projection {
  readonly name = 'order_summary';
  readonly subscribedEvents = [
    'OrderCreated',
    'OrderConfirmed',
    'OrderCancelled',
    'OrderItemAdded',
    'OrderItemRemoved',
  ];

  async handle(event: StoredEvent): Promise<void> {
    switch (event.type) {
      case 'OrderCreated':
        await this.readModel.upsert('order_summary', event.streamId, {
          orderId: event.streamId,
          customerId: event.data.customerId,
          status: 'draft',
          itemCount: 0,
          totalAmount: 0,
          createdAt: event.metadata.timestamp,
          updatedAt: event.metadata.timestamp,
        });
        break;

      case 'OrderConfirmed': {
        // Fetch current state to update
        const [order] = await this.readModel.query('order_summary', { orderId: event.streamId });
        if (order) {
          await this.readModel.upsert('order_summary', event.streamId, {
            ...order,
            status: 'confirmed',
            updatedAt: event.metadata.timestamp,
          });
        }
        break;
      }

      case 'OrderCancelled': {
        const [existing] = await this.readModel.query('order_summary', { orderId: event.streamId });
        if (existing) {
          await this.readModel.upsert('order_summary', event.streamId, {
            ...existing,
            status: 'cancelled',
            updatedAt: event.metadata.timestamp,
          });
        }
        break;
      }

      case 'OrderItemAdded': {
        const [current] = await this.readModel.query('order_summary', { orderId: event.streamId });
        if (current) {
          await this.readModel.upsert('order_summary', event.streamId, {
            ...current,
            itemCount: (current.itemCount as number) + 1,
            totalAmount: (current.totalAmount as number) + (event.data.price as number),
            updatedAt: event.metadata.timestamp,
          });
        }
        break;
      }

      case 'OrderItemRemoved': {
        const [cur] = await this.readModel.query('order_summary', { orderId: event.streamId });
        if (cur) {
          await this.readModel.upsert('order_summary', event.streamId, {
            ...cur,
            itemCount: Math.max(0, (cur.itemCount as number) - 1),
            totalAmount: Math.max(0, (cur.totalAmount as number) - (event.data.price as number)),
            updatedAt: event.metadata.timestamp,
          });
        }
        break;
      }
    }
  }
}
