#!/usr/bin/env bash
# =============================================================================
# generate-resource.sh — Generate a full CRUD resource following NestJS conventions
#
# Usage:
#   ./generate-resource.sh <resource-name> [--path src/modules] [--no-spec]
#
# Examples:
#   ./generate-resource.sh users
#   ./generate-resource.sh products --path src/modules --no-spec
#   ./generate-resource.sh order-items
#
# Generates:
#   src/<resource>/
#   ├── <resource>.module.ts
#   ├── <resource>.controller.ts
#   ├── <resource>.service.ts
#   ├── <resource>.controller.spec.ts  (unless --no-spec)
#   ├── <resource>.service.spec.ts     (unless --no-spec)
#   ├── dto/
#   │   ├── create-<resource>.dto.ts
#   │   └── update-<resource>.dto.ts
#   └── entities/
#       └── <resource>.entity.ts
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
RESOURCE_NAME=""
BASE_PATH="src"
GEN_SPEC=true

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    BASE_PATH="$2"; shift 2 ;;
    --no-spec) GEN_SPEC=false; shift ;;
    -h|--help)
      echo "Usage: $0 <resource-name> [--path src/modules] [--no-spec]"
      exit 0 ;;
    *)
      if [[ -z "$RESOURCE_NAME" ]]; then
        RESOURCE_NAME="$1"; shift
      else
        echo "Error: Unknown argument '$1'"; exit 1
      fi ;;
  esac
done

if [[ -z "$RESOURCE_NAME" ]]; then
  echo "Error: Resource name is required."
  echo "Usage: $0 <resource-name> [--path src/modules] [--no-spec]"
  exit 1
fi

# ── Naming conventions ───────────────────────────────────────────────────────
# Convert kebab-case to variants
KEBAB="$RESOURCE_NAME"
# PascalCase: order-items → OrderItems
PASCAL=$(echo "$KEBAB" | sed -E 's/(^|-)([a-z])/\U\2/g')
# camelCase: order-items → orderItems
CAMEL=$(echo "$PASCAL" | sed 's/^\(.\)/\l\1/')
# Singular (naive: strip trailing 's' if present, keep if not)
SINGULAR_PASCAL="$PASCAL"
SINGULAR_CAMEL="$CAMEL"

RESOURCE_DIR="$BASE_PATH/$KEBAB"

echo "🔧 Generating CRUD resource: $KEBAB"
echo "   Path: $RESOURCE_DIR"
echo "   Class prefix: $PASCAL"

# ── Create directories ───────────────────────────────────────────────────────
mkdir -p "$RESOURCE_DIR"/{dto,entities}

# ── Entity ────────────────────────────────────────────────────────────────────
cat > "$RESOURCE_DIR/entities/$KEBAB.entity.ts" <<EOF
import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';

@Entity('${KEBAB//-/_}')
export class ${PASCAL} {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column()
  name: string;

  @Column({ nullable: true })
  description: string;

  @Column({ default: true })
  isActive: boolean;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}
EOF

# ── Create DTO ────────────────────────────────────────────────────────────────
cat > "$RESOURCE_DIR/dto/create-$KEBAB.dto.ts" <<EOF
import { IsString, IsOptional, IsBoolean, MinLength } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class Create${PASCAL}Dto {
  @ApiProperty({ example: 'Example name', description: 'Name of the ${CAMEL}' })
  @IsString()
  @MinLength(1)
  name: string;

  @ApiPropertyOptional({ example: 'A description', description: 'Optional description' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: true, description: 'Whether the ${CAMEL} is active' })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}
EOF

# ── Update DTO ────────────────────────────────────────────────────────────────
cat > "$RESOURCE_DIR/dto/update-$KEBAB.dto.ts" <<EOF
import { PartialType } from '@nestjs/swagger';
import { Create${PASCAL}Dto } from './create-${KEBAB}.dto';

