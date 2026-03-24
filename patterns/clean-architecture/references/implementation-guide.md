# Clean Architecture Implementation Guide

## Table of Contents

- [TypeScript/Node.js with Express](#typescriptnodejs-with-express)
  - [Project Structure](#ts-project-structure)
  - [Dependency Injection Setup](#ts-dependency-injection)
  - [Repository Implementations](#ts-repositories)
  - [Use Case Orchestration](#ts-use-cases)
  - [Error Propagation](#ts-error-propagation)
  - [API Controller Wiring](#ts-controllers)
- [Python with FastAPI](#python-with-fastapi)
  - [Project Structure](#py-project-structure)
  - [Dependency Injection Setup](#py-dependency-injection)
  - [Repository Implementations](#py-repositories)
  - [Use Case Orchestration](#py-use-cases)
  - [Error Propagation](#py-error-propagation)
  - [API Controller Wiring](#py-controllers)
- [Go with Standard Library](#go-with-standard-library)
  - [Project Structure](#go-project-structure)
  - [Dependency Injection Setup](#go-dependency-injection)
  - [Repository Implementations](#go-repositories)
  - [Use Case Orchestration](#go-use-cases)
  - [Error Propagation](#go-error-propagation)
  - [API Controller Wiring](#go-controllers)

---

## TypeScript/Node.js with Express

### <a name="ts-project-structure"></a>Project Structure

```
project-root/
├── src/
│   ├── domain/
│   │   ├── entities/
│   │   │   ├── User.ts
│   │   │   └── Order.ts
│   │   ├── value-objects/
│   │   │   ├── Email.ts
│   │   │   ├── Money.ts
│   │   │   └── UserId.ts
│   │   ├── repositories/
│   │   │   ├── IUserRepository.ts
│   │   │   └── IOrderRepository.ts
│   │   ├── services/
│   │   │   └── IPasswordHasher.ts
│   │   └── errors/
│   │       ├── DomainError.ts
│   │       ├── NotFoundError.ts
│   │       ├── ValidationError.ts
│   │       └── AuthorizationError.ts
│   ├── application/
│   │   ├── use-cases/
│   │   │   ├── users/
│   │   │   │   ├── CreateUserUseCase.ts
│   │   │   │   ├── GetUserUseCase.ts
│   │   │   │   ├── UpdateUserUseCase.ts
│   │   │   │   └── DeleteUserUseCase.ts
│   │   │   └── orders/
│   │   │       ├── CreateOrderUseCase.ts
│   │   │       └── GetOrderUseCase.ts
│   │   └── dto/
│   │       ├── CreateUserRequest.ts
│   │       ├── CreateUserResponse.ts
│   │       ├── CreateOrderRequest.ts
│   │       └── CreateOrderResponse.ts
│   ├── infrastructure/
│   │   ├── persistence/
│   │   │   ├── PostgresUserRepository.ts
│   │   │   ├── PostgresOrderRepository.ts
│   │   │   ├── InMemoryUserRepository.ts
│   │   │   └── InMemoryOrderRepository.ts
│   │   ├── services/
│   │   │   └── BcryptPasswordHasher.ts
│   │   ├── config/
│   │   │   ├── database.ts
│   │   │   └── env.ts
│   │   └── di/
│   │       └── container.ts
│   ├── presentation/
│   │   ├── http/
│   │   │   ├── controllers/
│   │   │   │   ├── UserController.ts
│   │   │   │   └── OrderController.ts
│   │   │   ├── middleware/
│   │   │   │   ├── errorHandler.ts
│   │   │   │   └── validation.ts
│   │   │   └── routes/
│   │   │       ├── userRoutes.ts
│   │   │       └── orderRoutes.ts
│   │   └── presenters/
│   │       └── UserPresenter.ts
│   └── main.ts
├── tests/
│   ├── unit/
│   │   ├── domain/
│   │   │   └── entities/
│   │   └── application/
│   │       └── use-cases/
│   └── integration/
│       └── infrastructure/
│           └── persistence/
├── package.json
├── tsconfig.json
└── Makefile
```

### <a name="ts-dependency-injection"></a>Dependency Injection Setup

```typescript
// src/infrastructure/di/container.ts
// Manual wiring — no DI framework needed for small/medium projects

import { Pool } from 'pg';
import { PostgresUserRepository } from '../persistence/PostgresUserRepository';
import { PostgresOrderRepository } from '../persistence/PostgresOrderRepository';
import { BcryptPasswordHasher } from '../services/BcryptPasswordHasher';
import { CreateUserUseCase } from '../../application/use-cases/users/CreateUserUseCase';
import { GetUserUseCase } from '../../application/use-cases/users/GetUserUseCase';
import { UpdateUserUseCase } from '../../application/use-cases/users/UpdateUserUseCase';
import { DeleteUserUseCase } from '../../application/use-cases/users/DeleteUserUseCase';
import { UserController } from '../../presentation/http/controllers/UserController';

export interface Container {
  userController: UserController;
  orderController: OrderController;
}

export function createContainer(config: AppConfig): Container {
  // Infrastructure
  const pool = new Pool({
    host: config.db.host,
    port: config.db.port,
    database: config.db.name,
    user: config.db.user,
    password: config.db.password,
  });

  // Repositories
  const userRepo = new PostgresUserRepository(pool);
  const orderRepo = new PostgresOrderRepository(pool);

  // Services
  const passwordHasher = new BcryptPasswordHasher();

  // Use Cases
  const createUser = new CreateUserUseCase(userRepo, passwordHasher);
  const getUser = new GetUserUseCase(userRepo);
  const updateUser = new UpdateUserUseCase(userRepo);
  const deleteUser = new DeleteUserUseCase(userRepo);

  // Controllers
  const userController = new UserController(createUser, getUser, updateUser, deleteUser);
  const orderController = new OrderController(/* ... */);

  return { userController, orderController };
}

// src/main.ts
import express from 'express';
import { createContainer } from './infrastructure/di/container';
import { loadConfig } from './infrastructure/config/env';
import { errorHandler } from './presentation/http/middleware/errorHandler';
import { createUserRoutes } from './presentation/http/routes/userRoutes';

async function main(): Promise<void> {
  const config = loadConfig();
  const container = createContainer(config);

  const app = express();
  app.use(express.json());

  // Register routes
  app.use('/api/users', createUserRoutes(container.userController));
  app.use('/api/orders', createOrderRoutes(container.orderController));

  // Global error handler — MUST be last middleware
  app.use(errorHandler);

  app.listen(config.port, () => {
    console.log(`Server running on port ${config.port}`);
  });
}

main().catch(console.error);
```

### <a name="ts-repositories"></a>Repository Implementations

```typescript
// domain/repositories/IUserRepository.ts
export interface IUserRepository {
  findById(id: string): Promise<User | null>;
  findByEmail(email: Email): Promise<User | null>;
  save(user: User): Promise<void>;
  delete(id: string): Promise<void>;
  exists(email: Email): Promise<boolean>;
}

// infrastructure/persistence/PostgresUserRepository.ts
import { Pool } from 'pg';
import { IUserRepository } from '../../domain/repositories/IUserRepository';
import { User } from '../../domain/entities/User';
import { Email } from '../../domain/value-objects/Email';

export class PostgresUserRepository implements IUserRepository {
  constructor(private readonly pool: Pool) {}

  async findById(id: string): Promise<User | null> {
    const { rows } = await this.pool.query(
      'SELECT id, email, name, password_hash, created_at, updated_at FROM users WHERE id = $1',
      [id]
    );
    if (rows.length === 0) return null;
    return this.toDomain(rows[0]);
  }

  async findByEmail(email: Email): Promise<User | null> {
    const { rows } = await this.pool.query(
      'SELECT id, email, name, password_hash, created_at, updated_at FROM users WHERE email = $1',
      [email.value]
    );
    if (rows.length === 0) return null;
    return this.toDomain(rows[0]);
  }

  async save(user: User): Promise<void> {
    await this.pool.query(
      `INSERT INTO users (id, email, name, password_hash, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (id) DO UPDATE SET
         email = EXCLUDED.email,
         name = EXCLUDED.name,
         password_hash = EXCLUDED.password_hash,
         updated_at = EXCLUDED.updated_at`,
      [user.id, user.email.value, user.name, user.passwordHash, user.createdAt, user.updatedAt]
    );
  }

  async delete(id: string): Promise<void> {
    await this.pool.query('DELETE FROM users WHERE id = $1', [id]);
  }

  async exists(email: Email): Promise<boolean> {
    const { rows } = await this.pool.query(
      'SELECT 1 FROM users WHERE email = $1 LIMIT 1',
      [email.value]
    );
    return rows.length > 0;
  }

  private toDomain(row: any): User {
    return User.reconstitute({
      id: row.id,
      email: Email.create(row.email),
      name: row.name,
      passwordHash: row.password_hash,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });
  }
}

// infrastructure/persistence/InMemoryUserRepository.ts
export class InMemoryUserRepository implements IUserRepository {
  private users = new Map<string, User>();

  async findById(id: string): Promise<User | null> {
    return this.users.get(id) ?? null;
  }

  async findByEmail(email: Email): Promise<User | null> {
    for (const user of this.users.values()) {
      if (user.email.equals(email)) return user;
    }
    return null;
  }

  async save(user: User): Promise<void> {
    this.users.set(user.id, user);
  }

  async delete(id: string): Promise<void> {
    this.users.delete(id);
  }

  async exists(email: Email): Promise<boolean> {
    return (await this.findByEmail(email)) !== null;
  }

  // Test helper
  clear(): void {
    this.users.clear();
  }
}
```

### <a name="ts-use-cases"></a>Use Case Orchestration

```typescript
// application/use-cases/users/CreateUserUseCase.ts
import { IUserRepository } from '../../../domain/repositories/IUserRepository';
import { IPasswordHasher } from '../../../domain/services/IPasswordHasher';
import { User } from '../../../domain/entities/User';
import { Email } from '../../../domain/value-objects/Email';
import { ConflictError } from '../../../domain/errors/ConflictError';

export interface CreateUserRequest {
  email: string;
  name: string;
  password: string;
}

export interface CreateUserResponse {
  id: string;
  email: string;
  name: string;
  createdAt: Date;
}

export class CreateUserUseCase {
  constructor(
    private readonly userRepo: IUserRepository,
    private readonly passwordHasher: IPasswordHasher
  ) {}

  async execute(request: CreateUserRequest): Promise<CreateUserResponse> {
    const email = Email.create(request.email); // Throws ValidationError if invalid

    const exists = await this.userRepo.exists(email);
    if (exists) {
      throw new ConflictError('User', 'email', request.email);
    }

    const passwordHash = await this.passwordHasher.hash(request.password);
    const user = User.create({
      email,
      name: request.name,
      passwordHash,
    });

    await this.userRepo.save(user);

    return {
      id: user.id,
      email: user.email.value,
      name: user.name,
      createdAt: user.createdAt,
    };
  }
}
```

### <a name="ts-error-propagation"></a>Error Propagation

```typescript
// domain/errors/DomainError.ts
export abstract class DomainError extends Error {
  abstract readonly code: string;
  abstract readonly statusCode: number;
}

// domain/errors/NotFoundError.ts
export class NotFoundError extends DomainError {
  readonly code = 'NOT_FOUND';
  readonly statusCode = 404;

  constructor(entity: string, field: string, value: string) {
    super(`${entity} with ${field} "${value}" not found`);
  }
}

// domain/errors/ValidationError.ts
export class ValidationError extends DomainError {
  readonly code = 'VALIDATION_ERROR';
  readonly statusCode = 422;

  constructor(public readonly field: string, message: string) {
    super(message);
  }
}

// domain/errors/AuthorizationError.ts
export class AuthorizationError extends DomainError {
  readonly code = 'UNAUTHORIZED';
  readonly statusCode = 403;

  constructor(action: string, resource: string) {
    super(`Not authorized to ${action} ${resource}`);
  }
}

// domain/errors/ConflictError.ts
export class ConflictError extends DomainError {
  readonly code = 'CONFLICT';
  readonly statusCode = 409;

  constructor(entity: string, field: string, value: string) {
    super(`${entity} with ${field} "${value}" already exists`);
  }
}

// presentation/http/middleware/errorHandler.ts
import { Request, Response, NextFunction } from 'express';
import { DomainError } from '../../../domain/errors/DomainError';

export function errorHandler(err: Error, _req: Request, res: Response, _next: NextFunction): void {
  if (err instanceof DomainError) {
    res.status(err.statusCode).json({
      error: {
        code: err.code,
        message: err.message,
      },
    });
    return;
  }

  // Unexpected error — log and return generic 500
  console.error('Unhandled error:', err);
  res.status(500).json({
    error: {
      code: 'INTERNAL_ERROR',
      message: 'An unexpected error occurred',
    },
  });
}
```

### <a name="ts-controllers"></a>API Controller Wiring

```typescript
// presentation/http/controllers/UserController.ts
import { Request, Response, NextFunction } from 'express';
import { CreateUserUseCase } from '../../../application/use-cases/users/CreateUserUseCase';
import { GetUserUseCase } from '../../../application/use-cases/users/GetUserUseCase';

export class UserController {
  constructor(
    private readonly createUser: CreateUserUseCase,
    private readonly getUser: GetUserUseCase,
    private readonly updateUser: UpdateUserUseCase,
    private readonly deleteUser: DeleteUserUseCase
  ) {}

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await this.createUser.execute({
        email: req.body.email,
        name: req.body.name,
        password: req.body.password,
      });
      res.status(201).json(result);
    } catch (err) {
      next(err); // Forward to errorHandler middleware
    }
  }

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await this.getUser.execute({ id: req.params.id });
      res.status(200).json(result);
    } catch (err) {
      next(err);
    }
  }

  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await this.updateUser.execute({
        id: req.params.id,
        name: req.body.name,
        email: req.body.email,
      });
      res.status(200).json(result);
    } catch (err) {
      next(err);
    }
  }

  async remove(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      await this.deleteUser.execute({ id: req.params.id });
      res.status(204).send();
    } catch (err) {
      next(err);
    }
  }
}

// presentation/http/routes/userRoutes.ts
import { Router } from 'express';
import { UserController } from '../controllers/UserController';

export function createUserRoutes(controller: UserController): Router {
  const router = Router();
  router.post('/', (req, res, next) => controller.create(req, res, next));
  router.get('/:id', (req, res, next) => controller.getById(req, res, next));
  router.put('/:id', (req, res, next) => controller.update(req, res, next));
  router.delete('/:id', (req, res, next) => controller.remove(req, res, next));
  return router;
}
```

---

## Python with FastAPI

### <a name="py-project-structure"></a>Project Structure

```
project-root/
├── src/
│   ├── domain/
│   │   ├── __init__.py
│   │   ├── entities/
│   │   │   ├── __init__.py
│   │   │   ├── user.py
│   │   │   └── order.py
│   │   ├── value_objects/
│   │   │   ├── __init__.py
│   │   │   ├── email.py
│   │   │   └── money.py
│   │   ├── repositories/
│   │   │   ├── __init__.py
│   │   │   ├── user_repository.py
│   │   │   └── order_repository.py
│   │   └── errors.py
│   ├── application/
│   │   ├── __init__.py
│   │   ├── use_cases/
│   │   │   ├── __init__.py
│   │   │   ├── create_user.py
│   │   │   ├── get_user.py
│   │   │   ├── update_user.py
│   │   │   └── delete_user.py
│   │   └── dto/
│   │       ├── __init__.py
│   │       ├── user_dto.py
│   │       └── order_dto.py
│   ├── infrastructure/
│   │   ├── __init__.py
│   │   ├── persistence/
│   │   │   ├── __init__.py
│   │   │   ├── postgres_user_repository.py
│   │   │   ├── in_memory_user_repository.py
│   │   │   └── database.py
│   │   ├── services/
│   │   │   └── bcrypt_password_hasher.py
│   │   └── config.py
│   ├── presentation/
│   │   ├── __init__.py
│   │   ├── api/
│   │   │   ├── __init__.py
│   │   │   ├── user_router.py
│   │   │   └── order_router.py
│   │   ├── middleware/
│   │   │   └── error_handler.py
│   │   └── dependencies.py
│   └── main.py
├── tests/
│   ├── unit/
│   │   └── ...
│   └── integration/
│       └── ...
├── requirements.txt
├── pyproject.toml
└── Makefile
```

### <a name="py-dependency-injection"></a>Dependency Injection Setup

```python
# src/infrastructure/config.py
from dataclasses import dataclass
import os

@dataclass(frozen=True)
class DatabaseConfig:
    host: str
    port: int
    name: str
    user: str
    password: str

    @classmethod
    def from_env(cls) -> "DatabaseConfig":
        return cls(
            host=os.environ.get("DB_HOST", "localhost"),
            port=int(os.environ.get("DB_PORT", "5432")),
            name=os.environ.get("DB_NAME", "app"),
            user=os.environ.get("DB_USER", "postgres"),
            password=os.environ.get("DB_PASSWORD", ""),
        )

    @property
    def dsn(self) -> str:
        return f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.name}"


# src/presentation/dependencies.py — FastAPI dependency injection
from functools import lru_cache
from fastapi import Depends
import asyncpg

from src.infrastructure.config import DatabaseConfig
from src.infrastructure.persistence.postgres_user_repository import PostgresUserRepository
from src.infrastructure.services.bcrypt_password_hasher import BcryptPasswordHasher
from src.application.use_cases.create_user import CreateUserUseCase
from src.application.use_cases.get_user import GetUserUseCase

_pool: asyncpg.Pool | None = None

async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        config = DatabaseConfig.from_env()
        _pool = await asyncpg.create_pool(config.dsn)
    return _pool

async def get_user_repository(pool: asyncpg.Pool = Depends(get_pool)) -> PostgresUserRepository:
    return PostgresUserRepository(pool)

def get_password_hasher() -> BcryptPasswordHasher:
    return BcryptPasswordHasher()

async def get_create_user_use_case(
    repo: PostgresUserRepository = Depends(get_user_repository),
    hasher: BcryptPasswordHasher = Depends(get_password_hasher),
) -> CreateUserUseCase:
    return CreateUserUseCase(repo, hasher)

async def get_get_user_use_case(
    repo: PostgresUserRepository = Depends(get_user_repository),
) -> GetUserUseCase:
    return GetUserUseCase(repo)


# src/main.py
from fastapi import FastAPI
from src.presentation.api.user_router import user_router
from src.presentation.api.order_router import order_router
from src.presentation.middleware.error_handler import add_error_handlers

def create_app() -> FastAPI:
    app = FastAPI(title="Clean Architecture App")
    add_error_handlers(app)
    app.include_router(user_router, prefix="/api/users", tags=["users"])
    app.include_router(order_router, prefix="/api/orders", tags=["orders"])
    return app

app = create_app()
```

### <a name="py-repositories"></a>Repository Implementations

```python
# src/domain/repositories/user_repository.py
from abc import ABC, abstractmethod
from src.domain.entities.user import User
from src.domain.value_objects.email import Email

class UserRepository(ABC):
    @abstractmethod
    async def find_by_id(self, user_id: str) -> User | None: ...

    @abstractmethod
    async def find_by_email(self, email: Email) -> User | None: ...

    @abstractmethod
    async def save(self, user: User) -> None: ...

    @abstractmethod
    async def delete(self, user_id: str) -> None: ...

    @abstractmethod
    async def exists(self, email: Email) -> bool: ...


# src/infrastructure/persistence/postgres_user_repository.py
import asyncpg
from src.domain.entities.user import User
from src.domain.value_objects.email import Email
from src.domain.repositories.user_repository import UserRepository

class PostgresUserRepository(UserRepository):
    def __init__(self, pool: asyncpg.Pool):
        self._pool = pool

    async def find_by_id(self, user_id: str) -> User | None:
        row = await self._pool.fetchrow(
            "SELECT id, email, name, password_hash, created_at, updated_at "
            "FROM users WHERE id = $1",
            user_id,
        )
        if row is None:
            return None
        return self._to_domain(row)

    async def find_by_email(self, email: Email) -> User | None:
        row = await self._pool.fetchrow(
            "SELECT id, email, name, password_hash, created_at, updated_at "
            "FROM users WHERE email = $1",
            email.value,
        )
        if row is None:
            return None
        return self._to_domain(row)

    async def save(self, user: User) -> None:
        await self._pool.execute(
            """INSERT INTO users (id, email, name, password_hash, created_at, updated_at)
               VALUES ($1, $2, $3, $4, $5, $6)
               ON CONFLICT (id) DO UPDATE SET
                 email = EXCLUDED.email,
                 name = EXCLUDED.name,
                 password_hash = EXCLUDED.password_hash,
                 updated_at = EXCLUDED.updated_at""",
            user.id, user.email.value, user.name, user.password_hash,
            user.created_at, user.updated_at,
        )

    async def delete(self, user_id: str) -> None:
        await self._pool.execute("DELETE FROM users WHERE id = $1", user_id)

    async def exists(self, email: Email) -> bool:
        row = await self._pool.fetchrow(
            "SELECT 1 FROM users WHERE email = $1 LIMIT 1", email.value
        )
        return row is not None

    def _to_domain(self, row: asyncpg.Record) -> User:
        return User.reconstitute(
            id=row["id"],
            email=Email(row["email"]),
            name=row["name"],
            password_hash=row["password_hash"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )


# src/infrastructure/persistence/in_memory_user_repository.py
class InMemoryUserRepository(UserRepository):
    def __init__(self):
        self._users: dict[str, User] = {}

    async def find_by_id(self, user_id: str) -> User | None:
        return self._users.get(user_id)

    async def find_by_email(self, email: Email) -> User | None:
        return next((u for u in self._users.values() if u.email == email), None)

    async def save(self, user: User) -> None:
        self._users[user.id] = user

    async def delete(self, user_id: str) -> None:
        self._users.pop(user_id, None)

    async def exists(self, email: Email) -> bool:
        return await self.find_by_email(email) is not None

    def clear(self) -> None:
        self._users.clear()
```

### <a name="py-use-cases"></a>Use Case Orchestration

```python
# src/application/dto/user_dto.py
from dataclasses import dataclass
from datetime import datetime

@dataclass(frozen=True)
class CreateUserRequest:
    email: str
    name: str
    password: str

@dataclass(frozen=True)
class CreateUserResponse:
    id: str
    email: str
    name: str
    created_at: datetime

@dataclass(frozen=True)
class GetUserRequest:
    id: str

@dataclass(frozen=True)
class GetUserResponse:
    id: str
    email: str
    name: str
    created_at: datetime


# src/application/use_cases/create_user.py
from src.domain.entities.user import User
from src.domain.value_objects.email import Email
from src.domain.repositories.user_repository import UserRepository
from src.domain.errors import ConflictError
from src.application.dto.user_dto import CreateUserRequest, CreateUserResponse

class CreateUserUseCase:
    def __init__(self, user_repo: UserRepository, password_hasher):
        self._repo = user_repo
        self._hasher = password_hasher

    async def execute(self, request: CreateUserRequest) -> CreateUserResponse:
        email = Email(request.email)  # Raises ValidationError if invalid

        if await self._repo.exists(email):
            raise ConflictError("User", "email", request.email)

        password_hash = self._hasher.hash(request.password)
        user = User.create(email=email, name=request.name, password_hash=password_hash)
        await self._repo.save(user)

        return CreateUserResponse(
            id=user.id,
            email=user.email.value,
            name=user.name,
            created_at=user.created_at,
        )
```

### <a name="py-error-propagation"></a>Error Propagation

```python
# src/domain/errors.py
class DomainError(Exception):
    def __init__(self, message: str, code: str, status_code: int = 400):
        super().__init__(message)
        self.code = code
        self.status_code = status_code

class NotFoundError(DomainError):
    def __init__(self, entity: str, field: str, value: str):
        super().__init__(
            f'{entity} with {field} "{value}" not found',
            code="NOT_FOUND",
            status_code=404,
        )

class ValidationError(DomainError):
    def __init__(self, field: str, message: str):
        super().__init__(message, code="VALIDATION_ERROR", status_code=422)
        self.field = field

class AuthorizationError(DomainError):
    def __init__(self, action: str, resource: str):
        super().__init__(
            f"Not authorized to {action} {resource}",
            code="UNAUTHORIZED",
            status_code=403,
        )

class ConflictError(DomainError):
    def __init__(self, entity: str, field: str, value: str):
        super().__init__(
            f'{entity} with {field} "{value}" already exists',
            code="CONFLICT",
            status_code=409,
        )


# src/presentation/middleware/error_handler.py
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from src.domain.errors import DomainError

def add_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def domain_error_handler(_request: Request, exc: DomainError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": {"code": exc.code, "message": str(exc)}},
        )

    @app.exception_handler(Exception)
    async def generic_error_handler(_request: Request, exc: Exception) -> JSONResponse:
        return JSONResponse(
            status_code=500,
            content={"error": {"code": "INTERNAL_ERROR", "message": "An unexpected error occurred"}},
        )
```

### <a name="py-controllers"></a>API Controller Wiring

```python
# src/presentation/api/user_router.py
from fastapi import APIRouter, Depends, status
from src.application.use_cases.create_user import CreateUserUseCase
from src.application.use_cases.get_user import GetUserUseCase
from src.application.dto.user_dto import CreateUserRequest
from src.presentation.dependencies import get_create_user_use_case, get_get_user_use_case
from pydantic import BaseModel

user_router = APIRouter()

class CreateUserBody(BaseModel):
    email: str
    name: str
    password: str

class UserResponse(BaseModel):
    id: str
    email: str
    name: str
    created_at: str

@user_router.post("/", status_code=status.HTTP_201_CREATED, response_model=UserResponse)
async def create_user(
    body: CreateUserBody,
    use_case: CreateUserUseCase = Depends(get_create_user_use_case),
):
    result = await use_case.execute(
        CreateUserRequest(email=body.email, name=body.name, password=body.password)
    )
    return UserResponse(
        id=result.id,
        email=result.email,
        name=result.name,
        created_at=result.created_at.isoformat(),
    )

@user_router.get("/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: str,
    use_case: GetUserUseCase = Depends(get_get_user_use_case),
):
    result = await use_case.execute(GetUserRequest(id=user_id))
    return UserResponse(
        id=result.id,
        email=result.email,
        name=result.name,
        created_at=result.created_at.isoformat(),
    )
```

---

## Go with Standard Library

### <a name="go-project-structure"></a>Project Structure

```
project-root/
├── cmd/
│   └── api/
│       └── main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── user.go
│   │   │   └── order.go
│   │   ├── valueobject/
│   │   │   ├── email.go
│   │   │   └── money.go
│   │   ├── repository/
│   │   │   ├── user_repository.go
│   │   │   └── order_repository.go
│   │   ├── service/
│   │   │   └── password_hasher.go
│   │   └── domainerror/
│   │       └── errors.go
│   ├── usecase/
│   │   ├── create_user.go
│   │   ├── get_user.go
│   │   ├── update_user.go
│   │   └── delete_user.go
│   ├── adapter/
│   │   ├── handler/
│   │   │   ├── user_handler.go
│   │   │   └── order_handler.go
│   │   └── repository/
│   │       ├── postgres_user_repo.go
│   │       └── inmemory_user_repo.go
│   └── infrastructure/
│       ├── db/
│       │   └── postgres.go
│       ├── config/
│       │   └── config.go
│       └── service/
│           └── bcrypt_hasher.go
├── go.mod
├── go.sum
└── Makefile
```

### <a name="go-dependency-injection"></a>Dependency Injection Setup

```go
// cmd/api/main.go
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"

	"myapp/internal/adapter/handler"
	"myapp/internal/adapter/repository"
	"myapp/internal/infrastructure/config"
	"myapp/internal/infrastructure/db"
	"myapp/internal/infrastructure/service"
	"myapp/internal/usecase"
)

func main() {
	cfg := config.Load()

	pool, err := db.NewPostgresPool(context.Background(), cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer pool.Close()

	// Repositories
	userRepo := repository.NewPostgresUserRepository(pool)

	// Services
	passwordHasher := service.NewBcryptHasher()

	// Use Cases
	createUser := usecase.NewCreateUserUseCase(userRepo, passwordHasher)
	getUser := usecase.NewGetUserUseCase(userRepo)
	updateUser := usecase.NewUpdateUserUseCase(userRepo)
	deleteUser := usecase.NewDeleteUserUseCase(userRepo)

	// Handlers
	userHandler := handler.NewUserHandler(createUser, getUser, updateUser, deleteUser)

	// Router
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/users", userHandler.Create)
	mux.HandleFunc("GET /api/users/{id}", userHandler.GetByID)
	mux.HandleFunc("PUT /api/users/{id}", userHandler.Update)
	mux.HandleFunc("DELETE /api/users/{id}", userHandler.Delete)

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("Server starting on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
```

### <a name="go-repositories"></a>Repository Implementations

```go
// internal/domain/repository/user_repository.go
package repository

import (
	"context"
	"myapp/internal/domain/entity"
	"myapp/internal/domain/valueobject"
)

type UserRepository interface {
	FindByID(ctx context.Context, id string) (*entity.User, error)
	FindByEmail(ctx context.Context, email valueobject.Email) (*entity.User, error)
	Save(ctx context.Context, user *entity.User) error
	Delete(ctx context.Context, id string) error
	Exists(ctx context.Context, email valueobject.Email) (bool, error)
}


// internal/adapter/repository/postgres_user_repo.go
package repository

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"myapp/internal/domain/entity"
	"myapp/internal/domain/valueobject"
)

type PostgresUserRepository struct {
	pool *pgxpool.Pool
}

func NewPostgresUserRepository(pool *pgxpool.Pool) *PostgresUserRepository {
	return &PostgresUserRepository{pool: pool}
}

func (r *PostgresUserRepository) FindByID(ctx context.Context, id string) (*entity.User, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT id, email, name, password_hash, created_at, updated_at
		 FROM users WHERE id = $1`, id)

	return r.scanUser(row)
}

func (r *PostgresUserRepository) FindByEmail(ctx context.Context, email valueobject.Email) (*entity.User, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT id, email, name, password_hash, created_at, updated_at
		 FROM users WHERE email = $1`, email.Value())

	return r.scanUser(row)
}

func (r *PostgresUserRepository) Save(ctx context.Context, user *entity.User) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO users (id, email, name, password_hash, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 ON CONFLICT (id) DO UPDATE SET
		   email = EXCLUDED.email,
		   name = EXCLUDED.name,
		   password_hash = EXCLUDED.password_hash,
		   updated_at = EXCLUDED.updated_at`,
		user.ID, user.Email.Value(), user.Name, user.PasswordHash,
		user.CreatedAt, user.UpdatedAt)
	return err
}

func (r *PostgresUserRepository) Delete(ctx context.Context, id string) error {
	_, err := r.pool.Exec(ctx, "DELETE FROM users WHERE id = $1", id)
	return err
}

func (r *PostgresUserRepository) Exists(ctx context.Context, email valueobject.Email) (bool, error) {
	var exists bool
	err := r.pool.QueryRow(ctx,
		"SELECT EXISTS(SELECT 1 FROM users WHERE email = $1)", email.Value()).Scan(&exists)
	return exists, err
}

func (r *PostgresUserRepository) scanUser(row pgx.Row) (*entity.User, error) {
	var emailStr string
	user := &entity.User{}
	err := row.Scan(&user.ID, &emailStr, &user.Name, &user.PasswordHash,
		&user.CreatedAt, &user.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	email, err := valueobject.NewEmail(emailStr)
	if err != nil {
		return nil, err
	}
	user.Email = email
	return user, nil
}


// internal/adapter/repository/inmemory_user_repo.go
package repository

import (
	"context"
	"sync"
	"myapp/internal/domain/entity"
	"myapp/internal/domain/valueobject"
)

type InMemoryUserRepository struct {
	mu    sync.RWMutex
	users map[string]*entity.User
}

func NewInMemoryUserRepository() *InMemoryUserRepository {
	return &InMemoryUserRepository{users: make(map[string]*entity.User)}
}

func (r *InMemoryUserRepository) FindByID(_ context.Context, id string) (*entity.User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	user, ok := r.users[id]
	if !ok {
		return nil, nil
	}
	return user, nil
}

func (r *InMemoryUserRepository) FindByEmail(_ context.Context, email valueobject.Email) (*entity.User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, u := range r.users {
		if u.Email.Value() == email.Value() {
			return u, nil
		}
	}
	return nil, nil
}

func (r *InMemoryUserRepository) Save(_ context.Context, user *entity.User) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.users[user.ID] = user
	return nil
}

func (r *InMemoryUserRepository) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.users, id)
	return nil
}

func (r *InMemoryUserRepository) Exists(_ context.Context, email valueobject.Email) (bool, error) {
	u, err := r.FindByEmail(context.Background(), email)
	return u != nil, err
}
```

### <a name="go-use-cases"></a>Use Case Orchestration

```go
// internal/usecase/create_user.go
package usecase

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"myapp/internal/domain/domainerror"
	"myapp/internal/domain/entity"
	"myapp/internal/domain/repository"
	"myapp/internal/domain/service"
	"myapp/internal/domain/valueobject"
)

type CreateUserRequest struct {
	Email    string
	Name     string
	Password string
}

type CreateUserResponse struct {
	ID        string
	Email     string
	Name      string
	CreatedAt time.Time
}

type CreateUserUseCase struct {
	repo   repository.UserRepository
	hasher service.PasswordHasher
}

func NewCreateUserUseCase(repo repository.UserRepository, hasher service.PasswordHasher) *CreateUserUseCase {
	return &CreateUserUseCase{repo: repo, hasher: hasher}
}

func (uc *CreateUserUseCase) Execute(ctx context.Context, req CreateUserRequest) (*CreateUserResponse, error) {
	email, err := valueobject.NewEmail(req.Email)
	if err != nil {
		return nil, fmt.Errorf("create user: %w", err)
	}

	exists, err := uc.repo.Exists(ctx, email)
	if err != nil {
		return nil, fmt.Errorf("create user: check exists: %w", err)
	}
	if exists {
		return nil, domainerror.NewConflictError("User", "email", req.Email)
	}

	hash, err := uc.hasher.Hash(req.Password)
	if err != nil {
		return nil, fmt.Errorf("create user: hash password: %w", err)
	}

	now := time.Now().UTC()
	user := &entity.User{
		ID:           uuid.New().String(),
		Email:        email,
		Name:         req.Name,
		PasswordHash: hash,
		CreatedAt:    now,
		UpdatedAt:    now,
	}

	if err := uc.repo.Save(ctx, user); err != nil {
		return nil, fmt.Errorf("create user: save: %w", err)
	}

	return &CreateUserResponse{
		ID:        user.ID,
		Email:     user.Email.Value(),
		Name:      user.Name,
		CreatedAt: user.CreatedAt,
	}, nil
}
```

### <a name="go-error-propagation"></a>Error Propagation

```go
// internal/domain/domainerror/errors.go
package domainerror

import "fmt"

type DomainError struct {
	Code       string
	Message    string
	StatusCode int
}

func (e *DomainError) Error() string {
	return e.Message
}

func NewNotFoundError(entity, field, value string) *DomainError {
	return &DomainError{
		Code:       "NOT_FOUND",
		Message:    fmt.Sprintf(`%s with %s "%s" not found`, entity, field, value),
		StatusCode: 404,
	}
}

func NewValidationError(field, message string) *DomainError {
	return &DomainError{
		Code:       "VALIDATION_ERROR",
		Message:    fmt.Sprintf("%s: %s", field, message),
		StatusCode: 422,
	}
}

func NewConflictError(entity, field, value string) *DomainError {
	return &DomainError{
		Code:       "CONFLICT",
		Message:    fmt.Sprintf(`%s with %s "%s" already exists`, entity, field, value),
		StatusCode: 409,
	}
}

func NewAuthorizationError(action, resource string) *DomainError {
	return &DomainError{
		Code:       "UNAUTHORIZED",
		Message:    fmt.Sprintf("not authorized to %s %s", action, resource),
		StatusCode: 403,
	}
}

// IsDomainError checks if an error is a DomainError and returns it
func IsDomainError(err error) (*DomainError, bool) {
	var de *DomainError
	if errors.As(err, &de) {
		return de, true
	}
	return nil, false
}
```

### <a name="go-controllers"></a>API Controller Wiring

```go
// internal/adapter/handler/user_handler.go
package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"myapp/internal/domain/domainerror"
	"myapp/internal/usecase"
)

type UserHandler struct {
	createUser *usecase.CreateUserUseCase
	getUser    *usecase.GetUserUseCase
	updateUser *usecase.UpdateUserUseCase
	deleteUser *usecase.DeleteUserUseCase
}

func NewUserHandler(
	create *usecase.CreateUserUseCase,
	get *usecase.GetUserUseCase,
	update *usecase.UpdateUserUseCase,
	del *usecase.DeleteUserUseCase,
) *UserHandler {
	return &UserHandler{
		createUser: create,
		getUser:    get,
		updateUser: update,
		deleteUser: del,
	}
}

func (h *UserHandler) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Name     string `json:"name"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "Invalid request body")
		return
	}

	result, err := h.createUser.Execute(r.Context(), usecase.CreateUserRequest{
		Email:    body.Email,
		Name:     body.Name,
		Password: body.Password,
	})
	if err != nil {
		handleError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, result)
}

func (h *UserHandler) GetByID(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	result, err := h.getUser.Execute(r.Context(), usecase.GetUserRequest{ID: id})
	if err != nil {
		handleError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// handleError maps domain errors to HTTP responses
func handleError(w http.ResponseWriter, err error) {
	if de, ok := domainerror.IsDomainError(err); ok {
		writeError(w, de.StatusCode, de.Code, de.Message)
		return
	}
	writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "An unexpected error occurred")
}

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
}
```
