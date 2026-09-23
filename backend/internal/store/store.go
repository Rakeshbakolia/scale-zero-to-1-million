package store

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

const (
	listCacheVersionKey = "users:list:ver"
	listCacheTTL        = 60 * time.Second
)

type Store struct {
	write *pgxpool.Pool
	read  *pgxpool.Pool
	redis *redis.Client
}

type User struct {
	ID           int64     `json:"id"`
	Email        string    `json:"email"`
	DisplayName  *string   `json:"display_name,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
	PasswordHash string    `json:"-"`
}

type UserListResult struct {
	Users       []User `json:"users"`
	Page        int    `json:"page"`
	Limit       int    `json:"limit"`
	Total       int64  `json:"total"`
	TotalPages  int    `json:"total_pages"`
	NextAfterID *int64 `json:"next_after_id,omitempty"`
}

func Connect(ctx context.Context, primaryURL, replicaURL, redisURL string) (*Store, error) {
	write, err := pgxpool.New(ctx, primaryURL)
	if err != nil {
		return nil, fmt.Errorf("connect primary: %w", err)
	}
	if err := write.Ping(ctx); err != nil {
		write.Close()
		return nil, fmt.Errorf("ping primary: %w", err)
	}

	readURL := strings.TrimSpace(replicaURL)
	if readURL == "" {
		readURL = primaryURL
	}
	read, err := pgxpool.New(ctx, readURL)
	if err != nil {
		write.Close()
		return nil, fmt.Errorf("connect replica: %w", err)
	}
	if err := read.Ping(ctx); err != nil {
		read.Close()
		write.Close()
		return nil, fmt.Errorf("ping replica: %w", err)
	}

	s := &Store{write: write, read: read}
	if strings.TrimSpace(redisURL) != "" {
		opts, err := redis.ParseURL(redisURL)
		if err != nil {
			s.Close()
			return nil, fmt.Errorf("parse redis url: %w", err)
		}
		s.redis = redis.NewClient(opts)
		if err := s.redis.Ping(ctx).Err(); err != nil {
			s.Close()
			return nil, fmt.Errorf("ping redis: %w", err)
		}
	}
	if err := s.runMigrations(ctx); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() {
	if s.redis != nil {
		s.redis.Close()
	}
	s.write.Close()
	if s.read != s.write {
		s.read.Close()
	}
}

func (s *Store) Ping(ctx context.Context) error {
	if err := s.write.Ping(ctx); err != nil {
		return err
	}
	if err := s.read.Ping(ctx); err != nil {
		return err
	}
	if s.redis != nil {
		if err := s.redis.Ping(ctx).Err(); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) runMigrations(ctx context.Context) error {
	data, err := migrationFS.ReadFile("migrations/001_init.up.sql")
	if err != nil {
		return fmt.Errorf("read migration: %w", err)
	}
	_, err = s.write.Exec(ctx, string(data))
	if err != nil {
		return fmt.Errorf("apply migration: %w", err)
	}
	return nil
}

func (s *Store) CreateUser(ctx context.Context, email, passwordHash, displayName string) (User, error) {
	var display *string
	if strings.TrimSpace(displayName) != "" {
		display = &displayName
	}
	var u User
	err := s.write.QueryRow(ctx, `
		INSERT INTO users (email, password_hash, display_name)
		VALUES ($1, $2, $3)
		RETURNING id, email, display_name, created_at
	`, email, passwordHash, display).Scan(&u.ID, &u.Email, &u.DisplayName, &u.CreatedAt)
	if err != nil {
		return User{}, err
	}
	if s.redis != nil {
		s.redis.Incr(ctx, listCacheVersionKey)
	}
	return u, nil
}

func (s *Store) listCacheKey(ctx context.Context, page, limit int) (string, error) {
	ver, err := s.redis.Get(ctx, listCacheVersionKey).Int64()
	if err == redis.Nil {
		ver = 0
	} else if err != nil {
		return "", err
	}
	return fmt.Sprintf("users:list:v%d:page:%d:limit:%d", ver, page, limit), nil
}

func (s *Store) listCacheKeyAfter(ctx context.Context, afterID int64, limit int) (string, error) {
	ver, err := s.redis.Get(ctx, listCacheVersionKey).Int64()
	if err == redis.Nil {
		ver = 0
	} else if err != nil {
		return "", err
	}
	return fmt.Sprintf("users:list:v%d:after:%d:limit:%d", ver, afterID, limit), nil
}

// ListUsersAfter returns the next page using keyset (created_at, id) — no COUNT(*), safe for deep pages at ~1M rows.
func (s *Store) ListUsersAfter(ctx context.Context, afterID int64, limit int) (UserListResult, error) {
	if afterID < 0 {
		afterID = 0
	}

	if s.redis != nil && afterID > 0 {
		key, err := s.listCacheKeyAfter(ctx, afterID, limit)
		if err == nil {
			cached, err := s.redis.Get(ctx, key).Bytes()
			if err == nil {
				var result UserListResult
				if json.Unmarshal(cached, &result) == nil {
					return result, nil
				}
			}
		}
	}

	var rows pgxRows
	var err error
	if afterID == 0 {
		rows, err = s.read.Query(ctx, `
			SELECT id, email, display_name, created_at
			FROM users
			ORDER BY created_at DESC, id DESC
			LIMIT $1
		`, limit)
	} else {
		rows, err = s.read.Query(ctx, `
			SELECT id, email, display_name, created_at
			FROM users
			WHERE (created_at, id) < (
				SELECT created_at, id FROM users WHERE id = $1
			)
			ORDER BY created_at DESC, id DESC
			LIMIT $2
		`, afterID, limit)
	}
	if err != nil {
		return UserListResult{}, err
	}
	defer rows.Close()

	users, err := scanUsers(rows)
	if err != nil {
		return UserListResult{}, err
	}

	var nextAfter *int64
	if len(users) == limit {
		id := users[len(users)-1].ID
		nextAfter = &id
	}

	result := UserListResult{
		Users:       users,
		Page:        0,
		Limit:       limit,
		Total:       0,
		TotalPages:  0,
		NextAfterID: nextAfter,
	}
	if s.redis != nil && afterID > 0 {
		key, err := s.listCacheKeyAfter(ctx, afterID, limit)
		if err == nil {
			if b, err := json.Marshal(result); err == nil {
				s.redis.Set(ctx, key, b, listCacheTTL)
			}
		}
	}
	return result, nil
}

type pgxRows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
	Close()
}

func scanUsers(rows pgxRows) ([]User, error) {
	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Email, &u.DisplayName, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (s *Store) ListUsers(ctx context.Context, page, limit int) (UserListResult, error) {
	if page < 1 {
		page = 1
	}

	if s.redis != nil {
		key, err := s.listCacheKey(ctx, page, limit)
		if err == nil {
			cached, err := s.redis.Get(ctx, key).Bytes()
			if err == nil {
				var result UserListResult
				if json.Unmarshal(cached, &result) == nil {
					return result, nil
				}
			}
		}
	}

	offset := (page - 1) * limit

	var total int64
	if err := s.read.QueryRow(ctx, `SELECT COUNT(*) FROM users`).Scan(&total); err != nil {
		return UserListResult{}, err
	}

	rows, err := s.read.Query(ctx, `
		SELECT id, email, display_name, created_at
		FROM users
		ORDER BY created_at DESC, id DESC
		LIMIT $1 OFFSET $2
	`, limit, offset)
	if err != nil {
		return UserListResult{}, err
	}
	defer rows.Close()

	users, err := scanUsers(rows)
	if err != nil {
		return UserListResult{}, err
	}

	var nextAfter *int64
	if len(users) == limit {
		id := users[len(users)-1].ID
		nextAfter = &id
	}

	totalPages := int(total) / limit
	if int(total)%limit != 0 {
		totalPages++
	}
	if totalPages == 0 {
		totalPages = 1
	}

	result := UserListResult{
		Users:       users,
		Page:        page,
		Limit:       limit,
		Total:       total,
		TotalPages:  totalPages,
		NextAfterID: nextAfter,
	}
	if s.redis != nil {
		key, err := s.listCacheKey(ctx, page, limit)
		if err == nil {
			if b, err := json.Marshal(result); err == nil {
				s.redis.Set(ctx, key, b, listCacheTTL)
			}
		}
	}
	return result, nil
}

func IsUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return true
	}
	return err != nil && strings.Contains(err.Error(), "duplicate key")
}
