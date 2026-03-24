#!/usr/bin/env bash
# =============================================================================
# init-clean-project.sh — Scaffold a Clean Architecture project
#
# Usage:
#   ./init-clean-project.sh <language> <project-name>
#
# Languages: typescript | python | go
#
# Examples:
#   ./init-clean-project.sh typescript my-order-service
#   ./init-clean-project.sh python invoice-api
#   ./init-clean-project.sh go user-service
#
# Creates:
#   - Full folder structure with layer separation
#   - Base interfaces (repository, use case, entity)
#   - Example entity, use case, and repository implementation
#   - Makefile with common commands
# =============================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <language> <project-name>"
  echo "Languages: typescript | python | go"
  exit 1
fi

LANG="$1"
PROJECT="$2"

if [[ -d "$PROJECT" ]]; then
  echo "Error: Directory '$PROJECT' already exists."
  exit 1
fi

echo "🏗️  Scaffolding Clean Architecture project: $PROJECT ($LANG)"

# =============================================================================
# TypeScript
# =============================================================================
scaffold_typescript() {
  mkdir -p "$PROJECT"/{src/{domain/{entities,value-objects,repositories,services,errors},application/{use-cases/create-example,dto},infrastructure/{persistence,services,config,di},presentation/{http/{controllers,middleware,routes},presenters}},tests/{unit/{domain,application},integration}}

  # --- Base Entity ---
  cat > "$PROJECT/src/domain/entities/BaseEntity.ts" << 'EOF'
export abstract class BaseEntity {
  constructor(
    public readonly id: string,
    public readonly createdAt: Date = new Date(),
    public updatedAt: Date = new Date()
  ) {}

  equals(other: BaseEntity): boolean {
    return this.id === other.id;
  }
}
EOF

  # --- Example Entity ---
  cat > "$PROJECT/src/domain/entities/Example.ts" << 'EOF'
import { BaseEntity } from './BaseEntity';

export class Example extends BaseEntity {
  private constructor(
    id: string,
    public readonly name: string,
    public readonly description: string,
    createdAt?: Date,
    updatedAt?: Date
  ) {
    super(id, createdAt, updatedAt);
    if (!name || name.trim().length === 0) {
      throw new Error('Example name cannot be empty');
    }
  }

  static create(id: string, name: string, description: string): Example {
    return new Example(id, name, description);
  }

  static reconstitute(
    id: string, name: string, description: string,
    createdAt: Date, updatedAt: Date
  ): Example {
    return new Example(id, name, description, createdAt, updatedAt);
  }
}
EOF

  # --- Domain Errors ---
  cat > "$PROJECT/src/domain/errors/DomainError.ts" << 'EOF'
export abstract class DomainError extends Error {
  abstract readonly code: string;
  abstract readonly statusCode: number;
}

export class NotFoundError extends DomainError {
  readonly code = 'NOT_FOUND';
  readonly statusCode = 404;
  constructor(entity: string, id: string) {
    super(`${entity} with id "${id}" not found`);
  }
}

export class ValidationError extends DomainError {
  readonly code = 'VALIDATION_ERROR';
  readonly statusCode = 422;
  constructor(message: string) {
    super(message);
  }
}
EOF

  # --- Repository Interface ---
  cat > "$PROJECT/src/domain/repositories/IExampleRepository.ts" << 'EOF'
import { Example } from '../entities/Example';

export interface IExampleRepository {
  findById(id: string): Promise<Example | null>;
  findAll(): Promise<Example[]>;
  save(example: Example): Promise<void>;
  delete(id: string): Promise<void>;
}
EOF

  # --- Use Case ---
  cat > "$PROJECT/src/application/use-cases/create-example/CreateExampleUseCase.ts" << 'EOF'
import { IExampleRepository } from '../../../domain/repositories/IExampleRepository';
import { Example } from '../../../domain/entities/Example';

export interface CreateExampleRequest {
  name: string;
  description: string;
}

export interface CreateExampleResponse {
  id: string;
  name: string;
  description: string;
  createdAt: Date;
}

export class CreateExampleUseCase {
  constructor(
    private readonly repo: IExampleRepository,
    private readonly idGenerator: { generate(): string }
  ) {}

  async execute(request: CreateExampleRequest): Promise<CreateExampleResponse> {
    const example = Example.create(
      this.idGenerator.generate(),
      request.name,
      request.description
    );
    await this.repo.save(example);
    return {
      id: example.id,
      name: example.name,
      description: example.description,
      createdAt: example.createdAt,
    };
  }
}
EOF

  # --- In-Memory Repository ---
  cat > "$PROJECT/src/infrastructure/persistence/InMemoryExampleRepository.ts" << 'EOF'
import { IExampleRepository } from '../../domain/repositories/IExampleRepository';
import { Example } from '../../domain/entities/Example';

export class InMemoryExampleRepository implements IExampleRepository {
  private store = new Map<string, Example>();

  async findById(id: string): Promise<Example | null> {
    return this.store.get(id) ?? null;
  }

  async findAll(): Promise<Example[]> {
    return Array.from(this.store.values());
  }

  async save(example: Example): Promise<void> {
    this.store.set(example.id, example);
  }

  async delete(id: string): Promise<void> {
    this.store.delete(id);
  }
}
EOF

  # --- Controller ---
  cat > "$PROJECT/src/presentation/http/controllers/ExampleController.ts" << 'EOF'
import { Request, Response, NextFunction } from 'express';
import { CreateExampleUseCase } from '../../../application/use-cases/create-example/CreateExampleUseCase';

export class ExampleController {
  constructor(private readonly createExample: CreateExampleUseCase) {}

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await this.createExample.execute({
        name: req.body.name,
        description: req.body.description,
      });
      res.status(201).json(result);
    } catch (err) {
      next(err);
    }
  }
}
EOF

  # --- Error Handler Middleware ---
  cat > "$PROJECT/src/presentation/http/middleware/errorHandler.ts" << 'EOF'
