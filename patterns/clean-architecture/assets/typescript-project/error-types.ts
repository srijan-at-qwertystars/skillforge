/**
 * Domain Error hierarchy for Clean Architecture.
 *
 * Three-tier error system aligned with architectural layers:
 * - DomainError: invariant violations in entities/value objects
 * - ApplicationError: business rule violations in use cases
 * - InfrastructureError: external system failures
 *
 * All errors carry a machine-readable `code` and an HTTP-mappable `statusCode`.
 * The presentation layer's error handler middleware maps these to responses.
 *
 * Usage:
 *   throw new NotFoundError('Order', 'id', 'order-123');
 *   throw new ValidationError('email', 'Invalid email format');
 *   throw new AuthorizationError('delete', 'Order');
 */

// =============================================================================
// Base Error Classes
// =============================================================================

export abstract class DomainError extends Error {
  abstract readonly code: string;
  abstract readonly statusCode: number;

  constructor(message: string) {
    super(message);
    this.name = this.constructor.name;
    // Fix prototype chain for instanceof checks
    Object.setPrototypeOf(this, new.target.prototype);
  }

  /**
   * Serialize error for logging or API responses.
   */
  toJSON(): Record<string, unknown> {
    return {
      code: this.code,
      message: this.message,
      name: this.name,
    };
  }
}

// =============================================================================
// Not Found Errors (404)
// =============================================================================

export class NotFoundError extends DomainError {
  readonly code = 'NOT_FOUND';
  readonly statusCode = 404;
  readonly entity: string;

  constructor(entity: string, field: string, value: string) {
    super(`${entity} with ${field} "${value}" not found`);
    this.entity = entity;
  }
}

// =============================================================================
// Validation Errors (422)
// =============================================================================

export class ValidationError extends DomainError {
  readonly code = 'VALIDATION_ERROR';
  readonly statusCode = 422;
  readonly field: string;

  constructor(field: string, message: string) {
    super(`${field}: ${message}`);
    this.field = field;
  }
}

/**
 * Aggregates multiple field validation errors into one.
 */
export class AggregateValidationError extends DomainError {
  readonly code = 'VALIDATION_ERROR';
  readonly statusCode = 422;
  readonly errors: { field: string; message: string }[];

  constructor(errors: { field: string; message: string }[]) {
    const summary = errors.map(e => `${e.field}: ${e.message}`).join('; ');
    super(`Validation failed: ${summary}`);
    this.errors = errors;
  }

  toJSON(): Record<string, unknown> {
    return {
      ...super.toJSON(),
      errors: this.errors,
    };
  }
}

// =============================================================================
// Authorization Errors (403)
// =============================================================================

export class AuthorizationError extends DomainError {
  readonly code = 'UNAUTHORIZED';
  readonly statusCode = 403;

  constructor(action: string, resource: string) {
    super(`Not authorized to ${action} ${resource}`);
  }
}

/**
 * Authentication failure — user identity not established.
 */
export class AuthenticationError extends DomainError {
  readonly code = 'UNAUTHENTICATED';
  readonly statusCode = 401;

  constructor(message = 'Authentication required') {
    super(message);
  }
}

// =============================================================================
// Conflict Errors (409)
// =============================================================================

export class ConflictError extends DomainError {
  readonly code = 'CONFLICT';
  readonly statusCode = 409;

  constructor(entity: string, field: string, value: string) {
    super(`${entity} with ${field} "${value}" already exists`);
  }
}

/**
 * Optimistic concurrency conflict.
 */
export class ConcurrencyError extends DomainError {
  readonly code = 'CONCURRENCY_CONFLICT';
  readonly statusCode = 409;

  constructor(entity: string, id: string) {
    super(
      `${entity} "${id}" was modified by another process. Retry the operation.`
    );
  }
}

// =============================================================================
// Business Rule Errors (422)
// =============================================================================

/**
 * Base class for domain-specific business rule violations.
 * Extend this for each specific business rule.
 *
 * Example:
 *   class InsufficientFundsError extends BusinessRuleError {
 *     constructor(available: Money, required: Money) {
 *       super('INSUFFICIENT_FUNDS', `Available ${available} < required ${required}`);
 *     }
 *   }
 */
export class BusinessRuleError extends DomainError {
  readonly statusCode = 422;

  constructor(
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

// =============================================================================
// Infrastructure Errors (500)
// =============================================================================

/**
 * External system or infrastructure failure.
 * Use in adapters when calling databases, APIs, etc.
 */
export class InfrastructureError extends DomainError {
  readonly code = 'INFRASTRUCTURE_ERROR';
  readonly statusCode = 500;
  readonly cause?: Error;

  constructor(message: string, cause?: Error) {
    super(message);
    this.cause = cause;
  }
}

// =============================================================================
// Error Type Guards
// =============================================================================

export function isDomainError(error: unknown): error is DomainError {
  return error instanceof DomainError;
}

export function isNotFoundError(error: unknown): error is NotFoundError {
  return error instanceof NotFoundError;
}

export function isValidationError(error: unknown): error is ValidationError {
  return error instanceof ValidationError;
}

export function isAuthorizationError(error: unknown): error is AuthorizationError {
  return error instanceof AuthorizationError;
}

export function isConflictError(error: unknown): error is ConflictError {
  return error instanceof ConflictError;
}
