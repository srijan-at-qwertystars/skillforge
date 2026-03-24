// ============================================================================
// Clean Architecture Template — Feature Module Structure
//
// This file shows the complete structure for a single feature using
// clean architecture with Riverpod. Copy and adapt per feature.
//
// Layer dependencies: presentation → domain ← data
// Domain layer has NO Flutter imports.
// ============================================================================

// ─── DOMAIN LAYER ───────────────────────────────────────────────────────────
// File: lib/features/product/domain/entities/product.dart

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product.freezed.dart';

@freezed
class Product with _$Product {
  const factory Product({
    required String id,
    required String name,
    required String description,
    required double price,
    required String imageUrl,
    required ProductCategory category,
    @Default(true) bool isActive,
    @Default(0) int stockCount,
    DateTime? createdAt,
  }) = _Product;
}

enum ProductCategory {
  electronics,
  clothing,
  food,
  other;

  String get displayName => switch (this) {
        electronics => 'Electronics',
        clothing => 'Clothing',
        food => 'Food & Drink',
        other => 'Other',
      };
}

// ─── DOMAIN: Repository Interface ───────────────────────────────────────────
// File: lib/features/product/domain/repositories/product_repository.dart

abstract interface class ProductRepository {
  Future<List<Product>> fetchAll({int page = 1, int limit = 20});
  Future<Product> fetchById(String id);
  Future<Product> create(CreateProductParams params);
  Future<Product> update(String id, UpdateProductParams params);
  Future<void> delete(String id);
  Stream<List<Product>> watchAll();
}

class CreateProductParams {
  final String name;
  final String description;
  final double price;
  final String imageUrl;
  final ProductCategory category;

  const CreateProductParams({
    required this.name,
    required this.description,
    required this.price,
    required this.imageUrl,
    required this.category,
  });
}

class UpdateProductParams {
  final String? name;
  final String? description;
  final double? price;
  final String? imageUrl;
  final ProductCategory? category;
  final bool? isActive;

  const UpdateProductParams({
    this.name,
    this.description,
    this.price,
    this.imageUrl,
    this.category,
    this.isActive,
  });
}

// ─── DOMAIN: Use Cases ──────────────────────────────────────────────────────
// File: lib/features/product/domain/usecases/fetch_products.dart

class FetchProductsUseCase {
  final ProductRepository _repository;

  const FetchProductsUseCase(this._repository);

  Future<List<Product>> call({int page = 1, int limit = 20}) =>
      _repository.fetchAll(page: page, limit: limit);
}

// File: lib/features/product/domain/usecases/get_product.dart

class GetProductUseCase {
  final ProductRepository _repository;

  const GetProductUseCase(this._repository);

  Future<Product> call(String id) => _repository.fetchById(id);
}

// ─── DATA LAYER ─────────────────────────────────────────────────────────────
// File: lib/features/product/data/models/product_dto.dart

import 'package:json_annotation/json_annotation.dart';

part 'product_dto.g.dart';

@JsonSerializable()
class ProductDto {
  final String id;
  final String name;
  final String description;
  final double price;
  @JsonKey(name: 'image_url')
  final String imageUrl;
  final String category;
  @JsonKey(name: 'is_active', defaultValue: true)
  final bool isActive;
  @JsonKey(name: 'stock_count', defaultValue: 0)
  final int stockCount;
  @JsonKey(name: 'created_at')
  final String? createdAt;

  const ProductDto({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.imageUrl,
    required this.category,
    this.isActive = true,
    this.stockCount = 0,
    this.createdAt,
  });

  factory ProductDto.fromJson(Map<String, dynamic> json) =>
      _$ProductDtoFromJson(json);

  Map<String, dynamic> toJson() => _$ProductDtoToJson(this);