import { Request, Response, NextFunction } from 'express';
import { DomainError } from '../../../domain/errors/DomainError';

export function errorHandler(
  err: Error, _req: Request, res: Response, _next: NextFunction
): void {
  if (err instanceof DomainError) {
    res.status(err.statusCode).json({
      error: { code: err.code, message: err.message },
    });
    return;
  }
  console.error('Unhandled error:', err);
  res.status(500).json({
    error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' },
  });
}
EOF

  # --- Main entry point ---
  cat > "$PROJECT/src/main.ts" << 'EOF'
import express from 'express';
import { InMemoryExampleRepository } from './infrastructure/persistence/InMemoryExampleRepository';
import { CreateExampleUseCase } from './application/use-cases/create-example/CreateExampleUseCase';
import { ExampleController } from './presentation/http/controllers/ExampleController';
import { errorHandler } from './presentation/http/middleware/errorHandler';
import { randomUUID } from 'crypto';

const repo = new InMemoryExampleRepository();
const createExample = new CreateExampleUseCase(repo, { generate: () => randomUUID() });
const controller = new ExampleController(createExample);

const app = express();
app.use(express.json());
app.post('/api/examples', (req, res, next) => controller.create(req, res, next));
app.use(errorHandler);

const PORT = process.env.PORT ?? 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
EOF

  # --- package.json ---
  cat > "$PROJECT/package.json" << EOF
{
  "name": "$PROJECT",
  "version": "1.0.0",
  "scripts": {
    "build": "tsc",
    "start": "node dist/main.js",
    "dev": "ts-node src/main.ts",
    "test": "jest",
    "lint": "eslint src/"
  },
  "dependencies": {
    "express": "^4.18.0"
  },
  "devDependencies": {
    "@types/express": "^4.17.0",
    "@types/node": "^20.0.0",
    "typescript": "^5.0.0",
    "ts-node": "^10.9.0",
    "jest": "^29.0.0",
    "ts-jest": "^29.0.0",
    "@types/jest": "^29.0.0"
  }
}
EOF

  # --- tsconfig.json ---
  cat > "$PROJECT/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "tests"]
}
EOF

  # --- Makefile ---
  cat > "$PROJECT/Makefile" << 'EOF'
.PHONY: install build start dev test lint clean

install:
	npm install

build:
	npm run build

start: build
	npm start

dev:
	npm run dev

test:
	npm test

lint:
	npm run lint

clean:
	rm -rf dist node_modules
EOF
}

