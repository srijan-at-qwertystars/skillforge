// pipeline.go — Type-safe pipeline framework with stages, fan-out/fan-in,
// cancellation via context, and error propagation.
//
// Usage:
//   ctx, cancel := context.WithCancel(context.Background())
//   defer cancel()
//
//   source := pipeline.Generate(ctx, 1, 2, 3, 4, 5)
//   doubled := pipeline.Map(ctx, source, func(ctx context.Context, n int) (int, error) {
//       return n * 2, nil
//   })
//   filtered := pipeline.Filter(ctx, doubled, func(n int) bool { return n > 4 })
//   results := pipeline.Collect(ctx, filtered)

package concurrency

import (
	"context"
	"sync"
)

// --- Core Pipeline Functions ---

// Generate creates a channel that emits the provided values, then closes.
func Generate[T any](ctx context.Context, values ...T) <-chan T {
	out := make(chan T)
	go func() {
		defer close(out)
		for _, v := range values {
			select {
			case out <- v:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out
}

// GenerateFromSlice creates a channel from a slice.
func GenerateFromSlice[T any](ctx context.Context, slice []T) <-chan T {
	out := make(chan T)
	go func() {
		defer close(out)
		for _, v := range slice {
			select {
			case out <- v:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out
}

// Map applies a function to each element, propagating errors.
// If fn returns an error, the pipeline stops (via context cancellation from caller).
func Map[In, Out any](ctx context.Context, in <-chan In, fn func(context.Context, In) (Out, error)) (<-chan Out, <-chan error) {
	out := make(chan Out)
	errc := make(chan error, 1)
	go func() {
		defer close(out)
		defer close(errc)
		for v := range in {
			select {
			case <-ctx.Done():
				errc <- ctx.Err()
				return
			default:
			}
			result, err := fn(ctx, v)
			if err != nil {
				errc <- err
				return
			}
			select {
			case out <- result:
			case <-ctx.Done():
				errc <- ctx.Err()
				return
			}
		}
	}()
	return out, errc
}

// Filter passes through only elements that satisfy the predicate.
func Filter[T any](ctx context.Context, in <-chan T, pred func(T) bool) <-chan T {
	out := make(chan T)
	go func() {
		defer close(out)
		for v := range in {
			if !pred(v) {
				continue
			}
			select {
			case out <- v:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out
}

// ForEach applies a side-effecting function to each element. Blocks until all
// elements are processed or the context is cancelled.
func ForEach[T any](ctx context.Context, in <-chan T, fn func(T)) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case v, ok := <-in:
			if !ok {
				return nil
			}
			fn(v)
		}
	}
}

// Collect drains a channel into a slice.
func Collect[T any](ctx context.Context, in <-chan T) []T {
	var result []T
	for {
		select {
		case <-ctx.Done():
			return result
		case v, ok := <-in:
			if !ok {
				return result
			}
			result = append(result, v)
		}
	}
}

// --- Fan-Out / Fan-In ---

// FanOut distributes input across n workers, each running fn concurrently.
// Returns n output channels (one per worker).
func FanOut[In, Out any](ctx context.Context, in <-chan In, n int, fn func(context.Context, In) (Out, error)) ([]<-chan Out, <-chan error) {
	outs := make([]<-chan Out, n)
	errChans := make([]<-chan error, n)
	for i := range n {
		out, errc := Map(ctx, in, fn)
		outs[i] = out
		errChans[i] = errc
	}
	return outs, MergeErrorChans(ctx, errChans...)
}

// FanIn merges multiple channels into a single channel.
// The output channel is closed when all input channels are closed.
func FanIn[T any](ctx context.Context, channels ...<-chan T) <-chan T {
	var wg sync.WaitGroup
	out := make(chan T)

	for _, ch := range channels {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for v := range ch {
				select {
				case out <- v:
				case <-ctx.Done():
					return
				}
			}
		}()
	}

	go func() {
		wg.Wait()
		close(out)
	}()
	return out
}

// FanOutFanIn is a convenience function that fans out to n workers and merges results.
func FanOutFanIn[In, Out any](ctx context.Context, in <-chan In, n int, fn func(context.Context, In) (Out, error)) (<-chan Out, <-chan error) {
	outs, errc := FanOut(ctx, in, n, fn)
	return FanIn(ctx, outs...), errc
}

// --- Batch Processing ---

// Batch collects elements into slices of the given size.
// The last batch may be smaller than size.
func Batch[T any](ctx context.Context, in <-chan T, size int) <-chan []T {
	out := make(chan []T)
	go func() {
		defer close(out)
		batch := make([]T, 0, size)
		for {
			select {
			case <-ctx.Done():
				if len(batch) > 0 {
					out <- batch
				}
				return
			case v, ok := <-in:
				if !ok {
					if len(batch) > 0 {
						out <- batch
					}
					return
				}
				batch = append(batch, v)
				if len(batch) >= size {
					select {
					case out <- batch:
					case <-ctx.Done():
						return
					}
					batch = make([]T, 0, size)
				}
			}
		}
	}()
	return out
}

// --- Error Handling ---

// MergeErrorChans merges multiple error channels into one.
func MergeErrorChans(ctx context.Context, errChans ...<-chan error) <-chan error {
	var wg sync.WaitGroup
	merged := make(chan error)
	for _, ec := range errChans {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for err := range ec {
				if err != nil {
					select {
					case merged <- err:
					case <-ctx.Done():
						return
					}
				}
			}
		}()
	}
	go func() {
		wg.Wait()
		close(merged)
	}()
	return merged
}

// --- Utility ---

// Tee duplicates a channel into two output channels.
// Both consumers must read at roughly the same pace to avoid blocking.
func Tee[T any](ctx context.Context, in <-chan T) (<-chan T, <-chan T) {
	out1, out2 := make(chan T), make(chan T)
	go func() {
		defer close(out1)
		defer close(out2)
		for v := range in {
			// Send to both; handle case where one blocks
			o1, o2 := out1, out2
			for range 2 {
				select {
				case o1 <- v:
					o1 = nil
				case o2 <- v:
					o2 = nil
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out1, out2
}

// OrDone wraps a channel read with context cancellation.
func OrDone[T any](ctx context.Context, in <-chan T) <-chan T {
	out := make(chan T)
	go func() {
		defer close(out)
		for {
			select {
			case <-ctx.Done():
				return
			case v, ok := <-in:
				if !ok {
					return
				}
				select {
				case out <- v:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out
}

// Take reads at most n values from a channel.
func Take[T any](ctx context.Context, in <-chan T, n int) <-chan T {
	out := make(chan T)
	go func() {
		defer close(out)
		for i := range n {
			_ = i
			select {
			case <-ctx.Done():
				return
			case v, ok := <-in:
				if !ok {
					return
				}
				select {
				case out <- v:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out
}
