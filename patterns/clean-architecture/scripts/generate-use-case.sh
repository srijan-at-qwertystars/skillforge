#!/usr/bin/env bash
# =============================================================================
# generate-use-case.sh — Generate a Clean Architecture use case with all parts
#
# Usage:
#   ./generate-use-case.sh <language> <entity-name> <operation> [output-dir]
#
# Languages:   typescript | python | go
# Operations:  create | read | update | delete
#
# Examples:
#   ./generate-use-case.sh typescript Order create
#   ./generate-use-case.sh python Invoice read ./src
#   ./generate-use-case.sh go Product update ./internal
#
# Generates:
#   - Use case class with execute method
#   - Input DTO (request)
#   - Output DTO (response)
#   - Repository interface (if not exists)
#   - Controller/handler stub
# =============================================================================

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <language> <entity-name> <operation> [output-dir]"
  echo ""
  echo "Languages:  typescript | python | go"
  echo "Operations: create | read | update | delete"
  echo ""
  echo "Examples:"
  echo "  $0 typescript Order create"
  echo "  $0 python Invoice read ./src"
  echo "  $0 go Product update ./internal"
  exit 1
fi

LANG="$1"
ENTITY="$2"
OPERATION="$3"
OUTPUT_DIR="${4:-.}"

# Naming utilities
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
to_upper_first() { echo "$1" | sed 's/./\U&/'; }
to_snake() { echo "$1" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//'; }
to_kebab() { echo "$1" | sed 's/\([A-Z]\)/-\L\1/g' | sed 's/^-//'; }

ENTITY_UPPER="$(to_upper_first "$ENTITY")"
ENTITY_LOWER="$(to_lower "$ENTITY")"
ENTITY_SNAKE="$(to_snake "$ENTITY")"
ENTITY_KEBAB="$(to_kebab "$ENTITY")"
OP_UPPER="$(to_upper_first "$OPERATION")"
OP_LOWER="$(to_lower "$OPERATION")"

echo "🔧 Generating ${OP_UPPER}${ENTITY_UPPER} use case ($LANG)"

# =============================================================================
# TypeScript Generation
# =============================================================================
generate_typescript() {
  local UC_DIR="$OUTPUT_DIR/src/application/use-cases/${OP_LOWER}-${ENTITY_KEBAB}"
  local REPO_DIR="$OUTPUT_DIR/src/domain/repositories"
  local CTRL_DIR="$OUTPUT_DIR/src/presentation/http/controllers"

  mkdir -p "$UC_DIR" "$REPO_DIR" "$CTRL_DIR"

  local UC_NAME="${OP_UPPER}${ENTITY_UPPER}UseCase"
  local REQ_NAME="${OP_UPPER}${ENTITY_UPPER}Request"
  local RES_NAME="${OP_UPPER}${ENTITY_UPPER}Response"
  local REPO_IFACE="I${ENTITY_UPPER}Repository"

  # --- Repository Interface (if not exists) ---
  local REPO_FILE="$REPO_DIR/${REPO_IFACE}.ts"
  if [[ ! -f "$REPO_FILE" ]]; then
    cat > "$REPO_FILE" << EOF
import { ${ENTITY_UPPER} } from '../entities/${ENTITY_UPPER}';

export interface ${REPO_IFACE} {
  findById(id: string): Promise<${ENTITY_UPPER} | null>;
  findAll(): Promise<${ENTITY_UPPER}[]>;
  save(${ENTITY_LOWER}: ${ENTITY_UPPER}): Promise<void>;
  delete(id: string): Promise<void>;
}
EOF
    echo "  Created: $REPO_FILE"
  fi

  # --- Use Case ---
  case "$OP_LOWER" in
    create)
      cat > "$UC_DIR/${UC_NAME}.ts" << EOF
import { ${REPO_IFACE} } from '../../../domain/repositories/${REPO_IFACE}';
import { ${ENTITY_UPPER} } from '../../../domain/entities/${ENTITY_UPPER}';

export interface ${REQ_NAME} {
  // TODO: Add fields for creating a ${ENTITY_UPPER}
  name: string;
}

export interface ${RES_NAME} {
  id: string;
  // TODO: Add response fields
  name: string;
  createdAt: Date;
}

export class ${UC_NAME} {
  constructor(
    private readonly repo: ${REPO_IFACE},
    private readonly idGenerator: { generate(): string }
  ) {}

  async execute(request: ${REQ_NAME}): Promise<${RES_NAME}> {
    const ${ENTITY_LOWER} = ${ENTITY_UPPER}.create(
      this.idGenerator.generate(),
      request.name
    );
    await this.repo.save(${ENTITY_LOWER});
    return {
      id: ${ENTITY_LOWER}.id,
      name: ${ENTITY_LOWER}.name,
      createdAt: ${ENTITY_LOWER}.createdAt,
    };
  }
}
EOF
      ;;
    read)
      cat > "$UC_DIR/${UC_NAME}.ts" << EOF
