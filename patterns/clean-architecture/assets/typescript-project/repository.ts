/**
 * Generic Repository interfaces for Clean Architecture.
 *
 * Define these in the domain layer. Implement in infrastructure.
 * One repository per aggregate root.
 *
 * Usage:
 *   // Domain layer — interface only
 *   export interface IOrderRepository extends IRepository<Order> {
 *     findByCustomerId(customerId: string): Promise<Order[]>;
 *   }
 *
 *   // Infrastructure layer — implementation
 *   export class PostgresOrderRepository implements IOrderRepository {
 *     // ... SQL implementation
 *   }
 */

/**
 * Base read-only repository. Use for query-side repositories in CQRS.
 */
export interface IReadRepository<T> {
  findById(id: string): Promise<T | null>;
  findAll(options?: PaginationOptions): Promise<PaginatedResult<T>>;
  exists(id: string): Promise<boolean>;
  count(): Promise<number>;
}

/**
 * Base write repository. Use for command-side repositories in CQRS.
 */
export interface IWriteRepository<T> {
  save(entity: T): Promise<void>;
  saveMany(entities: T[]): Promise<void>;
  delete(id: string): Promise<void>;
  deleteMany(ids: string[]): Promise<void>;
}

/**
 * Full CRUD repository. Combines read and write operations.
 * This is the most common repository interface.
 */
export interface IRepository<T> extends IReadRepository<T>, IWriteRepository<T> {}

/**
 * Pagination options for list queries.
 */
export interface PaginationOptions {
  page: number;
  pageSize: number;
  sortBy?: string;
  sortOrder?: 'asc' | 'desc';
}

/**
 * Paginated result wrapper.
 */
export interface PaginatedResult<T> {
  items: T[];
  total: number;
  page: number;
  pageSize: number;
  totalPages: number;
  hasNext: boolean;
  hasPrevious: boolean;
}

/**
 * Helper to create a PaginatedResult from items and total count.
 */
export function paginate<T>(
  items: T[],
  total: number,
  options: PaginationOptions
): PaginatedResult<T> {
  const totalPages = Math.ceil(total / options.pageSize);
  return {
    items,
    total,
    page: options.page,
    pageSize: options.pageSize,
    totalPages,
    hasNext: options.page < totalPages,
    hasPrevious: options.page > 1,
  };
}

/**
 * Unit of Work interface for transactional operations across aggregates.
 * Implement in infrastructure layer.
 */
export interface IUnitOfWork {
  begin(): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

/**
 * Transactional unit of work that provides repository access.
 * Use when a use case needs to save multiple aggregates atomically.
 *
 * Usage:
 *   const uow = uowFactory.create();
 *   try {
 *     await uow.begin();
 *     await uow.orderRepository.save(order);
 *     await uow.paymentRepository.save(payment);
 *     await uow.commit();
 *   } catch (e) {
 *     await uow.rollback();
 *     throw e;
 *   }
 */
export interface ITransactionalUnitOfWork extends IUnitOfWork {
  // Add typed repository accessors in your domain-specific interface:
  // readonly orderRepository: IOrderRepository;
  // readonly paymentRepository: IPaymentRepository;
}
