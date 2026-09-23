package main

import (
	"context"
	"log"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/scalelab/zero-to-million/backend/internal/config"
	"github.com/scalelab/zero-to-million/backend/internal/handlers"
	"github.com/scalelab/zero-to-million/backend/internal/middleware"
	"github.com/scalelab/zero-to-million/backend/internal/store"
)

func main() {
	cfg := config.Load()
	gin.SetMode(gin.ReleaseMode)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	db, err := store.Connect(ctx, cfg.DatabaseURL, cfg.DatabaseReplicaURL, cfg.RedisURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()

	api := handlers.New(db, cfg)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.RequestID())
	r.Use(middleware.CORS(cfg.CORSOrigins))

	r.GET("/health", api.Health)
	r.GET("/ready", api.Ready)

	v1 := r.Group("/api/v1")
	{
		v1.POST("/signup", api.Signup)
		admin := v1.Group("")
		admin.Use(middleware.AdminAuth(cfg.AdminAPIKey))
		admin.GET("/users", api.ListUsers)
	}

	addr := ":" + cfg.Port
	go func() {
		log.Printf("api listening on %s", addr)
		if err := r.Run(addr); err != nil {
			log.Printf("server stopped: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutting down")
	time.Sleep(100 * time.Millisecond)
}