# =============================================================================
# Python
# =============================================================================
scaffold_python() {
  mkdir -p "$PROJECT"/{src/{domain/{entities,value_objects,repositories,services},application/{use_cases,dto},infrastructure/{persistence,services,config},presentation/{api,middleware}},tests/{unit/{domain,application},integration}}

  # Create __init__.py files
  find "$PROJECT/src" -type d -exec touch {}/__init__.py \;
  find "$PROJECT/tests" -type d -exec touch {}/__init__.py \;

  # --- Base Entity ---
  cat > "$PROJECT/src/domain/entities/base.py" << 'EOF'
from dataclasses import dataclass, field
from datetime import datetime, timezone
import uuid

@dataclass
class BaseEntity:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def __eq__(self, other):
        if not isinstance(other, BaseEntity):
            return False
        return self.id == other.id

    def __hash__(self):
        return hash(self.id)
EOF

  # --- Example Entity ---
  cat > "$PROJECT/src/domain/entities/example.py" << 'EOF'
from dataclasses import dataclass
from src.domain.entities.base import BaseEntity
from src.domain.errors import ValidationError

@dataclass
class Example(BaseEntity):
    name: str = ""
    description: str = ""

    def __post_init__(self):
        if not self.name or not self.name.strip():
            raise ValidationError("name", "Example name cannot be empty")

    @classmethod
    def create(cls, name: str, description: str) -> "Example":
        return cls(name=name, description=description)
EOF

  # --- Domain Errors ---
  cat > "$PROJECT/src/domain/errors.py" << 'EOF'
class DomainError(Exception):
    def __init__(self, message: str, code: str, status_code: int = 400):
        super().__init__(message)
        self.code = code
        self.status_code = status_code

class NotFoundError(DomainError):
    def __init__(self, entity: str, id: str):
        super().__init__(f'{entity} with id "{id}" not found', "NOT_FOUND", 404)

class ValidationError(DomainError):
    def __init__(self, field: str, message: str):
        super().__init__(f"{field}: {message}", "VALIDATION_ERROR", 422)

class ConflictError(DomainError):
    def __init__(self, entity: str, field: str, value: str):
        super().__init__(f'{entity} with {field} "{value}" already exists', "CONFLICT", 409)
EOF

  # --- Repository Interface ---
  cat > "$PROJECT/src/domain/repositories/example_repository.py" << 'EOF'
from abc import ABC, abstractmethod
from src.domain.entities.example import Example

class ExampleRepository(ABC):
    @abstractmethod
    async def find_by_id(self, id: str) -> Example | None: ...

    @abstractmethod
    async def find_all(self) -> list[Example]: ...

    @abstractmethod
    async def save(self, example: Example) -> None: ...

    @abstractmethod
    async def delete(self, id: str) -> None: ...
EOF

  # --- Use Case ---
  cat > "$PROJECT/src/application/use_cases/create_example.py" << 'EOF'
from dataclasses import dataclass
from datetime import datetime
from src.domain.entities.example import Example
from src.domain.repositories.example_repository import ExampleRepository

@dataclass(frozen=True)
class CreateExampleRequest:
    name: str
    description: str

@dataclass(frozen=True)
class CreateExampleResponse:
    id: str
    name: str
    description: str
    created_at: datetime

class CreateExampleUseCase:
    def __init__(self, repo: ExampleRepository):
        self._repo = repo

    async def execute(self, request: CreateExampleRequest) -> CreateExampleResponse:
        example = Example.create(name=request.name, description=request.description)
        await self._repo.save(example)
        return CreateExampleResponse(
            id=example.id,
            name=example.name,
            description=example.description,
            created_at=example.created_at,
        )
EOF

  # --- In-Memory Repository ---
  cat > "$PROJECT/src/infrastructure/persistence/in_memory_example_repository.py" << 'EOF'
from src.domain.entities.example import Example
from src.domain.repositories.example_repository import ExampleRepository

class InMemoryExampleRepository(ExampleRepository):
    def __init__(self):
        self._store: dict[str, Example] = {}

    async def find_by_id(self, id: str) -> Example | None:
        return self._store.get(id)

    async def find_all(self) -> list[Example]:
        return list(self._store.values())

    async def save(self, example: Example) -> None:
        self._store[example.id] = example

    async def delete(self, id: str) -> None:
        self._store.pop(id, None)
EOF

  # --- FastAPI Router ---
  cat > "$PROJECT/src/presentation/api/example_router.py" << 'EOF'
from fastapi import APIRouter, Depends, status
from pydantic import BaseModel
from src.application.use_cases.create_example import CreateExampleUseCase, CreateExampleRequest

router = APIRouter()

class CreateExampleBody(BaseModel):
    name: str
    description: str

@router.post("/", status_code=status.HTTP_201_CREATED)
async def create_example(body: CreateExampleBody, use_case: CreateExampleUseCase = Depends()):
    result = await use_case.execute(
        CreateExampleRequest(name=body.name, description=body.description)
    )
    return {"id": result.id, "name": result.name, "description": result.description}
EOF

  # --- Main ---
  cat > "$PROJECT/src/main.py" << 'EOF'
from fastapi import FastAPI
from src.presentation.api.example_router import router as example_router

app = FastAPI(title="Clean Architecture App")
app.include_router(example_router, prefix="/api/examples", tags=["examples"])
EOF

  # --- requirements.txt ---
  cat > "$PROJECT/requirements.txt" << 'EOF'
fastapi>=0.100.0
uvicorn[standard]>=0.23.0
asyncpg>=0.28.0
pydantic>=2.0.0
pytest>=7.0.0
pytest-asyncio>=0.21.0
httpx>=0.24.0
EOF

  # --- Makefile ---
  cat > "$PROJECT/Makefile" << 'EOF'
.PHONY: install run dev test lint clean

install:
	pip install -r requirements.txt

run:
	uvicorn src.main:app --host 0.0.0.0 --port 8000

dev:
	uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload

test:
	pytest tests/ -v

lint:
	ruff check src/ tests/

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
EOF
}