import { ${REPO_IFACE} } from '../../../domain/repositories/${REPO_IFACE}';
import { NotFoundError } from '../../../domain/errors/DomainError';

export interface ${REQ_NAME} {
  id: string;
}

export interface ${RES_NAME} {
  id: string;
  // TODO: Add response fields
  name: string;
  createdAt: Date;
}

export class ${UC_NAME} {
  constructor(private readonly repo: ${REPO_IFACE}) {}

  async execute(request: ${REQ_NAME}): Promise<${RES_NAME}> {
    const ${ENTITY_LOWER} = await this.repo.findById(request.id);
    if (!${ENTITY_LOWER}) {
      throw new NotFoundError('${ENTITY_UPPER}', request.id);
    }
    return {
      id: ${ENTITY_LOWER}.id,
      name: ${ENTITY_LOWER}.name,
      createdAt: ${ENTITY_LOWER}.createdAt,
    };
  }
}
EOF
      ;;
    update)
      cat > "$UC_DIR/${UC_NAME}.ts" << EOF
import { ${REPO_IFACE} } from '../../../domain/repositories/${REPO_IFACE}';
import { NotFoundError } from '../../../domain/errors/DomainError';

export interface ${REQ_NAME} {
  id: string;
  // TODO: Add updatable fields
  name?: string;
}

export interface ${RES_NAME} {
  id: string;
  name: string;
  updatedAt: Date;
}

export class ${UC_NAME} {
  constructor(private readonly repo: ${REPO_IFACE}) {}

  async execute(request: ${REQ_NAME}): Promise<${RES_NAME}> {
    const ${ENTITY_LOWER} = await this.repo.findById(request.id);
    if (!${ENTITY_LOWER}) {
      throw new NotFoundError('${ENTITY_UPPER}', request.id);
    }

    // TODO: Apply updates to ${ENTITY_LOWER}
    // ${ENTITY_LOWER}.updateName(request.name);

    await this.repo.save(${ENTITY_LOWER});
    return {
      id: ${ENTITY_LOWER}.id,
      name: ${ENTITY_LOWER}.name,
      updatedAt: ${ENTITY_LOWER}.updatedAt,
    };
  }
}
EOF
      ;;
    delete)
      cat > "$UC_DIR/${UC_NAME}.ts" << EOF
import { ${REPO_IFACE} } from '../../../domain/repositories/${REPO_IFACE}';
import { NotFoundError } from '../../../domain/errors/DomainError';

export interface ${REQ_NAME} {
  id: string;
}

export class ${UC_NAME} {
  constructor(private readonly repo: ${REPO_IFACE}) {}

  async execute(request: ${REQ_NAME}): Promise<void> {
    const ${ENTITY_LOWER} = await this.repo.findById(request.id);
    if (!${ENTITY_LOWER}) {
      throw new NotFoundError('${ENTITY_UPPER}', request.id);
    }
    await this.repo.delete(request.id);
  }
}
EOF
      ;;
  esac
  echo "  Created: $UC_DIR/${UC_NAME}.ts"

  # --- Controller Stub ---
  local CTRL_FILE="$CTRL_DIR/${ENTITY_UPPER}Controller.ts"
  if [[ ! -f "$CTRL_FILE" ]]; then
    cat > "$CTRL_FILE" << EOF
import { Request, Response, NextFunction } from 'express';
import { ${UC_NAME} } from '../../../application/use-cases/${OP_LOWER}-${ENTITY_KEBAB}/${UC_NAME}';

export class ${ENTITY_UPPER}Controller {
  constructor(private readonly ${OP_LOWER}${ENTITY_UPPER}: ${UC_NAME}) {}

  async handle(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      // TODO: Map request to DTO and invoke use case
      const result = await this.${OP_LOWER}${ENTITY_UPPER}.execute(req.body);
      res.status(${OP_LOWER === "create" ? 201 : 200}).json(result);
    } catch (err) {
      next(err);
    }
  }
}
EOF
    echo "  Created: $CTRL_FILE"
  else
    echo "  Skipped: $CTRL_FILE (already exists)"
  fi
}

