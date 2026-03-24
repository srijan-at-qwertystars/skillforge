// worker-pool.go — Production worker pool with configurable workers, job queue,
// results channel, graceful shutdown, and error handling.
//
// Copy into your project and customize the Job/Result types and ProcessFunc.
//
// Usage:
//   pool := NewWorkerPool[MyInput, MyOutput](Config{
//       Workers:   runtime.NumCPU(),
//       QueueSize: 1000,
//   })
//   pool.Start(ctx, func(ctx context.Context, input MyInput) (MyOutput, error) {
//       return transform(input), nil
//   })
//   pool.Submit(ctx, myInput)
//   // ...
//   results, err := pool.StopAndCollect()

package concurrency

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
)

// Config holds worker pool configuration.
type Config struct {
	Workers   int // number of concurrent workers (default: 4)
	QueueSize int // buffer size for job and result channels (default: 100)
}

func (c Config) withDefaults() Config {
	if c.Workers <= 0 {
		c.Workers = 4
	}
	if c.QueueSize <= 0 {
		c.QueueSize = 100
	}
	return c
}

// WorkerPool processes jobs concurrently with a fixed number of workers.
// It is generic over input type In and output type Out.
type WorkerPool[In, Out any] struct {
	cfg       Config
	jobs      chan job[In]
	results   chan Result[Out]
	wg        sync.WaitGroup
	started   atomic.Bool
	stopped   atomic.Bool
	processed atomic.Int64
	failed    atomic.Int64
}

type job[In any] struct {
	id    int
	input In
}

// Result holds the output of processing a single job.
type Result[Out any] struct {
	JobID int
	Value Out
	Err   error
}

// ProcessFunc defines the function signature for processing a single input.
type ProcessFunc[In, Out any] func(ctx context.Context, input In) (Out, error)

// NewWorkerPool creates a new worker pool with the given configuration.
func NewWorkerPool[In, Out any](cfg Config) *WorkerPool[In, Out] {
	cfg = cfg.withDefaults()
	return &WorkerPool[In, Out]{
		cfg:     cfg,
		jobs:    make(chan job[In], cfg.QueueSize),
		results: make(chan Result[Out], cfg.QueueSize),
	}
}

// Start launches worker goroutines that process jobs using the provided function.
// Start must be called exactly once.
func (p *WorkerPool[In, Out]) Start(ctx context.Context, fn ProcessFunc[In, Out]) error {
	if !p.started.CompareAndSwap(false, true) {
		return errors.New("worker pool already started")
	}

	for i := range p.cfg.Workers {
		p.wg.Add(1)
		go p.worker(ctx, i, fn)
	}
	return nil
}

func (p *WorkerPool[In, Out]) worker(ctx context.Context, id int, fn ProcessFunc[In, Out]) {
	defer p.wg.Done()

	for {
		select {
		case <-ctx.Done():
			// Drain remaining jobs on cancellation
			for j := range p.jobs {
				p.results <- Result[Out]{JobID: j.id, Err: ctx.Err()}
				p.failed.Add(1)
			}
			return
		case j, ok := <-p.jobs:
			if !ok {
				return // channel closed, shut down
			}
			out, err := p.safeProcess(ctx, fn, j.input)
			if err != nil {
				p.failed.Add(1)
			}
			p.processed.Add(1)
			select {
			case p.results <- Result[Out]{JobID: j.id, Value: out, Err: err}:
			case <-ctx.Done():
				return
			}
		}
	}
}

// safeProcess calls fn and recovers from panics.
func (p *WorkerPool[In, Out]) safeProcess(ctx context.Context, fn ProcessFunc[In, Out], input In) (out Out, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("worker panic: %v", r)
		}
	}()
	return fn(ctx, input)
}

// Submit sends a job to the pool. Blocks if the queue is full.
// Returns an error if the context is cancelled while waiting.
func (p *WorkerPool[In, Out]) Submit(ctx context.Context, id int, input In) error {
	if p.stopped.Load() {
		return errors.New("worker pool is stopped")
	}
	select {
	case p.jobs <- job[In]{id: id, input: input}:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("submit cancelled: %w", ctx.Err())
	}
}

// Results returns a read-only channel of results. Closed after Stop() completes.
func (p *WorkerPool[In, Out]) Results() <-chan Result[Out] {
	return p.results
}

// Stop signals no more jobs will be submitted and waits for all workers to finish.
// The results channel is closed after all workers exit. Safe to call once.
func (p *WorkerPool[In, Out]) Stop() {
	if !p.stopped.CompareAndSwap(false, true) {
		return
	}
	close(p.jobs)
	p.wg.Wait()
	close(p.results)
}

// StopAndCollect stops the pool and collects all remaining results.
func (p *WorkerPool[In, Out]) StopAndCollect() ([]Result[Out], error) {
	// Close jobs channel to signal workers to finish
	if !p.stopped.CompareAndSwap(false, true) {
		return nil, errors.New("worker pool already stopped")
	}
	close(p.jobs)
	p.wg.Wait()
	close(p.results)

	var results []Result[Out]
	var errs []error
	for r := range p.results {
		results = append(results, r)
		if r.Err != nil {
			errs = append(errs, r.Err)
		}
	}
	return results, errors.Join(errs...)
}

// Stats returns processing statistics.
func (p *WorkerPool[In, Out]) Stats() (processed, failed int64) {
	return p.processed.Load(), p.failed.Load()
}