# =============================================================================
# Go
# =============================================================================
scaffold_go() {
  mkdir -p "$PROJECT"/{cmd/api,internal/{domain/{entity,valueobject,repository,service,domainerror},usecase,adapter/{handler,repository},infrastructure/{db,config,service}},tests}

  # --- Base Entity ---
  cat > "$PROJECT/internal/domain/entity/base.go" << 'EOF'
package entity

import "time"

type BaseEntity struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
EOF

  # --- Example Entity ---
  cat > "$PROJECT/internal/domain/entity/example.go" << 'EOF'
package entity

import (
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Example struct {
	BaseEntity
	Name        string `json:"name"`
	Description string `json:"description"`
}

func NewExample(name, description string) (*Example, error) {
	if strings.TrimSpace(name) == "" {
		return nil, errors.New("example name cannot be empty")
	}
	now := time.Now().UTC()
	return &Example{
		BaseEntity: BaseEntity{
			ID:        uuid.New().String(),
			CreatedAt: now,
			UpdatedAt: now,
		},
		Name:        name,
		Description: description,
	}, nil
}
EOF

  # --- Domain Errors ---
  cat > "$PROJECT/internal/domain/domainerror/errors.go" << 'EOF'
package domainerror

import "fmt"

type DomainError struct {
	Code       string
	Message    string
	StatusCode int
}

func (e *DomainError) Error() string { return e.Message }

func NewNotFoundError(entity, id string) *DomainError {
	return &DomainError{
		Code:       "NOT_FOUND",
		Message:    fmt.Sprintf(`%s with id "%s" not found`, entity, id),
		StatusCode: 404,
	}
}

func NewValidationError(message string) *DomainError {
	return &DomainError{
		Code:       "VALIDATION_ERROR",
		Message:    message,
		StatusCode: 422,
	}
}
EOF

  # --- Repository Interface ---
  cat > "$PROJECT/internal/domain/repository/example_repository.go" << 'EOF'
package repository

import (
	"context"
	"MODNAME/internal/domain/entity"
)

type ExampleRepository interface {
	FindByID(ctx context.Context, id string) (*entity.Example, error)
	FindAll(ctx context.Context) ([]*entity.Example, error)
	Save(ctx context.Context, example *entity.Example) error
	Delete(ctx context.Context, id string) error
}
EOF
  sed -i "s|MODNAME|$PROJECT|g" "$PROJECT/internal/domain/repository/example_repository.go"

  # --- Use Case ---
  cat > "$PROJECT/internal/usecase/create_example.go" << 'EOF'
package usecase

import (
	"context"
	"fmt"

	"MODNAME/internal/domain/entity"
	"MODNAME/internal/domain/repository"
)

type CreateExampleRequest struct {
	Name        string
	Description string
}

type CreateExampleResponse struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

type CreateExampleUseCase struct {
	repo repository.ExampleRepository
}

func NewCreateExampleUseCase(repo repository.ExampleRepository) *CreateExampleUseCase {
	return &CreateExampleUseCase{repo: repo}
}

func (uc *CreateExampleUseCase) Execute(ctx context.Context, req CreateExampleRequest) (*CreateExampleResponse, error) {
	example, err := entity.NewExample(req.Name, req.Description)
	if err != nil {
		return nil, fmt.Errorf("create example: %w", err)
	}
	if err := uc.repo.Save(ctx, example); err != nil {
		return nil, fmt.Errorf("create example: save: %w", err)
	}
	return &CreateExampleResponse{
		ID:          example.ID,
		Name:        example.Name,
		Description: example.Description,
	}, nil
}
EOF
  sed -i "s|MODNAME|$PROJECT|g" "$PROJECT/internal/usecase/create_example.go"

  # --- In-Memory Repository ---
  cat > "$PROJECT/internal/adapter/repository/inmemory_example_repo.go" << 'EOF'
package repository

import (
	"context"
	"sync"

	"MODNAME/internal/domain/entity"
)

type InMemoryExampleRepository struct {
	mu    sync.RWMutex
	store map[string]*entity.Example
}

func NewInMemoryExampleRepository() *InMemoryExampleRepository {
	return &InMemoryExampleRepository{store: make(map[string]*entity.Example)}
}

func (r *InMemoryExampleRepository) FindByID(_ context.Context, id string) (*entity.Example, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.store[id]
	if !ok {
		return nil, nil
	}
	return e, nil
}

func (r *InMemoryExampleRepository) FindAll(_ context.Context) ([]*entity.Example, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make([]*entity.Example, 0, len(r.store))
	for _, e := range r.store {
		result = append(result, e)
	}
	return result, nil
}

func (r *InMemoryExampleRepository) Save(_ context.Context, example *entity.Example) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.store[example.ID] = example
	return nil
}

func (r *InMemoryExampleRepository) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.store, id)
	return nil
}
EOF
  sed -i "s|MODNAME|$PROJECT|g" "$PROJECT/internal/adapter/repository/inmemory_example_repo.go"

  # --- Handler ---
  cat > "$PROJECT/internal/adapter/handler/example_handler.go" << 'EOF'
