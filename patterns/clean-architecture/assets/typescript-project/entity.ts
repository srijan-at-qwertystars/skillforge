/**
 * Base Entity class for Clean Architecture domain layer.
 *
 * All domain entities extend this class. Provides identity, timestamps,
 * and equality semantics based on ID (not structural equality).
 *
 * Usage:
 *   class User extends BaseEntity {
 *     private constructor(id: string, public readonly name: string) {
 *       super(id);
 *     }
 *     static create(id: string, name: string): User {
 *       return new User(id, name);
 *     }
 *   }
 */

export abstract class BaseEntity {
  public readonly createdAt: Date;
  public updatedAt: Date;

  protected constructor(
    public readonly id: string,
    createdAt?: Date,
    updatedAt?: Date
  ) {
    if (!id || id.trim().length === 0) {
      throw new Error('Entity ID cannot be empty');
    }
    this.createdAt = createdAt ?? new Date();
    this.updatedAt = updatedAt ?? new Date();
  }

  /**
   * Entities are equal if they have the same ID, regardless of other fields.
   */
  equals(other: BaseEntity): boolean {
    if (!(other instanceof BaseEntity)) return false;
    return this.id === other.id;
  }

  /**
   * Mark entity as modified. Call in mutation methods.
   */
  protected touch(): void {
    this.updatedAt = new Date();
  }
}

/**
 * Aggregate root marker. Aggregates are the only entities that can be
 * directly saved/loaded via repositories. They collect domain events.
 */
export abstract class AggregateRoot extends BaseEntity {
  private _domainEvents: DomainEvent[] = [];

  protected addDomainEvent(event: DomainEvent): void {
    this._domainEvents.push(event);
  }

  /**
   * Pull and clear all pending domain events.
   * Call after successfully persisting the aggregate.
   */
  pullDomainEvents(): DomainEvent[] {
    const events = [...this._domainEvents];
    this._domainEvents = [];
    return events;
  }

  hasDomainEvents(): boolean {
    return this._domainEvents.length > 0;
  }
}

/**
 * Base domain event interface.
 */
export interface DomainEvent {
  readonly eventType: string;
  readonly occurredAt: Date;
  readonly aggregateId: string;
}
