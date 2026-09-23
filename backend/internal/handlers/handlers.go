package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/scalelab/zero-to-million/backend/internal/config"
	"github.com/scalelab/zero-to-million/backend/internal/store"
	"golang.org/x/crypto/bcrypt"
)

type API struct {
	store  *store.Store
	config config.Config
}

func New(s *store.Store, cfg config.Config) *API {
	return &API{store: s, config: cfg}
}

type signupRequest struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	DisplayName string `json:"display_name"`
}

func (a *API) Health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (a *API) Ready(c *gin.Context) {
	if err := a.store.Ping(c.Request.Context()); err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "not_ready", "error": "database unavailable"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ready"})
}

func (a *API) Signup(c *gin.Context) {
	var req signupRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid json body"})
		return
	}
	email := strings.TrimSpace(strings.ToLower(req.Email))
	if email == "" || !strings.Contains(email, "@") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "valid email is required"})
		return
	}
	if len(req.Password) < 8 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "password must be at least 8 characters"})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "could not process password"})
		return
	}

	user, err := a.store.CreateUser(c.Request.Context(), email, string(hash), req.DisplayName)
	if err != nil {
		if store.IsUniqueViolation(err) {
			c.JSON(http.StatusConflict, gin.H{"error": "email already registered"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "could not create user"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"id":           user.ID,
		"email":        user.Email,
		"display_name": user.DisplayName,
		"created_at":   user.CreatedAt,
	})
}

func (a *API) ListUsers(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", strconv.Itoa(a.config.DefaultLimit)))
	if limit <= 0 {
		limit = a.config.DefaultLimit
	}
	if limit > a.config.MaxLimit {
		limit = a.config.MaxLimit
	}

	var result store.UserListResult
	var err error
	if c.Query("after_id") != "" {
		afterID, _ := strconv.ParseInt(c.Query("after_id"), 10, 64)
		result, err = a.store.ListUsersAfter(c.Request.Context(), afterID, limit)
	} else {
		result, err = a.store.ListUsers(c.Request.Context(), page, limit)
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "could not list users"})
		return
	}
	c.JSON(http.StatusOK, result)
}