# =============================================================================
# Python Generation
# =============================================================================
generate_python() {
  local UC_DIR="$OUTPUT_DIR/src/application/use_cases"
  local REPO_DIR="$OUTPUT_DIR/src/domain/repositories"
  local API_DIR="$OUTPUT_DIR/src/presentation/api"

  mkdir -p "$UC_DIR" "$REPO_DIR" "$API_DIR"
  touch "$UC_DIR/__init__.py" "$REPO_DIR/__init__.py" "$API_DIR/__init__.py" 2>/dev/null || true

  local UC_FILE="${OP_LOWER}_${ENTITY_SNAKE}.py"

  # --- Repository Interface (if not exists) ---
  local REPO_FILE="$REPO_DIR/${ENTITY_SNAKE}_repository.py"
  if [[ ! -f "$REPO_FILE" ]]; then
    cat > "$REPO_FILE" << EOF
from abc import ABC, abstractmethod
from src.domain.entities.${ENTITY_SNAKE} import ${ENTITY_UPPER}


class ${ENTITY_UPPER}Repository(ABC):
    @abstractmethod
    async def find_by_id(self, id: str) -> ${ENTITY_UPPER} | None: ...

    @abstractmethod
    async def find_all(self) -> list[${ENTITY_UPPER}]: ...

    @abstractmethod
    async def save(self, ${ENTITY_SNAKE}: ${ENTITY_UPPER}) -> None: ...

    @abstractmethod
    async def delete(self, id: str) -> None: ...
EOF
    echo "  Created: $REPO_FILE"
  fi

  # --- Use Case ---
  case "$OP_LOWER" in
    create)
      cat > "$UC_DIR/$UC_FILE" << EOF
from dataclasses import dataclass
from datetime import datetime
from src.domain.entities.${ENTITY_SNAKE} import ${ENTITY_UPPER}
from src.domain.repositories.${ENTITY_SNAKE}_repository import ${ENTITY_UPPER}Repository


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Request:
    # TODO: Add fields for creating a ${ENTITY_UPPER}
    name: str


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Response:
    id: str
    name: str
    created_at: datetime


class ${OP_UPPER}${ENTITY_UPPER}UseCase:
    def __init__(self, repo: ${ENTITY_UPPER}Repository):
        self._repo = repo

    async def execute(self, request: ${OP_UPPER}${ENTITY_UPPER}Request) -> ${OP_UPPER}${ENTITY_UPPER}Response:
        ${ENTITY_SNAKE} = ${ENTITY_UPPER}.create(name=request.name)
        await self._repo.save(${ENTITY_SNAKE})
        return ${OP_UPPER}${ENTITY_UPPER}Response(
            id=${ENTITY_SNAKE}.id,
            name=${ENTITY_SNAKE}.name,
            created_at=${ENTITY_SNAKE}.created_at,
        )
EOF
      ;;
    read)
      cat > "$UC_DIR/$UC_FILE" << EOF
from dataclasses import dataclass
from datetime import datetime
from src.domain.repositories.${ENTITY_SNAKE}_repository import ${ENTITY_UPPER}Repository
from src.domain.errors import NotFoundError


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Request:
    id: str


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Response:
    id: str
    name: str
    created_at: datetime


class ${OP_UPPER}${ENTITY_UPPER}UseCase:
    def __init__(self, repo: ${ENTITY_UPPER}Repository):
        self._repo = repo

    async def execute(self, request: ${OP_UPPER}${ENTITY_UPPER}Request) -> ${OP_UPPER}${ENTITY_UPPER}Response:
        ${ENTITY_SNAKE} = await self._repo.find_by_id(request.id)
        if ${ENTITY_SNAKE} is None:
            raise NotFoundError("${ENTITY_UPPER}", request.id)
        return ${OP_UPPER}${ENTITY_UPPER}Response(
            id=${ENTITY_SNAKE}.id,
            name=${ENTITY_SNAKE}.name,
            created_at=${ENTITY_SNAKE}.created_at,
        )
EOF
      ;;
    update)
      cat > "$UC_DIR/$UC_FILE" << EOF
from dataclasses import dataclass
from datetime import datetime
from src.domain.repositories.${ENTITY_SNAKE}_repository import ${ENTITY_UPPER}Repository
from src.domain.errors import NotFoundError


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Request:
    id: str
    # TODO: Add updatable fields
    name: str | None = None


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Response:
    id: str
    name: str
    updated_at: datetime


