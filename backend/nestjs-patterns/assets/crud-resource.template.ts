// =============================================================================
// Complete CRUD Resource Template
//
// Copy this file and replace "Resource" with your entity name.
// Includes: Controller, Service, DTOs, Entity — all in one file for reference.
// In practice, split into separate files per NestJS conventions.
//
// Dependencies: @nestjs/common, @nestjs/typeorm, @nestjs/swagger,
//               class-validator, class-transformer, typeorm
// =============================================================================

// ── Entity ───────────────────────────────────────────────────────────────────
// File: entities/resource.entity.ts

import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
  Index,
} from 'typeorm';

@Entity('resources')
export class Resource {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Index()
  @Column({ length: 255 })
  name: string;

  @Column({ type: 'text', nullable: true })
  description: string;

  @Column({ default: true })
  isActive: boolean;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}

// ── Create DTO ───────────────────────────────────────────────────────────────
// File: dto/create-resource.dto.ts

import {
  IsString,
  IsOptional,
  IsBoolean,
  MinLength,
  MaxLength,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';

export class CreateResourceDto {
  @ApiProperty({ example: 'My Resource', minLength: 1, maxLength: 255 })
  @IsString()
  @MinLength(1)
  @MaxLength(255)
  name: string;

  @ApiPropertyOptional({ example: 'A detailed description' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: true, default: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}

// ── Update DTO ───────────────────────────────────────────────────────────────
// File: dto/update-resource.dto.ts

export class UpdateResourceDto extends PartialType(CreateResourceDto) {}

// ── Pagination DTO ───────────────────────────────────────────────────────────
// File: dto/paginated-response.dto.ts

export class PaginatedResponse<T> {
  data: T[];
  meta: {
    total: number;
    page: number;
    limit: number;
    totalPages: number;
  };
}

// ── Service ──────────────────────────────────────────────────────────────────
// File: resource.service.ts

import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, FindOptionsWhere, ILike } from 'typeorm';

@Injectable()
export class ResourceService {
  constructor(
    @InjectRepository(Resource)
    private readonly repo: Repository<Resource>,
  ) {}

  async create(dto: CreateResourceDto): Promise<Resource> {
    const entity = this.repo.create(dto);
    return this.repo.save(entity);
  }

  async findAll(options: {
    page?: number;
    limit?: number;
    search?: string;
    isActive?: boolean;
  } = {}): Promise<PaginatedResponse<Resource>> {
    const { page = 1, limit = 20, search, isActive } = options;

    const where: FindOptionsWhere<Resource> = {};
    if (search) where.name = ILike(`%${search}%`);
    if (isActive !== undefined) where.isActive = isActive;

    const [data, total] = await this.repo.findAndCount({
      where,
      skip: (page - 1) * limit,
      take: limit,
      order: { createdAt: 'DESC' },
    });

    return {
      data,
      meta: {
        total,
        page,
        limit,
        totalPages: Math.ceil(total / limit),
      },
    };
  }

  async findOne(id: string): Promise<Resource> {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) {
      throw new NotFoundException(`Resource with ID "${id}" not found`);
    }
    return entity;
  }

  async update(id: string, dto: UpdateResourceDto): Promise<Resource> {
    const entity = await this.findOne(id);
    Object.assign(entity, dto);
    return this.repo.save(entity);
  }

  async remove(id: string): Promise<void> {
    const entity = await this.findOne(id);
    await this.repo.remove(entity);
  }
}

// ── Controller ───────────────────────────────────────────────────────────────
// File: resource.controller.ts

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
  ParseBoolPipe,
} from '@nestjs/common';
import {
  ApiTags,
  ApiOperation,
  ApiResponse,
  ApiBearerAuth,
  ApiQuery,
} from '@nestjs/swagger';

@ApiTags('resources')
@ApiBearerAuth()
@Controller('resources')
export class ResourceController {
  constructor(private readonly service: ResourceService) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({ summary: 'Create a new resource' })
  @ApiResponse({ status: 201, description: 'Resource created', type: Resource })
  @ApiResponse({ status: 400, description: 'Validation error' })
  create(@Body() dto: CreateResourceDto) {
    return this.service.create(dto);
  }

  @Get()
  @ApiOperation({ summary: 'List all resources with pagination' })
  @ApiQuery({ name: 'page', required: false, type: Number, example: 1 })
  @ApiQuery({ name: 'limit', required: false, type: Number, example: 20 })
  @ApiQuery({ name: 'search', required: false, type: String })
  @ApiQuery({ name: 'isActive', required: false, type: Boolean })
  findAll(
    @Query('page', new DefaultValuePipe(1), ParseIntPipe) page: number,
    @Query('limit', new DefaultValuePipe(20), ParseIntPipe) limit: number,
    @Query('search') search?: string,
    @Query('isActive', new DefaultValuePipe(undefined)) isActive?: boolean,
  ) {
    return this.service.findAll({ page, limit, search, isActive });
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get a resource by ID' })
  @ApiResponse({ status: 200, description: 'Resource found', type: Resource })
  @ApiResponse({ status: 404, description: 'Resource not found' })
  findOne(@Param('id', ParseUUIDPipe) id: string) {
    return this.service.findOne(id);
  }

  @Put(':id')
  @ApiOperation({ summary: 'Update a resource' })
  @ApiResponse({ status: 200, description: 'Resource updated', type: Resource })
  @ApiResponse({ status: 404, description: 'Resource not found' })
  update(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: UpdateResourceDto,
  ) {
    return this.service.update(id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Delete a resource' })
  @ApiResponse({ status: 204, description: 'Resource deleted' })
  @ApiResponse({ status: 404, description: 'Resource not found' })
  remove(@Param('id', ParseUUIDPipe) id: string) {
    return this.service.remove(id);
  }
}

// ── Module ───────────────────────────────────────────────────────────────────
// File: resource.module.ts

import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

@Module({
  imports: [TypeOrmModule.forFeature([Resource])],
  controllers: [ResourceController],
  providers: [ResourceService],
  exports: [ResourceService],
})
export class ResourceModule {}