export class Update${PASCAL}Dto extends PartialType(Create${PASCAL}Dto) {}
EOF

# ── Service ───────────────────────────────────────────────────────────────────
cat > "$RESOURCE_DIR/$KEBAB.service.ts" <<EOF
import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { ${PASCAL} } from './entities/${KEBAB}.entity';
import { Create${PASCAL}Dto } from './dto/create-${KEBAB}.dto';
import { Update${PASCAL}Dto } from './dto/update-${KEBAB}.dto';

@Injectable()
export class ${PASCAL}Service {
  constructor(
    @InjectRepository(${PASCAL})
    private readonly repo: Repository<${PASCAL}>,
  ) {}

  async create(dto: Create${PASCAL}Dto): Promise<${PASCAL}> {
    const entity = this.repo.create(dto);
    return this.repo.save(entity);
  }

  async findAll(page = 1, limit = 20): Promise<{ data: ${PASCAL}[]; total: number }> {
    const [data, total] = await this.repo.findAndCount({
      skip: (page - 1) * limit,
      take: limit,
      order: { createdAt: 'DESC' },
    });
    return { data, total };
  }

  async findOne(id: string): Promise<${PASCAL}> {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) {
      throw new NotFoundException(\`${PASCAL} with ID "\${id}" not found\`);
    }
    return entity;
  }

  async update(id: string, dto: Update${PASCAL}Dto): Promise<${PASCAL}> {
    const entity = await this.findOne(id);
    Object.assign(entity, dto);
    return this.repo.save(entity);
  }

  async remove(id: string): Promise<void> {
    const entity = await this.findOne(id);
    await this.repo.remove(entity);
  }
}
EOF

# ── Controller ────────────────────────────────────────────────────────────────
cat > "$RESOURCE_DIR/$KEBAB.controller.ts" <<EOF
import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Body,
  Param,
  Query,
  HttpCode,
  HttpStatus,
  ParseUUIDPipe,
  DefaultValuePipe,
  ParseIntPipe,
} from '@nestjs/common';
import {
  ApiTags,
  ApiOperation,
  ApiResponse,
  ApiBearerAuth,
} from '@nestjs/swagger';
import { ${PASCAL}Service } from './${KEBAB}.service';
import { Create${PASCAL}Dto } from './dto/create-${KEBAB}.dto';
import { Update${PASCAL}Dto } from './dto/update-${KEBAB}.dto';

@ApiTags('${KEBAB}')
@ApiBearerAuth()
@Controller('${KEBAB}')
export class ${PASCAL}Controller {
  constructor(private readonly service: ${PASCAL}Service) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({ summary: 'Create a new ${CAMEL}' })
  @ApiResponse({ status: 201, description: '${PASCAL} created successfully' })
  @ApiResponse({ status: 400, description: 'Invalid input' })
  create(@Body() dto: Create${PASCAL}Dto) {
    return this.service.create(dto);
  }

  @Get()
  @ApiOperation({ summary: 'Get all ${CAMEL} records' })
  @ApiResponse({ status: 200, description: 'List of ${CAMEL} records' })
  findAll(
    @Query('page', new DefaultValuePipe(1), ParseIntPipe) page: number,
    @Query('limit', new DefaultValuePipe(20), ParseIntPipe) limit: number,
  ) {
    return this.service.findAll(page, limit);
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get a ${CAMEL} by ID' })
  @ApiResponse({ status: 200, description: '${PASCAL} found' })
  @ApiResponse({ status: 404, description: '${PASCAL} not found' })
  findOne(@Param('id', ParseUUIDPipe) id: string) {
    return this.service.findOne(id);
  }

  @Put(':id')
  @ApiOperation({ summary: 'Update a ${CAMEL}' })
  @ApiResponse({ status: 200, description: '${PASCAL} updated successfully' })
  @ApiResponse({ status: 404, description: '${PASCAL} not found' })
  update(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: Update${PASCAL}Dto,
  ) {
    return this.service.update(id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Delete a ${CAMEL}' })
  @ApiResponse({ status: 204, description: '${PASCAL} deleted' })
  @ApiResponse({ status: 404, description: '${PASCAL} not found' })
  remove(@Param('id', ParseUUIDPipe) id: string) {
    return this.service.remove(id);
  }
}
EOF

# ── Module ────────────────────────────────────────────────────────────────────
cat > "$RESOURCE_DIR/$KEBAB.module.ts" <<EOF
import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ${PASCAL}Controller } from './${KEBAB}.controller';
import { ${PASCAL}Service } from './${KEBAB}.service';
import { ${PASCAL} } from './entities/${KEBAB}.entity';

@Module({
  imports: [TypeOrmModule.forFeature([${PASCAL}])],
  controllers: [${PASCAL}Controller],
  providers: [${PASCAL}Service],
  exports: [${PASCAL}Service],
})
export class ${PASCAL}Module {}
EOF

# ── Test files ────────────────────────────────────────────────────────────────
if [[ "$GEN_SPEC" == true ]]; then
  cat > "$RESOURCE_DIR/$KEBAB.service.spec.ts" <<EOF
import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { ${PASCAL}Service } from './${KEBAB}.service';
import { ${PASCAL} } from './entities/${KEBAB}.entity';

describe('${PASCAL}Service', () => {
  let service: ${PASCAL}Service;
  let repo: jest.Mocked<Repository<${PASCAL}>>;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ${PASCAL}Service,
        {
          provide: getRepositoryToken(${PASCAL}),
          useValue: {
            create: jest.fn(),
            save: jest.fn(),
            findOne: jest.fn(),
            findAndCount: jest.fn(),
            remove: jest.fn(),
          },
        },
      ],
    }).compile();

    service = module.get<${PASCAL}Service>(${PASCAL}Service);
    repo = module.get(getRepositoryToken(${PASCAL}));
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('create', () => {
    it('should create a ${CAMEL}', async () => {
      const dto = { name: 'Test' };
      const entity = { id: '1', ...dto } as ${PASCAL};
      repo.create.mockReturnValue(entity);
      repo.save.mockResolvedValue(entity);
      expect(await service.create(dto)).toEqual(entity);
    });
  });

  describe('findOne', () => {
    it('should throw NotFoundException when not found', async () => {
      repo.findOne.mockResolvedValue(null);
      await expect(service.findOne('nonexistent')).rejects.toThrow();
    });
  });
});
EOF

  cat > "$RESOURCE_DIR/$KEBAB.controller.spec.ts" <<EOF
import { Test, TestingModule } from '@nestjs/testing';
import { ${PASCAL}Controller } from './${KEBAB}.controller';
import { ${PASCAL}Service } from './${KEBAB}.service';

describe('${PASCAL}Controller', () => {
  let controller: ${PASCAL}Controller;
  let service: jest.Mocked<${PASCAL}Service>;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [${PASCAL}Controller],
      providers: [
        {
          provide: ${PASCAL}Service,
          useValue: {
            create: jest.fn(),
            findAll: jest.fn(),
            findOne: jest.fn(),
            update: jest.fn(),
            remove: jest.fn(),
          },
        },
      ],
    }).compile();

    controller = module.get<${PASCAL}Controller>(${PASCAL}Controller);
    service = module.get(${PASCAL}Service);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });
});
EOF
fi

echo ""
echo "✅ Resource '$KEBAB' generated successfully!"
echo ""
echo "Files created:"
find "$RESOURCE_DIR" -type f | sort | sed 's/^/  /'
echo ""
echo "Don't forget to import ${PASCAL}Module in your AppModule:"
echo "  import { ${PASCAL}Module } from './${KEBAB}/${KEBAB}.module';"
echo "  @Module({ imports: [..., ${PASCAL}Module] })"