class ${OP_UPPER}${ENTITY_UPPER}UseCase:
    def __init__(self, repo: ${ENTITY_UPPER}Repository):
        self._repo = repo

    async def execute(self, request: ${OP_UPPER}${ENTITY_UPPER}Request) -> ${OP_UPPER}${ENTITY_UPPER}Response:
        ${ENTITY_SNAKE} = await self._repo.find_by_id(request.id)
        if ${ENTITY_SNAKE} is None:
            raise NotFoundError("${ENTITY_UPPER}", request.id)
        # TODO: Apply updates
        await self._repo.save(${ENTITY_SNAKE})
        return ${OP_UPPER}${ENTITY_UPPER}Response(
            id=${ENTITY_SNAKE}.id,
            name=${ENTITY_SNAKE}.name,
            updated_at=${ENTITY_SNAKE}.updated_at,
        )
EOF
      ;;
    delete)
      cat > "$UC_DIR/$UC_FILE" << EOF
from dataclasses import dataclass
from src.domain.repositories.${ENTITY_SNAKE}_repository import ${ENTITY_UPPER}Repository
from src.domain.errors import NotFoundError


@dataclass(frozen=True)
class ${OP_UPPER}${ENTITY_UPPER}Request:
    id: str


class ${OP_UPPER}${ENTITY_UPPER}UseCase:
    def __init__(self, repo: ${ENTITY_UPPER}Repository):
        self._repo = repo

    async def execute(self, request: ${OP_UPPER}${ENTITY_UPPER}Request) -> None:
        ${ENTITY_SNAKE} = await self._repo.find_by_id(request.id)
        if ${ENTITY_SNAKE} is None:
            raise NotFoundError("${ENTITY_UPPER}", request.id)
        await self._repo.delete(request.id)
EOF
      ;;
  esac
  echo "  Created: $UC_DIR/$UC_FILE"

  # --- Router Stub ---
  local ROUTER_FILE="$API_DIR/${ENTITY_SNAKE}_router.py"
  if [[ ! -f "$ROUTER_FILE" ]]; then
    cat > "$ROUTER_FILE" << EOF
from fastapi import APIRouter, Depends, status
from pydantic import BaseModel

router = APIRouter()


class ${ENTITY_UPPER}Body(BaseModel):
    # TODO: Define request body fields
    name: str


@router.post("/", status_code=status.HTTP_201_CREATED)
async def create_${ENTITY_SNAKE}(body: ${ENTITY_UPPER}Body):
    # TODO: Wire use case via dependency injection
    return {"message": "TODO: implement"}
EOF
    echo "  Created: $ROUTER_FILE"
  else
    echo "  Skipped: $ROUTER_FILE (already exists)"
  fi
}

# =============================================================================
# Go Generation
# =============================================================================
generate_go() {
  local UC_DIR="$OUTPUT_DIR/internal/usecase"
  local REPO_DIR="$OUTPUT_DIR/internal/domain/repository"
  local HANDLER_DIR="$OUTPUT_DIR/internal/adapter/handler"

  mkdir -p "$UC_DIR" "$REPO_DIR" "$HANDLER_DIR"

  local UC_FILE="${OP_LOWER}_${ENTITY_SNAKE}.go"

  # Detect Go module name
  local MOD_NAME="myapp"
  if [[ -f "$OUTPUT_DIR/go.mod" ]]; then
    MOD_NAME=$(head -1 "$OUTPUT_DIR/go.mod" | awk '{print $2}')
  fi

  # --- Repository Interface (if not exists) ---
  local REPO_FILE="$REPO_DIR/${ENTITY_SNAKE}_repository.go"
  if [[ ! -f "$REPO_FILE" ]]; then
    cat > "$REPO_FILE" << EOF
package repository

import (
	"context"
	"${MOD_NAME}/internal/domain/entity"
)

type ${ENTITY_UPPER}Repository interface {
	FindByID(ctx context.Context, id string) (*entity.${ENTITY_UPPER}, error)
	FindAll(ctx context.Context) ([]*entity.${ENTITY_UPPER}, error)
	Save(ctx context.Context, ${ENTITY_LOWER} *entity.${ENTITY_UPPER}) error
	Delete(ctx context.Context, id string) error
}
EOF
    echo "  Created: $REPO_FILE"
  fi

  # --- Use Case ---
  case "$OP_LOWER" in
    create)
      cat > "$UC_DIR/$UC_FILE" << EOF
package usecase