package handler

import (
	"encoding/json"
	"net/http"

	"MODNAME/internal/usecase"
)

type ExampleHandler struct {
	createExample *usecase.CreateExampleUseCase
}

func NewExampleHandler(create *usecase.CreateExampleUseCase) *ExampleHandler {
	return &ExampleHandler{createExample: create}
}

func (h *ExampleHandler) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}
	result, err := h.createExample.Execute(r.Context(), usecase.CreateExampleRequest{
		Name:        body.Name,
		Description: body.Description,
	})
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusUnprocessableEntity)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(result)
}
EOF
  sed -i "s|MODNAME|$PROJECT|g" "$PROJECT/internal/adapter/handler/example_handler.go"

  # --- Main ---
  cat > "$PROJECT/cmd/api/main.go" << 'EOF'
package main

import (
	"fmt"
	"log"
	"net/http"

	handler "MODNAME/internal/adapter/handler"
	repo "MODNAME/internal/adapter/repository"
	"MODNAME/internal/usecase"
)

func main() {
	exampleRepo := repo.NewInMemoryExampleRepository()
	createExample := usecase.NewCreateExampleUseCase(exampleRepo)
	exampleHandler := handler.NewExampleHandler(createExample)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/examples", exampleHandler.Create)

	port := 8080
	addr := fmt.Sprintf(":%d", port)
	log.Printf("Server starting on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
EOF
  sed -i "s|MODNAME|$PROJECT|g" "$PROJECT/cmd/api/main.go"

  # --- go.mod ---
  cat > "$PROJECT/go.mod" << EOF
module $PROJECT

go 1.22

require github.com/google/uuid v1.6.0
EOF

  # --- Makefile ---
  cat > "$PROJECT/Makefile" << 'EOF'
.PHONY: build run test lint clean

build:
	go build -o bin/api ./cmd/api

run: build
	./bin/api

test:
	go test ./... -v

lint:
	golangci-lint run ./...

clean:
	rm -rf bin/
EOF
}

# =============================================================================
# Main dispatch
# =============================================================================
case "$LANG" in
  typescript|ts)
    scaffold_typescript
    ;;
  python|py)
    scaffold_python
    ;;
  go)
    scaffold_go
    ;;
  *)
    echo "Error: Unsupported language '$LANG'. Use: typescript | python | go"
    exit 1
    ;;
esac

echo ""
echo "✅ Project '$PROJECT' created successfully!"
echo ""
echo "Structure:"
find "$PROJECT" -type f | head -40 | sed 's/^/  /'
TOTAL_FILES=$(find "$PROJECT" -type f | wc -l)
if [[ $TOTAL_FILES -gt 40 ]]; then
  echo "  ... and $((TOTAL_FILES - 40)) more files"
fi
echo ""
echo "Next steps:"
echo "  cd $PROJECT"
echo "  make install  # Install dependencies"
echo "  make dev      # Start development server"
