// =============================================================================
// Aggregate Root Template — TypeScript Event Sourcing
//
// Usage: Copy and rename for each aggregate. Replace TODO markers.
// Pattern: Load events → rehydrate state → validate command → emit events
// =============================================================================

// --- Event Base Types ---

export interface EventMetadata {
  readonly timestamp: string;
  readonly version: number;
  readonly causationId?: string;
  readonly correlationId?: string;
}

export interface DomainEvent<TType extends string = string, TData = Record<string, unknown>> {
  readonly type: TType;
  readonly data: TData;
  readonly metadata: EventMetadata;
}

// --- TODO: Define your domain events ---

export interface MyAggregateCreated extends DomainEvent<'MyAggregateCreated'> {
  data: { id: string; name: string };
}

export interface MyAggregateUpdated extends DomainEvent<'MyAggregateUpdated'> {
  data: { id: string; name: string };
}

export interface MyAggregateDeleted extends DomainEvent<'MyAggregateDeleted'> {
  data: { id: string };
}

type MyAggregateEvent = MyAggregateCreated | MyAggregateUpdated | MyAggregateDeleted;

// --- Aggregate State ---

interface MyAggregateState {
  id: string;
  name: string;
  status: 'active' | 'deleted';
  createdAt: string;
  updatedAt: string;
}

// --- Aggregate Root ---

export class MyAggregate {
  private state: MyAggregateState = {
    id: '',
    name: '',
    status: 'active',
    createdAt: '',
    updatedAt: '',
  };
  private version: number = 0;
  private uncommitted: DomainEvent[] = [];

  // --- Rehydration ---

  static rehydrate(events: DomainEvent[]): MyAggregate {
    const agg = new MyAggregate();
    for (const event of events) {
      agg.apply(event, false);
    }
    return agg;
  }

  // --- Snapshot Support ---

  static fromSnapshot(snapshot: {
    state: MyAggregateState;
    version: number;
  }): MyAggregate {
    const agg = new MyAggregate();
    agg.state = { ...snapshot.state };
    agg.version = snapshot.version;
    return agg;
  }

  toSnapshot(): { state: MyAggregateState; version: number; schemaVersion: number } {
    return {
      state: { ...this.state },
      version: this.version,
      schemaVersion: 1, // Increment when state shape changes
    };
  }

  // --- Command Methods (enforce invariants, emit events) ---

  create(cmd: { id: string; name: string }): void {
    if (this.state.id) {
      throw new Error('Aggregate already created');
    }
    if (!cmd.name || cmd.name.trim().length === 0) {
      throw new Error('Name is required');
    }
    this.apply({
      type: 'MyAggregateCreated',
      data: { id: cmd.id, name: cmd.name.trim() },
      metadata: this.newMetadata(),
    });
  }

  updateName(cmd: { name: string }): void {
    this.ensureExists();
    this.ensureNotDeleted();
    if (cmd.name === this.state.name) return; // no-op, idempotent
    this.apply({
      type: 'MyAggregateUpdated',
      data: { id: this.state.id, name: cmd.name.trim() },
      metadata: this.newMetadata(),
    });
  }

  delete(): void {
    this.ensureExists();
    if (this.state.status === 'deleted') return; // idempotent
    this.apply({
      type: 'MyAggregateDeleted',
      data: { id: this.state.id },
      metadata: this.newMetadata(),
    });
  }

  // --- Event Application (state transitions, no side effects) ---

  private apply(event: DomainEvent, isNew: boolean = true): void {
    switch (event.type) {
      case 'MyAggregateCreated': {
        const e = event as MyAggregateCreated;
        this.state.id = e.data.id;
        this.state.name = e.data.name;
        this.state.status = 'active';
        this.state.createdAt = e.metadata.timestamp;
        this.state.updatedAt = e.metadata.timestamp;
        break;
      }
      case 'MyAggregateUpdated': {
        const e = event as MyAggregateUpdated;
        this.state.name = e.data.name;
        this.state.updatedAt = e.metadata.timestamp;
        break;
      }
      case 'MyAggregateDeleted': {
        this.state.status = 'deleted';
        this.state.updatedAt = event.metadata.timestamp;
        break;
      }
    }
    this.version++;
    if (isNew) {
      this.uncommitted.push(event);
    }
  }

  // --- Queries ---

  getId(): string { return this.state.id; }
  getName(): string { return this.state.name; }
  getStatus(): string { return this.state.status; }
  getVersion(): number { return this.version; }
  getUncommitted(): DomainEvent[] { return [...this.uncommitted]; }
  clearUncommitted(): void { this.uncommitted = []; }

  // --- Guards ---

  private ensureExists(): void {
    if (!this.state.id) throw new Error('Aggregate does not exist');
  }

  private ensureNotDeleted(): void {
    if (this.state.status === 'deleted') throw new Error('Aggregate is deleted');
  }

  private newMetadata(): EventMetadata {
    return { timestamp: new Date().toISOString(), version: 1 };
  }
}