  Product toEntity() => Product(
        id: id,
        name: name,
        description: description,
        price: price,
        imageUrl: imageUrl,
        category: ProductCategory.values.byName(category),
        isActive: isActive,
        stockCount: stockCount,
        createdAt:
            createdAt != null ? DateTime.tryParse(createdAt!) : null,
      );
}

// ─── DATA: Data Source ──────────────────────────────────────────────────────
// File: lib/features/product/data/datasources/product_remote_datasource.dart

import 'package:dio/dio.dart';

abstract interface class ProductRemoteDataSource {
  Future<List<ProductDto>> fetchAll({int page, int limit});
  Future<ProductDto> fetchById(String id);
  Future<ProductDto> create(Map<String, dynamic> data);
  Future<ProductDto> update(String id, Map<String, dynamic> data);
  Future<void> delete(String id);
}

class ProductRemoteDataSourceImpl implements ProductRemoteDataSource {
  final Dio _dio;

  const ProductRemoteDataSourceImpl(this._dio);

  @override
  Future<List<ProductDto>> fetchAll({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/products',
      queryParameters: {'page': page, 'limit': limit},
    );
    final List<dynamic> data = response.data['data'] as List<dynamic>;
    return data
        .map((json) => ProductDto.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ProductDto> fetchById(String id) async {
    final response = await _dio.get('/products/$id');
    return ProductDto.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ProductDto> create(Map<String, dynamic> data) async {
    final response = await _dio.post('/products', data: data);
    return ProductDto.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ProductDto> update(String id, Map<String, dynamic> data) async {
    final response = await _dio.patch('/products/$id', data: data);
    return ProductDto.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> delete(String id) async {
    await _dio.delete('/products/$id');
  }
}

// ─── DATA: Repository Implementation ────────────────────────────────────────
// File: lib/features/product/data/repositories/product_repository_impl.dart

class ProductRepositoryImpl implements ProductRepository {
  final ProductRemoteDataSource _remoteDataSource;

  const ProductRepositoryImpl(this._remoteDataSource);

  @override
  Future<List<Product>> fetchAll({int page = 1, int limit = 20}) async {
    final dtos = await _remoteDataSource.fetchAll(page: page, limit: limit);
    return dtos.map((dto) => dto.toEntity()).toList();
  }

  @override
  Future<Product> fetchById(String id) async {
    final dto = await _remoteDataSource.fetchById(id);
    return dto.toEntity();
  }

  @override
  Future<Product> create(CreateProductParams params) async {
    final dto = await _remoteDataSource.create({
      'name': params.name,
      'description': params.description,
      'price': params.price,
      'image_url': params.imageUrl,
      'category': params.category.name,
    });
    return dto.toEntity();
  }

  @override
  Future<Product> update(String id, UpdateProductParams params) async {
    final data = <String, dynamic>{};
    if (params.name != null) data['name'] = params.name;
    if (params.description != null) data['description'] = params.description;
    if (params.price != null) data['price'] = params.price;
    if (params.imageUrl != null) data['image_url'] = params.imageUrl;
    if (params.category != null) data['category'] = params.category!.name;
    if (params.isActive != null) data['is_active'] = params.isActive;

    final dto = await _remoteDataSource.update(id, data);
    return dto.toEntity();
  }

  @override
  Future<void> delete(String id) => _remoteDataSource.delete(id);

  @override
  Stream<List<Product>> watchAll() {
    // Implement with local database (Isar/drift) for reactive updates
    throw UnimplementedError('Implement with local data source');
  }
}

// ─── PRESENTATION: Providers (Riverpod) ─────────────────────────────────────
// File: lib/features/product/presentation/providers/product_providers.dart

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'product_providers.g.dart';

// DI: Repository provider
@riverpod
ProductRepository productRepository(Ref ref) {
  final dio = ref.watch(dioProvider);
  final dataSource = ProductRemoteDataSourceImpl(dio);
  return ProductRepositoryImpl(dataSource);
}

// Read-only: All products
@riverpod
Future<List<Product>> products(Ref ref) async {
  final repo = ref.watch(productRepositoryProvider);
  return repo.fetchAll();
}

// Read-only: Single product by ID (family)
@riverpod
Future<Product> product(Ref ref, String id) async {
  final repo = ref.watch(productRepositoryProvider);
  return repo.fetchById(id);
}

// Read-write: Product list with mutations
@riverpod
class ProductListNotifier extends _$ProductListNotifier {
  @override
  Future<List<Product>> build() async {
    final repo = ref.watch(productRepositoryProvider);
    return repo.fetchAll();
  }

  Future<void> addProduct(CreateProductParams params) async {
    final repo = ref.read(productRepositoryProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await repo.create(params);
      return repo.fetchAll(); // Refresh list
    });
  }

  Future<void> deleteProduct(String id) async {
    final repo = ref.read(productRepositoryProvider);
    // Optimistic update
    final previousState = state;
    state = AsyncData(
      state.valueOrNull?.where((p) => p.id != id).toList() ?? [],
    );
    try {
      await repo.delete(id);
    } catch (e) {
      state = previousState; // Rollback on failure
      rethrow;
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

// ─── PRESENTATION: Page ─────────────────────────────────────────────────────
// File: lib/features/product/presentation/pages/product_list_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProductListPage extends ConsumerWidget {
  const ProductListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productsAsync = ref.watch(productListNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(productListNotifierProvider.notifier).refresh(),
          ),
        ],
      ),
      body: productsAsync.when(
        data: (products) => products.isEmpty
            ? const _EmptyState()
            : RefreshIndicator(
                onRefresh: () =>
                    ref.read(productListNotifierProvider.notifier).refresh(),
                child: ListView.builder(
                  itemCount: products.length,
                  itemBuilder: (context, index) => ProductTile(
                    product: products[index],
                    onDelete: () => ref
                        .read(productListNotifierProvider.notifier)
                        .deleteProduct(products[index].id),
                  ),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: error.toString(),
          onRetry: () =>
              ref.read(productListNotifierProvider.notifier).refresh(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Navigate to create product page
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ─── PRESENTATION: Widgets ──────────────────────────────────────────────────
// File: lib/features/product/presentation/widgets/product_tile.dart

class ProductTile extends StatelessWidget {
  const ProductTile({
    super.key,
    required this.product,
    this.onTap,
    this.onDelete,
  });

  final Product product;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: colorScheme.primaryContainer,
          child: Text(
            product.name[0].toUpperCase(),
            style: TextStyle(color: colorScheme.onPrimaryContainer),
          ),
        ),
        title: Text(product.name, style: textTheme.titleMedium),
        subtitle: Text(
          product.category.displayName,
          style: textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '\$${product.price.toStringAsFixed(2)}',
              style: textTheme.titleSmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2_outlined, size: 64),
            SizedBox(height: 16),
            Text('No products yet'),
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      );
}

// ─── TEST EXAMPLE ───────────────────────────────────────────────────────────
// File: test/features/product/domain/usecases/fetch_products_test.dart

/*
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockProductRepository extends Mock implements ProductRepository {}

void main() {
  late MockProductRepository mockRepo;
  late FetchProductsUseCase useCase;

  setUp(() {
    mockRepo = MockProductRepository();
    useCase = FetchProductsUseCase(mockRepo);
  });

  test('returns products from repository', () async {
    final products = [
      const Product(
        id: '1',
        name: 'Test',
        description: 'Desc',
        price: 9.99,
        imageUrl: 'https://example.com/img.png',
        category: ProductCategory.electronics,
      ),
    ];

    when(() => mockRepo.fetchAll(page: 1, limit: 20))
        .thenAnswer((_) async => products);

    final result = await useCase();

    expect(result, equals(products));
    verify(() => mockRepo.fetchAll(page: 1, limit: 20)).called(1);
  });
}
*/
