package config

import (
	"os"
	"strconv"
)

type Config struct {
	Port               string
	DatabaseURL        string
	DatabaseReplicaURL string
	RedisURL           string
	AdminAPIKey        string
	CORSOrigins  []string
	DefaultLimit int
	MaxLimit     int
}

func Load() Config {
	limit, _ := strconv.Atoi(getEnv("DEFAULT_PAGE_LIMIT", "20"))
	maxLimit, _ := strconv.Atoi(getEnv("MAX_PAGE_LIMIT", "100"))

	origins := getEnv("CORS_ORIGINS", "http://localhost:5173")
	var cors []string
	for _, o := range splitComma(origins) {
		if o != "" {
			cors = append(cors, o)
		}
	}

	return Config{
		Port:         getEnv("PORT", "8080"),
		DatabaseURL:        getEnv("DATABASE_URL", "postgres://scalelab:scalelab@localhost:5433/scalelab?sslmode=disable"),
		DatabaseReplicaURL: getEnv("DATABASE_REPLICA_URL", ""),
		RedisURL:           getEnv("REDIS_URL", ""),
		AdminAPIKey:        getEnv("ADMIN_API_KEY", "dev-admin-key-change-me"),
		CORSOrigins:  cors,
		DefaultLimit: limit,
		MaxLimit:     maxLimit,
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitComma(s string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return out
}
