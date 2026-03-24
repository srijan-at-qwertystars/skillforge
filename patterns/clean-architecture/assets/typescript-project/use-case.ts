/**
 * Base Use Case interfaces and abstract class for Clean Architecture.
 *
 * Every use case implements IUseCase<TRequest, TResponse>.
 * Use cases orchestrate domain entities to fulfill a single application operation.
 *
 * Usage:
 *   class CreateOrderUseCase implements IUseCase<CreateOrderRequest, CreateOrderResponse> {
 *     async execute(request: CreateOrderRequest): Promise<CreateOrderResponse> {
 *       // orchestration logic
 *     }
 *   }
 */

/**
 * Core use case interface. Every use case has one public method: execute.
 */
export interface IUseCase<TRequest, TResponse> {
  execute(request: TRequest): Promise<TResponse>;
}

/**
 * Use case with no input (e.g., "list all active orders").
 */
export interface IQueryUseCase<TResponse> {
  execute(): Promise<TResponse>;
}

/**
 * Use case with no output (e.g., "delete order").
 */
export interface ICommandUseCase<TRequest> {
  execute(request: TRequest): Promise<void>;
}

/**
 * Abstract base class for use cases that need common functionality.
 * Extend this when you need shared behavior (logging, validation, etc.).
 */
export abstract class BaseUseCase<TRequest, TResponse>
  implements IUseCase<TRequest, TResponse>
{
  async execute(request: TRequest): Promise<TResponse> {
    await this.validate(request);
    return this.handle(request);
  }

  /**
   * Override to add input validation before the use case runs.
   * Throw a ValidationError for invalid input.
   */
  protected async validate(_request: TRequest): Promise<void> {
    // Default: no validation. Override in subclasses.
  }

  /**
   * Implement the actual use case logic here.
   */
  protected abstract handle(request: TRequest): Promise<TResponse>;
}

/**
 * CQRS Command handler interface.
 * Commands modify state and return void or a minimal result.
 */
export interface ICommandHandler<TCommand> {
  handle(command: TCommand): Promise<void>;
}

/**
 * CQRS Query handler interface.
 * Queries read state and never modify it.
 */
export interface IQueryHandler<TQuery, TResult> {
  handle(query: TQuery): Promise<TResult>;
}

/**
 * Event handler interface for domain events.
 * Handlers must be idempotent — safe to replay.
 */
export interface IEventHandler<TEvent> {
  handle(event: TEvent): Promise<void>;
}