import (
	"context"
	"fmt"

	"${MOD_NAME}/internal/domain/entity"
	"${MOD_NAME}/internal/domain/repository"
)

type ${OP_UPPER}${ENTITY_UPPER}Request struct {
	// TODO: Add fields
	Name string
}

type ${OP_UPPER}${ENTITY_UPPER}Response struct {
	ID   string \`json:"id"\`
	Name string \`json:"name"\`
}

type ${OP_UPPER}${ENTITY_UPPER}UseCase struct {
	repo repository.${ENTITY_UPPER}Repository
}

func New${OP_UPPER}${ENTITY_UPPER}UseCase(repo repository.${ENTITY_UPPER}Repository) *${OP_UPPER}${ENTITY_UPPER}UseCase {
	return &${OP_UPPER}${ENTITY_UPPER}UseCase{repo: repo}
}

func (uc *${OP_UPPER}${ENTITY_UPPER}UseCase) Execute(ctx context.Context, req ${OP_UPPER}${ENTITY_UPPER}Request) (*${OP_UPPER}${ENTITY_UPPER}Response, error) {
	${ENTITY_LOWER}, err := entity.New${ENTITY_UPPER}(req.Name)
	if err != nil {
		return nil, fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: %w", err)
	}
	if err := uc.repo.Save(ctx, ${ENTITY_LOWER}); err != nil {
		return nil, fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: save: %w", err)
	}
	return &${OP_UPPER}${ENTITY_UPPER}Response{
		ID:   ${ENTITY_LOWER}.ID,
		Name: ${ENTITY_LOWER}.Name,
	}, nil
}
EOF
      ;;
    read)
      cat > "$UC_DIR/$UC_FILE" << EOF
package usecase

import (
	"context"
	"fmt"

	"${MOD_NAME}/internal/domain/domainerror"
	"${MOD_NAME}/internal/domain/repository"
)

type ${OP_UPPER}${ENTITY_UPPER}Request struct {
	ID string
}

type ${OP_UPPER}${ENTITY_UPPER}Response struct {
	ID   string \`json:"id"\`
	Name string \`json:"name"\`
}

type ${OP_UPPER}${ENTITY_UPPER}UseCase struct {
	repo repository.${ENTITY_UPPER}Repository
}

func New${OP_UPPER}${ENTITY_UPPER}UseCase(repo repository.${ENTITY_UPPER}Repository) *${OP_UPPER}${ENTITY_UPPER}UseCase {
	return &${OP_UPPER}${ENTITY_UPPER}UseCase{repo: repo}
}

func (uc *${OP_UPPER}${ENTITY_UPPER}UseCase) Execute(ctx context.Context, req ${OP_UPPER}${ENTITY_UPPER}Request) (*${OP_UPPER}${ENTITY_UPPER}Response, error) {
	${ENTITY_LOWER}, err := uc.repo.FindByID(ctx, req.ID)
	if err != nil {
		return nil, fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: %w", err)
	}
	if ${ENTITY_LOWER} == nil {
		return nil, domainerror.NewNotFoundError("${ENTITY_UPPER}", req.ID)
	}
	return &${OP_UPPER}${ENTITY_UPPER}Response{
		ID:   ${ENTITY_LOWER}.ID,
		Name: ${ENTITY_LOWER}.Name,
	}, nil
}
EOF
      ;;
    update)
      cat > "$UC_DIR/$UC_FILE" << EOF
package usecase

import (
	"context"
	"fmt"

	"${MOD_NAME}/internal/domain/domainerror"
	"${MOD_NAME}/internal/domain/repository"
)

type ${OP_UPPER}${ENTITY_UPPER}Request struct {
	ID   string
	Name string
}

type ${OP_UPPER}${ENTITY_UPPER}Response struct {
	ID   string \`json:"id"\`
	Name string \`json:"name"\`
}

type ${OP_UPPER}${ENTITY_UPPER}UseCase struct {
	repo repository.${ENTITY_UPPER}Repository
}

func New${OP_UPPER}${ENTITY_UPPER}UseCase(repo repository.${ENTITY_UPPER}Repository) *${OP_UPPER}${ENTITY_UPPER}UseCase {
	return &${OP_UPPER}${ENTITY_UPPER}UseCase{repo: repo}
}

func (uc *${OP_UPPER}${ENTITY_UPPER}UseCase) Execute(ctx context.Context, req ${OP_UPPER}${ENTITY_UPPER}Request) (*${OP_UPPER}${ENTITY_UPPER}Response, error) {
	${ENTITY_LOWER}, err := uc.repo.FindByID(ctx, req.ID)
	if err != nil {
		return nil, fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: %w", err)
	}
	if ${ENTITY_LOWER} == nil {
		return nil, domainerror.NewNotFoundError("${ENTITY_UPPER}", req.ID)
	}
	// TODO: Apply updates
	${ENTITY_LOWER}.Name = req.Name
	if err := uc.repo.Save(ctx, ${ENTITY_LOWER}); err != nil {
		return nil, fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: save: %w", err)
	}
	return &${OP_UPPER}${ENTITY_UPPER}Response{
		ID:   ${ENTITY_LOWER}.ID,
		Name: ${ENTITY_LOWER}.Name,
	}, nil
}
EOF
      ;;
    delete)
      cat > "$UC_DIR/$UC_FILE" << EOF
package usecase

import (
	"context"
	"fmt"

	"${MOD_NAME}/internal/domain/domainerror"
	"${MOD_NAME}/internal/domain/repository"
)

type ${OP_UPPER}${ENTITY_UPPER}Request struct {
	ID string
}

type ${OP_UPPER}${ENTITY_UPPER}UseCase struct {
	repo repository.${ENTITY_UPPER}Repository
}

func New${OP_UPPER}${ENTITY_UPPER}UseCase(repo repository.${ENTITY_UPPER}Repository) *${OP_UPPER}${ENTITY_UPPER}UseCase {
	return &${OP_UPPER}${ENTITY_UPPER}UseCase{repo: repo}
}

func (uc *${OP_UPPER}${ENTITY_UPPER}UseCase) Execute(ctx context.Context, req ${OP_UPPER}${ENTITY_UPPER}Request) error {
	${ENTITY_LOWER}, err := uc.repo.FindByID(ctx, req.ID)
	if err != nil {
		return fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: %w", err)
	}
	if ${ENTITY_LOWER} == nil {
		return domainerror.NewNotFoundError("${ENTITY_UPPER}", req.ID)
	}
	if err := uc.repo.Delete(ctx, req.ID); err != nil {
		return fmt.Errorf("${OP_LOWER} ${ENTITY_LOWER}: delete: %w", err)
	}
	return nil
}
EOF
      ;;
  esac
  echo "  Created: $UC_DIR/$UC_FILE"

  # --- Handler Stub ---
  local HANDLER_FILE="$HANDLER_DIR/${ENTITY_SNAKE}_handler.go"
  if [[ ! -f "$HANDLER_FILE" ]]; then
    cat > "$HANDLER_FILE" << EOF
package handler

import (
	"encoding/json"
	"net/http"

	"${MOD_NAME}/internal/usecase"
)

type ${ENTITY_UPPER}Handler struct {
	// TODO: Add use case fields
	${OP_LOWER}${ENTITY_UPPER} *usecase.${OP_UPPER}${ENTITY_UPPER}UseCase
}

func New${ENTITY_UPPER}Handler(${OP_LOWER} *usecase.${OP_UPPER}${ENTITY_UPPER}UseCase) *${ENTITY_UPPER}Handler {
	return &${ENTITY_UPPER}Handler{${OP_LOWER}${ENTITY_UPPER}: ${OP_LOWER}}
}

func (h *${ENTITY_UPPER}Handler) Handle(w http.ResponseWriter, r *http.Request) {
	// TODO: Implement request handling
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "TODO: implement"})
}
EOF
    echo "  Created: $HANDLER_FILE"
  else
    echo "  Skipped: $HANDLER_FILE (already exists)"
  fi
}

# =============================================================================
# Main dispatch
# =============================================================================
case "$OPERATION" in
  create|read|update|delete) ;;
  *)
    echo "Error: Invalid operation '$OPERATION'. Use: create | read | update | delete"
    exit 1
    ;;
esac

case "$LANG" in
  typescript|ts) generate_typescript ;;
  python|py)     generate_python ;;
  go)            generate_go ;;
  *)
    echo "Error: Unsupported language '$LANG'. Use: typescript | python | go"
    exit 1
    ;;
esac

echo ""
echo "✅ ${OP_UPPER}${ENTITY_UPPER} use case generated successfully!"
echo ""
echo "Next steps:"
echo "  1. Review generated files and fill in TODO placeholders"
echo "  2. Create the ${ENTITY_UPPER} entity if it doesn't exist"
echo "  3. Wire the use case in your composition root (main/container)"
echo "  4. Add tests for the use case"
