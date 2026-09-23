// Seed users for Phase 7 scale tests (run against primary DATABASE_URL).
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

func main() {
	target := flag.Int("target", 1_000_000, "total users to have in DB")
	batch := flag.Int("batch", 5000, "rows per COPY batch")
	flag.Parse()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL is required")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	var existing int64
	if err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM users`).Scan(&existing); err != nil {
		log.Fatalf("count: %v", err)
	}
	if existing >= int64(*target) {
		log.Printf("already have %d users (>=%d), nothing to do", existing, *target)
		return
	}
	start := int(existing)
	need := *target - start
	log.Printf("seeding %d users (existing %d → target %d)", need, start, *target)

	hash, err := bcrypt.GenerateFromPassword([]byte("seed-phase7-password"), bcrypt.MinCost)
	if err != nil {
		log.Fatalf("hash: %v", err)
	}
	hashStr := string(hash)

	t0 := time.Now()
	inserted := 0
	for inserted < need {
		n := min(*batch, need-inserted)
		base := start + inserted
		rows := make([][]any, n)
		for i := 0; i < n; i++ {
			id := base + i
			rows[i] = []any{
				fmt.Sprintf("seed-%d@phase7.example.com", id),
				hashStr,
				nil,
				time.Now().UTC().Add(-time.Duration(id) * time.Second),
			}
		}
		_, err := pool.CopyFrom(
			ctx,
			pgx.Identifier{"users"},
			[]string{"email", "password_hash", "display_name", "created_at"},
			pgx.CopyFromRows(rows),
		)
		if err != nil {
			log.Fatalf("copy at %d: %v", inserted, err)
		}
		inserted += n
		if inserted%50000 == 0 || inserted == need {
			log.Printf("  inserted %d / %d (%.1fs)", inserted, need, time.Since(t0).Seconds())
		}
	}
	log.Printf("done: +%d users in %s (total ~%d)", inserted, time.Since(t0).Round(time.Millisecond), *target)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
